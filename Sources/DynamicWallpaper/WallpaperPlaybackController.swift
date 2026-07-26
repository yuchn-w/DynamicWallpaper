import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import IOKit.ps
import QuartzCore

@MainActor
final class WallpaperPlaybackController: ObservableObject {
    @Published private(set) var displays: [DisplayTarget] = []
    @Published var selectedDisplayIDs: Set<String> = [] {
        didSet { preferences.set(Array(selectedDisplayIDs), forKey: PreferenceKey.selectedDisplays) }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var currentVideoURL: URL?
    @Published private(set) var previewPlayer: AVPlayer?
    @Published var soundEnabled = false {
        didSet {
            player?.volume = soundEnabled ? videoVolume : 0
            preferences.set(soundEnabled, forKey: PreferenceKey.soundEnabled)
        }
    }
    @Published var videoVolume: Float = 0.3 {
        didSet {
            player?.volume = soundEnabled ? videoVolume : 0
            preferences.set(videoVolume, forKey: PreferenceKey.videoVolume)
        }
    }
    @Published var playbackRate: Float = 1 {
        didSet {
            if isPlaying { player?.rate = playbackRate }
            preferences.set(playbackRate, forKey: PreferenceKey.playbackRate)
        }
    }
    @Published var scalingMode: PlayerScalingMode = .fill {
        didSet {
            wallpaperWindows.values.forEach { $0.setScalingMode(scalingMode) }
            preferences.set(scalingMode.rawValue, forKey: PreferenceKey.scalingMode)
        }
    }
    @Published var qualityLimit: PlaybackQuality = .original {
        didSet {
            player?.items().forEach { configureQuality(for: $0) }
            preferences.set(qualityLimit.rawValue, forKey: PreferenceKey.qualityLimit)
        }
    }
    @Published var transitionDuration: Double = 0.35 {
        didSet {
            let clamped = min(max(transitionDuration, 0), 1.5)
            if clamped != transitionDuration {
                transitionDuration = clamped
                return
            }
            preferences.set(transitionDuration, forKey: PreferenceKey.transitionDuration)
        }
    }
    @Published var pauseOnLowPower = true {
        didSet {
            preferences.set(pauseOnLowPower, forKey: PreferenceKey.pauseOnLowPower)
            handlePowerStateChange()
        }
    }
    @Published var pauseOnBatteryPower = true {
        didSet {
            preferences.set(pauseOnBatteryPower, forKey: PreferenceKey.pauseOnBatteryPower)
            handlePowerSourceChange()
        }
    }
    @Published private(set) var isUsingBatteryPower = false
    @Published var reduceQualityOnLowPower = true {
        didSet {
            preferences.set(reduceQualityOnLowPower, forKey: PreferenceKey.reduceQualityOnLowPower)
            player?.items().forEach { configureQuality(for: $0) }
        }
    }
    @Published var pauseWhenOtherAppFullScreen = true {
        didSet {
            preferences.set(pauseWhenOtherAppFullScreen, forKey: PreferenceKey.pauseWhenFullScreen)
            handleWorkspaceContextChange()
        }
    }
    @Published var resumeAfterWake = true {
        didSet { preferences.set(resumeAfterWake, forKey: PreferenceKey.resumeAfterWake) }
    }
    @Published var dayNightScheduleEnabled = true {
        didSet {
            preferences.set(dayNightScheduleEnabled, forKey: PreferenceKey.dayNightScheduleEnabled)
            evaluateDayNightSchedule(force: dayNightScheduleEnabled)
            rescheduleDayNightTimer()
        }
    }
    @Published var activeDayNightPlaylistID: WallpaperPlaylist.ID? {
        didSet {
            preferences.set(activeDayNightPlaylistID?.uuidString, forKey: PreferenceKey.activeDayNightPlaylist)
            evaluateDayNightSchedule(force: true)
        }
    }
    @Published private(set) var activeSchedulePeriod: WallpaperSchedulePeriod = .day
    @Published private(set) var scheduleStatus = "尚未設定日夜播放清單"
    @Published private(set) var status = "尚未播放"

    private var wallpaperWindows: [String: WallpaperWindow] = [:]
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var observers: [NSObjectProtocol] = []
    private var scheduleCancellables: Set<AnyCancellable> = []
    private let preferences = UserDefaults.standard
    private var library: WallpaperLibrary?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var scheduleTimer: Timer?
    private var wasPlayingBeforeSleep = false
    private var pausedForBatteryPower = false
    private var pausedForLowPower = false
    private var pausedForFullScreen = false
    private var pausedForNoDisplay = false

    init() {
        let savedDisplays = preferences.stringArray(forKey: PreferenceKey.selectedDisplays)
        selectedDisplayIDs = Set(savedDisplays ?? [])
        soundEnabled = preferences.object(forKey: PreferenceKey.soundEnabled) as? Bool ?? false
        videoVolume = preferences.object(forKey: PreferenceKey.videoVolume) == nil
            ? 0.3 : preferences.float(forKey: PreferenceKey.videoVolume)
        playbackRate = preferences.object(forKey: PreferenceKey.playbackRate) == nil
            ? 1 : preferences.float(forKey: PreferenceKey.playbackRate)
        scalingMode = PlayerScalingMode(
            rawValue: preferences.string(forKey: PreferenceKey.scalingMode) ?? ""
        ) ?? .fill
        qualityLimit = PlaybackQuality(
            rawValue: preferences.string(forKey: PreferenceKey.qualityLimit) ?? ""
        ) ?? .original
        transitionDuration = preferences.object(forKey: PreferenceKey.transitionDuration) as? Double ?? 0.35
        pauseOnBatteryPower = preferences.object(forKey: PreferenceKey.pauseOnBatteryPower) as? Bool ?? true
        pauseOnLowPower = preferences.object(forKey: PreferenceKey.pauseOnLowPower) as? Bool ?? true
        reduceQualityOnLowPower = preferences.object(forKey: PreferenceKey.reduceQualityOnLowPower) as? Bool ?? true
        pauseWhenOtherAppFullScreen = preferences.object(forKey: PreferenceKey.pauseWhenFullScreen) as? Bool ?? true
        resumeAfterWake = preferences.object(forKey: PreferenceKey.resumeAfterWake) as? Bool ?? true
        dayNightScheduleEnabled = preferences.object(forKey: PreferenceKey.dayNightScheduleEnabled) as? Bool ?? true
        activeDayNightPlaylistID = preferences.string(forKey: PreferenceKey.activeDayNightPlaylist)
            .flatMap(UUID.init(uuidString:))
        isUsingBatteryPower = Self.readBatteryPowerState()

        let needsDisplayMigration = savedDisplays?.allSatisfy { UInt32($0) != nil } ?? false
        refreshDisplays(selectDefaultIfNeeded: savedDisplays == nil || needsDisplayMigration)
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenChange() }
        })

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreensDidSleep() }
        })

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreensDidWake() }
        })

        observers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePowerStateChange() }
        })

        let powerContext = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<WallpaperPlaybackController>
                .fromOpaque(context)
                .takeUnretainedValue()
            Task { @MainActor in controller.handlePowerSourceChange() }
        }, powerContext)?.takeRetainedValue() {
            powerSourceRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        for name in [
            Notification.Name.NSSystemClockDidChange,
            Notification.Name.NSSystemTimeZoneDidChange,
            Notification.Name.NSCalendarDayChanged
        ] {
            observers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.evaluateDayNightSchedule(force: true)
                    self?.rescheduleDayNightTimer()
                }
            })
        }

        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleWorkspaceContextChange() }
            })
        }
    }

    deinit {
        scheduleTimer?.invalidate()
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .commonModes)
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func configureLibrary(_ library: WallpaperLibrary) {
        guard self.library !== library else { return }
        self.library = library
        if activeDayNightPlaylistID == nil || !library.playlists.contains(where: {
            $0.id == activeDayNightPlaylistID && $0.kind == .dayNight
        }) {
            activeDayNightPlaylistID = library.playlists.first(where: { $0.kind == .dayNight })?.id
        }
        scheduleCancellables.removeAll()

        Publishers.CombineLatest(library.$items, library.$playlists)
            .dropFirst()
            .debounce(for: .milliseconds(180), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.evaluateDayNightSchedule(force: false)
            }
            .store(in: &scheduleCancellables)

        evaluateDayNightSchedule(force: true)
        rescheduleDayNightTimer()
    }

    func toggleDisplay(_ id: String) {
        setDisplayEnabled(id, enabled: !selectedDisplayIDs.contains(id))
    }

    func setDisplayEnabled(_ id: String, enabled: Bool) {
        let wasPlaying = isPlaying
        if enabled {
            selectedDisplayIDs.insert(id)
        } else {
            selectedDisplayIDs.remove(id)
        }

        updateActiveDisplays()
        if selectedDisplayIDs.isEmpty {
            pausedForNoDisplay = wasPlaying
            pause(reason: "沒有選擇播放顯示器，桌布已暫停")
        } else if enabled, pausedForNoDisplay {
            pausedForNoDisplay = false
            resume()
        } else {
            updatePlaybackStatus()
        }
    }

    func apply(videoURL: URL) {
        let availableIDs = Set(displays.map(\.id))
        guard !selectedDisplayIDs.intersection(availableIDs).isEmpty else {
            status = "請先選擇至少一個顯示器"
            return
        }

        let previousPlayer = player
        let previousLooper = looper
        currentVideoURL = videoURL

        let item = AVPlayerItem(url: videoURL)
        item.preferredForwardBufferDuration = 2
        configureQuality(for: item)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        queuePlayer.actionAtItemEnd = .none
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
        queuePlayer.volume = soundEnabled ? videoVolume : 0
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        player = queuePlayer
        previewPlayer = queuePlayer

        let screenMap = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { (screenID($0), $0) })
        let unavailableIDs = Set(wallpaperWindows.keys).subtracting(selectedDisplayIDs)
        for id in unavailableIDs {
            wallpaperWindows[id]?.deactivate()
        }

        for id in selectedDisplayIDs {
            guard let screen = screenMap[id] else { continue }
            if let wallpaperWindow = wallpaperWindows[id] {
                wallpaperWindow.replacePlayer(queuePlayer, transitionDuration: transitionDuration)
            } else {
                let wallpaperWindow = WallpaperWindow(
                    screen: screen,
                    player: queuePlayer,
                    scalingMode: scalingMode
                )
                wallpaperWindows[id] = wallpaperWindow
                wallpaperWindow.show()
            }
        }

        // 每個顯示器只保留一個桌布視窗；播放器交接後即可釋放舊解碼器。
        previousPlayer?.pause()
        previousLooper?.disableLooping()

        if pauseOnBatteryPower && isUsingBatteryPower {
            pausedForBatteryPower = true
            isPlaying = false
            status = "使用電池供電中，桌布已暫停"
        } else if pauseOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled {
            pausedForLowPower = true
            isPlaying = false
            status = "低耗電模式中，桌布已暫停"
        } else if pauseWhenOtherAppFullScreen && isAnotherAppFullScreen() {
            pausedForFullScreen = true
            isPlaying = false
            status = "其他 App 正在全螢幕顯示，桌布保持暫停"
        } else {
            queuePlayer.playImmediately(atRate: playbackRate)
            isPlaying = true
            updatePlaybackStatus()
        }
    }

    func isCurrent(_ url: URL) -> Bool {
        currentVideoURL?.standardizedFileURL == url.standardizedFileURL
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause(reason: String = "已暫停") {
        guard player != nil else { return }
        player?.pause()
        isPlaying = false
        status = reason
    }

    func resume() {
        guard player != nil else { return }
        if pauseOnBatteryPower && isUsingBatteryPower {
            status = "使用電池供電中，保持暫停"
            return
        }
        if pauseOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled {
            status = "低耗電模式中，保持暫停"
            return
        }
        if pauseWhenOtherAppFullScreen && isAnotherAppFullScreen() {
            pausedForFullScreen = true
            status = "其他 App 正在全螢幕顯示，保持暫停"
            return
        }
        player?.playImmediately(atRate: playbackRate)
        isPlaying = true
        status = "正在播放"
    }

    func stop(clearCurrent: Bool = true) {
        player?.pause()
        looper?.disableLooping()
        wallpaperWindows.values.forEach { $0.deactivate() }
        player = nil
        looper = nil
        previewPlayer = nil
        pausedForBatteryPower = false
        pausedForLowPower = false
        pausedForFullScreen = false
        pausedForNoDisplay = false
        isPlaying = false
        if clearCurrent { currentVideoURL = nil }
        status = "已停止，顯示 macOS 原桌布"
    }

    private func refreshDisplays(selectDefaultIfNeeded: Bool = false) {
        displays = NSScreen.screens.map { screen in
            let name = screen.localizedName
            return DisplayTarget(
                id: screenID(screen),
                name: name,
                width: Int(screen.frame.width * screen.backingScaleFactor),
                height: Int(screen.frame.height * screen.backingScaleFactor),
                isBuiltIn: name.localizedCaseInsensitiveContains("內建") ||
                    name.localizedCaseInsensitiveContains("built-in")
            )
        }

        let available = Set(displays.map(\.id))
        if selectDefaultIfNeeded {
            selectedDisplayIDs.formIntersection(available)
        }
        if selectedDisplayIDs.isEmpty, selectDefaultIfNeeded {
            if let builtIn = displays.first(where: \.isBuiltIn) {
                selectedDisplayIDs = [builtIn.id]
            } else if let first = displays.first {
                selectedDisplayIDs = [first.id]
            }
        }
    }

    private func handleScreenChange() {
        let wasPlaying = isPlaying
        refreshDisplays()
        updateActiveDisplays(rebuildExisting: true)
        if wallpaperWindows.isEmpty, player != nil, wasPlaying {
            pausedForNoDisplay = true
            pause(reason: "已選顯示器目前未連接，桌布已暫停")
        } else if !wallpaperWindows.isEmpty, pausedForNoDisplay {
            pausedForNoDisplay = false
            resume()
        } else {
            updatePlaybackStatus()
        }
    }

    private func updateActiveDisplays(rebuildExisting: Bool = false) {
        let validIDs = selectedDisplayIDs.intersection(displays.map(\.id))
        for id in Set(wallpaperWindows.keys).subtracting(validIDs) {
            wallpaperWindows[id]?.deactivate()
        }

        guard let player else { return }
        let screenMap = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { (screenID($0), $0) })
        for id in validIDs {
            guard let screen = screenMap[id] else { continue }
            if let wallpaperWindow = wallpaperWindows[id] {
                wallpaperWindow.update(screen: screen)
                wallpaperWindow.replacePlayer(player, transitionDuration: 0)
                wallpaperWindow.show()
            } else {
                let wallpaperWindow = WallpaperWindow(screen: screen, player: player, scalingMode: scalingMode)
                wallpaperWindows[id] = wallpaperWindow
                wallpaperWindow.show()
            }
        }
    }

    private func updatePlaybackStatus() {
        guard currentVideoURL != nil else { return }
        if selectedDisplayIDs.isEmpty {
            status = "未選擇播放顯示器"
        } else if isPlaying {
            status = "正在 \(wallpaperWindows.count) 個顯示器播放"
        }
    }

    private func handlePowerStateChange() {
        player?.items().forEach { configureQuality(for: $0) }
        if pauseOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled {
            pausedForLowPower = isPlaying
            pause(reason: "低耗電模式中，桌布已自動暫停")
        } else if pausedForLowPower {
            pausedForLowPower = false
            resume()
        }
    }

    private func handlePowerSourceChange() {
        isUsingBatteryPower = Self.readBatteryPowerState()

        if pauseOnBatteryPower && isUsingBatteryPower {
            if isPlaying {
                pausedForBatteryPower = true
                pause(reason: "已切換為電池供電，桌布已自動暫停")
            }
        } else if pausedForBatteryPower {
            pausedForBatteryPower = false
            resume()
        }
    }

    private func handleWorkspaceContextChange() {
        guard pauseWhenOtherAppFullScreen else {
            if pausedForFullScreen {
                pausedForFullScreen = false
                resume()
            }
            return
        }

        if isAnotherAppFullScreen() {
            if isPlaying {
                pausedForFullScreen = true
                pause(reason: "其他 App 進入全螢幕，桌布已暫停")
            }
        } else if pausedForFullScreen {
            pausedForFullScreen = false
            resume()
        }
    }

    private func handleScreensDidSleep() {
        wasPlayingBeforeSleep = isPlaying
        pause(reason: "螢幕休眠時已自動暫停")
    }

    private func handleScreensDidWake() {
        handlePowerSourceChange()
        evaluateDayNightSchedule(force: true)
        rescheduleDayNightTimer()
        guard resumeAfterWake, wasPlayingBeforeSleep else { return }
        wasPlayingBeforeSleep = false
        resume()
    }

    private func configureQuality(for item: AVPlayerItem) {
        if reduceQualityOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled {
            item.preferredMaximumResolution = PlaybackQuality.fullHD.maximumResolution
        } else {
            item.preferredMaximumResolution = qualityLimit.maximumResolution
        }
    }

    private func isAnotherAppFullScreen() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else { return false }

        let screenSizes = NSScreen.screens.map { $0.frame.size }
        return windowList.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == frontmost.processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"],
                  let height = bounds["Height"] else { return false }
            return screenSizes.contains {
                abs($0.width - width) < 4 && abs($0.height - height) < 4
            }
        }
    }

    private func evaluateDayNightSchedule(force: Bool) {
        let now = Date()
        let period = DayNightScheduleLogic.period(at: now)
        activeSchedulePeriod = period

        guard dayNightScheduleEnabled else {
            scheduleStatus = "日夜排程已關閉"
            return
        }
        guard let library else {
            scheduleStatus = "正在載入播放清單"
            return
        }

        let scheduledItems = library.scheduledItems(
            in: activeDayNightPlaylistID,
            period: period
        )
        guard !scheduledItems.isEmpty else {
            scheduleStatus = "\(period.rawValue)時段尚未加入壁紙"
            return
        }

        let index = DayNightScheduleLogic.dailyRotationIndex(
            at: now,
            period: period,
            itemCount: scheduledItems.count
        )
        let item = scheduledItems[index]
        scheduleStatus = "\(period.rawValue)・今日播放「\(item.title)」"

        if force || !isCurrent(item.fileURL) {
            apply(videoURL: item.fileURL)
        }
    }

    private func rescheduleDayNightTimer() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        guard dayNightScheduleEnabled else { return }

        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let hour = calendar.component(.hour, from: now)
        let targetHour = hour < 6 ? 6 : (hour < 18 ? 18 : 6)
        let dayOffset = hour >= 18 ? 1 : 0
        guard let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: now),
              let boundary = calendar.date(
                bySettingHour: targetHour,
                minute: 0,
                second: 0,
                of: targetDay
              ) else { return }

        let timer = Timer(fire: boundary, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateDayNightSchedule(force: true)
                self?.rescheduleDayNightTimer()
            }
        }
        scheduleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func readBatteryPowerState() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return false
        }
        return (source as String) == kIOPSBatteryPowerValue
    }
}

