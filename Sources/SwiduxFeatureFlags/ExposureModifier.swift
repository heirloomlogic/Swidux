//
//  ExposureModifier.swift
//  SwiduxFeatureFlags
//

import Swidux
import SwiftUI

extension View {
    /// Records an exposure for the given variant flag when this view appears.
    ///
    /// Sugar over dispatching `.featureFlags(.recordExposure(key:))`. The
    /// plugin dedupes per session, so it's safe to attach this modifier to
    /// any view that displays a treatment.
    ///
    /// ```swift
    /// if store.featureFlags.variant(of: .checkoutLayout) == .wizard {
    ///     WizardView()
    ///         .recordsExposure(of: .checkoutLayout, store: store, action: AppAction.featureFlags)
    /// }
    /// ```
    public func recordsExposure<RootState, RootAction, Variant>(
        of flag: VariantFlag<Variant>,
        store: Store<RootState, RootAction>,
        action: @escaping (FeatureFlagsAction) -> RootAction
    ) -> some View where Variant: RawRepresentable & Sendable, Variant.RawValue == String {
        self.onAppear {
            store.send(action(.recordExposure(key: flag.key)))
        }
    }

    /// Records an exposure for a boolean flag when this view appears.
    public func recordsExposure<RootState, RootAction>(
        of flag: BoolFlag,
        store: Store<RootState, RootAction>,
        action: @escaping (FeatureFlagsAction) -> RootAction
    ) -> some View {
        self.onAppear {
            store.send(action(.recordExposure(key: flag.key)))
        }
    }
}
