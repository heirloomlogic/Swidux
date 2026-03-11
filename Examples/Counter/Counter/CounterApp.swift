import SwiftUI

/// App entry point. Creates the store and injects it into the environment.
///
/// `@State` owns the `AppStore` instance so it survives `Scene` body
/// re-evaluations without being recreated.
@main
struct CounterApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}
