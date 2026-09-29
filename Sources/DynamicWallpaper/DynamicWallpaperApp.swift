import AppKit
import AVFoundation
import Combine
import SwiftUI
import QuartzCore
import Darwin

// 參考 macOS 原生 Menu Bar Popover 的比例；Popover 與 SwiftUI 內容共用，
// 避免外框與內容各自裁切而產生雙層邊緣或四角漏底。
private let statusBarPopoverCornerRadius: CGFloat = 26

@main
struct DynamicWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = WallpaperLibrary()
    @StateObject private var playback = WallpaperPlaybackController()
    @StateObject private var ambientSound = SystemAmbientSoundController()
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            MainView(
                library: library,
                playback: playback,
                ambientSound: ambientSound,
                launchAtLogin: launchAtLogin
            )
                .frame(
                    minWidth: 1000,
                    maxWidth: .infinity,
                    minHeight: 620,
                    maxHeight: .infinity
                )
                .onAppear {
                    appDelegate.configureStatusBar(
                        library: library,
                        playback: playback,
                        ambientSound: ambientSound,
                        openMainWindow: {
                            appDelegate.showMainWindow {
                                openWindow(id: "main")
                            }
                        }
                    )
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    appDelegate.configureStatusBar(
                        library: library,
                        playback: playback,
                        ambientSound: ambientSound,
                        openMainWindow: {
                            appDelegate.showMainWindow {
                                openWindow(id: "main")
                            }
                        }
                    )
                }
        }
        // 保留原生標題列配置，避免自訂導覽列遮住關閉、縮小與放大鍵。
        .windowStyle(.titleBar)
        .defaultSize(width: 1320, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("狀態列") {
                Button("顯示或隱藏狀態播放器") {
                    appDelegate.toggleStatusPanel()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("複製 Auto HDR 診斷") {
                    appDelegate.copyHDRDiagnostics()
                }
                .keyboardShortcut("d", modifiers: [.command, .option, .control])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 以狀態列工具形式執行，不在 Dock 與 ⌘Tab 列表顯示。
        NSApp.setActivationPolicy(.accessory)
    }

    func configureStatusBar(
        library: WallpaperLibrary,
        playback: WallpaperPlaybackController,
        ambientSound: SystemAmbientSoundController,
        openMainWindow: @escaping () -> Void
    ) {
        guard statusBarController == nil else { return }
        playback.configureLibrary(library)
        statusBarController = StatusBarController(
            library: library,
            playback: playback,
            ambientSound: ambientSound,
            openMainWindow: openMainWindow
        )
        fitMainWindowToVisibleScreen()
    }

    func toggleStatusPanel() {
        statusBarController?.togglePanel()
    }

    func copyHDRDiagnostics() {
        statusBarController?.copyHDRDiagnostics()
    }

    func showMainWindow(openWindow: @escaping () -> Void) {
        if mainWindow() != nil {
            fitMainWindowToVisibleScreen()
            return
        }

        // WindowGroup 的主視窗可能已被使用者關閉；此時原本只搜尋
        // NSApp.windows 會找不到任何東西，狀態欄按鈕就會完全沒有反應。
        openWindow()
        fitMainWindowToVisibleScreen()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func fitMainWindowToVisibleScreen() {
        DispatchQueue.main.async {
            guard let window = self.mainWindow(),
                  let screen = window.screen ?? NSScreen.main else { return }

            let visibleFrame = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            var frame = window.frame
            // 不沿用可能超出螢幕的舊視窗尺寸；啟動時回到穩定且完整可見的大小。
            frame.size.width = min(1320, visibleFrame.width)
            frame.size.height = min(720, visibleFrame.height)
            frame.origin.x = visibleFrame.midX - frame.width / 2
            frame.origin.y = visibleFrame.midY - frame.height / 2
            window.minSize = NSSize(width: 1000, height: 620)
            window.setFrame(frame, display: true, animate: false)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func mainWindow() -> NSWindow? {
        // 狀態欄 Popover 與壁紙視窗也可能回報 canBecomeMain；
        // 只有主程式的標題列視窗才是可重新開啟的 App 視窗。
        NSApp.windows.first {
            $0.canBecomeMain && $0.styleMask.contains(.titled)
        }
    }
}

private final class StatusBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let panel: StatusBarPanel
    private let playback: WallpaperPlaybackController
    private let hdrController: DisplayHDRController
    private let autoHDRController: AutoHDRController
    private var cancellables: Set<AnyCancellable> = []
    private var dismissEventMonitors: [Any] = []
    private var anchorFrame: CGRect?

    func copyHDRDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(autoHDRController.diagnosticsText(), forType: .string)
    }

    init(
        library: WallpaperLibrary,
        playback: WallpaperPlaybackController,
        ambientSound: SystemAmbientSoundController,
        openMainWindow: @escaping () -> Void
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let panel = StatusBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 604),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.panel = panel
        self.playback = playback
        self.hdrController = DisplayHDRController()
        self.autoHDRController = AutoHDRController(displayController: self.hdrController)

        super.init()

        let content = StatusBarPlayer(
            library: library,
            playback: playback,
            ambientSound: ambientSound,
            hdrController: hdrController,
            autoHDRController: autoHDRController,
            openMainWindow: openMainWindow,
            closePanel: { [weak panel, weak playback] in
                playback?.setStatusPreviewVisible(false)
                panel?.orderOut(nil)
            }
        )
        panel.contentViewController = NSHostingController(rootView: content)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        autoHDRController.start()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusButton(isPlaying: playback.isPlaying)

        playback.$isPlaying
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                self?.updateStatusButton(isPlaying: isPlaying)
            }
            .store(in: &cancellables)
    }

    private func updateStatusButton(isPlaying: Bool) {
        guard let button = statusItem.button else {
            statusItem.isVisible = true
            return
        }

        let symbolName = isPlaying ? "mountain.2.fill" : "mountain.2"
        let accessibilityDescription = isPlaying ? "動態壁紙正在播放" : "動態壁紙已暫停"
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        ) ?? NSImage(named: NSImage.applicationIconName)

        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = image == nil ? "動態壁紙" : ""
        button.toolTip = accessibilityDescription
        statusItem.isVisible = true
    }

    func togglePanel() {
        togglePanel(from: statusItem.button)
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        // macOS 會在多螢幕選單列建立對應的狀態欄按鈕；sender 才是
        // 使用者實際點到的那一個。不能每次重新抓 statusItem.button，
        // 否則按外接螢幕圖示時，Popover 可能被放回內建螢幕。
        togglePanel(from: sender as? NSStatusBarButton ?? statusItem.button)
    }

    private func togglePanel(from button: NSStatusBarButton?) {
        if panel.isVisible {
            // 同一個狀態欄按鈕再次點擊就是關閉；若是另一個螢幕的
            // 狀態欄按鈕，先關閉舊 Popover，再用新按鈕重新定位。
            if button != nil,
               let anchorFrame,
               anchorFrame.contains(NSEvent.mouseLocation) {
                dismissPanel()
                return
            }
            dismissPanel()
        }

        guard let button else { return }
        anchorFrame = button.window?.frame
        if let controller = panel.contentViewController as? NSHostingController<StatusBarPlayer> {
            controller.rootView.ambientSound.refresh()
        }
        autoHDRController.refresh()
        playback.setStatusPreviewVisible(true)
        guard let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        anchorFrame = anchor
        let screen = buttonWindow.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = NSSize(width: 540, height: 604)
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = max(origin.y, visible.minY + 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        applySingleLayerPanel()
        installDismissEventMonitors()
    }

    private func applySingleLayerPanel() {
        guard let hostingView = panel.contentViewController?.view else { return }
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = statusBarPopoverCornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.borderWidth = 0
    }

    private func installDismissEventMonitors() {
        removeDismissEventMonitors()

        let localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.dismissIfClickedOutside()
            return event
        }
        if let localMonitor {
            dismissEventMonitors.append(localMonitor)
        }

        let globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.dismissIfClickedOutside()
        }
        if let globalMonitor {
            dismissEventMonitors.append(globalMonitor)
        }
    }

    private func removeDismissEventMonitors() {
        dismissEventMonitors.forEach { NSEvent.removeMonitor($0) }
        dismissEventMonitors.removeAll()
    }

    private func dismissIfClickedOutside() {
        guard panel.isVisible else { return }
        let point = NSEvent.mouseLocation

        if panel.frame.contains(point) {
            return
        }
        // 點狀態欄圖示本身要交給按鈕 action 處理，避免監聽器先關閉後
        // action 又重新打開，造成「點一下反而不收回」的錯覺。
        if let anchorFrame, anchorFrame.contains(point) {
            return
        }

        dismissPanel()
    }

    private func dismissPanel() {
        guard panel.isVisible else { return }
        removeDismissEventMonitors()
        playback.setStatusPreviewVisible(false)
        panel.orderOut(nil)
    }

    func closePanel() {
        dismissPanel()
    }

}

