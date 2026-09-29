import AppKit
import CoreAudio
import Foundation

/// 只讀取 Core Audio 提供的「程序目前是否有輸出串流」狀態。
/// 不建立音訊 Tap、不擷取聲音內容，也不要求螢幕或系統錄音權限。
enum SystemAudioActivityMonitor {
    struct OutputProcess: Sendable {
        let pid: pid_t
        let bundleID: String?
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
            return OutputProcess(
                pid: pid,
                // 直接由 PID 查詢執行中的 App，避免 Core Audio 的 CFString
                // 所有權在不同 macOS 版本間產生不一致的記憶體管理風險。
                bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
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
            guard let bundleID = process.bundleID?.lowercased() else {
                hasDirectOutput = true
                continue
            }
            if alwaysIgnoredBundleFragments.contains(where: bundleID.contains) {
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

    private static let alwaysIgnoredBundleFragments = [
        "com.apple.accessibility.heard",
        "com.apple.comfortsounds",
        "com.apple.controlcenter",
        // FineTune 常駐處理系統輸出，本身不代表使用者正在播放媒體。
        "com.finetuneapp.finetune"
    ]

    private static let mediaRemoteBundleFragments = [
        // IINA 暫停後仍可能保留 Core Audio 輸出串流，需再確認「播放中」狀態。
        "com.colliderli.iina"
    ]
}
