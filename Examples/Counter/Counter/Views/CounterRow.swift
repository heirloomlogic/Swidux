import SwiftUI

struct CounterRow: View {
    @Environment(AppStore.self) private var store
    let counterID: UUID

    var body: some View {
        if let counter = store.counters[counterID] {
            HStack {
                // Controlled component — store is single source of truth
                TextField(
                    "Name",
                    text: Binding(
                        get: { counter.name },
                        set: { store.send(.counter(.setName(counterID, $0))) }
                    )
                )
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                Text("\(counter.count)")
                    .font(.title2.monospacedDigit())
                    .frame(minWidth: 40)

                Button {
                    store.send(.counter(.decrement(counterID)))
                } label: {
                    Image(systemName: "minus.circle")
                }

                Button {
                    store.send(.counter(.increment(counterID)))
                } label: {
                    Image(systemName: "plus.circle")
                }

                Button {
                    store.send(.counter(.incrementAsync(counterID)))
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Increment after 1 second delay")
            }
            .buttonStyle(.borderless)
        }
    }
}
