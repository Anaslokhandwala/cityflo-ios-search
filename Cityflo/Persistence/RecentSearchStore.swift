import Foundation

/// The rules for the recents list, kept pure so they're easy to test.
enum RecentSearches {
    static let limit = 8

    /// What we store and show: trimmed, inner whitespace collapsed, case kept as typed.
    static func normalize(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Two searches are "the same" if they'd hit the endpoint the same way. Used for de-duplication
    /// and for deciding whether on-screen results answer the current query.
    static func key(_ raw: String) -> String {
        normalize(raw).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Most recent first, de-duplicated by `key`, capped at `limit`. Re-running a search moves it to the top.
    static func inserting(_ raw: String, into list: [String]) -> [String] {
        let entry = normalize(raw)
        guard !entry.isEmpty else { return list }
        let entryKey = key(entry)
        return Array(([entry] + list.filter { key($0) != entryKey }).prefix(limit))
    }

    /// Used when the user searched before the saved list finished loading: this session's
    /// entries go first, then saved ones.
    static func merging(current: [String], loaded: [String]) -> [String] {
        loaded.reversed().reduce(current.reversed()) { acc, item in
            acc.contains { key($0) == key(item) } ? acc : [item] + acc
        }
        .reversed()
        .prefix(limit)
        .map { $0 }
    }
}

/// Saves recent searches as a small JSON file in Application Support.
///
/// It's an actor so it's the only writer. Each save carries a revision number assigned on the main
/// actor, and older revisions are ignored. Two quick saves can reach the actor in either order,
/// and without the revision an older list could overwrite a newer one.
actor RecentSearchStore {
    private struct FileFormat: Codable {
        var version = 1
        var items: [String]
    }

    private let fileURL: URL
    private var lastSavedRevision = Int.min

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func defaultLocation() -> URL {
        URL.applicationSupportDirectory.appending(path: "recent-searches.json")
    }

    func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(FileFormat.self, from: data) else { return [] }
        return Array(file.items.map(RecentSearches.normalize).filter { !$0.isEmpty }.prefix(RecentSearches.limit))
    }

    /// Returns `false` if the save was skipped as stale, or failed.
    @discardableResult
    func save(_ items: [String], revision: Int) -> Bool {
        guard revision > lastSavedRevision else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(FileFormat(items: items))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastSavedRevision = revision
            return true
        } catch {
            // Recents are a convenience. A failed write must never surface as a search error.
            return false
        }
    }
}