/// macOS 26 優先使用系統 Liquid Glass；舊版系統以原生 Popover
/// vibrancy material 回退。兩者都由 WindowServer 合成，不建立自訂
/// 即時 blur/filter，避免額外 CPU/GPU 負擔。
private struct StatusPopoverMaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if let glassView = GlassBridgeLoader.makeView() {
            glassView.wantsLayer = true
            glassView.layer?.backgroundColor = NSColor.clear.cgColor
            return glassView
        }

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        return effect
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private enum GlassBridgeLoader {
    private typealias Factory = @convention(c) () -> UnsafeMutableRawPointer?

    static func makeView() -> NSView? {
        guard #available(macOS 26.0, *),
              let url = Bundle.main.privateFrameworksURL?
                .appendingPathComponent("libDWGlassBridge.dylib"),
              let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL),
              let symbol = dlsym(handle, "DWCreateGlassEffectView") else { return nil }
        let factory = unsafeBitCast(symbol, to: Factory.self)
        guard let pointer = factory() else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue() as? NSView
    }
}

private struct StatusVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let horizontalFlip: Bool

    func makeNSView(context: Context) -> StatusVideoView {
        let view = StatusVideoView()
        view.attach(player: player, horizontalFlip: horizontalFlip)
        return view
    }

    func updateNSView(_ nsView: StatusVideoView, context: Context) {
        nsView.attach(player: player, horizontalFlip: horizontalFlip)
    }
}

