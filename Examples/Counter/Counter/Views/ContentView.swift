import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.counters.values) { counter in
                    CounterRow(counterID: counter.id)
                }
                .onDelete { offsets in
                    for index in offsets {
                        let id = store.counters.values[index].id
                        store.send(.counter(.remove(id)))
                    }
                }
            }
            .navigationTitle("Counters")
            .toolbar {
                Button {
                    store.send(.counter(.add))
                } label: {
                    Image(systemName: "plus")
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
        }
    }
}

#Preview {
    ContentView()
        .environment(AppStore(environment: .mock(), reducer: AppReducer()))
}
