import SwiftUI

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
