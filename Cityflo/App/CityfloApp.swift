import SwiftUI

@main
struct CityfloApp: App {
    @State private var model = SearchModel(
        service: CFNetworkConduit.simulated(),
        recentsStore: RecentSearchStore(fileURL: RecentSearchStore.defaultLocation())
    )

    var body: some Scene {
        WindowGroup {
            SearchScreen(model: model)
                .task {
                    // Demo hook: launch straight into a search, e.g. CF_QUERY=powai.
                    if let query = ProcessInfo.processInfo.environment["CF_QUERY"], model.query.isEmpty {
                        model.query = query
                    }
                }
        }
    }
}
