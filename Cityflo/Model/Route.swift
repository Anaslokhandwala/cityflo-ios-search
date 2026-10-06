import Foundation

/// A route as the UI sees it: decoded leniently, with every problem we noticed attached as an issue
/// instead of being silently fixed or dropped. See DECISION.md §4 for which fields we trust and why.
struct Route: Identifiable, Hashable, Sendable {
    /// The endpoint's `id` is not unique (two different routes ship as `R-110`), so identity is
    /// the endpoint id plus the record's position in the result list.
    struct ID: Hashable, Sendable {
        let routeID: String
        let position: Int
    }

    var id: ID { ID(routeID: routeID, position: position) }
    let routeID: String
    var position: Int
    /// `nil` when the endpoint sent a blank name; never invented.
    let name: String?
    /// The endpoint's corridor label. Shown on the detail screen only, as a label, because the
    /// snapshot assigns corridors round-robin by id rather than by geography.
    let corridor: String?
    /// `nil` when the endpoint omitted `active`; treated as "not confirmed in service".
    let isActive: Bool?
    let seatsTotal: Int?
    let trips: [Trip]
    var issues: Set<RouteIssue>

    var displayName: String { name ?? "Unnamed route" }
    var isConfirmedActive: Bool { isActive == true }

    /// Trips in departure order. Trips without a usable departure sort last.
    var tripsByDeparture: [Trip] {
        trips.sorted { lhs, rhs in
            switch (lhs.departure, rhs.departure) {
            case let (l?, r?): l < r
            case (.some, nil): true
            default: false
            }
        }
    }

    var hasDataWarnings: Bool {
        !issues.isEmpty || trips.contains { $0.issues.contains(where: \.isUserVisible) }
    }
}

enum RouteIssue: Hashable, Sendable, Comparable {
    case missingName
    case missingCorridor
    case duplicateRouteID
    case missingCapacity
    case activeUnknown
    case unreadableTrips(count: Int)

    var explanation: String {
        switch self {
        case .missingName:
            "This route has no name in our data. Check the stops before you board."
        case .missingCorridor:
            "No corridor is listed for this route."
        case .duplicateRouteID:
            "Another route in these results has the same route ID. Treat this listing with care."
        case .missingCapacity:
            "Bus capacity is missing, so we can't show seats left."
        case .activeUnknown:
            "We can't confirm this route is in service."
        case .unreadableTrips(let count):
            "\(count) trip\(count == 1 ? "" : "s") on this route couldn't be read and \(count == 1 ? "is" : "are") hidden."
        }
    }
}

struct Trip: Identifiable, Hashable, Sendable {
    struct ID: Hashable, Sendable {
        let tripID: String
        let position: Int
    }

    var id: ID { ID(tripID: tripID, position: position) }
    let tripID: String
    let position: Int
    let departure: Date?
    /// The arrival as sent. Use `trustedArrival` for display.
    let arrival: Date?
    let seatsBooked: Int?
    let seatsTotal: Int?
    /// Historical on-time share, 0–100. `nil` if missing or out of range.
    let onTimePercent: Double?
    let status: TripStatus
    var issues: Set<TripIssue>

    /// Arrival is shown only when it comes after departure.
    var trustedArrival: Date? {
        issues.contains(.arrivalBeforeDeparture) ? nil : arrival
    }

    var scheduledDuration: Duration? {
        guard let departure, let arrival = trustedArrival else { return nil }
        return .seconds(arrival.timeIntervalSince(departure))
    }

    var seats: SeatAvailability {
        guard let seatsTotal, let seatsBooked, seatsTotal > 0, seatsBooked >= 0 else { return .unknown }
        let left = seatsTotal - seatsBooked
        return left > 0 ? .available(left: left, of: seatsTotal) : .full
    }
}

enum SeatAvailability: Hashable, Sendable {
    case available(left: Int, of: Int)
    case full
    case unknown
}

enum TripStatus: Hashable, Sendable {
    case onTime
    case delayed
    case unrecognised(String)
    case missing

    init(raw: String?) {
        switch raw?.lowercased() {
        case "on_time": self = .onTime
        case "delayed": self = .delayed
        case nil, "": self = .missing
        case let other?: self = .unrecognised(other)
        }
    }
}

enum TripIssue: Hashable, Sendable {
    case arrivalBeforeDeparture
    /// More than 2 h end to end. Every other trip in the snapshot takes 36–72 min.
    case unusuallyLong(minutes: Int)
    case overCapacity(booked: Int, capacity: Int)
    case duplicateTripID
    case missingTimes
    case onTimeOutOfRange
    /// `on_time_pct` arrived as a numeric string. The value is used, so this is logged but never shown.
    case onTimeCoercedFromString

    var isUserVisible: Bool { self != .onTimeCoercedFromString }

    var explanation: String? {
        switch self {
        case .arrivalBeforeDeparture:
            "The arrival time in our data is earlier than departure, so it's hidden."
        case .unusuallyLong(let minutes):
            "The scheduled journey is \(minutes / 60) h \(minutes % 60) min, much longer than usual for this route. Allow extra time."
        case .overCapacity(let booked, let capacity):
            "\(booked) seats booked on a \(capacity)-seat bus. Treat this trip as full."
        case .duplicateTripID:
            "This trip's ID is listed twice on this route. Times may be a correction of the other listing."
        case .missingTimes:
            "Departure or arrival time is missing."
        case .onTimeOutOfRange:
            "On-time history is unavailable."
        case .onTimeCoercedFromString:
            nil
        }
    }
}
