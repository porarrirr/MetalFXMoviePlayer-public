import MetalKit
import UIKit
import UniformTypeIdentifiers

final class PlayerView: MTKView, PlayerSeekUpdating {
    weak var player: VideoPlayer?
    var onOpenRequest: (() -> Void)?
    /// Fired when the on-screen chrome is shown or hidden.
    var onChromeVisibilityChange: ((Bool) -> Void)?
    var onCloseRequest: (() -> Void)?
    var onPiPRequest: (() -> Void)?
    var onQueueRequest: (() -> Void)?
    var onPreviousRequest: (() -> Void)?
    var onNextRequest: (() -> Void)?
    var onRepeatModeRequest: (() -> Void)?
    /// A video file was dropped; the URL is a persistent copy already
    /// moved into the app's Documents folder by the caller.
    var onDropURL: ((URL) -> Void)?

    /// True while all controls and labels are hidden (immersive playback).
    private(set) var chromeHidden = false

    // Queue/host-side state, mirrored into the controls by
    // updatePlaybackControls().
    var repeatMode: RepeatMode = .off
    var isPiPActive = false
    var canGoPrevious = false
    var canGoNext = false

    private let topBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let openButton = UIButton(type: .system)
    private let fxButton = UIButton(type: .system)
    private let pipButton = UIButton(type: .system)
    private let queueButton = UIButton(type: .system)

    private let bottomBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let previousButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let seekSlider = UISlider()
    private let timeLabel = UILabel()
    private let rateButton = UIButton(type: .system)
    private let muteButton = UIButton(type: .system)
    private let volumeSlider = UISlider()
    private let loopButton = UIButton(type: .system)
    private let fullScreenButton = UIButton(type: .system)

    private var isSeeking = false
    private var autoHideWorkItem: DispatchWorkItem?

