import Foundation

struct SimulatedResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

/// An in-process stand-in for Cityflo's search endpoint, reached through `URLSession` via
/// `SimulatedCityfloProtocol`. It serves `routes.json` (or the file at `CF_DATA_PATH`, so the
/// slice can be swapped without a rebuild), filtered and paged server-side, with latency,
/// jitter, a sliding-window rate limit and random 503s.
///
/// Contract: `GET /v1/routes/search?q=<text>&page=<n>` returns the snapshot's top-level object
/// with `routes` replaced by one page of matches, plus `page`, `page_size`, `total_results`, `next_page`.
actor SimulatedBackend {
    static let host = "search.cityflo.test"
    static let shared = SimulatedBackend()

    private(set) var conditions: NetworkConditions
    private let snapshotURL: URL?
    private var snapshot: Data?
    private var acceptedRequests: [ContinuousClock.Instant] = []
    private let clock = ContinuousClock()

    init(conditions: NetworkConditions = .fromEnvironment(), snapshotURL: URL? = SimulatedBackend.defaultSnapshotURL()) {
        self.conditions = conditions
        self.snapshotURL = snapshotURL
    }

    nonisolated static func defaultSnapshotURL() -> URL? {
        if let path = ProcessInfo.processInfo.environment["CF_DATA_PATH"], !path.isEmpty {
            return URL(filePath: path)
        }
        return Bundle.main.url(forResource: "routes", withExtension: "json")
    }

    func setConditions(_ conditions: NetworkConditions) {
        self.conditions = conditions
        acceptedRequests.removeAll()
    }

    /// Returns `nil` if the calling task is cancelled while the "network" is still busy.
    func handle(_ request: URLRequest) async -> SimulatedResponse? {
        let conditions = self.conditions

        // Rate limiting is decided on arrival, like a gateway would.
        let now = clock.now
        acceptedRequests.removeAll { now - $0 >= conditions.window }
        var limitedFor: Duration?
        if conditions.requestsPerWindow > 0, acceptedRequests.count >= conditions.requestsPerWindow,
           let oldest = acceptedRequests.first {
            limitedFor = conditions.window - (now - oldest)
        } else {
            acceptedRequests.append(now)
        }

        // Reentrancy: other requests are served while this one "travels". State read after this
        // await is not touched, so interleaving is safe.
        let jitterMs = conditions.jitter.milliseconds
        let delay = conditions.baseLatency + .milliseconds(jitterMs > 0 ? Int.random(in: 0...jitterMs) : 0)
        do {
            try await Task.sleep(for: limitedFor == nil ? delay : min(delay, .milliseconds(150)))
        } catch {
            return nil
        }

        if let limitedFor {
            let seconds = max(1, Int((Double(limitedFor.milliseconds) / 1000).rounded(.up)))
            return json(429, ["error": "rate_limited"], headers: ["Retry-After": String(seconds)])
        }
        if conditions.failureRate > 0, Double.random(in: 0..<1) < conditions.failureRate {
            return json(503, ["error": "upstream_unavailable"])
        }
        guard let url = request.url, url.path() == "/v1/routes/search" else {
            return json(404, ["error": "not_found"])
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = items.first { $0.name == "q" }?.value ?? ""
        let page = items.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 1
        let pageSize = items.first { $0.name == "page_size" }?.value.flatMap(Int.init)

        do {
            let body = try SimulatedSearchEngine.respond(to: query, page: page, pageSize: pageSize, snapshot: try loadSnapshot())
            return SimulatedResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
        } catch {
            return json(500, ["error": "snapshot_unreadable"])
        }
    }

    private func loadSnapshot() throws -> Data {
        if let snapshot { return snapshot }
        guard let snapshotURL else { throw CocoaError(.fileNoSuchFile) }
        let data = try Data(contentsOf: snapshotURL)
        snapshot = data
        return data
    }

    private func json(_ status: Int, _ body: [String: String], headers: [String: String] = [:]) -> SimulatedResponse {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return SimulatedResponse(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body: data)
    }
}

/// Server-side matching. Works on raw JSON so records reach the client exactly as malformed as
/// they are in the snapshot: cleaning them up is the client's job, not the fake server's.
enum SimulatedSearchEngine {
    static func respond(to query: String, page: Int, pageSize: Int?, snapshot: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let routes = (root["routes"] as? [Any]) ?? []
        let config = root["client_config"] as? [String: Any]
        let size = max(1, min(pageSize ?? (config?["results_page_size"] as? Int) ?? 20, 100))
        let matches = rank(routes, for: query)
        let start = max(0, (page - 1) * size)
        let slice = start < matches.count ? Array(matches[start..<min(start + size, matches.count)]) : []

        root["routes"] = slice
        root["page"] = page
        root["page_size"] = size
        root["total_results"] = matches.count
        root["next_page"] = start + size < matches.count ? page + 1 : NSNull()
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Every query token must prefix-match a token of the route. Matches on name or id rank
    /// above matches that needed the corridor label or a trip id. Order is otherwise stable.
    static func rank(_ routes: [Any], for query: String) -> [Any] {
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return [] }
        var primary: [Any] = []
        var secondary: [Any] = []
        for case let route as [String: Any] in routes {
            let id = route["id"] as? String ?? ""
            let name = route["name"] as? String ?? ""
            let corridor = route["corridor"] as? String ?? ""
            let tripIDs = (route["trips"] as? [[String: Any]] ?? []).compactMap { $0["trip_id"] as? String }

            let strong = tokens(name) + tokens(id) + [fold(id)]
            let weak = tokens(corridor) + [fold(corridor)] + tripIDs.flatMap { tokens($0) + [fold($0)] }
            let matchesStrong = { (q: String) in strong.contains { $0.hasPrefix(q) } }
            let matchesWeak = { (q: String) in weak.contains { $0.hasPrefix(q) } }

            if queryTokens.allSatisfy(matchesStrong) {
                primary.append(route)
            } else if queryTokens.allSatisfy({ matchesStrong($0) || matchesWeak($0) }) {
                secondary.append(route)
            }
        }
        return primary + secondary
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func tokens(_ text: String) -> [String] {
        fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

extension Duration {
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
