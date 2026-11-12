import Foundation
import Synchronization
import Testing
@testable import VIRTKit
// Foundation on macOS has its own `Host`; this scoped import picks VIRTKit's.
import struct VIRTKit.Host

/// A resolver and interface list the test controls, with call counters. Tailscale starts on,
/// and `mac.tailnet.ts.net` resolves to `100.101.2.3`.
final class FakeTailnet: Sendable {
    struct ResolveError: Error {}

    /// What the resolver returns, or `nil` to throw.
    let resolved = Mutex<[String]?>(["100.101.2.3"])
    let local = Mutex<[String]>(["127.0.0.1", "192.168.1.20", "100.90.1.1"])
    let resolves = Mutex(0)
    let interfaceReads = Mutex(0)

    var resolver: HostResolver {
        HostResolver { _ in
            self.resolves.withLock { $0 += 1 }
            guard let addresses = self.resolved.withLock({ $0 }) else { throw ResolveError() }
            return addresses
        }
    }

    var interfaces: LocalInterfaces {
        LocalInterfaces {
            self.interfaceReads.withLock { $0 += 1 }
            return self.local.withLock { $0 }
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct TailnetCheckTests {
    private let temporary = TemporaryDefaults()
    private let tokens = FakeTokenStore()
    private let fakeHosts = FakeHosts()
    private let tailnet = FakeTailnet()
    private let connected = HostConnector.Status.connected(protocolVersion: FakeHosts.version)

    /// Saves the host and its token, connects, and returns the connector, which the caller
    /// keeps alive to see any retry, with the statuses up to `done`.
    private func connect(_ url: String, until done: (HostConnector.Status) -> Bool)
        async throws -> (HostConnector, [HostConnector.Status]) {
        let host = Host(name: "Mac", url: URL(string: url)!)
        try HostStore(defaults: temporary.defaults).save([host])
        try await tokens.setToken("tok", for: host.id)
        let library = HostLibrary(hostStore: HostStore(defaults: temporary.defaults), tokenStore: tokens)
        let connector = HostConnector(library: library, transportMaker: fakeHosts.maker, reconnectPolicy: .exponential,
                                      resolver: tailnet.resolver, interfaces: tailnet.interfaces)
        var updates = await connector.statusUpdates(for: host.id).makeAsyncIterator()
        await connector.connect(host.id)
        return (connector, await next(&updates, until: done))
    }

    @Test(arguments: [
        ("outside the ranges", ["192.168.1.20"], true),
        ("a mix", ["100.101.2.3", "203.0.113.7"], true),
        ("empty", [], true),
        ("a resolver error", nil, true),
        ("no Tailscale interface", ["100.101.2.3"], false),
    ] as [(String, [String]?, Bool)])
    func offTheTailnetFailsWithoutTokenOrTransport(_ name: String, resolved: [String]?, tailscaleOn: Bool) async throws {
        tailnet.resolved.withLock { $0 = resolved }
        if !tailscaleOn { tailnet.local.withLock { $0 = ["127.0.0.1", "192.168.1.20", "fd00::1"] } }
        let (connector, seen) = try await connect("ws://mac.tailnet.ts.net:48765/ahp", until: isFailed)

        #expect(seen.last == .failed(.notOnTailnet))
        #expect(HostConnector.Failure.notOnTailnet.message == "This address isn't on your tailnet. Is Tailscale on?")
        // Turning Tailscale on doesn't help: nothing retries after the failure.
        tailnet.resolved.withLock { $0 = ["100.101.2.3"] }
        tailnet.local.withLock { $0 = ["100.90.1.1"] }
        try await Task.sleep(for: .milliseconds(700))
        #expect(tokens.reads.withLock { $0 } == 0)
        #expect(fakeHosts.urls.withLock { $0 }.isEmpty)
        #expect(tailnet.interfaceReads.withLock { $0 } == 1)
        withExtendedLifetime(connector) {}
    }

    @Test func offTheTailnetLiteralFails() async throws {
        tailnet.local.withLock { $0 = ["127.0.0.1"] }
        let (_, seen) = try await connect("ws://100.101.2.3:48765/ahp", until: isFailed)
        #expect(seen.last == .failed(.notOnTailnet))
        #expect(tailnet.resolves.withLock { $0 } == 0)
        #expect(tokens.reads.withLock { $0 } == 0)
        #expect(fakeHosts.urls.withLock { $0 }.isEmpty)
    }

    @Test(arguments: [
        ("100.101.2.3", "ws://100.101.2.3:48765/ahp?tkn=tok"),
        ("fd7a:115c:a1e0::1", "ws://[fd7a:115c:a1e0::1]:48765/ahp?tkn=tok"),
    ])
    func connectsToTheCheckedAddress(resolved: String, expected: String) async throws {
        tailnet.resolved.withLock { $0 = [resolved, "100.100.9.9"] }
        let (_, seen) = try await connect("ws://mac.tailnet.ts.net:48765/ahp") { $0 == connected }
        #expect(seen.last == connected)
        #expect(fakeHosts.urls.withLock { $0 }.map(\.absoluteString) == [expected])
        #expect(tailnet.resolves.withLock { $0 } == 1)
    }

    @Test func connectsToALiteralWithoutResolving() async throws {
        let (_, seen) = try await connect("ws://100.101.2.3:48765/ahp") { $0 == connected }
        #expect(seen.last == connected)
        #expect(fakeHosts.urls.withLock { $0 }.map(\.absoluteString) == ["ws://100.101.2.3:48765/ahp?tkn=tok"])
        #expect(tailnet.resolves.withLock { $0 } == 0)
        #expect(tailnet.interfaceReads.withLock { $0 } == 1)
    }

    @Test(arguments: [
        "wss://mac.tailnet.ts.net:48765/ahp", "wss://100.101.2.3/ahp",
        "ws://localhost:48765", "ws://127.0.0.1:48765/ahp", "ws://[::1]:48765",
    ])
    func wssAndLoopbackSkipTheCheck(url: String) async throws {
        tailnet.local.withLock { $0 = [] }
        tailnet.resolved.withLock { $0 = nil }
        let (_, seen) = try await connect(url) { $0 == connected }
        #expect(seen.last == connected)
        #expect(fakeHosts.urls.withLock { $0 }.map(\.absoluteString) == [url + "?tkn=tok"])
        #expect(tailnet.resolves.withLock { $0 } == 0)
        #expect(tailnet.interfaceReads.withLock { $0 } == 0)
    }

    @Test(arguments: [
        ("100.63.255.255", false), ("100.128.0.0", false), ("100.64.0.0", true), ("100.127.255.255", true),
        ("fd7a:115c:a1e0::1", true), ("FD7A:115C:A1E0:ab12::1", true), ("fd7a:115c:a1e1::1", false),
        ("fd7a:115c::1", false), ("::ffff:100.64.0.1", false), ("fe80::1%en0", false), ("mac.ts.net", false),
    ])
    func tailnetRanges(address: String, expected: Bool) {
        #expect(TailnetCheck.isTailnetAddress(address) == expected)
    }

    @Test func systemProvidersReportLoopback() async throws {
        #expect(LocalInterfaces.system.addresses().contains { $0 == "127.0.0.1" || $0 == "::1" })
        // A numeric host resolves without DNS.
        #expect(try await HostResolver.system.addresses(for: "100.64.0.1") == ["100.64.0.1"])
    }
}
