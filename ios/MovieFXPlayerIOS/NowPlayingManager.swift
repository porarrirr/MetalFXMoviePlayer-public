import AVFoundation
import MediaPlayer

/// Wires MPNowPlayingInfoCenter + MPRemoteCommandCenter to the player so
/// the video shows up on the lock screen / Control Center, and handles
/// audio-session interruptions (calls, Siri) for background playback.
@MainActor
final class NowPlayingManager: NSObject {
    private let player: VideoPlayer
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    private var interruptionObserver: NSObjectProtocol?
    private var info: [String: Any] = [:]

    init(player: VideoPlayer) {
        self.player = player
        super.init()
        installRemoteCommands()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // MARK: - Now Playing info

    /// Call when a different item starts playing.
    func itemDidChange(title: String, duration: Double) {
        info = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? player.playbackRate : 0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Call on seek and periodically (~0.25s) to keep elapsed time fresh.
    func updatePosition(elapsed: Double, duration: Double) {
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? player.playbackRate : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Remote commands

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.runOnMain { $0.togglePlayIfPaused() } ?? .commandFailed
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.runOnMain { $0.pauseIfPlaying() } ?? .commandFailed
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.runOnMain { $0.togglePlay() } ?? .commandFailed
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.runOnMain { $0.seek(by: -10) } ?? .commandFailed
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.runOnMain { $0.seek(by: 10) } ?? .commandFailed
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            return self?.runOnMain { $0.seek(to: event.positionTime) } ?? .commandFailed
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, let onNext = self.onNext else { return .commandFailed }
            Task { @MainActor in onNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, let onPrevious = self.onPrevious else { return .commandFailed }
            Task { @MainActor in onPrevious() }
            return .success
        }
    }

    private func runOnMain(
        _ action: @escaping @MainActor (VideoPlayer) -> Void
    ) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor [weak self] in
            guard let self else { return }
            action(self.player)
        }
        return .success
    }

    // MARK: - Interruptions

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        switch type {
        case .began:
            player.player?.pause()
        case .ended:
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                player.player?.play()
            }
        @unknown default:
            break
        }
    }
}

private extension VideoPlayer {
    func togglePlayIfPaused() {
        if !isPlaying { togglePlay() }
    }

    func pauseIfPlaying() {
        if isPlaying { togglePlay() }
    }
}
