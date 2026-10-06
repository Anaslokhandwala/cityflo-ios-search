import Foundation
import Testing
@testable import Cityflo

/// A scripted endpoint: each query answers after its own delay, so tests can force the
/// "slow old request lands after the fast new one" ordering.
actor ScriptedSearch: RouteSearching {
    private var delays: [String: Duration]
    private var failures: [String: SearchFailure]
    private(set) var started: [String] = []
    private(set) var completed: [String] = []

    init(delays: [String: Duration] = [:], failures: [String: SearchFailure] = [:]) {
        self.delays = delays
        self.failures = failures
    }

    func setFailure(_ failure: SearchFailure?, for query: String) {
        failures[query] = failure
    }

    func search(query: String, page: Int) async throws -> SearchPage {
        started.append(query)
        try await Task.sleep(for: delays[query] ?? .milliseconds(10))
        completed.append(query)
        if let failure = failures[query] { throw failure }
        let route = Route(routeID: "R-\(query)-\(page)", position: 0, name: query, corridor: nil, isActive: true,
                          seatsTotal: 40, trips: [], issues: [])
        return SearchPage(routes: [route], page: page, nextPage: page < 2 ? page + 1 : nil, totalResults: 2,
                          snapshotTakenAt: nil, unreadableRouteCount: 0)
    }
}

/// Like `ScriptedSearch` but ignores cancellation, the worst case for stale-response stomping.
actor UncancellableSearch: RouteSearching {
    let delays: [String: Duration]
    init(delays: [String: Duration]) { self.delays = delays }

    func search(query: String, page: Int) async throws -> SearchPage {
        let deadline = ContinuousClock.now + (delays[query] ?? .zero)
        while ContinuousClock.now < deadline { await Task.yield() }
        let route = Route(routeID: query, position: 0, name: query, corridor: nil, isActive: true,
                          seatsTotal: 40, trips: [], issues: [])
        return SearchPage(routes: [route], page: 1, nextPage: nil, totalResults: 1, snapshotTakenAt: nil, unreadableRouteCount: 0)
    }
}

@MainActor
struct SearchModelTests {
    private func settle(_ duration: Duration = .milliseconds(600)) async throws {
        try await Task.sleep(for: duration)
    }

    @Test func rapidTypingSendsOneRequest() async throws {
        let service = ScriptedSearch()
        let model = SearchModel(service: service, recentsStore: nil, debounce: .milliseconds(80))
        for prefix in ["m", "mu", "mum", "mumb"] {
            model.query = prefix
            try await Task.sleep(for: .milliseconds(20))
        }
        try await settle(.milliseconds(300))
        #expect(await service.started == ["mumb"])
        #expect(model.resultsQuery == "mumb")
    }

    @Test func lateResponseNeverStompsFreshOne() async throws {
        // "powa" is slow and ignores cancellation. "powai" is fast. The slow one lands last.
        let service = UncancellableSearch(delays: ["powa": .milliseconds(400), "powai": .milliseconds(10)])
        let model = SearchModel(service: service, recentsStore: nil, debounce: .milliseconds(1))
        model.query = "powa"
        try await Task.sleep(for: .milliseconds(50))
        model.query = "powai"
        try await settle(.milliseconds(700))
        #expect(model.resultsQuery == "powai")
        #expect(model.results.map(\.routeID) == ["powai"])
        #expect(!model.isSearching)
    }

    @Test func staleResultsStayLabelledWhileTheNextQueryLoads() async throws {
        let service = ScriptedSearch(delays: ["kurla": .milliseconds(400)])
        let model = SearchModel(service: service, recentsStore: nil, debounce: .milliseconds(1))
        model.query = "powai"
        try await settle(.milliseconds(100))
        #expect(model.resultsQuery == "powai")

        model.query = "kurla"
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.isSearching)
        #expect(model.isShowingStaleResults)
        #expect(model.resultsQuery == "powai", "old results stay on screen, labelled with their query")
        #expect(!model.results.isEmpty)

        try await settle()
        #expect(!model.isShowingStaleResults)
        #expect(model.resultsQuery == "kurla")
    }

    @Test func failureKeepsStaleResultsAndReportsTheError() async throws {
        let service = ScriptedSearch(failures: ["kurla": .rateLimited(retryAfter: .seconds(9))])
        let model = SearchModel(service: service, recentsStore: nil, debounce: .milliseconds(1))
        model.query = "powai"
        try await settle(.milliseconds(100))
        model.query = "kurla"
        try await settle(.milliseconds(100))
        #expect(model.failure == .rateLimited(retryAfter: .seconds(9)))
        #expect(model.resultsQuery == "powai")
        #expect(model.isShowingStaleResults)

        await service.setFailure(nil, for: "kurla")
        model.retry()
        try await settle(.milliseconds(100))
        #expect(model.failure == nil)
        #expect(model.resultsQuery == "kurla")
    }

    @Test func clearingTheFieldClearsResults() async throws {
        let model = SearchModel(service: ScriptedSearch(), recentsStore: nil, debounce: .milliseconds(1))
        model.query = "powai"
        try await settle(.milliseconds(100))
        model.query = "   "
        #expect(model.results.isEmpty)
        #expect(model.resultsQuery == nil)
        #expect(!model.isSearching)
    }

    @Test func nextPageForAnOldQueryIsDropped() async throws {
        let service = ScriptedSearch(delays: ["powai": .milliseconds(10)])
        let model = SearchModel(service: service, recentsStore: nil, debounce: .milliseconds(1))
        model.query = "powai"
        try await settle(.milliseconds(100))
        model.loadMore()
        model.query = "kurla"
        try await settle(.milliseconds(200))
        #expect(model.results.map(\.routeID) == ["R-kurla-1"])
    }

    @Test func loadMoreAppendsWithUniqueIdentity() async throws {
        let model = SearchModel(service: ScriptedSearch(), recentsStore: nil, debounce: .milliseconds(1))
        model.query = "powai"
        try await settle(.milliseconds(100))
        model.rowAppeared(try #require(model.results.last))
        try await settle(.milliseconds(100))
        #expect(model.results.map(\.routeID) == ["R-powai-1", "R-powai-2"])
        #expect(model.results.map(\.position) == [0, 1])
        #expect(model.nextPage == nil)
    }

    @Test func onlyCommittedSearchesBecomeRecents() async throws {
        let model = SearchModel(service: ScriptedSearch(), recentsStore: nil, debounce: .milliseconds(1))
        model.query = "pow"
        try await settle(.milliseconds(100))
        #expect(model.recents.isEmpty, "debounced keystrokes are not recents")
        model.query = "powai"
        model.submit()
        #expect(model.recents == ["powai"])
    }

    @Test func openingAStaleResultRecordsTheQueryThatProducedIt() async throws {
        let service = ScriptedSearch(delays: ["kurla": .seconds(2)])
        let model = SearchModel(service: service, recentsStore: nil, debounce: .milliseconds(1))
        model.query = "powai"
        try await settle(.milliseconds(100))
        model.query = "kurla"
        model.didOpenResult()
        #expect(model.recents == ["powai"])
    }
}
