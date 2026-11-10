import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private var store: LibraryStore!
    private var queue: PlaybackQueue!
    private var player: VideoPlayer!
    private var playerViewController: PlayerViewController!

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window

        guard let renderer = MetalFXRenderer.make() else {
            window.rootViewController = UnsupportedDeviceViewController()
            window.makeKeyAndVisible()
            return
        }

        store = LibraryStore()
        queue = PlaybackQueue()
        player = VideoPlayer(renderer: renderer)
        playerViewController = PlayerViewController(player: player, store: store, queue: queue)

        let library = LibraryViewController(store: store, queue: queue)
        library.onPlayItem = { [weak self] item in
            self?.playFromLibrary(item)
        }
        let navigation = UINavigationController(rootViewController: library)
        navigation.navigationBar.prefersLargeTitles = true
        window.rootViewController = navigation
        window.makeKeyAndVisible()

        if let url = connectionOptions.urlContexts.first?.url {
            importAndPlay(url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        importAndPlay(url)
    }

    // MARK: - Coordination

    private func playFromLibrary(_ item: LibraryItem) {
        presentPlayerIfNeeded()
        playerViewController.playFromLibrary(item)
    }

    private func importAndPlay(_ url: URL) {
        presentPlayerIfNeeded()
        playerViewController.importAndPlay(url: url)
    }

    private func presentPlayerIfNeeded() {
        guard playerViewController.presentingViewController == nil,
              let presenter = window?.rootViewController
        else { return }
        presenter.present(playerViewController, animated: true)
    }
}

/// Shown when Metal or MetalFX Spatial is unavailable (unsupported GPU,
/// e.g. the simulator).
final class UnsupportedDeviceViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let label = UILabel()
        label.text = "MetalFX Spatial is not available on this device.\n"
            + "MovieFX Player requires an iPhone or iPad that supports MetalFX."
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }
}
