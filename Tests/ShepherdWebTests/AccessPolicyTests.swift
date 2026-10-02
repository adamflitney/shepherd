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

// MARK: - requestSafety (web pages in the user's own browser)

private let tailnet = "macbook1.stern-saturation.ts.net"

private func safety(
    _ method: String = "GET", host: String? = "localhost:8787", origin: String? = nil, site: String? = nil,
    contentType: String? = nil, body: Bool = false, tailnetHost: String? = nil
) -> AccessDecision {
    var headers: [String: String] = [:]
    if let host { headers["host"] = host }
    if let origin { headers["origin"] = origin }
    if let site { headers["sec-fetch-site"] = site }
    if let contentType { headers["content-type"] = contentType }
    return requestSafety(method: method, headers: headers, hasBody: body, tailnetHost: tailnetHost)
}

@Test func localHostNamesAreAllowed() {
    #expect(safety(host: "localhost:8787") == .allow)
    #expect(safety(host: "127.0.0.1:8787") == .allow)
    #expect(safety(host: "[::1]:8787") == .allow)
}

@Test func aRequestWithNoHostIsRefused() {
    #expect(safety(host: nil) != .allow)
}

@Test func anAttackersDomainPointingAtUsIsRefusedWhichIsWhatStopsDNSRebinding() {
    #expect(safety(host: "rebind.evil.example:8787") != .allow)
    #expect(safety(host: "evil.example") != .allow)
}

@Test func theTailnetNameIsAllowedOnlyWhenItIsOursAndKnown() {
    #expect(safety(host: tailnet, tailnetHost: tailnet) == .allow)
    #expect(safety(host: "\(tailnet):8443", tailnetHost: tailnet) == .allow)
    #expect(safety(host: tailnet, tailnetHost: "other.tail1234.ts.net") != .allow)
    #expect(safety(host: tailnet, tailnetHost: nil) != .allow)
}

@Test func aCrossOriginRequestIsRefusedEvenWhenTheHostLooksFine() {
    #expect(safety("POST", origin: "https://evil.example", contentType: "application/json", body: true) != .allow)
    #expect(safety(origin: "null") != .allow)
}

@Test func aSameOriginRequestIsAllowed() {
    #expect(safety("POST", origin: "http://localhost:8787", contentType: "application/json", body: true) == .allow)
    #expect(safety("POST", host: tailnet, origin: "https://\(tailnet)", contentType: "application/json", body: true, tailnetHost: tailnet) == .allow)
    #expect(safety("POST", host: "[::1]:8787", origin: "http://[::1]:8787", contentType: "application/json", body: true) == .allow)
}

@Test func aSameSiteButDifferentAppIsRefusedViaFetchMetadata() {
    // another dev server on localhost:3000 is same-site with us, not same-origin
    #expect(safety(site: "same-site") != .allow)
    #expect(safety(site: "cross-site") != .allow)
}

@Test func sameOriginAndUserNavigationFetchMetadataAreAllowed() {
    #expect(safety(site: "same-origin") == .allow)
    #expect(safety(site: "none") == .allow)
}

@Test func aNonJSONBodyIsRefused() {
    #expect(safety("POST", contentType: "text/plain", body: true) != .allow)
    #expect(safety("POST", contentType: nil, body: true) != .allow)
    #expect(safety("POST", contentType: "application/x-www-form-urlencoded", body: true) != .allow)
}

@Test func aJSONBodyIsAllowedWithOrWithoutACharset() {
    #expect(safety("POST", contentType: "application/json", body: true) == .allow)
    #expect(safety("POST", contentType: "application/json; charset=utf-8", body: true) == .allow)
}

@Test func aBodylessPostNeedsNoContentType() {
    #expect(safety("POST", body: false) == .allow)
}

@Test func hostHeadersAreParsedForPortsIPv6AndTrailingDots() {
    #expect(hostname(fromHostHeader: "Localhost:8787") == "localhost")
    #expect(hostname(fromHostHeader: "[::1]:8787") == "[::1]")
    #expect(hostname(fromHostHeader: "macbook1.ts.net.") == "macbook1.ts.net")
    #expect(hostname(fromHostHeader: "") == nil)
}
