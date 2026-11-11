import Foundation
import Testing

/// The tests run hosted in the app, so `Bundle.main` is VIRT.app.
struct ATSTests {
    private let info = Bundle.main.infoDictionary ?? [:]

    private var ats: [String: Any] {
        info["NSAppTransportSecurity"] as? [String: Any] ?? [:]
    }

    @Test func allowsPlainWebSocketsOnlyToTailnetNames() throws {
        let domains = try #require(ats["NSExceptionDomains"] as? [String: Any])
        #expect(Array(domains.keys) == ["ts.net"])
        let tailnet = try #require(domains["ts.net"] as? [String: Any])
        #expect(tailnet["NSIncludesSubdomains"] as? Bool == true)
        #expect(tailnet["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true)
    }

    @Test func doesNotAllowArbitraryLoads() {
        #expect(ats["NSAllowsArbitraryLoads"] == nil)
        #expect(ats["NSAllowsArbitraryLoadsInWebContent"] == nil)
        #expect(ats["NSAllowsArbitraryLoadsForMedia"] == nil)
    }

    @Test func keepsGeneratedKeys() {
        #expect(info["CFBundleDisplayName"] as? String == "VIRT")
        #expect(info["UIApplicationSceneManifest"] != nil)
    }
}
