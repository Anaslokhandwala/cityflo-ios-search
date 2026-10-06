import Foundation

/// Knobs for the simulated search endpoint. A bundled file answers instantly, so without these
/// nothing exercises cancellation, out-of-order responses, or rate limiting.
struct NetworkConditions: Sendable, Equatable {
    var baseLatency: Duration
    /// Added uniformly at random on top of `baseLatency`, so responses can arrive out of order.
    var jitter: Duration
    /// Requests allowed per `window` before the endpoint answers 429. `0` means unlimited.
    var requestsPerWindow: Int
    var window: Duration
    /// Share of requests answered with 503, from 0 to 1.
    var failureRate: Double

    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case instant, typical, peak
        var id: String { rawValue }

        var title: String {
            switch self {
            case .instant: "Instant (bundled file)"
            case .typical: "Typical 4G"
            case .peak: "8 am peak, rate-limited"
            }
        }

        var conditions: NetworkConditions {
            switch self {
            case .instant:
                NetworkConditions(baseLatency: .zero, jitter: .zero, requestsPerWindow: 0, window: .seconds(10), failureRate: 0)
            case .typical:
                NetworkConditions(baseLatency: .milliseconds(250), jitter: .milliseconds(600), requestsPerWindow: 0, window: .seconds(10), failureRate: 0)
            case .peak:
                NetworkConditions(baseLatency: .milliseconds(900), jitter: .milliseconds(1600), requestsPerWindow: 4, window: .seconds(10), failureRate: 0.05)
            }
        }
    }

    /// Reads `CF_NETWORK` (`instant` / `typical` / `peak`) from the environment. Defaults to `typical`.
    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> NetworkConditions {
        let preset = environment["CF_NETWORK"].flatMap(Preset.init(rawValue:)) ?? .typical
        return preset.conditions
    }
}
