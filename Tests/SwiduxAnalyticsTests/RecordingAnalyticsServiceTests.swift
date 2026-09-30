import Swidux
import Testing

@testable import SwiduxAnalytics

@Suite("RecordingAnalyticsService")
struct RecordingAnalyticsServiceTests {
    @Test("A new recorder is empty")
    func startsEmpty() async {
        let recorder = RecordingAnalyticsService()
        #expect(await recorder.calls.isEmpty)
        #expect(await recorder.trackedEvents.isEmpty)
        #expect(await recorder.identifyCalls.isEmpty)
        #expect(await recorder.aliasCalls.isEmpty)
        #expect(await recorder.resetCount == 0)
        #expect(await recorder.flushCount == 0)
    }

    @Test("calls keeps every kind in arrival order")
    func recordsCallsInOrder() async {
        let recorder = RecordingAnalyticsService()
        await recorder.setOptedOut(false)
        await recorder.identify(userID: "u1", properties: ["plan": .string("pro")])
        await recorder.track(AnalyticsEvent("opened", ["count": .int(1)]))
        await recorder.alias(newID: "u1", previousID: "anon")
        await recorder.setOptedOut(true)
        await recorder.reset()
        await recorder.flush()

        #expect(
            await recorder.calls == [
                .setOptedOut(false),
                .identify(userID: "u1", properties: ["plan": .string("pro")]),
                .track(AnalyticsEvent("opened", ["count": .int(1)])),
                .alias(newID: "u1", previousID: "anon"),
                .setOptedOut(true),
                .reset,
                .flush,
            ])
    }

    @Test("Per-kind views read from the ordered log")
    func perKindViews() async {
        let recorder = RecordingAnalyticsService()
        await recorder.track(AnalyticsEvent("a"))
        await recorder.identify(userID: "u1", properties: [:])
        await recorder.track(AnalyticsEvent("b"))
        await recorder.alias(newID: "u2", previousID: nil)
        await recorder.identify(userID: "u2", properties: ["tier": .string("free")])
        await recorder.reset()
        await recorder.reset()
        await recorder.flush()
        await recorder.setOptedOut(true)

        #expect(await recorder.trackedEvents == [AnalyticsEvent("a"), AnalyticsEvent("b")])
        #expect(
            await recorder.identifyCalls == [
                .init(userID: "u1"),
                .init(userID: "u2", properties: ["tier": .string("free")]),
            ])
        #expect(await recorder.aliasCalls == [.init(newID: "u2")])
        #expect(await recorder.resetCount == 2)
        #expect(await recorder.flushCount == 1)
    }
}
