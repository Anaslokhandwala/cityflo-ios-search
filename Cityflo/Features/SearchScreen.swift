import SwiftUI

struct SearchScreen: View {
    @State var model: SearchModel
    @State private var path: [Route] = []
    @State private var showsNetworkSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                content
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Find your bus")
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Stop, route or trip ID")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit(of: .search) { model.submit() }
            .navigationDestination(for: Route.self) { route in
                RouteDetailView(route: route, snapshotTakenAt: model.snapshotTakenAt)
            }
            .onChange(of: path) { old, new in
                if new.count > old.count { model.didOpenResult() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Network conditions", systemImage: "antenna.radiowaves.left.and.right") {
                        showsNetworkSettings = true
                    }
                }
            }
            .sheet(isPresented: $showsNetworkSettings) {
                NetworkConditionsSheet()
            }
            .task { await model.loadRecents() }
        }
    }

    @ViewBuilder private var content: some View {
        if model.currentKey.isEmpty {
            recentsSection
        } else if !model.results.isEmpty {
            resultsSection
        } else if model.isSearching {
            HStack {
                Spacer()
                ProgressView("Searching…")
                Spacer()
            }
            .listRowBackground(Color.clear)
        } else if let failure = model.failure {
            ContentUnavailableView {
                Label("Search failed", systemImage: "wifi.exclamationmark")
            } description: {
                Text(failure.message)
            } actions: {
                Button("Try again") { model.retry() }
            }
            .listRowBackground(Color.clear)
        } else if model.resultsQuery != nil {
            ContentUnavailableView.search(text: model.resultsQuery ?? model.query)
                .listRowBackground(Color.clear)
        }
    }

    // MARK: Recents

    @ViewBuilder private var recentsSection: some View {
        if model.recents.isEmpty {
            ContentUnavailableView(
                "Search for your bus",
                systemImage: "bus",
                description: Text("Try a stop like “Powai”, a route like “R-103”, or a trip ID.")
            )
            .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(model.recents, id: \.self) { recent in
                    Button {
                        model.rerun(recent)
                    } label: {
                        Label(recent, systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(.primary)
                    }
                }
                .onDelete { model.removeRecents(at: $0) }
            } header: {
                HStack {
                    Text("Recent searches")
                    Spacer()
                    Button("Clear") { model.clearRecents() }
                        .font(.caption)
                        .textCase(nil)
                }
            } footer: {
                Text("Stored only on this device.")
            }
        }
    }

    // MARK: Results

    private var resultsSection: some View {
        Section {
            ForEach(model.results) { route in
                NavigationLink(value: route) {
                    RouteRow(route: route)
                }
                .opacity(model.isShowingStaleResults ? 0.45 : 1)
                .onAppear { model.rowAppeared(route) }
            }
            pagingFooter
        } header: {
            resultsHeader
        } footer: {
            resultsFooter
        }
    }

    /// Stale results are always labelled with the query they belong to.
    @ViewBuilder private var resultsHeader: some View {
        let shownFor = model.resultsQuery ?? ""
        if model.isShowingStaleResults, let failure = model.failure {
            VStack(alignment: .leading, spacing: 4) {
                Label("Still showing results for “\(shownFor)”", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(failure.message)
                Button("Retry “\(RecentSearches.normalize(model.query))”") { model.retry() }
                    .font(.caption.bold())
            }
            .textCase(nil)
        } else if model.isShowingStaleResults {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Updating… showing results for “\(shownFor)”")
            }
            .textCase(nil)
        } else if let total = model.totalResults {
            Text("\(total) route\(total == 1 ? "" : "s") for “\(shownFor)”")
                .textCase(nil)
        }
    }

    @ViewBuilder private var pagingFooter: some View {
        if model.isLoadingMore {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        } else if let failure = model.loadMoreFailure {
            Button {
                model.loadMore()
            } label: {
                Label("Couldn't load more. \(failure.message) Tap to retry.", systemImage: "arrow.clockwise")
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder private var resultsFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.unreadableRouteCount > 0 {
                Text("\(model.unreadableRouteCount) route record\(model.unreadableRouteCount == 1 ? "" : "s") couldn't be read and \(model.unreadableRouteCount == 1 ? "isn't" : "aren't") shown.")
            }
            if let snapshot = model.snapshotTakenAt {
                Text("Timetable as of \(IST.dateTime(snapshot)). Seats and status may have changed since.")
            }
        }
    }
}

struct RouteRow: View {
    let route: Route

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(route.displayName)
                    .font(.headline)
                    .foregroundStyle(route.name == nil ? .secondary : .primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if route.hasDataWarnings {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Some details on this route may be unreliable")
                }
            }
            HStack(spacing: 6) {
                Text(route.routeID).monospaced()
                if !route.isConfirmedActive {
                    Text("· Not confirmed in service").foregroundStyle(.red)
                }
                Text("· \(route.trips.count) trip\(route.trips.count == 1 ? "" : "s")")
                if let window = departureWindow {
                    Text("· \(window)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var departureWindow: String? {
        let departures = route.trips.compactMap(\.departure).sorted()
        guard let first = departures.first, let last = departures.last else { return nil }
        return first == last ? IST.time(first) : "\(IST.time(first))–\(IST.time(last))"
    }
}
