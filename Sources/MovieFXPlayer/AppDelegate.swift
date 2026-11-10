import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var player: VideoPlayer?
    /// File delivered by Launch Services before the player exists
    /// (e.g. "Open With" or a drop on the app icon at launch).
    private var pendingOpenURL: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let renderer = MetalFXRenderer.make() else {
            let alert = NSAlert()
            alert.messageText = "MetalFX Spatial is not available on this Mac"
            alert.informativeText = "MovieFX Player requires Metal and a Mac with Apple silicon."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let player = VideoPlayer(renderer: renderer)
        self.player = player

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MovieFX Player"
        window.center()
        window.minSize = NSSize(width: 480, height: 270)

        let view = PlayerView(frame: window.contentLayoutRect)
        view.configure()
        window.contentView = view
        player.attach(view: view)
        view.player = player
        view.onOpenRequest = { [weak self] in self?.openPanel() }
        window.makeFirstResponder(view)

        player.onStatusChange = { [weak self] status in
            self?.window.subtitle = status
        }
        player.onTitleChange = { [weak self] title in
            self?.window.title = title
        }
        player.onPlaybackStateChange = { [weak view] in
            view?.updatePlaybackControls()
        }
        view.updatePlaybackControls()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let url = pendingOpenURL {
            pendingOpenURL = nil
            player.open(url: url)
        } else if CommandLine.arguments.count > 1 {
            player.open(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        } else {
            openPanel()
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if let player {
            player.open(url: url)
        } else {
            pendingOpenURL = url
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            player?.open(url: url)
        }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit MovieFX Player", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(menuItem("Open…", #selector(openPanel), "o", modifiers: .command))
        fileItem.submenu = fileMenu

        let playbackItem = NSMenuItem()
        mainMenu.addItem(playbackItem)
        let playbackMenu = NSMenu(title: "Playback")
        playbackMenu.addItem(menuItem("Play/Pause", #selector(togglePlay), " "))
        playbackMenu.addItem(.separator())
        playbackMenu.addItem(menuItem("Faster", #selector(rateUp), "]"))
        playbackMenu.addItem(menuItem("Slower", #selector(rateDown), "["))
        playbackMenu.addItem(menuItem("Normal Speed", #selector(rateNormal), "="))
        playbackMenu.addItem(.separator())
        playbackMenu.addItem(menuItem("Step Forward", #selector(stepFrameForward), "."))
        playbackMenu.addItem(menuItem("Step Backward", #selector(stepFrameBackward), ","))
        playbackMenu.addItem(.separator())
        playbackMenu.addItem(menuItem("Jump to Beginning", #selector(jumpToStart), "\u{F702}", modifiers: .command))
        playbackMenu.addItem(menuItem("Jump to End", #selector(jumpToEnd), "\u{F703}", modifiers: .command))
        playbackMenu.addItem(.separator())
        playbackMenu.addItem(menuItem("Mute", #selector(toggleMute), "m"))
        playbackMenu.addItem(menuItem("Loop", #selector(toggleLoop), "l"))
        playbackItem.submenu = playbackMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(menuItem("Toggle Full Screen", #selector(toggleFullScreen), "f",
                                  modifiers: [.command, .control]))
        viewMenu.addItem(menuItem("MetalFX Spatial", #selector(toggleMetalFX), "x"))
        viewItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    private func menuItem(_ title: String, _ action: Selector, _ key: String,
                          modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let loaded = player?.hasItem == true
        switch item.action {
        case #selector(togglePlay):
            item.title = player?.isPlaying == true ? "Pause" : "Play"
        case #selector(toggleMute):
            item.state = player?.isMuted == true ? .on : .off
        case #selector(toggleLoop):
            item.state = player?.isLooping == true ? .on : .off
            return true
        case #selector(toggleMetalFX):
            item.state = player?.isMetalFXEnabled == true ? .on : .off
            return true
        case #selector(rateUp), #selector(rateDown), #selector(rateNormal),
             #selector(stepFrameForward), #selector(stepFrameBackward),
             #selector(jumpToStart), #selector(jumpToEnd):
            break
        default:
            return true
        }
        return loaded
    }

    @objc private func togglePlay() { player?.togglePlay() }
    @objc private func rateUp() { player?.stepRate(1) }
    @objc private func rateDown() { player?.stepRate(-1) }
    @objc private func rateNormal() { player?.setRate(1) }
    @objc private func stepFrameForward() { player?.stepFrame(1) }
    @objc private func stepFrameBackward() { player?.stepFrame(-1) }
    @objc private func jumpToStart() { player?.jumpToStart() }
    @objc private func jumpToEnd() { player?.jumpToEnd() }
    @objc private func toggleMute() { player?.toggleMute() }
    @objc private func toggleLoop() { player?.isLooping.toggle() }
    @objc private func toggleMetalFX() { player?.isMetalFXEnabled.toggle() }
    @objc private func toggleFullScreen() { window?.toggleFullScreen(nil) }
}
