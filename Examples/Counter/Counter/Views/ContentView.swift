import SwiduxFeatureFlags
import SwiftUI

/// Main list view displaying all counters with selection highlighting.
struct ContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationStack {
            List(store.counters.values) { counter in
                CounterRow(counterID: counter.id)
                    .listRowBackground(
                        store.ui.selectedCounterID == counter.id
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.send(.selectCounter(counter.id))
                    }
            }
            .navigationTitle("Counters")
            .toolbar {
                Button("Add Counter", systemImage: "plus") {
                    store.send(.counter(.add))
                }
                .disabled(store.counters.count >= store.featureFlags.value(of: .maxCounters))
                .help(addButtonHelp)
            }
            .safeAreaInset(edge: .bottom) {
                footer
            }
            .overlay {
                if store.counters.isEmpty {
                    ContentUnavailableView(
                        "No Counters",
                        systemImage: "number.square",
                        description: Text("Tap + to add a counter.")
                    )
                }
            }
            .onAppear { store.undoManager = undoManager }
            .onChange(of: undoManager) { _, new in store.undoManager = new }
        }
    }

    /// Tooltip for the add button — shows the active `max_counters` cap when
    /// the button is disabled so users know why it's dimmed.
    private var addButtonHelp: String {
        let cap = store.featureFlags.value(of: .maxCounters)
        return if store.counters.count >= cap {
            "Reached the max_counters limit (\(cap)) — adjust the flag to add more"
        } else {
            "Add a new counter"
        }
    }

    /// Footer hosting the Flags shortcut and the async-delay slider.
    ///
    /// The slider demonstrates ``Store/binding(_:sending:)`` — a keypath
    /// read on the observer tree paired with an action constructor. Moving
    /// the slider into a footer (rather than the toolbar) gives it the
    /// horizontal room it needs to render labels and thumb cleanly.
    private var footer: some View {
        HStack(spacing: 12) {
            NavigationLink {
                FeatureFlagsDemoView()
            } label: {
                Label("Flags", systemImage: "flag.checkered")
            }
            .buttonStyle(.bordered)

            Spacer()

            Slider(
                value: store.binding(\.ui.asyncDelay) { .setAsyncDelay($0) },
                in: 0.1...3.0,
                step: 0.1
            ) {
                Text("Async delay")
            } minimumValueLabel: {
                Image(systemName: "hare").foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "tortoise").foregroundStyle(.secondary)
            }
            .frame(maxWidth: 260)
            .help(
                "Delay for the async increment button (\(store.ui.asyncDelay, format: .number.precision(.fractionLength(1)))s)"
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

#Preview {
    ContentView()
        .environment(AppStore.configured(environment: .mock()))
}
