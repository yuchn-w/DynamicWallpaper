import AppKit
import AVFoundation
import Combine
import Foundation
import OSLog

private let ambientSoundLogger = Logger(
    subsystem: "app.dynamicwallpaper.DynamicWallpaper",
    category: "AmbientSound"
)

enum AmbientSoundCategory: String, CaseIterable, Identifiable {
    case nature
    case noise
    case scene

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nature: "自然"
        case .noise: "噪音"
        case .scene: "場景"
        }
    }
}

struct AmbientSoundOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let category: AmbientSoundCategory

    static let rain = AmbientSoundOption(id: "Rain", displayName: "雨聲", category: .nature)

    static let all: [AmbientSoundOption] = [
        .rain,
        AmbientSoundOption(id: "RainOnRoof", displayName: "屋頂雨聲", category: .nature),
        AmbientSoundOption(id: "Ocean", displayName: "海洋", category: .nature),
        AmbientSoundOption(id: "Stream", displayName: "溪流", category: .nature),
        AmbientSoundOption(id: "Night", displayName: "夜晚", category: .nature),
        AmbientSoundOption(id: "QuietNight", displayName: "寧靜夜晚", category: .nature),
        AmbientSoundOption(id: "Fire", displayName: "火焰", category: .nature),
        AmbientSoundOption(id: "WhiteNoise", displayName: "白噪音", category: .noise),
        AmbientSoundOption(id: "PinkNoise", displayName: "粉紅噪音", category: .noise),
        AmbientSoundOption(id: "BrownNoise", displayName: "棕色噪音", category: .noise),
        AmbientSoundOption(id: "Airplane", displayName: "飛機", category: .scene),
        AmbientSoundOption(id: "Train", displayName: "火車", category: .scene),
        AmbientSoundOption(id: "Bus", displayName: "巴士", category: .scene),
        AmbientSoundOption(id: "Boat", displayName: "船艙", category: .scene),
        AmbientSoundOption(id: "Steam", displayName: "蒸汽", category: .scene),
        AmbientSoundOption(id: "Babble", displayName: "人聲低語", category: .scene)
    ]
}

/// 播放建置時由這台 Mac 的系統資源複製進 App 的 Apple 背景聲音，並在其他程式輸出聲音時自動避讓。
///
/// 專案不保存或散布 Apple 音檔；播放器也不會註冊成系統「播放中」媒體。
/// Core Audio 偵測同時排除目前 App 的 PID，因此不會把自己的雨聲誤判成外部媒體。
@MainActor
final class SystemAmbientSoundController: ObservableObject {
    @Published private(set) var isAvailable = false
    /// 使用者是否希望播放背景聲音；自動避讓與睡眠期間仍維持 `true`。
    @Published private(set) var isEnabled = false
    @Published private(set) var isActuallyPlaying = false
    @Published private(set) var isPausedForOtherAudio = false
    @Published private(set) var isPausedForSleep = false
    @Published private(set) var volume: Double = 0.3
    @Published private(set) var selectedSound = AmbientSoundOption.rain
    @Published private(set) var availableSounds: [AmbientSoundOption] = []
    @Published private(set) var status = "正在載入 Apple 背景聲音"
    @Published private(set) var pauseWhenMediaPlays = true

    private let mediaPlaybackMonitor = SystemMediaPlaybackMonitor()
    private let preferences = UserDefaults.standard
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private var resumeWorkItem: DispatchWorkItem?
    private var audioPollGeneration = 0
    private var mediaIsPlaying = false
    private var lastPollSummary: String?

    var selectedSoundName: String {
        selectedSound.displayName
    }

    init() {
        pauseWhenMediaPlays = preferences.object(forKey: PreferenceKey.pauseForMedia) as? Bool ?? true
        isEnabled = preferences.object(forKey: PreferenceKey.userWantsEnabled) as? Bool ?? false
        volume = Self.normalizedVolume(preferences.object(forKey: PreferenceKey.volume) as? Double ?? 0.3)
        availableSounds = AmbientSoundOption.all.filter { soundURL(for: $0) != nil }
        let savedSoundID = preferences.string(forKey: PreferenceKey.selectedSound)
        selectedSound = availableSounds.first(where: { $0.id == savedSoundID })
            ?? availableSounds.first(where: { $0.id == AmbientSoundOption.rain.id })
            ?? availableSounds.first
            ?? .rain
        configurePlayer()
        refresh()

        if isAvailable, isEnabled {
            updateOtherAudioState()
            reconcilePlayback(resumeDelay: isPausedForOtherAudio ? 0 : 0.6)
        }
        updateAudioMonitoring()
        installSleepObservers()
    }

