import AppKit
import CoreAudio
import Darwin
import Foundation

/// 只讀取 Core Audio 提供的「程序目前是否有輸出串流」狀態。
/// 不建立音訊 Tap、不擷取聲音內容，也不要求螢幕或系統錄音權限。
enum SystemAudioActivityMonitor {
    struct OutputProcess: Sendable {
        let pid: pid_t
        let bundleID: String?
        let executableName: String?
        let localizedName: String?
    }

    struct ActivityState: Sendable {
        /// 可直接確認正在輸出聲音的程序。
        let hasDirectOutput: Bool
        /// IINA 暫停後仍可能保留輸出串流，只有此情況才需要查詢「播放中」中心。
        let needsMediaRemoteCheck: Bool
    }

    static func activeOutputProcesses() -> [OutputProcess] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            systemObject,
            &listAddress,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processObjects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            systemObject,
            &listAddress,
            0,
            nil,
            &dataSize,
            &processObjects
        ) == noErr else { return [] }

        return processObjects.compactMap { objectID in
            guard uint32Property(
                objectID,
                selector: kAudioProcessPropertyIsRunningOutput
            ) != 0 else { return nil }
            let pid = pidProperty(objectID)
            guard pid > 0 else { return nil }
            let application = NSRunningApplication(processIdentifier: pid)
            return OutputProcess(
                pid: pid,
                // 直接由 PID 查詢執行中的 App，避免 Core Audio 的 CFString
                // 所有權在不同 macOS 版本間產生不一致的記憶體管理風險。
                bundleID: application?.bundleIdentifier,
                executableName: executableName(for: pid) ?? application?.executableURL?.lastPathComponent,
                localizedName: application?.localizedName
            )
        }
    }

    static func hasActiveOutput(ignoredPIDs: Set<pid_t> = []) -> Bool {
        activityState(ignoredPIDs: ignoredPIDs).hasDirectOutput
    }

    static func activityState(ignoredPIDs: Set<pid_t> = []) -> ActivityState {
        let ignored = ignoredPIDs.union([ProcessInfo.processInfo.processIdentifier])
        var hasDirectOutput = false
        var needsMediaRemoteCheck = false

        for process in activeOutputProcesses() {
            guard !ignored.contains(process.pid) else { continue }
            // macOS 環境音由 HearingUtilities 的 `heard` 服務輸出；它通常
            // 沒有 Bundle ID。若只把「無 Bundle ID」視為外部媒體，App 會
            // 把自己剛開啟的環境音判斷成外部音訊，造成開／關循環與斷續聲音。
            if let executableName = process.executableName?.lowercased(),
               alwaysIgnoredExecutableNames.contains(executableName) {
                continue
            }
            guard let bundleID = process.bundleID?.lowercased() else {
                // Chrome／Edge 的 AudioService 子程序可能沒有 Bundle ID，
                // 但即使沒有播放也會長駐。這些程序要交給 MediaRemote
                // 查詢，不能像一般無 Bundle ID 程序一樣直接視為有聲音。
                if let executableName = process.executableName?.lowercased(),
                   mediaRemoteExecutableNameFragments.contains(where: executableName.contains) {
                    needsMediaRemoteCheck = true
                    continue
                }
                hasDirectOutput = true
                continue
            }
            if alwaysIgnoredBundleFragments.contains(where: bundleID.contains) {
                continue
            }
            // WebKit.GPU 會在影片結束後繼續存在，不能把它本身當成
            //「仍有聲音」。只有短暫出現、明確代表媒體輸出的程序才算。
            // 哔哩哔哩 Helper 不屬於這個 Bundle，會在下方走直接輸出判斷。
            if webKitBundleFragments.contains(where: bundleID.contains) {
                if let localizedName = process.localizedName?.lowercased(),
                   transientWebMediaNameFragments.contains(where: localizedName.contains) {
                    hasDirectOutput = true
                }
                continue
            }
            if mediaRemoteBundleFragments.contains(where: bundleID.contains) {
                needsMediaRemoteCheck = true
                continue
            }
            hasDirectOutput = true
        }

        return ActivityState(
            hasDirectOutput: hasDirectOutput,
            needsMediaRemoteCheck: needsMediaRemoteCheck
        )
    }

    private static func uint32Property(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return 0 }
        return value
    }

    private static func pidProperty(_ objectID: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return 0 }
        return value
    }

    private static func executableName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static let alwaysIgnoredBundleFragments = [
        "com.apple.accessibility.heard",
        "com.apple.comfortsounds",
        "com.apple.controlcenter",
        // FineTune 常駐處理系統輸出，本身不代表使用者正在播放媒體。
        "com.finetuneapp.finetune"
    ]

    private static let alwaysIgnoredExecutableNames = [
        "heard"
    ]

    private static let mediaRemoteExecutableNameFragments = [
        "google chrome helper",
        "microsoft edge helper",
        "brave browser helper"
    ]

    private static let webKitBundleFragments = [
        "com.apple.webkit"
    ]

    private static let transientWebMediaNameFragments = [
        "youtube graphics and media",
        "youtube helper"
    ]

    private static let mediaRemoteBundleFragments = [
        // Safari／Chrome／Edge 的 App 程序可能保留輸出串流，
        // 需要用 MediaRemote 再確認實際播放狀態。WebKit.GPU
        // 另行處理，避免常駐的 Graphics and Media 造成假暫停。
        "com.apple.safari",
        "com.google.chrome",
        "com.microsoft.edgemac",
        "com.apple.quicktimeplayerx",
        "com.colliderli.iina"
        // 刻意不加入 com.bilibili：哔哩哔哩真正播放時會出現
        //「哔哩哔哩 Helper」直接輸出，但它的 MediaRemote 狀態可能仍是 paused。
    ]
}