private enum PreferenceKey {
    static let selectedDisplays = "播放設定.顯示器"
    static let soundEnabled = "播放設定.聲音"
    static let videoVolume = "播放設定.音量"
    static let playbackRate = "播放設定.速度"
    static let scalingMode = "播放設定.縮放"
    static let qualityLimit = "播放設定.畫質"
    static let transitionDuration = "播放設定.轉場秒數"
    static let pauseOnBatteryPower = "播放設定.電池供電暫停"
    static let pauseOnLowPower = "播放設定.低耗電暫停"
    static let reduceQualityOnLowPower = "播放設定.低耗電降畫質"
    static let pauseWhenFullScreen = "播放設定.全螢幕暫停"
    static let resumeAfterWake = "播放設定.喚醒續播"
    static let dayNightScheduleEnabled = "播放設定.日夜排程"
    static let activeDayNightPlaylist = "播放設定.目前日夜播放清單"
}

private func screenID(_ screen: NSScreen) -> String {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    if let number = screen.deviceDescription[key] as? NSNumber {
        let displayID = CGDirectDisplayID(number.uint32Value)
        if let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) {
            let uuid = unmanagedUUID.takeRetainedValue()
            return CFUUIDCreateString(nil, uuid) as String
        }
    }
    return screen.localizedName
}