private final class StatusVideoView: NSView {
    let playerLayer = AVPlayerLayer()
    private var horizontalFlip = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func attach(player: AVPlayer, horizontalFlip: Bool) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
        self.horizontalFlip = horizontalFlip
        playerLayer.setNeedsLayout()
    }

    override func layout() {
        super.layout()
        playerLayer.setAffineTransform(.identity)
        playerLayer.frame = bounds
        playerLayer.setAffineTransform(
            horizontalFlip ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        )
    }
}

private struct StatusGlassSurface<S: Shape>: View {
    let shape: S
    var strength: Double = 1

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.13 * strength),
                            Color.cyan.opacity(0.025 * strength),
                            Color.black.opacity(0.10 * strength)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.30 * strength),
                            Color.white.opacity(0.07 * strength),
                            Color.black.opacity(0.12 * strength)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
            }
            .shadow(color: Color.black.opacity(0.16 * strength), radius: 8, y: 3)
    }
}

private struct StatusBarPlayer: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var playback: WallpaperPlaybackController
    @ObservedObject var ambientSound: SystemAmbientSoundController
    @ObservedObject var hdrController: DisplayHDRController
    @ObservedObject var autoHDRController: AutoHDRController
    let openMainWindow: () -> Void
    let closePanel: () -> Void

    private var currentItem: WallpaperItem? {
        guard let url = playback.currentVideoURL else { return nil }
        return library.items.first { $0.fileURL.standardizedFileURL == url.standardizedFileURL }
    }

    private var currentTitle: String {
        guard let title = currentItem?.title else { return "選擇一張壁紙開始播放" }
        let uuidPattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        if title.range(of: uuidPattern, options: .regularExpression) != nil {
            return "未命名動態壁紙"
        }
        return title
    }

    var body: some View {
        ZStack {
            StatusPopoverMaterialView()
                .ignoresSafeArea()
            // Match macOS menu glass: the scene remains visible through the
            // clear glass, while a neutral dark veil keeps labels legible.
            Color.black.opacity(0.70)
            VStack(spacing: 14) {
                header
                hdrStatus
                ZStack(alignment: .bottom) {
                    artworkBackground
                    LinearGradient(colors: [.clear, .black.opacity(0.12), .black.opacity(0.92)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 0) {
                        nowPlaying
                        playbackControls
                    }
                    .padding(18)
                }
                .frame(height: 394)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                HStack(spacing: 10) {
                    displayControls
                    roundButton(symbol: "gearshape", size: 44) {
                        showMainWindow()
                        NotificationCenter.default.post(name: Notification.Name("DynamicWallpaper.openSettings"), object: nil)
                    }
                        .help("設定")
                }
            }
            .padding(18)
        }
        .frame(width: 540, height: 604)
        // 只保留這一個內容輪廓；外層 NSPopover 不再另外畫底板或邊框。
        .clipShape(RoundedRectangle(cornerRadius: statusBarPopoverCornerRadius, style: .continuous))
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var artworkBase: some View {
        if let path = currentItem?.thumbnailPath,
           let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.26, blue: 0.25), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var artworkBackground: some View {
        ZStack {
            artworkBase
            if let player = playback.previewPlayer {
                StatusVideoSurface(
                    player: player,
                    horizontalFlip: currentItem?.isHorizontallyFlipped ?? false
                )
            }
        }
        .frame(width: 504, height: 394)
        .clipped()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(playback.isPlaying ? "正在播放" : playback.currentVideoURL == nil ? "尚未播放" : "已暫停")
                    .font(.system(size: 25, weight: .bold))
                Text("動態壁紙 0.10.0")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
            }
            Spacer()
            hdrModePicker
            Rectangle().fill(.white.opacity(0.16)).frame(width: 0.5, height: 34)
            roundButton(symbol: "power", size: 44) {
                playback.stop()
            }
            .disabled(playback.currentVideoURL == nil)
        }
    }

    private var hdrModeBinding: Binding<AutoHDRMode> {
        Binding(
            get: { autoHDRController.mode },
            set: { autoHDRController.setMode($0) }
        )
    }

    private var hdrModePicker: some View {
        HStack(spacing: 5) {
            Image(systemName: "sun.max").font(.system(size: 21)).frame(width: 32)
            HStack(spacing: 2) {
                ForEach(AutoHDRMode.allCases) { mode in
                    Button { hdrModeBinding.wrappedValue = mode } label: {
                        Text(mode.shortTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 48, height: 32)
                            .background {
                                if autoHDRController.mode == mode {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.accentColor)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("HDR \(mode.shortTitle)")
                }
            }
        }
        .padding(5)
        .background(Capsule().fill(.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .focusEffectDisabled()
        .help("HDR 模式：OFF 關閉、AUTO 依正式 YouTube HDR 判斷、ON 強制開啟")
    }

    private var hdrStatus: some View {
        HStack(spacing: 7) {
            Spacer(minLength: 0)
            Image(systemName: "display")
                .foregroundStyle(
                    hdrController.isExternalHDREnabled
                        ? Color.yellow
                        : Color.white.opacity(hdrController.isExternalHDRAvailable ? 0.9 : 0.38)
                )
            HStack(spacing: 8) {
                Text(hdrController.targetDisplayName)
                    .foregroundStyle(.white.opacity(0.65))
                Text("·").foregroundStyle(.secondary)
                Text(autoHDRController.statusText)
                    .lineLimit(1)
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 4)
        .help(autoHDRController.lastDecision)
        .contextMenu {
            Button("複製 Auto HDR 診斷") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    autoHDRController.diagnosticsText(),
                    forType: .string
                )
            }
        }
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("本機動態壁紙")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.66))
            Text(currentTitle)
                .font(.system(size: 25, weight: .bold, design: .serif))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            if let currentItem {
                Text("\(currentItem.resolutionText) ・ \(currentItem.durationText)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.64))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playbackControls: some View {
        HStack(spacing: 0) {
            Button {
                if let currentItem { library.toggleFavorite(currentItem) }
            } label: {
                Image(systemName: currentItem?.isFavorite == true ? "heart.fill" : "heart")
                    .foregroundStyle(currentItem?.isFavorite == true ? Color.pink : Color.white)
                    .font(.system(size: 19))
                    .frame(width: 42, height: 42)
                    .background { StatusGlassSurface(shape: Circle(), strength: 0.7) }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(currentItem == nil)

            Spacer(minLength: 8)

            Button {
                guard let currentItem else { return }
                let enabled = !currentItem.isHorizontallyFlipped
                library.setHorizontalFlip(enabled, for: currentItem)
                playback.setHorizontalFlip(enabled, for: currentItem.id)
            } label: {
                Image(systemName: currentItem?.isHorizontallyFlipped == true
                    ? "arrow.left.arrow.right.circle.fill"
                    : "arrow.left.arrow.right")
                    .foregroundStyle(
                        currentItem?.isHorizontallyFlipped == true
                            ? Color(red: 0.43, green: 0.85, blue: 0.80)
                            : Color.white
                    )
                    .font(.system(size: 19))
                    .frame(width: 42, height: 42)
                    .background { StatusGlassSurface(shape: Circle(), strength: 0.7) }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(currentItem?.isHorizontallyFlipped == true ? "恢復這張壁紙的原方向" : "左右反轉這張壁紙")
            .disabled(currentItem == nil)

            Spacer(minLength: 8)

            roundButton(symbol: "backward.fill", size: 48) { moveCurrent(by: -1) }
                .disabled(library.items.count < 2)

            Spacer(minLength: 8)

            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 64, height: 64)
                    .background { StatusGlassSurface(shape: Circle(), strength: 1) }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(playback.currentVideoURL == nil)

            Spacer(minLength: 8)

            roundButton(symbol: "forward.fill", size: 48) { moveCurrent(by: 1) }
                .disabled(library.items.count < 2)

            Spacer(minLength: 8)

            ambientSoundMenu
            Spacer(minLength: 8)
            Menu {
                Button("開啟壁紙資料庫") { showMainWindow() }
            } label: {
                Image(systemName: "ellipsis").frame(width: 38, height: 42)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 42)
            .background { StatusGlassSurface(shape: Circle(), strength: 0.7) }
        }
        .padding(.top, 18)
    }

    private var ambientSoundMenu: some View {
        Menu {
            AmbientSoundMenuItems(ambientSound: ambientSound)
        } label: {
            Image(systemName: ambientSound.isPausedForOtherAudio
                ? "waveform.badge.minus"
                : ambientSound.isEnabled ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 38, height: 42)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 42)
        .background { StatusGlassSurface(shape: Circle(), strength: 0.7) }
        .help(ambientSound.status)
    }

    private var displayControls: some View {
        HStack(spacing: 8) {
            ForEach(playback.displays) { display in
                Button {
                    playback.setDisplayEnabled(
                        display.id,
                        enabled: !playback.selectedDisplayIDs.contains(display.id)
                    )
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(playback.selectedDisplayIDs.contains(display.id) ? Color.green : Color.yellow)
                            .frame(width: 7, height: 7)
                        Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                            .font(.caption)
                        Text(display.name)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(playback.selectedDisplayIDs.contains(display.id) ? Color.white : Color.white.opacity(0.58))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background { StatusGlassSurface(shape: Capsule(), strength: 0.72) }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func roundButton(
        symbol: String,
        size: CGFloat = 36,
        foreground: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size > 42 ? 17 : 14, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background { StatusGlassSurface(shape: Circle(), strength: 0.84) }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func moveCurrent(by offset: Int) {
        guard !library.items.isEmpty else { return }
        let index = currentItem.flatMap { item in
            library.items.firstIndex(where: { $0.id == item.id })
        } ?? 0
        let targetIndex = (index + offset + library.items.count) % library.items.count
        playback.apply(videoURL: library.items[targetIndex].fileURL)
    }

    private func showMainWindow() {
        closePanel()
        openMainWindow()
    }
}
