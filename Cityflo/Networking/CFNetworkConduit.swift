import Foundation

/// What the search screen needs from the network. A protocol so tests can script latency and ordering.
protocol RouteSearching: Sendable {
    func search(query: String, page: Int) async throws -> SearchPage
}

enum SearchFailure: Error, Equatable, Sendable {
    /// The endpoint said 429 and the wait was too long to absorb silently.
    case rateLimited(retryAfter: Duration)
    case server(status: Int)
    case offline
    case unreadableResponse

    init(_ error: any Error) {
        switch error {
        case let failure as SearchFailure: self = failure
        case is DecodingError: self = .unreadableResponse
        default: self = .offline
        }
    }

    var message: String {
        switch self {
        case .rateLimited(let wait):
            "Too many searches right now. Try again in \(max(1, wait.milliseconds / 1000)) s."
        case .server(let status):
            "Search is having trouble (\(status))."
        case .offline:
            "Can't reach Cityflo. Check your connection."
        case .unreadableResponse:
            "We got a response we couldn't read."
        }
    }
}

/// Owns every `URLSession` call the app makes.
///
/// An actor because it holds one piece of shared state: the rate-limit cool-down. After a 429,
/// *every* caller (new searches, next-page loads) waits out `Retry-After` here instead of
/// spending more of the budget. A caller cancelled during that wait never touches the network.
actor CFNetworkConduit: RouteSearching {
    private let session: URLSession
    private let baseURL: URL
    private let clock = ContinuousClock()
    private var coolDownUntil: ContinuousClock.Instant?

    /// Retries for 429 and 5xx. Short on purpose: someone at a bus stop would rather see an error
    /// and a Retry button than a spinner that hides three back-off rounds.
    private let maxRetries = 2
    /// Longest rate-limit wait absorbed silently. Anything longer goes to the UI as `.rateLimited`.
    private let maxSilentWait: Duration = .seconds(3)

    init(baseURL: URL, configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        self.baseURL = baseURL
        self.session = URLSession(configuration: configuration)
    }

    /// The conduit used by the app: real URLSession, in-process endpoint (see `SimulatedBackend`).
    static func simulated() -> CFNetworkConduit {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SimulatedCityfloProtocol.self]
        return CFNetworkConduit(baseURL: URL(string: "https://\(SimulatedBackend.host)")!, configuration: configuration)
    }

    func search(query: String, page: Int) async throws -> SearchPage {
        var components = URLComponents(url: baseURL.appending(path: "v1/routes/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page", value: String(page)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await send(request)
        try Task.checkCancellation()
        return try RouteNormalizer.page(from: data, requestedPage: page)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            try await waitOutCoolDown()
            try Task.checkCancellation()

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SearchFailure.offline
            }
            guard let http = response as? HTTPURLResponse else { throw SearchFailure.unreadableResponse }

            switch http.statusCode {
            case 200..<300:
                return data
            case 429:
                let wait = Self.retryAfter(http) ?? .seconds(1 << attempt)
                extendCoolDown(by: wait)
                guard attempt < maxRetries, wait <= maxSilentWait else {
                    throw SearchFailure.rateLimited(retryAfter: wait)
                }
            case 500...599 where attempt < maxRetries:
                try await Task.sleep(for: .milliseconds(300 * (attempt + 1)))
            default:
                throw SearchFailure.server(status: http.statusCode)
            }
            attempt += 1
        }
    }

    private func waitOutCoolDown() async throws {
        guard let until = coolDownUntil else { return }
        let remaining = until - clock.now
        guard remaining > .zero else {
            coolDownUntil = nil
            return
        }
        guard remaining <= maxSilentWait else { throw SearchFailure.rateLimited(retryAfter: remaining) }
        try await clock.sleep(until: until)
    }

    private func extendCoolDown(by wait: Duration) {
        let candidate = clock.now + wait
        coolDownUntil = max(coolDownUntil ?? candidate, candidate)
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Int(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 else { return nil }
        return .seconds(seconds)
    }
}
