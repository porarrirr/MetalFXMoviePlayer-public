import AVFoundation
import AVKit
import UIKit
import UniformTypeIdentifiers

final class PlayerViewController: UIViewController {
    private let player: VideoPlayer
    private let store: LibraryStore
    private let queue: PlaybackQueue
    private let nowPlaying: NowPlayingManager

    /// Security-scoped resource held for the currently playing file.
    private var securityScopedURL: URL?
    private var currentItem: LibraryItem?
    private var lastPositionWrite: Double = -1
    private var lastNowPlayingWrite: Double = -1

    private var pipController: AVPictureInPictureController?
    private let pipLayer = AVPlayerLayer()
    private var backgroundObserver: NSObjectProtocol?

    init(player: VideoPlayer, store: LibraryStore, queue: PlaybackQueue) {
        self.player = player
        self.store = store
        self.queue = queue
        self.nowPlaying = NowPlayingManager(player: player)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var playerView: PlayerView { view as! PlayerView }

    override func loadView() {
        let playerView = PlayerView(frame: .zero, device: nil)
        playerView.configure()
        player.attach(view: playerView)
        playerView.player = player
        view = playerView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)

        player.onStatusChange = { [weak self] status in
            self?.playerView.setStatus(status)
        }
        player.onTitleChange = { [weak self] title in
            self?.playerView.setTitle(self?.currentItem?.name ?? title)
        }
        player.onPlaybackStateChange = { [weak self] in
            self?.playerView.updatePlaybackControls()
            self?.savePosition()
        }
        player.onItemEnd = { [weak self] in
            self?.advanceQueue(resetPosition: true)
        }
        player.onTimeUpdate = { [weak self] seconds in
            self?.recordPosition(seconds)
        }

        playerView.onOpenRequest = { [weak self] in self?.presentDocumentPicker() }
        playerView.onCloseRequest = { [weak self] in self?.close() }
        playerView.onPiPRequest = { [weak self] in self?.togglePiP() }
        playerView.onQueueRequest = { [weak self] in self?.presentQueue() }
        playerView.onPreviousRequest = { [weak self] in self?.playPrevious() }
        playerView.onNextRequest = { [weak self] in self?.advanceQueue(resetPosition: false) }
        playerView.onRepeatModeRequest = { [weak self] in self?.cycleRepeatMode() }
        playerView.onDropURL = { [weak self] url in self?.importAndPlay(url: url) }
        playerView.onChromeVisibilityChange = { [weak self] _ in
            self?.setNeedsStatusBarAppearanceUpdate()
            self?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }

        nowPlaying.onNext = { [weak self] in self?.advanceQueue(resetPosition: false) }
        nowPlaying.onPrevious = { [weak self] in self?.playPrevious() }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        }

