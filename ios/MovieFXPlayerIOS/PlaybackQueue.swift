import Foundation

/// How playback behaves at the end of the current item/queue.
/// Cycles off → one → all, like a music player.
enum RepeatMode: Int, Codable, CaseIterable {
    case off = 0
    case one = 1
    case all = 2

    mutating func advance() {
        self = RepeatMode(rawValue: (rawValue + 1) % Self.allCases.count) ?? .off
    }
}

/// The ordered list of items queued for playback, persisted as JSON in
/// Application Support. Holds the current index and the repeat mode;
/// `VideoPlayer` owns single-item looping, this owns queue progression.
@MainActor
final class PlaybackQueue {
    private struct State: Codable {
        var items: [LibraryItem]
        var currentIndex: Int
        var repeatMode: RepeatMode
    }

    private(set) var items: [LibraryItem] = []
    private(set) var currentIndex: Int = -1
    private(set) var repeatMode: RepeatMode = .off
    var onChange: (() -> Void)?

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("queue.json")
        load()
    }

    var current: LibraryItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    var canGoPrevious: Bool { currentIndex > 0 }
    var canGoNext: Bool {
        currentIndex + 1 < items.count || (repeatMode == .all && !items.isEmpty)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return }
        items = state.items
        currentIndex = state.currentIndex
        repeatMode = state.repeatMode
    }

    private func save() {
        let state = State(items: items, currentIndex: currentIndex, repeatMode: repeatMode)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func commit() {
        save()
        onChange?()
    }

    // MARK: - Queue editing

    /// Replaces the queue (e.g. tapping a library row queues the whole
    /// library starting at that index).
    func replace(with items: [LibraryItem], index: Int) {
        self.items = items
        currentIndex = items.indices.contains(index) ? index : (items.isEmpty ? -1 : 0)
        commit()
    }

    /// Inserts an item right after the current one ("次に再生").
    func insertNext(_ item: LibraryItem) {
        let at = items.indices.contains(currentIndex) ? currentIndex + 1 : items.count
        items.insert(item, at: at)
        commit()
    }

    /// Appends an item to the end of the queue.
    func append(_ item: LibraryItem) {
        items.append(item)
        commit()
    }

    /// UITableView move semantics: `destination` is the final index.
    /// Tracks the current item's index across the move.
    func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source), destination >= 0 else { return }
        let target = min(destination, items.count - 1)
        let item = items.remove(at: source)
        items.insert(item, at: target)
        if currentIndex == source {
            currentIndex = target
        } else if source < currentIndex && target >= currentIndex {
            currentIndex -= 1
        } else if source > currentIndex && target <= currentIndex {
            currentIndex += 1
        }
        commit()
    }

    /// UITableView delete semantics. If the current item is removed the
    /// index points at whatever takes its place.
    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            currentIndex = min(currentIndex, items.count - 1)
        }
        commit()
    }

    func clear() {
        items = []
        currentIndex = -1
        commit()
    }

    func select(index: Int) {
        guard items.indices.contains(index) else { return }
        currentIndex = index
        commit()
    }

    func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        commit()
    }

    func cycleRepeatMode() -> RepeatMode {
        var mode = repeatMode
        mode.advance()
        setRepeatMode(mode)
        return mode
    }

    // MARK: - Progression

    /// Advances to the next item. Wraps to the start only in `.all`
    /// repeat mode; returns nil when the queue is exhausted.
    @discardableResult
    func nextItem() -> LibraryItem? {
        let next = currentIndex + 1
        if items.indices.contains(next) {
            currentIndex = next
            commit()
            return items[next]
        }
        if repeatMode == .all && !items.isEmpty {
            currentIndex = 0
            commit()
            return items[0]
        }
        commit()
        return nil
    }

    /// Moves back one item (no wrap). Returns nil at the queue start.
    @discardableResult
    func previousItem() -> LibraryItem? {
        guard currentIndex > 0 else { return nil }
        currentIndex -= 1
        commit()
        return items[currentIndex]
    }
}
