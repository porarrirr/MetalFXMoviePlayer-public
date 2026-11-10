import AVFoundation
import CoreMedia
import MetalKit
import QuartzCore

/// Receives periodic playback-position updates for display.
/// Implemented by each platform's player view.
@MainActor
protocol PlayerSeekUpdating: AnyObject {
    func updateSeek(current: Double, duration: Double)
}

@MainActor
final class VideoPlayer: NSObject {
    /// Selectable playback speeds, slowest to fastest.
    static let playbackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    private(set) var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var mutedObservation: NSKeyValueObservation?
    private var displaySizeLoadID = 0

    /// How the current video must be displayed: the size its preferred
    /// transform applies to (presentation dimensions — pixel aspect ratio
    /// and clean aperture included when the format description carries
    /// them) plus the transform itself. `.zero` until the track loads.
    private(set) var displayGeometry = DisplayGeometry.zero

    var isLooping = false

    /// Intended playback speed, applied via `defaultRate`/`rate`.
    /// Survives pause and file switches.
    private(set) var playbackRate: Float = 1.0
    private(set) var volume: Float = 1.0
    private(set) var isMuted = false
    /// True when a non-looping item finished; the next play() rewinds first.
    private var reachedEnd = false

    var isPlaying: Bool { (player?.rate ?? 0) != 0 }
    var hasItem: Bool { player?.currentItem != nil }
    /// Current playback position in seconds.
    var currentTime: Double { player?.currentTime().seconds ?? 0 }
    var duration: Double { player?.currentItem?.duration.seconds ?? 0 }

    /// Proxy for the renderer's MetalFX toggle.
    var isMetalFXEnabled: Bool {
        get { renderer.isMetalFXEnabled }
        set { renderer.isMetalFXEnabled = newValue }
    }

    var onStatusChange: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    /// Fired when play/pause, rate, volume or mute state changes.
    var onPlaybackStateChange: (() -> Void)?
    /// Fired when a non-looping item reaches its end; lets the host
    /// decide whether to advance a queue or stay paused.
    var onItemEnd: (() -> Void)?
    /// Fired by the periodic time observer (~0.25s) with the item's
    /// elapsed seconds; used for resume-position and Now Playing updates.
    var onTimeUpdate: ((Double) -> Void)?

    private weak var seekUI: (any PlayerSeekUpdating)?
    private weak var renderView: MTKView?
    private let renderer: MetalFXRenderer
    // Allow sparse frames and short stalls before suspending vsync polling.
    private var lastFrameHostTime = CACurrentMediaTime()

    init(renderer: MetalFXRenderer) {
        self.renderer = renderer
        super.init()
    }

    func attach(view: MTKView & PlayerSeekUpdating) {
        seekUI = view
        renderView = view
        view.device = renderer.device
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = output == nil
        view.enableSetNeedsDisplay = true
        renderer.onNeedsRedraw = { [weak self] in self?.requestRedraw() }
        renderer.frameProvider = { [weak self] in self?.copyCurrentFrame() }
        renderer.displayGeometryProvider = { [weak self] in self?.displayGeometry ?? .zero }
        renderer.onStatusChange = { [weak self] s in self?.onStatusChange?(s) }
        requestRedraw()
    }

