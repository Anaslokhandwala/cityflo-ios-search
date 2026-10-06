import Foundation
import Observation

/// Owns the search screen's state.
///
/// Cancellation model (DECISION.md §2):
/// - Each keystroke cancels the previous search task, so at most one search is ever waiting on
///   the debounce or the network. Cancelling reaches URLSession, then the endpoint.
/// - Cancellation only saves requests. What guarantees correctness is the key check: a response is
///   applied only if its query key still matches what's typed. So a slow, late, uncancelled
///   response can never overwrite newer results.
///
/// Stale vs blank (DECISION.md §3): results stay on screen while a new query loads, or after it
/// fails. The screen always says which query they belong to and dims them, and only clears when
/// the field is cleared.
@MainActor
@Observable
final class SearchModel {
    var query: String = "" {
        didSet { if query != oldValue { queryDidChange() } }
    }

    private(set) var results: [Route] = []
    /// The query that `results` answer, as typed. `nil` means no results are on screen.
    private(set) var resultsQuery: String?
    private(set) var isSearching = false
    private(set) var failure: SearchFailure?
    private(set) var nextPage: Int?
    private(set) var totalResults: Int?
    private(set) var isLoadingMore = false
    private(set) var loadMoreFailure: SearchFailure?
    private(set) var snapshotTakenAt: Date?
    private(set) var unreadableRouteCount = 0
    private(set) var recents: [String] = []

    @ObservationIgnored private let service: any RouteSearching
    @ObservationIgnored private let recentsStore: RecentSearchStore?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    /// Bumped every time `results` is replaced, so a next-page response for an older result set is dropped.
    @ObservationIgnored private var resultsGeneration = 0
    @ObservationIgnored private var recentsRevision = 0

    init(service: any RouteSearching, recentsStore: RecentSearchStore?, debounce: Duration = .milliseconds(327)) {
        self.service = service
        self.recentsStore = recentsStore
        self.debounce = debounce
    }

    var currentKey: String { RecentSearches.key(query) }

    /// True while the on-screen results answer an older query than the one typed.
    var isShowingStaleResults: Bool {
        guard let resultsQuery else { return false }
        return RecentSearches.key(resultsQuery) != currentKey
    }

    // MARK: Searching

    private func queryDidChange() {
        searchTask?.cancel()
        let key = currentKey

        if key.isEmpty {
            clearResults()
            return
        }
        if let resultsQuery, RecentSearches.key(resultsQuery) == key, failure == nil {
            // e.g. a trailing space, or typing back to the query already shown.
            isSearching = false
            return
        }

        pageTask?.cancel()
        isLoadingMore = false
        isSearching = true
        failure = nil
        let text = RecentSearches.normalize(query)
        searchTask = Task { [weak self, debounce] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            await self?.runSearch(text)
        }
    }

    /// Return key: skip the debounce, and save the query as a recent search.
    func submit() {
        let text = RecentSearches.normalize(query)
        guard !text.isEmpty else { return }
        recordRecent(text)
        if let resultsQuery, RecentSearches.key(resultsQuery) == currentKey, failure == nil, !isSearching {
            return
        }
        searchNow(text)
    }

    func retry() {
        let text = RecentSearches.normalize(query)
        guard !text.isEmpty else { return }
        searchNow(text)
    }

    func rerun(_ recent: String) {
        query = recent
        submit()
    }

    private func searchNow(_ text: String) {
        searchTask?.cancel()
        pageTask?.cancel()
        isLoadingMore = false
        isSearching = true
        failure = nil
        searchTask = Task { [weak self] in await self?.runSearch(text) }
    }

    private func runSearch(_ text: String) async {
        let key = RecentSearches.key(text)
        do {
            let page = try await service.search(query: text, page: 1)
            // The correctness guarantee: never apply a response to a query that's no longer typed.
            guard key == currentKey else { return }
            resultsGeneration += 1
            results = RouteNormalizer.markDuplicateRoutes(page.routes)
            resultsQuery = text
            nextPage = page.nextPage
            totalResults = page.totalResults
            snapshotTakenAt = page.snapshotTakenAt ?? snapshotTakenAt
            unreadableRouteCount = page.unreadableRouteCount
            failure = nil
            loadMoreFailure = nil
            isSearching = false
        } catch is CancellationError {
            // A newer query replaced this one. It owns `isSearching` now.
        } catch {
            guard key == currentKey else { return }
            failure = SearchFailure(error)
            isSearching = false
        }
    }

    private func clearResults() {
        pageTask?.cancel()
        resultsGeneration += 1
        results = []
        resultsQuery = nil
        nextPage = nil
        totalResults = nil
        unreadableRouteCount = 0
        isSearching = false
        isLoadingMore = false
        failure = nil
        loadMoreFailure = nil
    }

    // MARK: Paging

    /// Called when a row appears. Loads the next page when the last row is reached (infinite scroll).
    func rowAppeared(_ route: Route) {
        guard route.id == results.last?.id, loadMoreFailure == nil else { return }
        loadMore()
    }

    func loadMore() {
        guard let page = nextPage, !isLoadingMore, !isSearching, !isShowingStaleResults,
              let text = resultsQuery else { return }
        isLoadingMore = true
        loadMoreFailure = nil
        let generation = resultsGeneration
        pageTask = Task { [weak self] in
            await self?.runLoadMore(text, page: page, generation: generation)
        }
    }

    private func runLoadMore(_ text: String, page: Int, generation: Int) async {
        do {
            let next = try await service.search(query: text, page: page)
            guard generation == resultsGeneration else { return }
            results = RouteNormalizer.markDuplicateRoutes(results + next.routes)
            nextPage = next.nextPage
            totalResults = next.totalResults ?? totalResults
            unreadableRouteCount += next.unreadableRouteCount
            isLoadingMore = false
        } catch is CancellationError {
            return
        } catch {
            guard generation == resultsGeneration else { return }
            loadMoreFailure = SearchFailure(error)
            isLoadingMore = false
        }
    }

    // MARK: Recent searches

    /// Opening a result saves the query that *produced* it, which may be the older,
    /// still-on-screen query rather than what's currently typed.
    func didOpenResult() {
        guard let resultsQuery else { return }
        recordRecent(resultsQuery)
    }

    func loadRecents() async {
        guard let recentsStore else { return }
        let loaded = await recentsStore.load()
        if recentsRevision == 0 {
            recents = loaded
        } else {
            recents = RecentSearches.merging(current: recents, loaded: loaded)
            persistRecents()
        }
    }

    func removeRecents(at offsets: IndexSet) {
        recents.remove(atOffsets: offsets)
        persistRecents()
    }

    func clearRecents() {
        recents = []
        persistRecents()
    }

    private func recordRecent(_ text: String) {
        let updated = RecentSearches.inserting(text, into: recents)
        guard updated != recents else { return }
        recents = updated
        persistRecents()
    }

    private func persistRecents() {
        recentsRevision += 1
        guard let recentsStore else { return }
        let snapshot = recents
        let revision = recentsRevision
        Task { await recentsStore.save(snapshot, revision: revision) }
    }
}
