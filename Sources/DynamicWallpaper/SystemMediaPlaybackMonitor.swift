import Darwin
import Foundation
import OSLog

/// 讀取 macOS「播放中」中心的實際媒體狀態。
/// 這只取得播放／暫停布林值，不讀取曲名、歌詞或音訊內容。
@MainActor
final class SystemMediaPlaybackMonitor {
    private typealias Reply = @convention(block) (Bool) -> Void
    private typealias GetPlaying = @convention(c) (DispatchQueue, @escaping Reply) -> Void

    private let getPlaying: GetPlaying?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.dynamicwallpaper.DynamicWallpaper",
        category: "MediaRemote"
    )
    private var nextRequestID: UInt64 = 0
    private var activeRequestID: UInt64?
    private var consecutiveTimeouts = 0
    private var retryAfter = Date.distantPast

    init() {
        let framework = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(framework, RTLD_NOW),
              let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
            getPlaying = nil
            return
        }
        getPlaying = unsafeBitCast(symbol, to: GetPlaying.self)
    }

    func fetchIsPlaying(_ completion: @escaping (Bool) -> Void) {
        guard let getPlaying else {
            completion(false)
            return
        }

        // MediaRemote 是私有非同步 API；實機上可能在睡眠／喚醒或瀏覽器
        // AudioService 重建後不再回呼。禁止同時累積查詢，逾時後先回到
        // Core Audio 的直接偵測，並用指數退避重試，避免長期卡死或耗用資源。
        let now = Date()
        guard now >= retryAfter, activeRequestID == nil else {
            completion(false)
            return
        }

        nextRequestID &+= 1
        let requestID = nextRequestID
        activeRequestID = requestID

        getPlaying(.main) { [weak self] playing in
            guard let self, self.activeRequestID == requestID else { return }
            self.activeRequestID = nil
            self.consecutiveTimeouts = 0
            self.retryAfter = .distantPast
            completion(playing)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.activeRequestID == requestID else { return }
            self.activeRequestID = nil
            self.consecutiveTimeouts += 1
            let retryDelay = min(
                300.0,
                5.0 * pow(2.0, Double(min(self.consecutiveTimeouts - 1, 6)))
            )
            self.retryAfter = Date().addingTimeInterval(retryDelay)
            self.logger.error(
                "MediaRemote query timed out; retryDelay=\(retryDelay, privacy: .public)"
            )
            completion(false)
        }
    }
}
