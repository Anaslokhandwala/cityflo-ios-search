import Foundation

/// One page of search results, already normalised into domain types.
struct SearchPage: Sendable {
    let routes: [Route]
    let page: Int
    let nextPage: Int?
    let totalResults: Int?
    let snapshotTakenAt: Date?
    /// Route records we could not read at all (no `id`, or not an object). Counted, not shown.
    let unreadableRouteCount: Int
}

// MARK: - Wire format

/// The endpoint's shape. Every field is optional and every array is lossy: one bad record must
/// never take the rest of the page down with it.
struct SearchResponseDTO: Decodable, Sendable {
    let generatedAt: String?
    let routes: [Lossy<RouteDTO>]?
    let page: Int?
    let nextPage: Int?
    let totalResults: Int?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case routes, page
        case nextPage = "next_page"
        case totalResults = "total_results"
    }
}

struct RouteDTO: Decodable, Sendable {
    let id: String?
    let name: String?
    let corridor: String?
    let active: Bool?
    let seatsTotal: Int?
    let trips: [Lossy<TripDTO>]?

    enum CodingKeys: String, CodingKey {
        case id, name, corridor, active
        case seatsTotal = "seats_total"
        case trips
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientString(.id)
        name = c.lenientString(.name)
        corridor = c.lenientString(.corridor)
        active = try? c.decodeIfPresent(Bool.self, forKey: .active)
        seatsTotal = c.lenientNumber(.seatsTotal).flatMap { Int(exactly: $0.value) }
        trips = try? c.decodeIfPresent([Lossy<TripDTO>].self, forKey: .trips)
    }
}

struct TripDTO: Decodable, Sendable {
    let tripID: String?
    let departure: String?
    let arrival: String?
    let seatsBooked: Int?
    let onTimePct: LenientNumber?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case tripID = "trip_id"
        case departure, arrival
        case seatsBooked = "seats_booked"
        case onTimePct = "on_time_pct"
        case status
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tripID = c.lenientString(.tripID)
        departure = c.lenientString(.departure)
        arrival = c.lenientString(.arrival)
        seatsBooked = c.lenientNumber(.seatsBooked).flatMap { Int(exactly: $0.value) }
        onTimePct = c.lenientNumber(.onTimePct)
        status = c.lenientString(.status)
    }
}

/// Decodes `T` or records `nil`, so a malformed element doesn't fail its array.
struct Lossy<T: Decodable & Sendable>: Decodable, Sendable {
    let value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// A number that may arrive as a JSON number or a numeric string (`"97.0"`).
struct LenientNumber: Sendable, Hashable {
    let value: Double
    let wasString: Bool
}

private extension KeyedDecodingContainer {
    func lenientString(_ key: Key) -> String? {
        (try? decodeIfPresent(String.self, forKey: key)) ?? nil
    }

    func lenientNumber(_ key: Key) -> LenientNumber? {
        if let number = try? decodeIfPresent(Double.self, forKey: key) {
            return LenientNumber(value: number, wasString: false)
        }
        if let text = try? decodeIfPresent(String.self, forKey: key),
           let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite {
            return LenientNumber(value: number, wasString: true)
        }
        return nil
    }
}
