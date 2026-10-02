import Foundation
import Testing
@testable import ShepherdWebKit

private let host = "macbook1.stern-saturation.ts.net"

private func entry(_ port: Int, proxy: String? = "http://127.0.0.1:8787", handlers: Int = 1) -> ServeEntry {
    ServeEntry(hostPort: "\(host):\(port)", rootProxy: proxy, handlerCount: handlers)
}

@Test func serveStatusJSONIsParsedIntoEntries() {
    let json = """
    {"TCP":{"443":{"HTTPS":true}},
     "Web":{"macbook1.stern-saturation.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}}}
    """
    #expect(parseServeStatus(Data(json.utf8)) == [entry(443)])
}

@Test func noServeConfigMeansNoEntries() {
    #expect(parseServeStatus(Data("{}".utf8)) == [])
    #expect(parseServeStatus(Data("garbage".utf8)) == [])
}

@Test func anEmptyServeConfigPublishesOnThePreferredPort() {
    #expect(planServe(dnsName: host, entries: [], localPort: 8787) == .create(httpsPort: 443))
}

@Test func ourOwnExistingEntryIsReusedNotDuplicated() {
    #expect(planServe(dnsName: host, entries: [entry(443)], localPort: 8787) == .alreadyServing(httpsPort: 443))
}

@Test func someoneElsesEntryOn443IsLeftAloneAndWeUseTheNextPort() {
    let other = entry(443, proxy: "http://127.0.0.1:3000")
    #expect(planServe(dnsName: host, entries: [other], localPort: 8787) == .create(httpsPort: 8443))
}

@Test func anEntryWithExtraPathsIsNotOursEvenIfItsRootMatches() {
    let shared = entry(443, handlers: 2)
    #expect(planServe(dnsName: host, entries: [shared], localPort: 8787) == .create(httpsPort: 8443))
}

@Test func ourEntryOnALaterPortIsFoundBeforeAnyNewOneIsCreated() {
    let entries = [entry(443, proxy: "http://127.0.0.1:3000"), entry(8443)]
    #expect(planServe(dnsName: host, entries: entries, localPort: 8787) == .alreadyServing(httpsPort: 8443))
}

@Test func whenEveryPortIsTakenWeSayNoRatherThanOverwrite() {
    let entries = [443, 8443, 10000].map { entry($0, proxy: "http://127.0.0.1:3000") }
    #expect(planServe(dnsName: host, entries: entries, localPort: 8787) == .noFreePort)
}

@Test func entriesForAnOldHostnameDoNotCountAsTaken() {
    let stale = ServeEntry(hostPort: "old-name.tail1234.ts.net:443", rootProxy: "http://127.0.0.1:3000", handlerCount: 1)
    #expect(planServe(dnsName: host, entries: [stale], localPort: 8787) == .create(httpsPort: 443))
}

@Test func theDefaultPortGivesTheShortAddress() {
    #expect(serveURL(dnsName: host, httpsPort: 443) == "https://\(host)")
    #expect(serveURL(dnsName: host, httpsPort: 8443) == "https://\(host):8443")
}

@Test func aServeNotEnabledMessageYieldsTheAdminLink() {
    let output = """
    Serve is not enabled on your tailnet.
    To enable, visit:

             https://login.tailscale.com/f/serve?node=n123
    """
    let action = parseServeNeedsAction(output)
    #expect(action?.message == "Serve is not enabled on your tailnet.")
    #expect(action?.url == "https://login.tailscale.com/f/serve?node=n123")
}

@Test func ordinaryServeOutputIsNotAnActionRequest() {
    #expect(parseServeNeedsAction("Available within your tailnet:\n\nhttps://macbook1.ts.net/") == nil)
}

private func status(_ configure: (inout MobileAccessStatus) -> Void) -> MobileAccessStatus {
    var s = MobileAccessStatus()
    configure(&s)
    return s
}

@Test func theChecklistStartsWithInstallingTailscale() {
    #expect(MobileAccessStatus().nextStep == .installTailscale)
}

@Test func eachStepWaitsOnTheOneBeforeIt() {
    #expect(status { $0.tailscaleInstalled = true }.nextStep == .signInToTailscale)
    #expect(status { $0.tailscaleInstalled = true; $0.tailscaleConnected = true }.nextStep == .enableHTTPS)
    #expect(status { $0.tailscaleInstalled = true; $0.tailscaleConnected = true; $0.httpsEnabled = true }.nextStep == .publish)
}

@Test func publishedMeansReady() {
    let ready = status {
        $0.tailscaleInstalled = true; $0.tailscaleConnected = true; $0.httpsEnabled = true
        $0.publishedURL = "https://m.t.ts.net"
    }
    #expect(ready.nextStep == .ready)
}

@Test func aLaterStepDoneDoesNotSkipAnEarlierOne() {
    // e.g. a stale published URL while Tailscale has since signed out
    #expect(status { $0.tailscaleInstalled = true; $0.publishedURL = "https://m.t.ts.net" }.nextStep == .signInToTailscale)
}