@MainActor
private final class WallpaperWindow {
    private let window: NSWindow
    private let playerLayer: AVPlayerLayer
    private var isClosed = false

    init(screen: NSScreen, player: AVPlayer, scalingMode: PlayerScalingMode) {
        let contentView = NSView(frame: screen.frame)
        contentView.wantsLayer = true
        contentView.layer = CALayer()
        contentView.layer?.backgroundColor = NSColor.black.cgColor

        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = scalingMode == .fill ? .resizeAspectFill : .resizeAspect
        playerLayer.frame = contentView.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        contentView.layer?.addSublayer(playerLayer)

        window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentView = contentView
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.setFrame(screen.frame, display: true)
    }

    func setScalingMode(_ mode: PlayerScalingMode) {
        playerLayer.videoGravity = mode == .fill ? .resizeAspectFill : .resizeAspect
    }

    func show() {
        guard !isClosed else { return }
        window.alphaValue = 1
        window.orderFrontRegardless()
    }

    func update(screen: NSScreen) {
        guard !isClosed else { return }
        window.setFrame(screen.frame, display: false)
        playerLayer.frame = window.contentView?.bounds ?? .zero
    }

    func replacePlayer(_ player: AVPlayer, transitionDuration: Double) {
        guard !isClosed else { return }
        playerLayer.removeAllAnimations()
        if transitionDuration > 0 {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = transitionDuration
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            playerLayer.add(transition, forKey: "桌布切換")
        }
        playerLayer.player = player
    }

    func deactivate() {
        guard !isClosed else { return }
        window.contentView?.layer?.removeAllAnimations()
        playerLayer.removeAllAnimations()
        playerLayer.player = nil
        window.orderOut(nil)
    }
}
