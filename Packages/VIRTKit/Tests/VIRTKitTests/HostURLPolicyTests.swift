import Foundation
import Testing
@testable import VIRTKit

struct HostURLPolicyTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let url: String
        let expected: HostURLPolicy.Outcome
        var testDescription: String { url }
    }

    static let accepted: [Case] = [
        "wss://example.com",
        "wss://example.com:8443/ahp",
        "WSS://Example.COM/Path",
        "wss://100.128.0.1",
        "wss://ts.net",
        "ws://localhost",
        "ws://localhost:48765",
        "WS://LOCALHOST:48765/ahp",
        "ws://127.0.0.1:48765",
        "ws://[::1]:48765/",
        "ws://mac.ts.net",
        "ws://mac.tailnet-name.ts.net:48765/ahp",
        "ws://Mac.Tailnet-Name.TS.NET",
    ].map { Case(url: $0, expected: .accepted(warning: nil)) }

    static let carrierGradeNAT: [Case] = [
        "ws://100.64.0.1",
        "ws://100.64.0.0:48765/ahp",
        "ws://100.100.100.100",
        "ws://100.127.255.255",
    ].map { Case(url: $0, expected: .accepted(warning: .carrierGradeNAT)) }

    static let refused: [Case] = ([
        ("http://localhost", .unsupportedScheme),
        ("https://example.com", .unsupportedScheme),
        ("ftp://example.com", .unsupportedScheme),
        ("example.com", .unsupportedScheme),
        ("ws:///ahp", .missingHost),
        ("wss://", .missingHost),
        ("ws:/ahp", .missingHost),
        ("ws://example.com", .insecureHostNotAllowed),
        ("ws://ts.net", .insecureHostNotAllowed),
        ("ws://.ts.net", .insecureHostNotAllowed),
        ("ws://a..ts.net", .insecureHostNotAllowed),
        ("ws://x.ts.net.evil.com", .insecureHostNotAllowed),
        ("ws://evilts.net", .insecureHostNotAllowed),
        ("ws://a.ts.net.", .insecureHostNotAllowed),
        ("ws://a%41.ts.net", .insecureHostNotAllowed),
        ("ws://xn--bcher-kva.ts.net", .insecureHostNotAllowed),
        ("ws://100.128.0.1", .insecureHostNotAllowed),
        ("ws://100.63.255.255", .insecureHostNotAllowed),
        ("ws://100.64.0.1.example.com", .insecureHostNotAllowed),
        ("ws://100.064.0.1", .insecureHostNotAllowed),
        ("ws://100.64.0", .insecureHostNotAllowed),
        ("ws://100.64.0.256", .insecureHostNotAllowed),
        ("ws://192.168.1.10", .insecureHostNotAllowed),
        ("ws://127.0.0.2", .insecureHostNotAllowed),
        ("ws://[::2]", .insecureHostNotAllowed),
        ("wss://user@example.com", .userInfo),
        ("ws://user:secret@localhost", .userInfo),
        ("wss://example.com/?tkn=abc", .query),
        ("ws://localhost/?", .query),
        ("wss://example.com/#top", .fragment),
        ("ws://localhost#", .fragment),
    ] as [(String, HostURLPolicy.Refusal)]).map { Case(url: $0.0, expected: .refused($0.1)) }

    @Test(arguments: accepted + carrierGradeNAT + refused)
    func evaluates(_ testCase: Case) throws {
        let url = try #require(URL(string: testCase.url))
        let outcome = HostURLPolicy().evaluate(url)
        #expect(outcome == testCase.expected)
        #expect(outcome.isAccepted == (testCase.expected.refusal == nil))
        #expect(outcome.warning == testCase.expected.warning)
        #expect(outcome.refusal == testCase.expected.refusal)
    }

    @Test func idnHostIsRefusedForWS() throws {
        let url = try #require(URL(string: "ws://bücher.ts.net"))
        #expect(HostURLPolicy().evaluate(url) == .refused(.insecureHostNotAllowed))
    }

    /// The URL the README gives for a guppi host published with `tailscale serve --https=8443`.
    @Test func acceptsTheREADMETailscaleServeURL() throws {
        let url = try #require(URL(string: "wss://machine.tailnet.ts.net:8443"))
        #expect(HostURLPolicy().evaluate(url) == .accepted(warning: nil))
    }

    @Test func refusesTheREADMETailscaleServeURLWithATokenQuery() throws {
        let url = try #require(URL(string: "wss://machine.tailnet.ts.net:8443?tkn=x"))
        #expect(HostURLPolicy().evaluate(url) == .refused(.query))
    }

    @Test func everyRefusalHasAMessage() {
        for refusal in HostURLPolicy.Refusal.allCases {
            #expect(!refusal.message.isEmpty)
            #expect(refusal.localizedDescription == refusal.message)
        }
    }

    @Test func carrierGradeNATWarningExplainsTheRisk() {
        let message = HostURLPolicy.Warning.carrierGradeNAT.message
        #expect(message.contains("Tailscale off"))
        #expect(message.contains("plain text"))
        #expect(message.contains(".ts.net"))
    }
}
