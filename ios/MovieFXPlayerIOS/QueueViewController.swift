import UIKit

/// Shows the playback queue. Tap jumps to that item; Edit allows
/// reorder/delete; クリア empties the queue.
final class QueueViewController: UITableViewController {
    private let queue: PlaybackQueue
    /// Fired when the user taps a row to jump to it.
    var onSelect: ((Int) -> Void)?
    var onChange: (() -> Void)?

    init(queue: PlaybackQueue) {
        self.queue = queue
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "再生キュー"
        navigationItem.rightBarButtonItem = editButtonItem
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "クリア", style: .plain,
            target: self, action: #selector(clearTapped))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        queue.onChange = { [weak self] in self?.tableView.reloadData(); self?.onChange?() }
    }

    @objc private func clearTapped() {
        queue.clear()
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        queue.items.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let item = queue.items[indexPath.row]
        let isCurrent = indexPath.row == queue.currentIndex
        var content = cell.defaultContentConfiguration()
        content.text = item.name
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        content.textProperties.font = .systemFont(
            ofSize: 15, weight: isCurrent ? .semibold : .regular)
        cell.contentConfiguration = content
        cell.accessoryType = isCurrent ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(indexPath.row)
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
            queue.remove(at: indexPath.row)
        }
    }

    override func tableView(_ tableView: UITableView,
                            moveRowAt source: IndexPath, to destination: IndexPath) {
        queue.move(from: source.row, to: destination.row)
    }
}
