import Foundation

/// Turns wire records into domain values. These are the rules in DECISION.md §4, in code form:
/// keep every record we can key, never invent a value, and attach an issue for anything suspicious.
enum RouteNormalizer {
    /// Longest plausible end-to-end trip. Valid trips in the snapshot run 36–72 min.
    static let longTripThreshold: Duration = .seconds(120 * 60)

    static func page(from data: Data, requestedPage: Int) throws -> SearchPage {
        let dto = try JSONDecoder().decode(SearchResponseDTO.self, from: data)
        let records = dto.routes ?? []
        var routes: [Route] = []
        var unreadable = 0
        for record in records {
            guard let routeDTO = record.value, let route = route(from: routeDTO, position: routes.count) else {
                unreadable += 1
                continue
            }
            routes.append(route)
        }
        return SearchPage(
            routes: routes,
            page: dto.page ?? requestedPage,
            nextPage: dto.nextPage,
            totalResults: dto.totalResults,
            snapshotTakenAt: dto.generatedAt.flatMap(parseDate),
            unreadableRouteCount: unreadable
        )
    }

    /// Returns `nil` only when the record has no usable `id`: without a key we can't navigate to it,
    /// de-duplicate it, or book it.
    static func route(from dto: RouteDTO, position: Int) -> Route? {
        guard let routeID = dto.id?.trimmingCharacters(in: .whitespacesAndNewlines), !routeID.isEmpty else {
            return nil
        }
        var issues: Set<RouteIssue> = []

        let name = dto.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if name?.isEmpty ?? true { issues.insert(.missingName) }

        let corridor = dto.corridor?.trimmingCharacters(in: .whitespacesAndNewlines)
        if corridor?.isEmpty ?? true { issues.insert(.missingCorridor) }

        if dto.active == nil { issues.insert(.activeUnknown) }

        let capacity = dto.seatsTotal.flatMap { $0 > 0 ? $0 : nil }
        if capacity == nil { issues.insert(.missingCapacity) }

        let tripRecords = dto.trips ?? []
        var trips: [Trip] = []
        for record in tripRecords {
            if let tripDTO = record.value, let trip = trip(from: tripDTO, capacity: capacity, position: trips.count) {
                trips.append(trip)
            }
        }
        let unreadableTrips = tripRecords.count - trips.count
        if unreadableTrips > 0 { issues.insert(.unreadableTrips(count: unreadableTrips)) }

        return Route(
            routeID: routeID,
            position: position,
            name: (name?.isEmpty ?? true) ? nil : name,
            corridor: (corridor?.isEmpty ?? true) ? nil : corridor,
            isActive: dto.active,
            seatsTotal: capacity,
            trips: markDuplicateTrips(trips),
            issues: issues
        )
    }

    static func trip(from dto: TripDTO, capacity: Int?, position: Int) -> Trip? {
        guard let tripID = dto.tripID?.trimmingCharacters(in: .whitespacesAndNewlines), !tripID.isEmpty else {
            return nil
        }
        var issues: Set<TripIssue> = []
        let departure = dto.departure.flatMap(parseDate)
        let arrival = dto.arrival.flatMap(parseDate)

        if let departure, let arrival {
            if arrival <= departure {
                issues.insert(.arrivalBeforeDeparture)
            } else if Duration.seconds(arrival.timeIntervalSince(departure)) > longTripThreshold {
                issues.insert(.unusuallyLong(minutes: Int(arrival.timeIntervalSince(departure) / 60)))
            }
        } else {
            issues.insert(.missingTimes)
        }

        if let booked = dto.seatsBooked, let capacity, booked > capacity {
            issues.insert(.overCapacity(booked: booked, capacity: capacity))
        }

        var onTime: Double?
        if let pct = dto.onTimePct {
            if (0...100).contains(pct.value) {
                onTime = pct.value
                if pct.wasString { issues.insert(.onTimeCoercedFromString) }
            } else {
                issues.insert(.onTimeOutOfRange)
            }
        }

        return Trip(
            tripID: tripID,
            position: position,
            departure: departure,
            arrival: arrival,
            seatsBooked: dto.seatsBooked,
            seatsTotal: capacity,
            onTimePercent: onTime,
            status: TripStatus(raw: dto.status),
            issues: issues
        )
    }

    /// Flags every trip whose `trip_id` appears more than once on the route. Both are kept:
    /// we can't tell which one is the correction, and hiding the wrong one hides a real bus.
    static func markDuplicateTrips(_ trips: [Trip]) -> [Trip] {
        let counts = Dictionary(trips.map { ($0.tripID, 1) }, uniquingKeysWith: +)
        return trips.map { trip in
            guard counts[trip.tripID, default: 0] > 1 else { return trip }
            var flagged = trip
            flagged.issues.insert(.duplicateTripID)
            return flagged
        }
    }

    /// Flags routes whose endpoint id appears more than once in a loaded result list.
    /// It only sees loaded results: a duplicate that the query didn't match can't be detected here.
    static func markDuplicateRoutes(_ routes: [Route]) -> [Route] {
        let counts = Dictionary(routes.map { ($0.routeID, 1) }, uniquingKeysWith: +)
        return routes.enumerated().map { index, route in
            var annotated = route
            annotated.position = index
            if counts[route.routeID, default: 0] > 1 {
                annotated.issues.insert(.duplicateRouteID)
            }
            return annotated
        }
    }

    static func parseDate(_ text: String) -> Date? {
        try? Date(text, strategy: .iso8601)
    }
}
