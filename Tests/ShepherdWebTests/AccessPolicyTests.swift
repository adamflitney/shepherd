import Foundation
import Testing
@testable import ShepherdWebKit

@Test func aDirectLocalRequestIsAllowed() {
    #expect(accessDecision(headers: [:], ownerLogin: "me@example.com") == .allow)
}

@Test func theOwnersOwnDeviceThroughTailscaleServeIsAllowed() {
    let headers = ["tailscale-user-login": "me@example.com", "x-forwarded-for": "100.1.2.3"]
    #expect(accessDecision(headers: headers, ownerLogin: "me@example.com") == .allow)
}

@Test func theOwnerComparisonIgnoresCase() {
    #expect(accessDecision(headers: ["tailscale-user-login": "Me@Example.com"], ownerLogin: "me@example.com") == .allow)
}

@Test func anotherTailnetUserIsDenied() {
    let headers = ["tailscale-user-login": "someone@else.com", "x-forwarded-for": "100.1.2.3"]
    #expect(accessDecision(headers: headers, ownerLogin: "me@example.com") != .allow)
}

@Test func anIdentityWeCantCheckIsDeniedRatherThanAllowed() {
    #expect(accessDecision(headers: ["tailscale-user-login": "me@example.com"], ownerLogin: nil) != .allow)
}

@Test func aProxiedRequestWithNoUserIdentityIsDenied() {
    // e.g. a tagged device, which Tailscale serve forwards without a login
    #expect(accessDecision(headers: ["x-forwarded-for": "100.1.2.3"], ownerLogin: "me@example.com") != .allow)
}

@Test func publicFunnelTrafficIsAlwaysDenied() {
    let headers = ["tailscale-funnel-request": "?1", "tailscale-user-login": "me@example.com"]
    #expect(accessDecision(headers: headers, ownerLogin: "me@example.com") != .allow)
}

private let sampleStatus = """
{"BackendState":"Running","Self":{"DNSName":"macbook1.stern-saturation.ts.net.","UserID":42},
 "CertDomains":["macbook1.stern-saturation.ts.net"],
 "User":{"42":{"LoginName":"me@example.com"}}}
"""

@Test func tailscaleStatusParsesTheFieldsWeNeed() {
    let status = TailscaleStatus.parse(Data(sampleStatus.utf8))
    #expect(status?.isRunning == true)
    #expect(status?.dnsName == "macbook1.stern-saturation.ts.net")
    #expect(status?.ownerLogin == "me@example.com")
    #expect(status?.httpsEnabled == true)
    #expect(status?.httpsURL == "https://macbook1.stern-saturation.ts.net")
}

@Test func httpsIsNotEnabledWhenTheTailnetListsNoCertDomains() {
    let json = #"{"BackendState":"Running","Self":{"DNSName":"m.t.ts.net.","UserID":1},"CertDomains":null,"User":{}}"#
    let status = TailscaleStatus.parse(Data(json.utf8))
    #expect(status?.httpsEnabled == false)
    #expect(status?.ownerLogin == nil)
}

@Test func aNeedsLoginStateIsNotRunning() {
    let json = #"{"BackendState":"NeedsLogin","Self":{"DNSName":"","UserID":0},"User":{}}"#
    let status = TailscaleStatus.parse(Data(json.utf8))
    #expect(status?.isRunning == false)
    #expect(status?.dnsName == nil)
}

@Test func garbageIsNotAStatus() {
    #expect(TailscaleStatus.parse(Data("not json".utf8)) == nil)
}

@Test func theCLIIsFoundInTheFirstExistingLocation() {
    let found = locateTailscaleCLI(fileExists: { $0.hasPrefix("/Applications") })
    #expect(found == "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
    #expect(locateTailscaleCLI(fileExists: { _ in false }) == nil)
}
