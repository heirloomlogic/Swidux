import Testing

@testable import SwiduxAnalytics

/// Collects the tags of queued calls in the order their work runs.
private actor Ledger {
    private(set) var tags: [Int] = []
    func record(_ tag: Int) { tags.append(tag) }
}

@Suite("ServiceCallQueue")
struct ServiceCallQueueTests {
    private let ledger = Ledger()

    private func call(_ kind: ServiceCallKind, tag: Int) -> QueuedServiceCall {
        let ledger = self.ledger
        return QueuedServiceCall(kind: kind) { await ledger.record(tag) }
    }

    /// Runs every remaining call, so ``Ledger/tags`` shows the pop order.
    private func drain(_ queue: inout ServiceCallQueue) async -> [Int] {
        while let call = queue.popFirst() {
            await call.work()
        }
        return await ledger.tags
    }

    /// Fills the queue to the cap with tracks tagged `1...capacity`.
    private func fillTracks(_ queue: inout ServiceCallQueue) {
        for tag in 1...ServiceCallQueue.droppableCapacity {
            queue.append(call(.track, tag: tag))
        }
    }

    @Test("Calls come out in the order they went in")
    func fifo() async {
        var queue = ServiceCallQueue()
        queue.append(call(.track, tag: 1))
        queue.append(call(.identity, tag: 2))
        queue.append(call(.reset, tag: 3))
        #expect(queue.count == 3)
        #expect(await drain(&queue) == [1, 2, 3])
        #expect(queue.isEmpty)
        #expect(queue.popFirst() == nil)
    }

    @Test("A track past the cap evicts the oldest track, not an older identity call")
    func overflowDropsOldestTrack() async {
        var queue = ServiceCallQueue()
        queue.append(call(.identity, tag: 0))
        fillTracks(&queue)
        queue.append(call(.track, tag: -1))
        #expect(queue.count == ServiceCallQueue.droppableCapacity + 1)
        let order = await drain(&queue)
        #expect(order.prefix(2) == [0, 2])
        #expect(order.last == -1)
    }

    @Test("Identity and reset calls are appended past the cap without dropping anything")
    func identityCallsNeverDropped() async {
        var queue = ServiceCallQueue()
        fillTracks(&queue)
        queue.append(call(.identity, tag: -1))
        queue.append(call(.reset, tag: -2))
        #expect(queue.count == ServiceCallQueue.droppableCapacity + 2)
        let order = await drain(&queue)
        #expect(order.first == 1)
        #expect(order.suffix(2) == [-1, -2])
    }

    @Test("Popping and removing free room under the cap")
    func popAndRemoveMakeRoom() async {
        var queue = ServiceCallQueue()
        fillTracks(&queue)
        _ = queue.popFirst()
        queue.append(call(.track, tag: -1))
        #expect(queue.count == ServiceCallQueue.droppableCapacity)
        queue.removeAll { $0.kind.isDroppable }
        #expect(queue.isEmpty)
        fillTracks(&queue)
        #expect(queue.count == ServiceCallQueue.droppableCapacity)
        #expect(await drain(&queue).first == 1)
    }
}