    func open(url: URL) {
        displayGeometry = .zero
        renderer.reset()
        let item = AVPlayerItem(url: url)
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        output?.setDelegate(nil, queue: nil)
        videoOutput.setDelegate(self, queue: .main)
        item.add(videoOutput)
        output = videoOutput
        resumeFramePolling()

        // Surface playback failures (missing/unsupported files) instead of
        // leaving a silent black window.
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "cannot play this file"
            Task { @MainActor [weak self] in
                self?.onStatusChange?("ERROR: \(message)")
            }
        }

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isLooping {
                    self.player?.seek(to: .zero)
                    self.player?.play()
                } else {
                    self.reachedEnd = true
                    self.player?.pause()
                    self.onItemEnd?()
                }
            }
        }

        let newPlayer = AVPlayer(playerItem: item)
        player?.pause()
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        player = newPlayer
        reachedEnd = false
        newPlayer.volume = volume
        newPlayer.isMuted = isMuted
        newPlayer.defaultRate = playbackRate

        rateObservation?.invalidate()
        rateObservation = newPlayer.observe(\.rate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.onPlaybackStateChange?() }
        }
        mutedObservation?.invalidate()
        mutedObservation = newPlayer.observe(\.isMuted, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.onPlaybackStateChange?() }
        }

        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak newPlayer] time in
            MainActor.assumeIsolated {
                let duration = newPlayer?.currentItem?.duration.seconds ?? 0
                self?.seekUI?.updateSeek(current: time.seconds, duration: duration)
                self?.onTimeUpdate?(time.seconds)
            }
        }

        loadDisplayGeometry(from: item.asset)
        onTitleChange?(url.lastPathComponent)
        newPlayer.play()
    }

    private func loadDisplayGeometry(from asset: AVAsset) {
        displaySizeLoadID += 1
        let id = displaySizeLoadID
        Task { [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let naturalSize = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform)
            else { return }
            var source = naturalSize
            if let desc = try? await track.load(.formatDescriptions).first {
                let presentation = CMVideoFormatDescriptionGetPresentationDimensions(
                    desc, usePixelAspectRatio: true, useCleanAperture: true)
                if presentation.width > 0, presentation.height > 0 {
                    source = presentation
                }
            }
            guard let self, self.displaySizeLoadID == id else { return }
            self.displayGeometry = DisplayGeometry(sourceSize: source, transform: transform)
            self.requestRedraw()
        }
    }

    /// Called on vsync while polling is active, or for an explicit redraw.
    /// Returns a newly decoded pixel buffer when the video clock advanced to a new frame.
    private func copyCurrentFrame() -> CVPixelBuffer? {
        guard let output, player != nil else { return nil }
        let now = CACurrentMediaTime()
        let time = output.itemTime(forHostTime: now)
        if output.hasNewPixelBuffer(forItemTime: time),
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            lastFrameHostTime = now
            return buffer
        }
        if now - lastFrameHostTime > 0.25 {
            // AVFoundation wakes the display loop for playback, seeks and
            // frame steps, including changes made through the exposed AVPlayer.
            output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
            renderView?.isPaused = true
        }
        return nil
    }

    private func resumeFramePolling() {
        lastFrameHostTime = CACurrentMediaTime()
        renderView?.isPaused = false
    }

    private func requestRedraw() {
        #if os(macOS)
        renderView?.needsDisplay = true
        #else
        renderView?.setNeedsDisplay()
        #endif
    }

    // MARK: - Controls

    func togglePlay() {
        guard let player else { return }
        if player.rate == 0 {
            if reachedEnd {
                reachedEnd = false
                player.seek(to: .zero)
            }
            player.play()
        } else {
            player.pause()
        }
    }

    /// Sets the playback speed without forcing playback when paused.
    func setRate(_ rate: Float) {
        playbackRate = rate
        player?.defaultRate = rate
        if isPlaying {
            player?.rate = rate
        }
        onPlaybackStateChange?()
    }

    /// Moves one step through `playbackRates` (+1 faster, -1 slower).
    func stepRate(_ direction: Int) {
        let rates = Self.playbackRates
        let index = rates.firstIndex(where: { $0 >= playbackRate }) ?? rates.count - 1
        setRate(rates[min(max(index + direction, 0), rates.count - 1)])
    }

    /// Frame stepping; pauses first so the stepped frame stays on screen.
    func stepFrame(_ count: Int) {
        guard let item = player?.currentItem else { return }
        player?.pause()
        item.step(byCount: count)
    }

    func jumpToStart() {
        guard let player else { return }
        reachedEnd = false
        player.seek(to: .zero)
    }

    func jumpToEnd() {
        guard let item = player?.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        player?.seek(to: CMTime(seconds: duration, preferredTimescale: 600))
    }

    func seek(by seconds: Double) {
        guard let player else { return }
        reachedEnd = false
        let target = player.currentTime().seconds + seconds
        player.seek(to: CMTime(seconds: max(target, 0), preferredTimescale: 600))
    }

    /// Absolute seek in seconds.
    func seek(to seconds: Double) {
        guard let player else { return }
        reachedEnd = false
        player.seek(to: CMTime(seconds: max(seconds, 0), preferredTimescale: 600))
    }

    func seekToFraction(_ fraction: Double) {
        guard let item = player?.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        reachedEnd = false
        player?.seek(to: CMTime(seconds: duration * fraction, preferredTimescale: 600))
    }

    func setVolume(_ value: Float) {
        volume = min(max(value, 0), 1)
        player?.volume = volume
        onPlaybackStateChange?()
    }

    func adjustVolume(by delta: Float) {
        setVolume(volume + delta)
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
        onPlaybackStateChange?()
    }
}

extension VideoPlayer: AVPlayerItemOutputPullDelegate {
    nonisolated func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        // The delegate is explicitly installed on the main queue.
        MainActor.assumeIsolated {
            guard sender === output else { return }
            resumeFramePolling()
        }
    }

    nonisolated func outputSequenceWasFlushed(_ sender: AVPlayerItemOutput) {
        MainActor.assumeIsolated {
            guard sender === output else { return }
            resumeFramePolling()
        }
    }
}
