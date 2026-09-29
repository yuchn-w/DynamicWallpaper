import AppKit
import Combine
import Foundation

enum AutoHDRMode: String, CaseIterable, Identifiable {
    case off
    case auto
    case on

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .off: return "OFF"
        case .auto: return "AUTO"
        case .on: return "ON"
        }
    }
}

enum AutoHDRSourceState: String {
    case inactive
    case checking
    case hdr
    case sdr
    case unknown
}


@MainActor
protocol HDRDisplayControlling: AnyObject {
    var isExternalHDRAvailable: Bool { get }
    var isExternalHDREnabled: Bool { get }
    var targetDisplayName: String { get }
    var desiredHDRState: Bool? { get }
    var lastErrorMessage: String? { get }
    func refresh()
    func cancelPending()
    func setHDR(_ enabled: Bool, completion: @escaping (Result<Bool, Error>) -> Void)
}

/// Only this layer arbitrates sources. It never references the wallpaper renderer.
@MainActor
final class AutoHDRController: ObservableObject {
    @Published private(set) var mode: AutoHDRMode
    @Published private(set) var sourceState: AutoHDRSourceState = .inactive
    @Published private(set) var dynamicRange: String?
    @Published private(set) var currentURL = ""
    @Published private(set) var currentVideoID = ""
    @Published private(set) var metadataDetail = "—"
    @Published private(set) var browserStatus = "尚未初始化"
    @Published private(set) var lastDecision = "尚未初始化"
    @Published private(set) var lastAction = "尚未切換 HDR"
    @Published private(set) var lastError: String?

    let displayController: HDRDisplayControlling
    private let browserMonitor: YouTubeBrowserMonitoring
    private let metadataProvider: YouTubeMetadataProviding
    private let preferences: UserDefaults
    private let graceDelay: UInt64
    private let stabilityDelay: UInt64
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pendingSDROffTask: Task<Void, Never>?
    private var stableContextTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var activeContext: YouTubeWatchContext?
    private var proposedContext: YouTubeWatchContext?
    private var generation = 0
    private var commandGeneration = 0
    private var hasStarted = false
    private var isSleeping = false
    private var initialized = false
    private var immediateReconcile = true
    private var diagnosticEvents: [String] = []