    deinit {
        resumeWorkItem?.cancel()
        audioPollGeneration &+= 1
        player?.stop()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func refresh() {
        isAvailable = player != nil
        isActuallyPlaying = player?.isPlaying == true

        guard isAvailable else {
            status = "找不到這台 Mac 的 Apple 背景聲音檔案"
            return
        }

        if isPausedForSleep, isEnabled {
            status = "電腦或螢幕休眠，背景聲音已暫停"
        } else if isPausedForOtherAudio, isEnabled {
            status = "其他聲音播放中，背景聲音已自動暫停"
        } else {
            status = isActuallyPlaying ? "正在播放「\(selectedSoundName)」" : "背景聲音已關閉"
        }
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable else {
            refresh()
            return
        }

        resumeWorkItem?.cancel()
        resumeWorkItem = nil
        isEnabled = enabled
        preferences.set(enabled, forKey: PreferenceKey.userWantsEnabled)

        if enabled {
            updateOtherAudioState()
        } else {
            isPausedForOtherAudio = false
            isPausedForSleep = false
        }

        reconcilePlayback()
        updateAudioMonitoring()
    }

    func setVolume(_ newValue: Double) {
        let normalized = Self.normalizedVolume(newValue)
        volume = normalized
        player?.volume = Float(normalized)
        preferences.set(normalized, forKey: PreferenceKey.volume)
        refresh()
    }

    func selectSound(_ sound: AmbientSoundOption) {
        guard availableSounds.contains(sound), sound != selectedSound else { return }

        resumeWorkItem?.cancel()
        resumeWorkItem = nil
        player?.stop()
        selectedSound = sound
        preferences.set(sound.id, forKey: PreferenceKey.selectedSound)
        configurePlayer()
        reconcilePlayback()
        updateAudioMonitoring()
        ambientSoundLogger.info("切換 Apple 背景聲音：\(sound.id, privacy: .public)")
    }

    func sounds(in category: AmbientSoundCategory) -> [AmbientSoundOption] {
        availableSounds.filter { $0.category == category }
    }

    func setPauseWhenMediaPlays(_ enabled: Bool) {
        pauseWhenMediaPlays = enabled
        preferences.set(enabled, forKey: PreferenceKey.pauseForMedia)

        if !enabled {
            isPausedForOtherAudio = false
        } else {
            updateOtherAudioState()
        }

        reconcilePlayback()
        updateAudioMonitoring()
    }

    private func configurePlayer() {
        guard let url = soundURL(for: selectedSound) else {
            player = nil
            return
        }

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.numberOfLoops = -1
            audioPlayer.volume = Float(volume)
            audioPlayer.prepareToPlay()
            player = audioPlayer
        } catch {
            player = nil
            status = "無法載入「\(selectedSoundName)」：\(error.localizedDescription)"
        }
    }

    private func soundURL(for sound: AmbientSoundOption) -> URL? {
        Bundle.main.url(
            forResource: sound.id,
            withExtension: "m4a",
            subdirectory: "AppleComfortSounds"
        )
    }

    private static func normalizedVolume(_ value: Double) -> Double {
        min(max((value * 10).rounded() / 10, 0.1), 1)
    }

