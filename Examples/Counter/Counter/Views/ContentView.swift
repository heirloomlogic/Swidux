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
}

#Preview {
    ContentView()
        .environment(AppStore(environment: .mock()))
}
