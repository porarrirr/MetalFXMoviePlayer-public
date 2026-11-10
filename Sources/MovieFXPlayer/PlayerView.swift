import AppKit
import MetalKit

final class PlayerView: MTKView, PlayerSeekUpdating {
    weak var player: VideoPlayer?
    var onOpenRequest: (() -> Void)?

    private let playButton = NSButton()
    private let seekSlider = NSSlider()
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let ratePopUp = NSPopUpButton()
    private let muteButton = NSButton()
    private let volumeSlider = NSSlider()
    private let fullScreenButton = NSButton()
    private var isSeeking = false

    func configure() {
        wantsLayer = true
        registerForDraggedTypes([.fileURL])

        configureButton(playButton, symbol: "play.fill", action: #selector(playToggled(_:)))
        configureButton(muteButton, symbol: "speaker.wave.2.fill", action: #selector(muteToggled(_:)))
        configureButton(fullScreenButton, symbol: "arrow.up.left.and.arrow.down.right",
                        action: #selector(fullScreenToggled(_:)))

        seekSlider.translatesAutoresizingMaskIntoConstraints = false
        seekSlider.minValue = 0
        seekSlider.maxValue = 1
        seekSlider.isContinuous = true
        seekSlider.target = self
        seekSlider.action = #selector(seekChanged(_:))
        seekSlider.controlSize = .small
        seekSlider.refusesFirstResponder = true
        addSubview(seekSlider)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        addSubview(timeLabel)

        ratePopUp.translatesAutoresizingMaskIntoConstraints = false
        ratePopUp.controlSize = .small
        ratePopUp.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        ratePopUp.pullsDown = false
        ratePopUp.addItems(withTitles: VideoPlayer.playbackRates.map(rateTitle))
        ratePopUp.selectItem(at: VideoPlayer.playbackRates.firstIndex(of: 1.0) ?? 0)
        ratePopUp.target = self
        ratePopUp.action = #selector(rateChanged(_:))
        ratePopUp.refusesFirstResponder = true
        addSubview(ratePopUp)

        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.floatValue = 1
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volumeSlider.controlSize = .small
        volumeSlider.refusesFirstResponder = true
        addSubview(volumeSlider)

        NSLayoutConstraint.activate([
            playButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            playButton.centerYAnchor.constraint(equalTo: seekSlider.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 22),

            seekSlider.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 4),
            seekSlider.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -8),
            seekSlider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            timeLabel.trailingAnchor.constraint(equalTo: ratePopUp.leadingAnchor, constant: -8),
            timeLabel.centerYAnchor.constraint(equalTo: seekSlider.centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 100),

            ratePopUp.centerYAnchor.constraint(equalTo: seekSlider.centerYAnchor),
            ratePopUp.widthAnchor.constraint(equalToConstant: 70),
            ratePopUp.trailingAnchor.constraint(equalTo: muteButton.leadingAnchor, constant: -6),

            muteButton.centerYAnchor.constraint(equalTo: seekSlider.centerYAnchor),
            muteButton.widthAnchor.constraint(equalToConstant: 20),
            muteButton.trailingAnchor.constraint(equalTo: volumeSlider.leadingAnchor, constant: -4),

            volumeSlider.centerYAnchor.constraint(equalTo: seekSlider.centerYAnchor),
            volumeSlider.widthAnchor.constraint(equalToConstant: 64),
            volumeSlider.trailingAnchor.constraint(equalTo: fullScreenButton.leadingAnchor, constant: -8),

            fullScreenButton.centerYAnchor.constraint(equalTo: seekSlider.centerYAnchor),
            fullScreenButton.widthAnchor.constraint(equalToConstant: 22),
            fullScreenButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    override var acceptsFirstResponder: Bool { true }

    private func configureButton(_ button: NSButton, symbol: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.image = symbolImage(symbol)
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.refusesFirstResponder = true
        addSubview(button)
    }

    private func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }

    private func rateTitle(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate)×"
    }

    /// Reflects the player's play/pause, speed, mute and volume state in the controls.
    func updatePlaybackControls() {
        guard let player else { return }
        playButton.image = symbolImage(player.isPlaying ? "pause.fill" : "play.fill")
        if let index = VideoPlayer.playbackRates.firstIndex(where: {
            abs($0 - player.playbackRate) < 0.001
        }) {
            ratePopUp.selectItem(at: index)
        }
        muteButton.image = symbolImage(player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        volumeSlider.floatValue = player.volume
    }

    func updateSeek(current: Double, duration: Double) {
        guard !isSeeking else { return }
        seekSlider.doubleValue = duration > 0 ? current / duration : 0
        timeLabel.stringValue = "\(format(current)) / \(format(duration))"
    }

    @objc private func seekChanged(_ sender: NSSlider) {
        let eventType = NSApp.currentEvent?.type
        isSeeking = eventType == .leftMouseDown || eventType == .leftMouseDragged
        player?.seekToFraction(sender.doubleValue)
    }

    @objc private func playToggled(_ sender: NSButton) {
        player?.togglePlay()
    }

    @objc private func rateChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard VideoPlayer.playbackRates.indices.contains(index) else { return }
        player?.setRate(VideoPlayer.playbackRates[index])
    }

    @objc private func muteToggled(_ sender: NSButton) {
        player?.toggleMute()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        player?.setVolume(sender.floatValue)
    }

    @objc private func fullScreenToggled(_ sender: NSButton) {
        window?.toggleFullScreen(nil)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ":
            player?.togglePlay()
        case "f":
            window?.toggleFullScreen(nil)
        case "l":
            player?.isLooping.toggle()
        case "o":
            onOpenRequest?()
        case "m":
            player?.toggleMute()
        case "[":
            player?.stepRate(-1)
        case "]":
            player?.stepRate(1)
        case "=":
            player?.setRate(1)
        case ",", "<":
            player?.stepFrame(-1)
        case ".", ">":
            player?.stepFrame(1)
        default:
            if !handleArrowKey(event) {
                super.keyDown(with: event)
            }
        }
    }

    private func handleArrowKey(_ event: NSEvent) -> Bool {
        let step: Double = event.modifierFlags.contains(.shift) ? 30 : 5
        switch event.keyCode {
        case 123: player?.seek(by: -step)        // left
        case 124: player?.seek(by: step)         // right
        case 125: player?.adjustVolume(by: -0.1) // down
        case 126: player?.adjustVolume(by: 0.1)  // up
        default: return false
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.toggleFullScreen(nil)
        } else {
            super.mouseDown(with: event)
        }
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )?.first as? URL else {
            return false
        }
        player?.open(url: url)
        return true
    }
}
