import AVFoundation
import UIKit
import UniformTypeIdentifiers

/// Lists the registered videos. Tap plays (whole library becomes the
/// queue); long-press offers queue edits; Edit allows reorder/delete.
final class LibraryViewController: UITableViewController {
    private let store: LibraryStore
    private let queue: PlaybackQueue
    /// Fired when the user taps a row to start playback.
    var onPlayItem: ((LibraryItem) -> Void)?

    private let thumbCache = NSCache<NSString, UIImage>()
    private let durationCache = NSCache<NSString, NSString>()
    private let emptyLabel = UILabel()

    init(store: LibraryStore, queue: PlaybackQueue) {
        self.store = store
        self.queue = queue
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ライブラリ"
        navigationItem.rightBarButtonItems = [
            editButtonItem,
            UIBarButtonItem(barButtonSystemItem: .add,
                            target: self, action: #selector(importTapped)),
        ]
        tableView.register(LibraryCell.self, forCellReuseIdentifier: "cell")
        tableView.rowHeight = 64

        emptyLabel.text = "動画がありません\n＋ボタン・ドラッグ&ドロップ・「開く」で追加"
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.font = .systemFont(ofSize: 14)

        store.onChange = { [weak self] in self?.tableView.reloadData() }
    }

    // MARK: - Import

    @objc private func importTapped() {
        let types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .audiovisualContent]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    // MARK: - Table data

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        let count = store.items.count
        tableView.backgroundView = count == 0 ? emptyLabel : nil
        return count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: "cell", for: indexPath) as! LibraryCell
        let item = store.items[indexPath.row]
        let reachable = store.isReachable(item)
        cell.itemID = item.id
        cell.configure(
            name: item.name,
            subtitle: subtitle(for: item, reachable: reachable),
            thumbnail: thumbCache.object(forKey: item.id.uuidString as NSString),
            reachable: reachable
        )
        if reachable {
            loadThumbnailIfNeeded(for: item, cell: cell)
        }
        return cell
    }

    private func subtitle(for item: LibraryItem, reachable: Bool) -> String {
        if !reachable { return "見つかりません (削除・移動されたファイル)" }
        if let cached = durationCache.object(forKey: item.id.uuidString as NSString) {
            return cached as String
        }
        loadDuration(for: item)
        return "…"
    }

    private func loadDuration(for item: LibraryItem) {
        let key = item.id.uuidString as NSString
        guard let url = store.resolve(item) else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let seconds = (try? await asset.load(.duration).seconds) ?? 0
            if accessed { url.stopAccessingSecurityScopedResource() }
            let value: String
            if seconds.isFinite, seconds > 0 {
                let total = Int(seconds.rounded(.down))
                value = String(format: "%d:%02d", total / 60, total % 60)
            } else {
                value = "--:--"
            }
            self?.durationCache.setObject(value as NSString, forKey: key)
            self?.tableView.reloadData()
        }
    }

    private func loadThumbnailIfNeeded(for item: LibraryItem, cell: LibraryCell) {
        let key = item.id.uuidString as NSString
        guard thumbCache.object(forKey: key) == nil,
              let url = store.resolve(item) else { return }
        cell.itemID = item.id
        let accessed = url.startAccessingSecurityScopedResource()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 192, height: 108)
        Task { [weak self] in
            let result = try? await generator.image(at: .zero)
            if accessed { url.stopAccessingSecurityScopedResource() }
            guard let cgImage = result?.image else { return }
            let image = UIImage(cgImage: cgImage)
            self?.thumbCache.setObject(image, forKey: key)
            if cell.itemID == item.id {
                cell.setThumbnail(image)
            }
        }
    }

    // MARK: - Selection & editing

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = store.items[indexPath.row]
        guard store.isReachable(item) else {
            let alert = UIAlertController(
                title: "ファイルが見つかりません",
                message: "「\(item.name)」は削除または移動されたため再生できません。",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        onPlayItem?(item)
    }

    override func tableView(_ tableView: UITableView,
                            contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        let item = store.items[indexPath.row]
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIAction] = [
                UIAction(title: "次に再生",
                         image: UIImage(systemName: "text.insert")) { _ in
                    self.queue.insertNext(item)
                },
                UIAction(title: "キューに追加",
                         image: UIImage(systemName: "text.append")) { _ in
                    self.queue.append(item)
                },
            ]
            actions.append(UIAction(title: "ライブラリから削除",
                                    image: UIImage(systemName: "trash"),
                                    attributes: .destructive) { _ in
                self.store.remove(item)
            })
            return UIMenu(children: actions)
        })
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        true
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        true
    }

    override func tableView(_ tableView: UITableView,
                            commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            store.remove(at: indexPath.row)
        }
    }

    override func tableView(_ tableView: UITableView,
                            moveRowAt source: IndexPath, to destination: IndexPath) {
        store.move(from: source.row, to: destination.row)
    }
}

extension LibraryViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            store.importURL(url)
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
    }
}

// MARK: - Cell

private final class LibraryCell: UITableViewCell {
    /// The item currently displayed; guards async thumbnail delivery
    /// against cell reuse.
    var itemID: UUID?
    private let thumbView = UIImageView()
    private let nameLabel = UILabel()
    private let infoLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.layer.cornerRadius = 6
        thumbView.backgroundColor = .tertiarySystemFill
        thumbView.image = UIImage(systemName: "film")
        thumbView.tintColor = .tertiaryLabel

        nameLabel.font = .systemFont(ofSize: 15, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.font = .systemFont(ofSize: 12)
        infoLabel.textColor = .secondaryLabel

        let labels = UIStackView(arrangedSubviews: [nameLabel, infoLabel])
        labels.axis = .vertical
        labels.spacing = 2

        let stack = UIStackView(arrangedSubviews: [thumbView, labels])
        stack.spacing = 10
        stack.alignment = .center
        contentView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumbView.widthAnchor.constraint(equalToConstant: 96),
            thumbView.heightAnchor.constraint(equalToConstant: 54),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(name: String, subtitle: String,
                   thumbnail: UIImage?, reachable: Bool) {
        nameLabel.text = name
        infoLabel.text = subtitle
        thumbView.image = thumbnail ?? UIImage(systemName: "film")
        alpha = reachable ? 1 : 0.55
    }

    func setThumbnail(_ image: UIImage) {
        thumbView.image = image
    }
}
