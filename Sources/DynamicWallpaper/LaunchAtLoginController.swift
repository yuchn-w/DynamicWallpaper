import AppKit
import Combine
import ServiceManagement

/// 管理 macOS 的「登入項目」註冊，不自行建立 LaunchAgent 或背景輪詢。
/// 這樣可以讓系統負責啟動時機，也能在系統設定中正常管理這個 App。
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var statusMessage = "尚未啟用登入時自動啟動"

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            needsApproval = false
            statusMessage = "已加入 macOS 登入項目"
        case .requiresApproval:
            isEnabled = false
            needsApproval = true
            statusMessage = "已提出註冊，請在系統設定允許自動啟動"
        case .notRegistered:
            isEnabled = false
            needsApproval = false
            statusMessage = "尚未啟用登入時自動啟動"
        case .notFound:
            isEnabled = false
            needsApproval = false
            statusMessage = "目前 App 位置無法註冊登入項目"
        @unknown default:
            isEnabled = false
            needsApproval = false
            statusMessage = "無法確認登入項目狀態"
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            isEnabled = false
            needsApproval = enabled
            statusMessage = enabled
                ? "macOS 需要你在系統設定允許自動啟動"
                : "關閉自動啟動失敗：\(error.localizedDescription)"
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