    private func installSleepObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for notificationName in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(workspaceCenter.addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleSystemSleep() }
            })
        }
        for notificationName in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspaceCenter.addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleSystemWake() }
            })
        }
    }

    private func updateAudioMonitoring() {
        audioPollGeneration &+= 1
        let generation = audioPollGeneration
        guard isAvailable, isEnabled, pauseWhenMediaPlays, !isPausedForSleep else { return }
        pollOtherAudio(generation: generation)
    }

    private func pollOtherAudio(generation: Int) {
        let activity = SystemAudioActivityMonitor.activityState()
        guard activity.needsMediaRemoteCheck else {
            mediaIsPlaying = false
            logPollIfChanged(
                directOutput: activity.hasDirectOutput,
                mediaRemoteCandidate: false,
                mediaIsPlaying: false
            )
            handleOtherAudioActivity(activity.hasDirectOutput)
            scheduleNextAudioPoll(generation: generation)
            return
        }

        mediaPlaybackMonitor.fetchIsPlaying { [weak self] mediaIsPlaying in
            guard let self, self.audioPollGeneration == generation else { return }
            self.mediaIsPlaying = mediaIsPlaying
            self.logPollIfChanged(
                directOutput: activity.hasDirectOutput,
                mediaRemoteCandidate: true,
                mediaIsPlaying: mediaIsPlaying
            )
            self.handleOtherAudioActivity(activity.hasDirectOutput || mediaIsPlaying)
        }
        scheduleNextAudioPoll(generation: generation)
    }

    private func scheduleNextAudioPoll(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self, self.audioPollGeneration == generation else { return }
            self.pollOtherAudio(generation: generation)
        }
    }

    private func handleOtherAudioActivity(_ isActive: Bool) {
        guard isEnabled, pauseWhenMediaPlays, !isPausedForSleep else { return }

        if isActive {
            resumeWorkItem?.cancel()
            resumeWorkItem = nil
            if !isPausedForOtherAudio || player?.isPlaying == true {
                ambientSoundLogger.info("偵測到外部音訊，暫停 Apple 背景聲音")
                isPausedForOtherAudio = true
                reconcilePlayback()
            }
            return
        }

        guard isPausedForOtherAudio else { return }
        ambientSoundLogger.info("外部音訊已停止，排程恢復 Apple 背景聲音")
        isPausedForOtherAudio = false
        reconcilePlayback(resumeDelay: 1.5)
    }

    private func updateOtherAudioState() {
        let hasActiveOutput = SystemAudioActivityMonitor.hasActiveOutput()
        isPausedForOtherAudio = pauseWhenMediaPlays && hasActiveOutput
        ambientSoundLogger.info("同步外部音訊狀態：direct=\(hasActiveOutput, privacy: .public)")
    }

    private func logPollIfChanged(
        directOutput: Bool,
        mediaRemoteCandidate: Bool,
        mediaIsPlaying: Bool
    ) {
        let summary = "direct=\(directOutput), candidate=\(mediaRemoteCandidate), media=\(mediaIsPlaying)"
        guard summary != lastPollSummary else { return }
        lastPollSummary = summary
        ambientSoundLogger.info("音訊偵測：\(summary, privacy: .public)")
    }

    private func handleSystemSleep() {
        guard !isPausedForSleep else { return }
        isPausedForSleep = true
        resumeWorkItem?.cancel()
        resumeWorkItem = nil
        audioPollGeneration &+= 1
        reconcilePlayback()
    }

    private func handleSystemWake() {
        guard isPausedForSleep else { return }
        isPausedForSleep = false
        guard isEnabled else {
            refresh()
            return
        }

        updateOtherAudioState()
        updateAudioMonitoring()
        reconcilePlayback(resumeDelay: isPausedForOtherAudio ? 0 : 1.0)
    }

    private func reconcilePlayback(resumeDelay: TimeInterval = 0) {
        resumeWorkItem?.cancel()
        resumeWorkItem = nil

        let shouldPlay = isAvailable &&
            isEnabled &&
            !isPausedForSleep &&
            !(pauseWhenMediaPlays && isPausedForOtherAudio)

        guard shouldPlay else {
            player?.pause()
            refresh()
            return
        }

        guard resumeDelay > 0 else {
            player?.play()
            refresh()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isEnabled,
                      !self.isPausedForSleep,
                      !(self.pauseWhenMediaPlays && self.isPausedForOtherAudio) else { return }
                self.resumeWorkItem = nil
                self.player?.play()
                self.refresh()
            }
        }
        resumeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + resumeDelay, execute: workItem)
    }
}

private enum PreferenceKey {
    static let pauseForMedia = "環境音.其他媒體播放時暫停"
    static let userWantsEnabled = "環境音.使用者要求播放"
    static let volume = "環境音.音量"
    static let selectedSound = "環境音.選擇的背景聲音"
}
