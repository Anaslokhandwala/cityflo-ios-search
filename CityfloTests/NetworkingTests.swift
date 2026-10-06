import Foundation
import Testing
@testable import Cityflo

struct SimulatedSearchEngineTests {
    let routes: [Any]

    init() throws {
        let url = try #require(Bundle.main.url(forResource: "routes", withExtension: "json"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        routes = try #require(root["routes"] as? [Any])
    }

    private func ids(_ query: String) -> [String] {
        SimulatedSearchEngine.rank(routes, for: query).compactMap { ($0 as? [String: Any])?["id"] as? String }
    }

    @Test func matchesStopsByPrefixCaseAndDiacriticInsensitively() {
        #expect(ids("powai") == ["R-103", "R-109", "R-116"])
        #expect(ids("POWA") == ids("powai"))
    }

    @Test func everyTokenMustMatch() {
        #expect(ids("kurla bkc") == ["R-107"])
    }

    @Test func tripIDFindsItsRoute() {
        #expect(ids("T-1022") == ["R-107"])
    }

    @Test func corridorLabelStillMatches() {
        #expect(ids("central") == ["R-101", "R-105", "R-109", "R-113", "R-117"])
    }

    @Test func cityNameIsNotASearchTerm() {
        #expect(ids("mumb").isEmpty)
    }

    @Test func pagesUseTheEndpointsPageSize() throws {
        let url = try #require(Bundle.main.url(forResource: "routes", withExtension: "json"))
        let snapshot = try Data(contentsOf: url)
        let first = try RouteNormalizer.page(from: SimulatedSearchEngine.respond(to: "r", page: 1, pageSize: nil, snapshot: snapshot), requestedPage: 1)
        #expect(first.routes.count == 12)
        #expect(first.nextPage == 2)
        #expect(first.totalResults == 20)
        let second = try RouteNormalizer.page(from: SimulatedSearchEngine.respond(to: "r", page: 2, pageSize: nil, snapshot: snapshot), requestedPage: 2)
        #expect(second.routes.count == 8)
        #expect(second.nextPage == nil)
    }
}

/// End-to-end through URLSession -> SimulatedCityfloProtocol -> SimulatedBackend.
/// Serialized because they all reconfigure the shared backend.
@Suite(.serialized)
struct CFNetworkConduitTests {
    @Test func searchesThroughURLSession() async throws {
        await SimulatedBackend.shared.setConditions(NetworkConditions.Preset.instant.conditions)
        let page = try await CFNetworkConduit.simulated().search(query: "powai", page: 1)
        #expect(page.routes.map(\.routeID) == ["R-103", "R-109", "R-116"])
        #expect(page.snapshotTakenAt != nil)
    }

    @Test func cancellationStopsTheRequestPromptly() async throws {
        var slow = NetworkConditions.Preset.instant.conditions
        slow.baseLatency = .seconds(5)
        await SimulatedBackend.shared.setConditions(slow)
        let conduit = CFNetworkConduit.simulated()

        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { try await conduit.search(query: "powai", page: 1) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - start < .seconds(2))
    }

    @Test func longRateLimitSurfacesAndCoolsDownOtherCallers() async throws {
        var limited = NetworkConditions.Preset.instant.conditions
        limited.requestsPerWindow = 1
        limited.window = .seconds(30)
        await SimulatedBackend.shared.setConditions(limited)
        let conduit = CFNetworkConduit.simulated()

        _ = try await conduit.search(query: "powai", page: 1)
        await #expect {
            try await conduit.search(query: "kurla", page: 1)
        } throws: { error in
            guard case SearchFailure.rateLimited(let wait) = error else { return false }
            return wait > .seconds(3)
        }
        // While cooling down, the conduit fails fast instead of spending more of the budget.
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: SearchFailure.self) { try await conduit.search(query: "bkc", page: 1) }
        #expect(clock.now - start < .milliseconds(100))
    }

    @Test func shortRateLimitIsAbsorbedByRetry() async throws {
        var limited = NetworkConditions.Preset.instant.conditions
        limited.requestsPerWindow = 1
        limited.window = .seconds(1)
        await SimulatedBackend.shared.setConditions(limited)
        let conduit = CFNetworkConduit.simulated()

        _ = try await conduit.search(query: "powai", page: 1)
        let page = try await conduit.search(query: "kurla", page: 1)
        #expect(!page.routes.isEmpty)
        await SimulatedBackend.shared.setConditions(NetworkConditions.Preset.instant.conditions)
    }
}
