//
//  StoreBinding.swift
//  Swidux
//
//  Convenience helper for creating SwiftUI bindings that dispatch actions.
//

import SwiftUI

extension Store {
    /// Creates a SwiftUI ``Binding`` that reads a property through the
    /// observer tree and dispatches an action when written.
    ///
    /// Use this for the common case where a form control writes a single
    /// value to a single action:
    ///
    /// ```swift
    /// Slider(value: store.binding(\.ui.projector.slideDuration) {
    ///     .projector(.setSlideDuration($0))
    /// }, in: 5...60, step: 1)
    /// ```
    ///
    /// The keypath is resolved against ``SwiduxObservable/Observer``, so
    /// `\.ui.projector.slideDuration` traverses the generated observer tree.
    /// This preserves per-property observation: SwiftUI only invalidates the
    /// view when the read property actually changes.
    ///
    /// For transformed reads (optional unwraps, `EntityStore` lookups,
    /// negated booleans) or setters that need extra work (animation, branching),
    /// fall back to ``SwiftUI/Binding/init(get:set:)``.
    ///
    /// - Parameters:
    ///   - keyPath: A keypath into the observer tree identifying the property
    ///     to read.
    ///   - action: A closure mapping the new value to an ``Action`` that the
    ///     store will dispatch on change.
    /// - Returns: A binding suitable for any SwiftUI control.
    public func binding<Value>(
        _ keyPath: KeyPath<State.Observer, Value>,
        sending action: @escaping (Value) -> Action
    ) -> Binding<Value> {
        Binding(
            get: { self.observer[keyPath: keyPath] },
            set: { self.send(action($0)) }
        )
    }
}