        player.isLooping = (queue.repeatMode == .one)
        setupPiP()
        refreshQueueState()
        playerView.updatePlaybackControls()
    }

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    // MARK: - Playback entry points

    /// Plays a library item: the whole library becomes the queue with the
    /// item's index selected.
    func playFromLibrary(_ item: LibraryItem) {
        guard let index = store.items.firstIndex(where: { $0.id == item.id }) else { return }
        queue.replace(with: store.items, index: index)
        if let current = queue.current {
            playItem(current)
        }
    }

    /// Registers a URL in the library (bookmark reference, no copy) and
    /// plays it. The URL must be usable right now: picker/Open In URLs are
    /// wrapped in a security scope here; drop URLs are already persistent.
    func importAndPlay(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let item = store.importURL(url) else {
            showAlert(title: "取り込みに失敗しました",
                      message: "このファイルをライブラリに登録できません。")
            return
        }
        playFromLibrary(item)
    }

    /// Resolves and opens a queue/library item.
    private func playItem(_ item: LibraryItem) {
        guard let url = store.resolve(item) else {
            missingFileAlert(item)
            refreshQueueState()
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        guard (try? url.checkResourceIsReachable()) ?? false else {
            if accessed { url.stopAccessingSecurityScopedResource() }
            missingFileAlert(item)
            refreshQueueState()
            return
        }
        savePosition()
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = accessed ? url : nil

        currentItem = item
        lastPositionWrite = -1
        player.open(url: url)
        pipLayer.player = player.player
        if let position = item.lastPosition, position > 0.5 {
            player.seek(to: position)
        }
        playerView.setTitle(item.name)
        let duration = player.duration
        nowPlaying.itemDidChange(title: item.name,
                                 duration: duration.isFinite ? duration : 0)
        refreshQueueState()
    }

    /// Moves to the next queue item, skipping files whose bookmark no
    /// longer resolves. `resetPosition` clears the outgoing item's resume
    /// point (natural end) instead of saving it (manual skip).
    private func advanceQueue(resetPosition: Bool) {
        if resetPosition, let item = currentItem {
            store.setPosition(0, for: item.id)
        } else {
            savePosition()
        }
        var attempts = queue.items.count
        while attempts > 0, let item = queue.nextItem() {
            attempts -= 1
            guard store.isReachable(item) else { continue }
            playItem(item)
            return
        }
        // Queue exhausted: stay paused at the end.
        refreshQueueState()
    }

    /// Previous button: within the first 3 seconds jumps to the previous
    /// item, otherwise restarts the current one.
    private func playPrevious() {
        if player.currentTime > 3 {
            player.seek(to: 0)
            return
        }
        savePosition()
        var attempts = queue.items.count
        while attempts > 0, let item = queue.previousItem() {
            attempts -= 1
            guard store.isReachable(item) else { continue }
            playItem(item)
            return
        }
    }

    private func cycleRepeatMode() {
        let mode = queue.cycleRepeatMode()
        player.isLooping = (mode == .one)
        refreshQueueState()
    }

    private func refreshQueueState() {
        playerView.canGoPrevious = queue.canGoPrevious
        playerView.canGoNext = queue.canGoNext
        playerView.repeatMode = queue.repeatMode
        playerView.updatePlaybackControls()
    }

    // MARK: - Resume position

    private func recordPosition(_ seconds: Double) {
        guard let item = currentItem else { return }
        if abs(seconds - lastPositionWrite) >= 5 {
            lastPositionWrite = seconds
            store.setPosition(seconds, for: item.id)
        }
        if abs(seconds - lastNowPlayingWrite) >= 1 {
            lastNowPlayingWrite = seconds
            nowPlaying.updatePosition(elapsed: seconds, duration: player.duration)
        }
    }

    private func savePosition() {
        guard let item = currentItem else { return }
        store.setPosition(player.currentTime, for: item.id)
    }

    // MARK: - Queue sheet

    private func presentQueue() {
        let queueVC = QueueViewController(queue: queue)
        queueVC.onSelect = { [weak self] index in
            guard let self else { return }
            dismiss(animated: true)
            queue.select(index: index)
            if let item = queue.current {
                playItem(item)
            }
        }
        queueVC.onChange = { [weak self] in self?.refreshQueueState() }
        present(UINavigationController(rootViewController: queueVC), animated: true)
    }

    // MARK: - PiP

    private func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

        // PiP requires an AVPlayerLayer in the view hierarchy. The visible
        // output stays the MetalFX MTKView; this hidden 1pt layer only feeds
        // the PiP window, which therefore shows the decoded frames as-is.
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        host.alpha = 0.01
        host.isUserInteractionEnabled = false
        host.layer.addSublayer(pipLayer)
        pipLayer.frame = host.bounds
        view.addSubview(host)
        view.sendSubviewToBack(host)

        guard let controller = AVPictureInPictureController(playerLayer: pipLayer) else { return }
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller
    }

    private func togglePiP() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    // MARK: - Document picker

    private func presentDocumentPicker() {
        let types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .audiovisualContent]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    // MARK: - Close / chrome

    private func close() {
        savePosition()
        nowPlaying.clear()
        player.player?.pause()
        dismiss(animated: true)
    }

    private func missingFileAlert(_ item: LibraryItem) {
        showAlert(title: "ファイルが見つかりません",
                  message: "「\(item.name)」は削除または移動されたため再生できません。")
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    override var prefersStatusBarHidden: Bool {
        (view as? PlayerView)?.chromeHidden ?? false
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        (view as? PlayerView)?.chromeHidden ?? false
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        (view as? PlayerView)?.chromeHidden == true ? .all : []
    }
}

extension PlayerViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        importAndPlay(url: url)
    }
}

extension PlayerViewController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        playerView.isPiPActive = true
        playerView.updatePlaybackControls()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        playerView.isPiPActive = false
        playerView.updatePlaybackControls()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStop completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        showAlert(title: "PiP を開始できません", message: error.localizedDescription)
    }
}
