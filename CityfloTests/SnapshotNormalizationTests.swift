import Foundation
import Testing
@testable import Cityflo

/// Pins down what the client does with every known wart in the shipped snapshot.
struct SnapshotNormalizationTests {
    let page: SearchPage

    init() throws {
        let url = try #require(Bundle.main.url(forResource: "routes", withExtension: "json"))
        page = try RouteNormalizer.page(from: Data(contentsOf: url), requestedPage: 1)
    }

    private func route(_ id: String, named name: String? = nil) throws -> Route {
        try #require(page.routes.first { $0.routeID == id && (name == nil || $0.name == name) })
    }

    private func trip(_ id: String, on routeID: String) throws -> [Trip] {
        try route(routeID).trips.filter { $0.tripID == id }
    }

    @Test func keepsEveryRecordThatHasAnID() {
        #expect(page.routes.count == 20)
        #expect(page.routes.flatMap(\.trips).count == 67)
        #expect(page.unreadableRouteCount == 0)
    }

    @Test func numericStringOnTimeIsUsedSilently() throws {
        let t = try #require(try trip("T-1018", on: "R-105").first)
        #expect(t.onTimePercent == 97.0)
        #expect(t.issues.count == 1)
        #expect(t.issues.contains(.onTimeCoercedFromString))
        let hasVisibleIssue = t.issues.contains(where: \.isUserVisible)
        #expect(!hasVisibleIssue)
    }

    @Test func arrivalBeforeDepartureHidesArrivalAndDuration() throws {
        let t = try #require(try trip("T-1035", on: "R-111").first)
        #expect(t.issues.contains(.arrivalBeforeDeparture))
        #expect(t.trustedArrival == nil)
        #expect(t.scheduledDuration == nil)
        #expect(t.departure != nil)
    }

    @Test func overbookedTripIsFullNotNegative() throws {
        let t = try #require(try trip("T-1045", on: "R-114").first)
        #expect(t.seats == .full)
        #expect(t.issues.contains(.overCapacity(booked: 41, capacity: 34)))
    }

    @Test func implausiblyLongTripIsKeptButFlagged() throws {
        let t = try #require(try trip("T-1028", on: "R-109").first)
        #expect(t.issues.contains(.unusuallyLong(minutes: 200)))
        #expect(t.scheduledDuration == .seconds(200 * 60))
    }

    @Test func duplicateTripIDsAreBothKeptAndFlagged() throws {
        let dupes = try trip("T-1022", on: "R-107")
        #expect(dupes.count == 2)
        #expect(dupes.allSatisfy { $0.issues.contains(.duplicateTripID) })
        #expect(Set(dupes.map(\.id)).count == 2, "SwiftUI identity must stay unique")
    }

    @Test func blankNameIsNotInvented() throws {
        let r = try route("R-120")
        #expect(r.name == nil)
        #expect(r.displayName == "Unnamed route")
        #expect(r.issues.contains(.missingName))
    }

    @Test func missingCorridorIsFlagged() throws {
        let r = try route("R-119")
        #expect(r.corridor == nil)
        #expect(r.issues.contains(.missingCorridor))
    }

    @Test func duplicateRouteIDsGetDistinctIdentityAndAFlag() {
        let marked = RouteNormalizer.markDuplicateRoutes(page.routes)
        let r110 = marked.filter { $0.routeID == "R-110" }
        #expect(r110.count == 2)
        #expect(Set(r110.map(\.id)).count == 2)
        #expect(r110.allSatisfy { $0.issues.contains(.duplicateRouteID) })
        #expect(Set(marked.map(\.id)).count == marked.count)
    }

    @Test func cleanTripHasNoIssues() throws {
        let t = try #require(try trip("T-1001", on: "R-101").first)
        #expect(t.issues.isEmpty)
        #expect(t.seats == .available(left: 25, of: 40))
        #expect(t.scheduledDuration == .seconds(44 * 60))
    }

    @Test func malformedRecordsDoNotSinkThePage() throws {
        let json = """
        {"routes": [
          {"id": "R-1", "name": "A → B", "seats_total": "lots", "trips": [
            {"trip_id": "T-1", "departure": "nonsense", "seats_booked": 3, "on_time_pct": 140},
            {"departure": "2026-06-24T08:00:00+05:30"},
            42
          ]},
          {"name": "no id"},
          "garbage"
        ]}
        """
        let page = try RouteNormalizer.page(from: Data(json.utf8), requestedPage: 1)
        #expect(page.routes.count == 1)
        #expect(page.unreadableRouteCount == 2)
        let route = try #require(page.routes.first)
        #expect(route.seatsTotal == nil)
        #expect(route.issues.contains(.missingCapacity))
        #expect(route.issues.contains(.unreadableTrips(count: 2)))
        let trip = try #require(route.trips.first)
        #expect(trip.issues.contains(.missingTimes))
        #expect(trip.issues.contains(.onTimeOutOfRange))
        #expect(trip.onTimePercent == nil)
        #expect(trip.seats == .unknown)
    }
}
