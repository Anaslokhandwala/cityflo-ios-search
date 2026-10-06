import SwiftUI

/// Changes the simulated endpoint's latency, rate limit and failure rate while the app runs.
/// This is how the live debrief's "new constraint" gets imposed without a rebuild.
struct NetworkConditionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var conditions: NetworkConditions?

    var body: some View {
        NavigationStack {
            Form {
                if let binding = Binding($conditions) {
                    Section("Presets") {
                        ForEach(NetworkConditions.Preset.allCases) { preset in
                            Button(preset.title) { conditions = preset.conditions }
                        }
                    }
                    Section("Latency") {
                        Stepper("Base: \(binding.wrappedValue.baseLatency.milliseconds) ms",
                                value: milliseconds(binding.baseLatency), in: 0...10_000, step: 100)
                        Stepper("Jitter: up to \(binding.wrappedValue.jitter.milliseconds) ms",
                                value: milliseconds(binding.jitter), in: 0...10_000, step: 100)
                    }
                    Section {
                        Stepper(binding.wrappedValue.requestsPerWindow == 0
                                ? "Unlimited"
                                : "\(binding.wrappedValue.requestsPerWindow) requests / \(binding.wrappedValue.window.milliseconds / 1000) s",
                                value: binding.requestsPerWindow, in: 0...60)
                        Stepper("Window: \(binding.wrappedValue.window.milliseconds / 1000) s",
                                value: seconds(binding.window), in: 1...120)
                    } header: {
                        Text("Rate limit (HTTP 429)")
                    }
                    Section("Failures (HTTP 503)") {
                        Slider(value: binding.failureRate, in: 0...1, step: 0.05) {
                            Text("Failure rate")
                        }
                        Text("\(Int(binding.wrappedValue.failureRate * 100))% of requests fail")
                            .font(.caption)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Network conditions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        if let conditions {
                            Task { await SimulatedBackend.shared.setConditions(conditions) }
                        }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { conditions = await SimulatedBackend.shared.conditions }
        }
    }

    private func milliseconds(_ binding: Binding<Duration>) -> Binding<Int> {
        Binding(get: { binding.wrappedValue.milliseconds }, set: { binding.wrappedValue = .milliseconds($0) })
    }

    private func seconds(_ binding: Binding<Duration>) -> Binding<Int> {
        Binding(get: { binding.wrappedValue.milliseconds / 1000 }, set: { binding.wrappedValue = .seconds($0) })
    }
}
