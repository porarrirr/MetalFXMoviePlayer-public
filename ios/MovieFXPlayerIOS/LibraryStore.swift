import Foundation

/// A registered video in the library. The file itself is referenced by a
/// security-scoped bookmark — the original is never copied into the app.
struct LibraryItem: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var bookmarkData: Data
    var addedAt: Date
    /// Resume position in seconds; nil means start from the beginning.
    var lastPosition: Double?
}

/// Ordered list of library entries, persisted as JSON in
/// Application Support. Owns bookmark creation/resolution; callers must
/// ensure the source URL is currently accessible when importing
/// (security scope already started by the picker/Open In).
@MainActor
final class LibraryStore {
    private(set) var items: [LibraryItem] = []
    var onChange: (() -> Void)?

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("library.json")
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LibraryItem].self, from: data)
        else { return }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Import

    /// Registers a URL in the library via a bookmark. Returns the
    /// registered (or already-known) item, nil when the URL cannot be
    /// bookmarked.
    @discardableResult
    func importURL(_ url: URL, name: String? = nil) -> LibraryItem? {
        let standardized = url.standardizedFileURL
        if let existing = items.first(where: {
            resolve($0)?.standardizedFileURL == standardized
        }) {
            return existing
        }
        guard let bookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }

        let item = LibraryItem(
            id: UUID(),
            name: name ?? url.lastPathComponent,
            bookmarkData: bookmark,
            addedAt: Date(),
            lastPosition: nil
        )
        items.append(item)
        save()
        onChange?()
        return item
    }

    // MARK: - Resolution

    /// Resolves the item's bookmark to a URL. Does NOT start the security
    /// scope — callers needing file access must call
    /// `startAccessingSecurityScopedResource` themselves. Note resolution
    /// only decodes the bookmark; use `isReachable` to learn whether the
    /// original still exists.
    func resolve(_ item: LibraryItem) -> URL? {
        var stale = false
        return try? URL(
            resolvingBookmarkData: item.bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    /// True when the bookmark resolves AND the file actually exists
    /// (checked under the security scope). False means the original was
    /// deleted, moved, or the bookmark is dead.
    func isReachable(_ item: LibraryItem) -> Bool {
        guard let url = resolve(item) else { return false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return (try? url.checkResourceIsReachable()) ?? false
    }

    // MARK: - Mutation

    func remove(_ item: LibraryItem) {
        items.removeAll { $0.id == item.id }
        save()
        onChange?()
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        save()
        onChange?()
    }

    /// UITableView move semantics: `destination` is the final index.
    func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source), destination >= 0 else { return }
        let item = items.remove(at: source)
        items.insert(item, at: min(destination, items.count))
        save()
        onChange?()
    }

    /// Persists the resume position for an item.
    func setPosition(_ position: Double, for itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].lastPosition = position
        save()
    }
}
