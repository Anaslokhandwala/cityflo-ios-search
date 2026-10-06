import SwiftUI

struct RouteDetailView: View {
    let route: Route
    let snapshotTakenAt: Date?

    var body: some View {
        List {
            Section {
                LabeledContent("Route", value: route.routeID)
                LabeledContent("Service", value: serviceText)
                if let seats = route.seatsTotal {
                    LabeledContent("Bus capacity", value: "\(seats) seats")
                }
                if let corridor = route.corridor {
                    LabeledContent("Corridor (as labelled)", value: corridor)
                }
            } header: {
                Text(route.displayName)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .padding(.bottom, 4)
            }

            if !route.issues.isEmpty {
                Section("Check before you travel") {
                    ForEach(route.issues.sorted(), id: \.self) { issue in
                        Label(issue.explanation, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }

            ForEach(tripGroups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.trips) { TripRow(trip: $0) }
                }
            }

            if route.trips.isEmpty {
                ContentUnavailableView("No trips listed", systemImage: "calendar.badge.exclamationmark")
            }
        }
        .navigationTitle(route.routeID)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let snapshotTakenAt {
                Text("Timetable as of \(IST.dateTime(snapshotTakenAt)). Seats and status may have changed since.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }

    private var serviceText: String {
        switch route.isActive {
        case true?: "In service"
        case false?: "Not in service"
        case nil: "Unknown"
        }
    }

    private var tripGroups: [(title: String, trips: [Trip])] {
        let sorted = route.tripsByDeparture
        let morning = sorted.filter { $0.departure.map { IST.hour($0) < 12 } ?? false }
        let later = sorted.filter { $0.departure.map { IST.hour($0) >= 12 } ?? false }
        let unknown = sorted.filter { $0.departure == nil }
        return [("Morning", morning), ("Afternoon & evening", later), ("Time unknown", unknown)]
            .filter { !$0.1.isEmpty }
    }
}

struct TripRow: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(timesText)
                    .font(.body.monospacedDigit().weight(.semibold))
                Spacer()
                statusBadge
            }
            HStack(spacing: 6) {
                if let duration = trip.scheduledDuration {
                    Text(IST.duration(duration))
                }
                Text("· \(seatsText)")
                    .foregroundStyle(seatsAreTight ? .red : .secondary)
                if let pct = trip.onTimePercent {
                    Text("· \(pct, format: .number.precision(.fractionLength(0)))% on time")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(trip.tripID)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)

            ForEach(visibleIssues, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var timesText: String {
        let departure = trip.departure.map(IST.time) ?? "--:--"
        let arrival = trip.trustedArrival.map(IST.time) ?? "--:--"
        return "\(departure) → \(arrival)"
    }

    private var seatsText: String {
        switch trip.seats {
        case .available(let left, let total): "\(left) of \(total) seats left"
        case .full: "Full"
        case .unknown: "Seats unknown"
        }
    }

    private var seatsAreTight: Bool {
        switch trip.seats {
        case .available(let left, _): left <= 3
        case .full: true
        case .unknown: false
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch trip.status {
        case .onTime:
            Text("On time").font(.caption.bold()).foregroundStyle(.green)
        case .delayed:
            Text("Delayed").font(.caption.bold()).foregroundStyle(.orange)
        case .unrecognised, .missing:
            EmptyView()
        }
    }

    private var visibleIssues: [String] {
        trip.issues.compactMap(\.explanation).sorted()
    }
}
