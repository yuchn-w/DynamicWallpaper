import AppKit
import AVFoundation
import Combine
import SwiftUI

@main
struct DynamicWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = WallpaperLibrary()
    @StateObject private var playback = WallpaperPlaybackController()
    @StateObject private var ambientSound = SystemAmbientSoundController()

    var body: some Scene {
        WindowGroup {
            MainView(library: library, playback: playback, ambientSound: ambientSound)
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
                        ambientSound: ambientSound
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
        ambientSound: SystemAmbientSoundController
    ) {
        guard statusBarController == nil else { return }
        playback.configureLibrary(library)
        statusBarController = StatusBarController(
            library: library,
            playback: playback,
            ambientSound: ambientSound
        )
        fitMainWindowToVisibleScreen()
    }

    func toggleStatusPanel() {
        statusBarController?.togglePanel()
    }

    func applicationDidResignActive(_ notification: Notification) {
        statusBarController?.closePanel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func fitMainWindowToVisibleScreen() {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.canBecomeMain }),
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
        }
    }
}

@MainActor
private final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var globalMouseMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    init(
        library: WallpaperLibrary,
        playback: WallpaperPlaybackController,
        ambientSound: SystemAmbientSoundController
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()

        super.init()

        let content = StatusBarPlayer(
            library: library,
            playback: playback,
            ambientSound: ambientSound,
            closePanel: { [weak popover] in popover?.performClose(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: content)
        popover.contentSize = NSSize(width: 374, height: 560)
        // 暫時模式會保留面板內互動，點擊面板以外區域或切換 App 時自動收回。
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        // 狀態列彈窗本身不一定會啟用整個 App，因此額外監看其他 App 收到的滑鼠點擊。
        // 這不會攔截或記錄事件，只在使用者點到控制器之外時將控制器收回。
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePanel()
            }
        }

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mountain.2", accessibilityDescription: "動態壁紙")
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        playback.$isPlaying
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                self?.statusItem.button?.image = NSImage(
                    systemSymbolName: isPlaying ? "mountain.2.fill" : "mountain.2",
                    accessibilityDescription: isPlaying ? "動態壁紙正在播放" : "動態壁紙已暫停"
                )
            }
            .store(in: &cancellables)
    }

    deinit {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
    }

    @objc func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        guard let button = statusItem.button else { return }
        if let controller = popover.contentViewController as? NSHostingController<StatusBarPlayer> {
            controller.rootView.ambientSound.refresh()
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePanel() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }
}

private struct StatusVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> StatusVideoView {
        let view = StatusVideoView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: StatusVideoView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }
}

private final class StatusVideoView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
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
            artworkBackground

            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.18)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.06),
                    Color(red: 0.025, green: 0.12, blue: 0.115).opacity(0.42),
                    Color.black.opacity(0.88)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                header
                Spacer(minLength: 34)
                nowPlaying
                playbackControls
                displayControls
            }
            .padding(18)
        }
        .frame(width: 374, height: 560)
        .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.42), Color.white.opacity(0.12), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: 88, height: 1)
                .padding(.top, 1)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var artworkBackground: some View {
        ZStack {
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

            if let player = playback.previewPlayer {
                StatusVideoSurface(player: player)
            }
        }
        .frame(width: 374, height: 560)
        .clipped()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(playback.isPlaying ? "正在播放" : playback.currentVideoURL == nil ? "尚未播放" : "已暫停")
                    .font(.system(size: 17, weight: .bold))
                Text("動態壁紙 0.8.0")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
            }
            Spacer()
            roundButton(symbol: "macwindow.on.rectangle") {
                showMainWindow()
            }
            roundButton(symbol: "power") {
                playback.stop()
            }
            .disabled(playback.currentVideoURL == nil)
        }
    }

    private var nowPlaying: some View {
        VStack(spacing: 7) {
            Text("本機動態壁紙")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.66))
            Text(currentTitle)
                .font(.system(size: 25, weight: .bold, design: .serif))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            if let currentItem {
                Text("\(currentItem.resolutionText) ・ \(currentItem.durationText)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.64))
            }
        }
        .padding(.horizontal, 10)
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
                if let currentItem { library.toggleFavorite(currentItem) }
            } label: {
                Image(systemName: currentItem?.isFavorite == true ? "heart.fill" : "heart")
                    .foregroundStyle(currentItem?.isFavorite == true ? Color.pink : Color.white)
                    .font(.system(size: 19))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(currentItem == nil)

            roundButton(symbol: "backward.fill", size: 48) { moveCurrent(by: -1) }
                .disabled(library.items.count < 2)

            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 64, height: 64)
                    .background { StatusGlassSurface(shape: Circle(), strength: 1) }
            }
            .buttonStyle(.plain)
            .disabled(playback.currentVideoURL == nil)

            roundButton(symbol: "forward.fill", size: 48) { moveCurrent(by: 1) }
                .disabled(library.items.count < 2)

            ambientSoundMenu
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
                .frame(width: 32, height: 32)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 34)
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
                    .frame(height: 34)
                    .background { StatusGlassSurface(shape: Capsule(), strength: 0.72) }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
    }

    private func roundButton(
        symbol: String,
        size: CGFloat = 36,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size > 42 ? 17 : 14, weight: .semibold))
                .frame(width: size, height: size)
                .background { StatusGlassSurface(shape: Circle(), strength: 0.84) }
        }
        .buttonStyle(.plain)
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
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?
            .makeKeyAndOrderFront(nil)
    }
}