    init(displayController: HDRDisplayControlling,
         browserMonitor: YouTubeBrowserMonitoring? = nil,
         metadataProvider: YouTubeMetadataProviding = YTDLPMetadataProvider(),
         preferences: UserDefaults = .standard,
         graceDelay: UInt64 = 5_000_000_000,
         stabilityDelay: UInt64 = 400_000_000,
         observeLifecycle: Bool = true) {
        self.displayController = displayController
        self.browserMonitor = browserMonitor ?? YouTubeBrowserMonitor()
        self.metadataProvider = metadataProvider
        self.preferences = preferences
        self.graceDelay = graceDelay
        self.stabilityDelay = stabilityDelay
        mode = AutoHDRMode(rawValue: preferences.string(forKey: "AutoHDR.mode") ?? "") ?? .off
        guard observeLifecycle else { return }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.scheduleReconcile(after: 1.5) }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification) { $0.handleSleep() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification) { $0.handleWake() }
    }

    deinit {
        observers.forEach { $0.0.removeObserver($0.1) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (AutoHDRController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self { action(self) } }
        }
        observers.append((center, token))
    }

    var statusText: String {
        if let error = displayController.lastErrorMessage, !displayController.isExternalHDRAvailable {
            return error.contains("指定") ? "指定顯示器未連接" : "顯示器暫時無法使用"
        }
        switch mode {
        case .off: return "SDR · 手動關閉"
        case .on: return displayController.isExternalHDREnabled ? "HDR · 手動開啟" : "HDR · 等待顯示器"
        case .auto:
            switch sourceState {
            case .inactive: return initialized ? "SDR · 沒有正式 YouTube 影片" : "正在檢查 YouTube…"
            case .checking: return "Checking YouTube…"
            case .hdr: return "YouTube · \(dynamicRange ?? "HDR")"
            case .sdr: return "YouTube · SDR"
            case .unknown: return "YouTube · Unknown"
            }
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        displayController.refresh()
        if mode == .auto { beginAuto() }
        else { requestHDR(mode == .on, reason: "啟動 \(mode.shortTitle)") }
    }

    func refresh() {
        displayController.refresh()
        if mode == .auto, !isSleeping { browserMonitor.pollNow() }
    }

    func setMode(_ newMode: AutoHDRMode) {
        guard mode != newMode else { return }
        invalidateSource()
        browserMonitor.stop()
        displayController.cancelPending()
        mode = newMode
        preferences.set(newMode.rawValue, forKey: "AutoHDR.mode")
        if newMode == .auto {
            beginAuto()
        } else {
            sourceState = .inactive
            decide("手動 \(newMode.shortTitle)：立即要求 HDR \(newMode == .on ? "ON" : "OFF")")
            requestHDR(newMode == .on, reason: "手動 \(newMode.shortTitle)")
        }
    }

    private func invalidateSource() {
        generation &+= 1
        commandGeneration &+= 1
        pendingSDROffTask?.cancel()
        pendingSDROffTask = nil
        stableContextTask?.cancel()
        stableContextTask = nil
        reloadTask?.cancel()
        metadataProvider.cancelAll()
        activeContext = nil
        proposedContext = nil
        currentVideoID = ""
        dynamicRange = nil
        initialized = false
    }

    private func beginAuto() {
        guard !isSleeping else { return }
        immediateReconcile = true
        initialized = false
        sourceState = .checking
        decide("初始化 AUTO，讀取正式 Watch Session 後才決定 HDR")
        metadataProvider.warmup()
        browserMonitor.start { [weak self] snapshot in self?.consume(snapshot: snapshot) }
    }

    // Internal for deterministic lifecycle/session regression tests.
    func consume(snapshot: BrowserTabSnapshot) {
        guard mode == .auto, !isSleeping else { return }
        browserStatus = snapshot.errorMessage ?? "\(snapshot.browser.title) 已連線"
        currentURL = snapshot.urlString ?? ""
        if let error = snapshot.errorMessage {
            guard sourceState != .unknown || lastError != error else { return }
            stableContextTask?.cancel()
            proposedContext = nil
            activeContext = nil
            generation &+= 1
            metadataProvider.cancelAll()
            sourceState = .unknown
            initialized = true
            lastError = error
            decide("瀏覽器讀取失敗：\(error)，5 秒後安全回 SDR")
            scheduleSDROff(reason: "Browser Unknown")
            return
        }
        guard let context = YouTubeWatchContext(snapshot: snapshot) else {
            // Do not restart the 5s deadline on every 1s browser poll.
            guard !initialized || activeContext != nil || proposedContext != nil || sourceState != .inactive else { return }
            generation &+= 1
            stableContextTask?.cancel()
            stableContextTask = nil
            proposedContext = nil
            activeContext = nil
            metadataProvider.cancelAll()
            currentVideoID = ""
            dynamicRange = nil
            sourceState = .inactive
            initialized = true
            lastError = nil
            decide("沒有正式 YouTube Watch Session")
            reconcileSDR(reason: "沒有正式 Watch Session")
            return
        }
        if proposedContext == nil, activeContext?.identity == context.identity {
            activeContext = context
            return
        }
        if proposedContext?.identity == context.identity { return }
        stableContextTask?.cancel()
        pendingSDROffTask?.cancel()
        pendingSDROffTask = nil
        proposedContext = context
        sourceState = .checking
        generation &+= 1
        let token = generation
        decide("等待 \(context.browser.title) Watch URL 穩定，保持目前 HDR")
        stableContextTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.stabilityDelay)
            guard !Task.isCancelled, token == self.generation, self.mode == .auto, !self.isSleeping else { return }
            self.activeContext = context
            self.proposedContext = nil
            self.currentVideoID = context.videoID
            self.initialized = true
            self.dynamicRange = nil
            self.metadataDetail = "Checking"
            self.metadataProvider.lookup(videoID: context.videoID) { [weak self] result in
                Task { @MainActor in self?.consume(result: result, token: token) }
            }
        }
    }

    private func consume(result: YouTubeMetadataResult, token: Int) {
        guard mode == .auto, !isSleeping, token == generation,
              result.videoID == activeContext?.videoID else { return }
        dynamicRange = result.dynamicRange
        metadataDetail = result.cacheHit ? "Hit" : "Miss"
        lastError = result.failureReason
        switch result.state {
        case .hdr:
            sourceState = .hdr
            immediateReconcile = false
            pendingSDROffTask?.cancel()
            pendingSDROffTask = nil
            decide("\(result.videoID) = \(dynamicRange ?? "HDR") · Cache \(metadataDetail)，保持或開啟 HDR")
            requestHDR(true, reason: "YouTube \(dynamicRange ?? "HDR")")
        case .sdr:
            sourceState = .sdr
            decide("\(result.videoID) = SDR · Cache \(metadataDetail)")
            reconcileSDR(reason: "YouTube SDR")
        case .unknown:
            sourceState = .unknown
            immediateReconcile = false
            decide("Metadata Unknown：\(result.detail)，5 秒後安全回 SDR")
            scheduleSDROff(reason: "Metadata Unknown")
        }
    }

    private func reconcileSDR(reason: String) {
        if immediateReconcile {
            immediateReconcile = false
            requestHDR(false, reason: "首次仲裁：\(reason)")
        } else { scheduleSDROff(reason: reason) }
    }

    private func scheduleSDROff(reason: String) {
        pendingSDROffTask?.cancel()
        let token = generation
        pendingSDROffTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.graceDelay)
            guard !Task.isCancelled, token == self.generation, self.mode == .auto, !self.isSleeping,
                  [.sdr, .unknown, .inactive].contains(self.sourceState) else { return }
            self.pendingSDROffTask = nil
            self.requestHDR(false, reason: reason)
        }
    }

    private func requestHDR(_ enabled: Bool, reason: String) {
        guard !isSleeping else { return }
        commandGeneration &+= 1
        let command = commandGeneration
        let context = activeContext
        let shouldReload = mode == .auto && sourceState == .hdr && enabled
        lastAction = "要求 HDR \(enabled ? "ON" : "OFF")：\(reason)"
        record(lastAction)
        displayController.setHDR(enabled) { [weak self] result in
            guard let self, command == self.commandGeneration, !self.isSleeping else { return }
            switch result {
            case .success(let changed):
                if self.sourceState != .unknown { self.lastError = nil }
                self.lastAction = changed ? "HDR \(enabled ? "ON" : "OFF") 已切換並驗證" : "HDR 已是 \(enabled ? "ON" : "OFF")，不重複切換"
                self.record(self.lastAction)
                if changed, shouldReload, let context { self.reloadAfterHDR(context: context, command: command) }
            case .failure(let error):
                self.lastError = error.localizedDescription
                self.lastAction = "HDR 切換失敗：\(error.localizedDescription)"
                self.record(self.lastAction)
            }
        }
    }

    private func reloadAfterHDR(context: YouTubeWatchContext, command: Int) {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled, !self.isSleeping, self.mode == .auto,
                  command == self.commandGeneration, self.sourceState == .hdr,
                  self.activeContext?.identity == context.identity,
                  self.displayController.isExternalHDRAvailable,
                  self.displayController.isExternalHDREnabled else { return }
            self.browserMonitor.reloadWatchTab(context: context) { [weak self] error in
                guard let self else { return }
                if let error { self.lastError = error; self.record("Reload 失敗：\(error)") }
                else { self.record("SDR→HDR 已驗證，\(context.videoID) Watch Tab 單次 Reload 成功") }
            }
        }
    }

    private func scheduleReconcile(after delay: TimeInterval) {
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isSleeping else { return }
            self.displayController.refresh()
            guard self.displayController.isExternalHDRAvailable else { return }
            if self.mode != .auto {
                if self.displayController.isExternalHDREnabled != (self.mode == .on) {
                    self.requestHDR(self.mode == .on, reason: "顯示器重新連接")
                }
            } else {
                self.browserMonitor.pollNow()
                // Source remains authoritative; never let old desired state override Checking.
                if self.sourceState == .hdr, !self.displayController.isExternalHDREnabled {
                    self.requestHDR(true, reason: "重新連接，恢復 HDR Watch Session")
                } else if [.sdr, .inactive].contains(self.sourceState),
                          self.initialized, self.pendingSDROffTask == nil,
                          self.displayController.isExternalHDREnabled {
                    self.requestHDR(false, reason: "重新連接，恢復 SDR")
                }
            }
        }
    }

    func handleSleep() {
        isSleeping = true
        browserMonitor.stop()
        invalidateSource()
        displayController.cancelPending()
        wakeTask?.cancel()
        decide("睡眠：暫停偵測與切換，保留系統 HDR")
    }

    func handleWake() {
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isSleeping = false
            self.displayController.refresh()
            if self.mode == .auto { self.beginAuto() }
            else { self.requestHDR(self.mode == .on, reason: "喚醒後重新仲裁") }
        }
    }

    func diagnosticsText() -> String {
        let info = metadataProvider.diagnostics()
        return [
            "Mode: \(mode.shortTitle)", "Target Display: \(displayController.targetDisplayName)",
            "Actual HDR: \(displayController.isExternalHDRAvailable ? (displayController.isExternalHDREnabled ? "ON" : "OFF") : "Unavailable")",
            "Desired HDR: \(displayController.desiredHDRState.map { $0 ? "ON" : "OFF" } ?? "—")",
            "Browser: \(activeContext?.browser.title ?? browserStatus)",
            "Current URL: \(currentURL)", "Video ID: \(currentVideoID)",
            "yt-dlp Source: \(info.source)", "Path: \(info.path)", "Version: \(info.version)",
            "Version Result: \(info.versionResult)", "Metadata State: \(sourceState.rawValue)",
            "Dynamic Range: \(dynamicRange ?? (sourceState == .sdr ? "SDR" : "Unknown"))",
            "Cache: \(metadataDetail)", "Metadata Result: \(info.metadataResult)",
            "Metadata Processes This Launch: \(info.metadataLaunchCount)",
            "Metadata Exit Code: \(info.metadataExitCode.map(String.init) ?? "—")",
            "Last HDR Action: \(lastAction)",
            "Last Error: \(lastError ?? displayController.lastErrorMessage ?? "None")",
            "Last Decision: \(lastDecision)", "Events:", diagnosticEvents.joined(separator: "\n")
        ].joined(separator: "\n")
    }

    private func decide(_ text: String) { lastDecision = text; record(text) }
    private func record(_ text: String) {
        diagnosticEvents.append("[\(Date().formatted(date: .omitted, time: .standard))] \(text)")
        if diagnosticEvents.count > 160 { diagnosticEvents.removeFirst(diagnosticEvents.count - 160) }
    }
}
