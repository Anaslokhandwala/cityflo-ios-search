import Foundation
import Testing
@testable import Cityflo

struct RecentSearchesTests {
    @Test func mostRecentFirstDeduplicatedAndCapped() {
        var list: [String] = []
        for q in ["powai", "kurla", "  Powai  ", "bkc"] {
            list = RecentSearches.inserting(q, into: list)
        }
        #expect(list == ["bkc", "Powai", "kurla"])

        for i in 0..<20 { list = RecentSearches.inserting("q\(i)", into: list) }
        #expect(list.count == RecentSearches.limit)
        #expect(list.first == "q19")
    }

    @Test func blankIsIgnored() {
        #expect(RecentSearches.inserting("   ", into: ["a"]) == ["a"])
    }

    @Test func mergeKeepsSessionEntriesFirst() {
        let merged = RecentSearches.merging(current: ["new", "Powai"], loaded: ["powai", "old"])
        #expect(merged == ["new", "Powai", "old"])
    }

    @Test func persistsAcrossStoreInstances() async throws {
        let url = URL.temporaryDirectory.appending(path: "recents-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        await RecentSearchStore(fileURL: url).save(["powai", "kurla"], revision: 1)
        #expect(await RecentSearchStore(fileURL: url).load() == ["powai", "kurla"])
    }

    @Test func olderRevisionCannotOverwriteNewer() async throws {
        let url = URL.temporaryDirectory.appending(path: "recents-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RecentSearchStore(fileURL: url)

        #expect(await store.save(["b", "a"], revision: 2))
        #expect(await store.save(["a"], revision: 1) == false)
        #expect(await store.load() == ["b", "a"])
    }

    @Test func corruptFileLoadsAsEmpty() async throws {
        let url = URL.temporaryDirectory.appending(path: "recents-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        #expect(await RecentSearchStore(fileURL: url).load().isEmpty)
    }

    @MainActor
    @Test func modelPersistsAndReloadsAcrossLaunches() async throws {
        let url = URL.temporaryDirectory.appending(path: "recents-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = SearchModel(service: ScriptedSearch(), recentsStore: RecentSearchStore(fileURL: url))
        first.query = "powai"
        first.submit()
        first.query = "kurla"
        first.submit()
        try await Task.sleep(for: .milliseconds(200))

        let relaunched = SearchModel(service: ScriptedSearch(), recentsStore: RecentSearchStore(fileURL: url))
        await relaunched.loadRecents()
        #expect(relaunched.recents == ["kurla", "powai"])
    }
}