    override init(frame frameRect: CGRect, device: (any MTLDevice)?) {
        super.init(frame: frameRect, device: device)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    func configure() {
        backgroundColor = .black
        preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond

        configureTopBar()
        configureBottomBar()
        layoutBars()

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapGesture(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)

        addInteraction(UIDropInteraction(delegate: self))
    }

    // MARK: - Layout

    private func configureTopBar() {
        configureButton(closeButton, symbol: "chevron.down", action: #selector(closeTapped(_:)))
        configureButton(openButton, symbol: "folder", action: #selector(openTapped(_:)))
        configureButton(pipButton, symbol: "pip.enter", action: #selector(pipTapped(_:)))
        configureButton(queueButton, symbol: "list.bullet", action: #selector(queueTapped(_:)))

        // Text-only FX toggle (no suitable SF Symbol exists).
        fxButton.setTitle("FX", for: .normal)
        fxButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        fxButton.tintColor = .white
        fxButton.addTarget(self, action: #selector(fxTapped(_:)), for: .touchUpInside)
        fxButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.7)

        let titles = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        titles.axis = .vertical
        titles.alignment = .leading
        titles.spacing = 1

        let stack = UIStackView(arrangedSubviews: [
            closeButton, openButton, titles, UIView(), fxButton, pipButton, queueButton,
        ])
        stack.spacing = 10
        stack.alignment = .center
        topBar.contentView.addSubview(stack)
        stack.pinEdges(to: topBar.contentView,
                       insets: UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10))
        styleBar(topBar)
    }

    private func configureBottomBar() {
        configureButton(previousButton, symbol: "backward.end.fill",
                        action: #selector(previousTapped(_:)))
        configureButton(playButton, symbol: "play.fill", action: #selector(playToggled(_:)))
        configureButton(nextButton, symbol: "forward.end.fill",
                        action: #selector(nextTapped(_:)))
        configureButton(muteButton, symbol: "speaker.wave.2.fill", action: #selector(muteToggled(_:)))
        configureButton(loopButton, symbol: "repeat", action: #selector(loopTapped(_:)))
        configureButton(fullScreenButton, symbol: "arrow.up.left.and.arrow.down.right",
                        action: #selector(fullScreenTapped(_:)))

        seekSlider.minimumValue = 0
        seekSlider.maximumValue = 1
        seekSlider.isContinuous = true
        seekSlider.addTarget(self, action: #selector(seekChanged(_:)), for: .valueChanged)
        seekSlider.addTarget(self, action: #selector(seekBegan(_:)), for: .touchDown)
        seekSlider.addTarget(self, action: #selector(seekEnded(_:)),
                             for: [.touchUpInside, .touchUpOutside, .touchCancel])

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        timeLabel.text = "0:00 / 0:00"
        timeLabel.textAlignment = .center
        timeLabel.widthAnchor.constraint(equalToConstant: 92).isActive = true

        rateButton.showsMenuAsPrimaryAction = true
        rateButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rateButton.tintColor = .white
        updateRateMenu()

        volumeSlider.minimumValue = 0
        volumeSlider.maximumValue = 1
        volumeSlider.value = 1
        volumeSlider.addTarget(self, action: #selector(volumeChanged(_:)), for: .valueChanged)
        volumeSlider.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let transport = UIStackView(arrangedSubviews: [
            previousButton, playButton, nextButton, seekSlider, timeLabel, rateButton,
        ])
        transport.spacing = 8
        transport.alignment = .center

        let options = UIStackView(arrangedSubviews: [
            muteButton, volumeSlider, UIView(), loopButton, fullScreenButton,
        ])
        options.spacing = 8
        options.alignment = .center

        let rows = UIStackView(arrangedSubviews: [transport, options])
        rows.axis = .vertical
        rows.spacing = 4
        bottomBar.contentView.addSubview(rows)
        rows.pinEdges(to: bottomBar.contentView,
                      insets: UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10))
        styleBar(bottomBar)
    }

    private func styleBar(_ bar: UIVisualEffectView) {
        bar.layer.cornerRadius = 12
        bar.layer.masksToBounds = true
    }

    private func layoutBars() {
        addSubview(topBar)
        addSubview(bottomBar)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
            topBar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            topBar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),

            bottomBar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6),
            bottomBar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            bottomBar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
        ])
    }

    private func configureButton(_ button: UIButton, symbol: String, action: Selector) {
        button.setImage(symbolImage(symbol), for: .normal)
        button.tintColor = .white
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func symbolImage(_ name: String) -> UIImage? {
        UIImage(systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
    }

    // MARK: - State display

    /// Reflects the player's play/pause, speed, mute, volume state and the
    /// host-side queue/repeat/PiP state in the controls.
    func updatePlaybackControls() {
        guard let player else { return }
        playButton.setImage(
            symbolImage(player.isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        updateRateMenu()
        muteButton.setImage(
            symbolImage(player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"),
            for: .normal)
        volumeSlider.value = player.volume

        previousButton.isEnabled = canGoPrevious
        previousButton.alpha = canGoPrevious ? 1 : 0.35
        nextButton.isEnabled = canGoNext
        nextButton.alpha = canGoNext ? 1 : 0.35

        switch repeatMode {
        case .off:
            loopButton.setImage(symbolImage("repeat"), for: .normal)
            loopButton.tintColor = .white
        case .one:
            loopButton.setImage(symbolImage("repeat.1"), for: .normal)
            loopButton.tintColor = .systemYellow
        case .all:
            loopButton.setImage(symbolImage("repeat"), for: .normal)
            loopButton.tintColor = .systemYellow
        }

        fxButton.tintColor = player.isMetalFXEnabled ? .systemYellow : .white
        pipButton.tintColor = isPiPActive ? .systemYellow : .white

        if player.isPlaying {
            scheduleAutoHide()
        } else {
            autoHideWorkItem?.cancel()
            setChrome(hidden: false)
        }
    }

    private func updateRateMenu() {
        let current = player?.playbackRate ?? 1
        rateButton.setTitle(rateTitle(current), for: .normal)
        rateButton.menu = UIMenu(children: VideoPlayer.playbackRates.map { rate in
            UIAction(title: rateTitle(rate),
                     state: abs(rate - current) < 0.001 ? .on : .off) { [weak self] _ in
                self?.player?.setRate(rate)
            }
        })
    }

    private func rateTitle(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate)×"
    }

    func updateSeek(current: Double, duration: Double) {
        guard !isSeeking else { return }
        seekSlider.value = duration > 0 ? Float(current / duration) : 0
        timeLabel.text = "\(format(current)) / \(format(duration))"
    }

    func setStatus(_ text: String) {
        statusLabel.text = text
    }

    func setTitle(_ text: String) {
        titleLabel.text = text
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Chrome visibility

    private func setChrome(hidden: Bool) {
        guard hidden != chromeHidden else { return }
        chromeHidden = hidden
        topBar.isUserInteractionEnabled = !hidden
        bottomBar.isUserInteractionEnabled = !hidden
        UIView.animate(withDuration: 0.25) {
            self.topBar.alpha = hidden ? 0 : 1
            self.bottomBar.alpha = hidden ? 0 : 1
        }
        onChromeVisibilityChange?(hidden)
    }

    private func scheduleAutoHide() {
        autoHideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.setChrome(hidden: true) }
        autoHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    @objc private func tapGesture(_ gesture: UITapGestureRecognizer) {
        if chromeHidden {
            setChrome(hidden: false)
            if player?.isPlaying == true {
                scheduleAutoHide()
            }
        } else {
            setChrome(hidden: true)
        }
    }

    // MARK: - Control actions

    @objc private func closeTapped(_ sender: UIButton) {
        onCloseRequest?()
    }

    @objc private func openTapped(_ sender: UIButton) {
        onOpenRequest?()
    }

    @objc private func pipTapped(_ sender: UIButton) {
        onPiPRequest?()
    }

    @objc private func queueTapped(_ sender: UIButton) {
        onQueueRequest?()
    }

    @objc private func fxTapped(_ sender: UIButton) {
        player?.isMetalFXEnabled.toggle()
        updatePlaybackControls()
    }

    @objc private func previousTapped(_ sender: UIButton) {
        onPreviousRequest?()
    }

    @objc private func nextTapped(_ sender: UIButton) {
        onNextRequest?()
    }

    @objc private func playToggled(_ sender: UIButton) {
        player?.togglePlay()
    }

    @objc private func muteToggled(_ sender: UIButton) {
        player?.toggleMute()
    }

    @objc private func loopTapped(_ sender: UIButton) {
        onRepeatModeRequest?()
    }

    @objc private func fullScreenTapped(_ sender: UIButton) {
        setChrome(hidden: true)
    }

    @objc private func seekBegan(_ sender: UISlider) {
        isSeeking = true
    }

    @objc private func seekEnded(_ sender: UISlider) {
        isSeeking = false
    }

    @objc private func seekChanged(_ sender: UISlider) {
        player?.seekToFraction(Double(sender.value))
    }

    @objc private func volumeChanged(_ sender: UISlider) {
        player?.setVolume(sender.value)
    }

    // MARK: - Keyboard (hardware keyboards, e.g. iPad)

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(keyTogglePlay)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [],
                         action: #selector(keySeekBack)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [],
                         action: #selector(keySeekForward)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: .shift,
                         action: #selector(keySeekBackLarge)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: .shift,
                         action: #selector(keySeekForwardLarge)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: .command,
                         action: #selector(keyJumpToStart)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: .command,
                         action: #selector(keyJumpToEnd)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [],
                         action: #selector(keyVolumeUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [],
                         action: #selector(keyVolumeDown)),
            UIKeyCommand(input: "m", modifierFlags: [], action: #selector(keyToggleMute)),
            UIKeyCommand(input: "l", modifierFlags: [], action: #selector(keyToggleLoop)),
            UIKeyCommand(input: "[", modifierFlags: [], action: #selector(keyRateDown)),
            UIKeyCommand(input: "]", modifierFlags: [], action: #selector(keyRateUp)),
            UIKeyCommand(input: "=", modifierFlags: [], action: #selector(keyRateNormal)),
            UIKeyCommand(input: ",", modifierFlags: [], action: #selector(keyFrameBack)),
            UIKeyCommand(input: ".", modifierFlags: [], action: #selector(keyFrameForward)),
            UIKeyCommand(input: "o", modifierFlags: [], action: #selector(keyOpen)),
            UIKeyCommand(input: "f", modifierFlags: [], action: #selector(keyFullScreen)),
            UIKeyCommand(input: "x", modifierFlags: [], action: #selector(keyToggleFX)),
            UIKeyCommand(input: "n", modifierFlags: [], action: #selector(keyNext)),
            UIKeyCommand(input: "p", modifierFlags: [], action: #selector(keyPrevious)),
        ]
    }

    @objc private func keyTogglePlay() { player?.togglePlay() }
    @objc private func keySeekBack() { player?.seek(by: -5) }
    @objc private func keySeekForward() { player?.seek(by: 5) }
    @objc private func keySeekBackLarge() { player?.seek(by: -30) }
    @objc private func keySeekForwardLarge() { player?.seek(by: 30) }
    @objc private func keyJumpToStart() { player?.jumpToStart() }
    @objc private func keyJumpToEnd() { player?.jumpToEnd() }
    @objc private func keyVolumeUp() { player?.adjustVolume(by: 0.1) }
    @objc private func keyVolumeDown() { player?.adjustVolume(by: -0.1) }
    @objc private func keyToggleMute() { player?.toggleMute() }
    @objc private func keyToggleLoop() { onRepeatModeRequest?() }
    @objc private func keyRateDown() { player?.stepRate(-1) }
    @objc private func keyRateUp() { player?.stepRate(1) }
    @objc private func keyRateNormal() { player?.setRate(1) }
    @objc private func keyFrameBack() { player?.stepFrame(-1) }
    @objc private func keyFrameForward() { player?.stepFrame(1) }
    @objc private func keyOpen() { onOpenRequest?() }
    @objc private func keyFullScreen() { setChrome(hidden: !chromeHidden) }
    @objc private func keyToggleFX() {
        player?.isMetalFXEnabled.toggle()
        updatePlaybackControls()
    }
    @objc private func keyNext() { onNextRequest?() }
    @objc private func keyPrevious() { onPreviousRequest?() }
}

// MARK: - Tap handling outside the control bars

extension PlayerView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: self)
        return !(topBar.frame.contains(point) || bottomBar.frame.contains(point))
    }
}

// MARK: - Drag & Drop

extension PlayerView: UIDropInteractionDelegate {
    private static let dropTypes: [UTType] = [.movie, .video, .audiovisualContent]

    func dropInteraction(_ interaction: UIDropInteraction,
                         canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(
            toTypeIdentifiers: Self.dropTypes.map(\.identifier))
    }

    func dropInteraction(_ interaction: UIDropInteraction,
                         sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let provider = session.items.first?.itemProvider,
              let type = Self.dropTypes.first(where: {
                  provider.hasItemConformingToTypeIdentifier($0.identifier)
              })
        else { return }

        // The provider's file URL is only valid inside the completion
        // callback; copy it to a persistent location so playback and the
        // library bookmark survive afterwards.
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, _ in
            guard let url, let persistent = Self.persistDrop(url) else { return }
            DispatchQueue.main.async {
                self?.onDropURL?(persistent)
            }
        }
    }

    /// Drops arrive as temporary files (the one import path that cannot be
    /// a bookmark reference); keep them under Documents/Media.
    private static func persistDrop(_ url: URL) -> URL? {
        let media = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Media", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            var destination = media.appendingPathComponent(url.lastPathComponent)
            var counter = 1
            let base = destination.deletingPathExtension().lastPathComponent
            let ext = destination.pathExtension
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = media.appendingPathComponent("\(base)-\(counter).\(ext)")
                counter += 1
            }
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}

private extension UIView {
    func pinEdges(to other: UIView, insets: UIEdgeInsets) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }
}
