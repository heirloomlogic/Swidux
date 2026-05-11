import SwiduxFeatureFlags
import SwiftUI

/// A single counter row with an editable name, count display, and action buttons.
///
/// This is a **controlled component**: the `TextField` is bound directly to the
/// store via `Binding(get:set:)`. No local `@State` — the store is the single
/// source of truth.
///
/// Two feature flags shape the row's appearance:
///
/// - ``BoolFlag/showCelebrationEmoji`` decorates non-zero counts with a 🎉.
/// - ``VariantFlag/counterButtonStyle`` swaps borderless icons (`control`)
///   for bordered chrome (`treatment`).
///
/// Takes a `counterID` rather than the full `Counter` value so that SwiftUI's
/// child-view diffing can skip re-evaluation when the parent's body runs but
/// this row's inputs haven't changed.
struct CounterRow: View {
    @Environment(AppStore.self) private var store

    /// The ID of the counter to display. Looked up from the store each render.
    let counterID: UUID

    var body: some View {
        if let counter = store.counters[counterID] {
            let celebrate = store.featureFlags.isEnabled(.showCelebrationEmoji)
            let buttonVariant = store.featureFlags.variant(of: .counterButtonStyle)

            HStack {
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

                Text(celebrate && counter.count > 0 ? "\(counter.count) 🎉" : "\(counter.count)")
                    .font(.title2.monospacedDigit())
                    .frame(minWidth: 60, alignment: .trailing)

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
            .counterButtonStyle(buttonVariant)
        }
    }
}

extension View {
    /// Applies the button style selected by the `counter_button_style` variant
    /// flag. `@ViewBuilder` lets us return different concrete styled views
    /// from each branch under a single opaque return type.
    @ViewBuilder
    fileprivate func counterButtonStyle(_ variant: CounterButtonStyle) -> some View {
        switch variant {
        case .control:
            buttonStyle(.borderless)
        case .treatment:
            buttonStyle(.bordered)
        }
    }
}
