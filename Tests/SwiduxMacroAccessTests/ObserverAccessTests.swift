import Swidux
import SwiduxMacroAccessFixtures
import Testing

@Suite("@Swidux cross-module observer access")
@MainActor
struct ObserverAccessTests {
    @Test("A public observer initializes internal state through its public default initializer")
    func publicDefaultInitializerHidesInternalState() {
        let observer = PublicMixedAccessStateObserver()

        #expect(observer.count == 7)
    }

    @Test("A package observer initializes module-private state across targets")
    func packageDefaultInitializerHidesInternalState() {
        let observer = PackageMixedAccessStateObserver()

        #expect(observer.count == 7)
    }

    @Test("A public sliced parent remains constructible from another module")
    func publicSlicedParentIsConstructible() {
        let defaultObserver = PublicParentStateObserver()
        let customObserver = PublicParentStateObserver(child: PublicChildStateObserver(value: 19))

        #expect(defaultObserver.child.value == 0)
        #expect(customObserver.child.value == 19)
    }
}
