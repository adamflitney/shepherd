import Testing
@testable import ShepherdCore

@Test func backendEventHubDeliversBroadcastEventsToASubscriber() async {
    let hub = BackendEventHub()
    let stream = hub.makeStream()
    var iterator = stream.makeAsyncIterator()

    hub.broadcast(.connection(.connected))

    let received = await iterator.next()
    #expect(received == .connection(.connected))
}

@Test func backendEventHubFansOutToMultipleSubscribers() async {
    let hub = BackendEventHub()
    var first = hub.makeStream().makeAsyncIterator()
    var second = hub.makeStream().makeAsyncIterator()

    hub.broadcast(.sessionRemoved(SessionID(rawValue: "agent:1")))

    #expect(await first.next() == .sessionRemoved(SessionID(rawValue: "agent:1")))
    #expect(await second.next() == .sessionRemoved(SessionID(rawValue: "agent:1")))
}

@Test func backendEventHubPreservesDeliveryOrderPerSubscriber() async {
    let hub = BackendEventHub()
    var iterator = hub.makeStream().makeAsyncIterator()

    hub.broadcast(.focusChanged(SessionID(rawValue: "agent:1")))
    hub.broadcast(.focusChanged(nil))

    #expect(await iterator.next() == .focusChanged(SessionID(rawValue: "agent:1")))
    #expect(await iterator.next() == .focusChanged(nil))
}
