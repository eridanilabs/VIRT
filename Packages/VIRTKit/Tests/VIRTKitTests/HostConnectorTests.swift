import AgentHostProtocol
import AgentHostProtocolClient
import Foundation
import Synchronization
import Testing
@testable import VIRTKit
// Foundation on macOS has its own `Host`; this scoped import picks VIRTKit's.
import struct VIRTKit.Host

/// Plays the host on the server side of each `InMemoryTransport` pair it makes, and records
/// the URLs it was given and the requests it got. It can refuse the token with an HTTP status,
/// recorded as `URLSession` would, or answer `initialize` with an error code.
final class FakeHosts: Sendable {
    struct Request: Equatable, Sendable {
        var method: String
        var channel: String?
        var subscriptions: [String]?
    }

    static let version = "0.2.0"
    let urls = Mutex<[URL]>([])
    let requests = Mutex<[Request]>([])
    let servers = Mutex<[InMemoryTransport]>([])
    let upgradeStatus = Mutex<Int?>(nil)
    let initializeError = Mutex<Int?>(nil)

    var maker: HostConnector.TransportMaker {
        { url, recorder in
            self.urls.withLock { $0.append(url) }
            if let status = self.upgradeStatus.withLock({ $0 }) {
                let error = URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url])
                recorder.record(error: error, httpStatus: status)
                throw error
            }
            let (client, server) = InMemoryTransport.pair()
            self.servers.withLock { $0.append(server) }
            Task { await self.serve(server) }
            return client
        }
    }

    private func serve(_ transport: InMemoryTransport) async {
        while case .text(let text)? = try? await transport.recv() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let id = object["id"], let method = object["method"] as? String
            else { continue }
            let params = object["params"] as? [String: Any]
            let request = Request(method: method, channel: params?["channel"] as? String,
                                  subscriptions: params?["initialSubscriptions"] as? [String])
            requests.withLock { $0.append(request) }
            let result: [String: Any] = method == "initialize"
                ? ["protocolVersion": Self.version, "serverSeq": 0, "snapshots": [] as [Any]]
                : ["items": [] as [Any]]
            var response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
            if method == "initialize", let code = initializeError.withLock({ $0 }) {
                response = ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": "unsupported"]]
            }
            let reply = try! JSONSerialization.data(withJSONObject: response)
            try? await transport.send(.text(String(decoding: reply, as: UTF8.self)))
        }
    }
}

private typealias Status = HostConnector.Status

/// The statuses that `updates` yields, up to and including the first one that `done` accepts.
func next(_ updates: inout AsyncStream<HostConnector.Status>.Iterator,
          until done: (HostConnector.Status) -> Bool) async -> [HostConnector.Status] {
    var seen: [HostConnector.Status] = []
    while let status = await updates.next() {
        seen.append(status)
        if done(status) { break }
    }
    return seen
}

func isFailed(_ status: HostConnector.Status) -> Bool {
    if case .failed = status { return true }
    return false
}

@Suite(.timeLimit(.minutes(1)))
struct HostConnectorTests {
    private let temporary = TemporaryDefaults()
    private let tokens = FakeTokenStore()
    private let fakeHosts = FakeHosts()
    private let tailnet = FakeTailnet()
    private let token = "s3ntinel-a+b&c=d%e"
    private let connected = Status.connected(protocolVersion: FakeHosts.version)

    private func connector(policy: ReconnectPolicy = .exponential,
                           maker: HostConnector.TransportMaker? = nil) -> HostConnector {
        let library = HostLibrary(hostStore: HostStore(defaults: temporary.defaults), tokenStore: tokens)
        return HostConnector(library: library, transportMaker: maker ?? fakeHosts.maker, reconnectPolicy: policy,
                             resolver: tailnet.resolver, interfaces: tailnet.interfaces)
    }

    /// Saves a host with `HostStore`, which, unlike `HostLibrary`, doesn't check the policy.
    private func saved(_ url: String = "wss://mac.tailnet.ts.net:48765/ahp", token: String? = nil) async throws -> Host {
        let host = Host(name: "Mac", url: URL(string: url)!)
        try HostStore(defaults: temporary.defaults).save([host])
        if let token { try await tokens.setToken(token, for: host.id) }
        return host
    }

    /// No status, failure message, description or mirror holds the token or a token URL.
    private func expectNoSecret(_ statuses: [Status], _ connector: HostConnector) {
        for status in statuses {
            var dumped = ""
            dump(status, to: &dumped)
            var texts = [String(describing: status), String(reflecting: status), dumped,
                         String(describing: Mirror(reflecting: status).children.map(\.value))]
            if case .failed(let failure) = status { texts += [failure.message, failure.localizedDescription] }
            texts += [String(describing: connector), String(reflecting: connector)]
            for text in texts {
                #expect(!text.contains("s3ntinel") && !text.contains("tkn"))
            }
        }
    }

    @Test(arguments: ["wss://mac.tailnet.ts.net:48765/ahp", "ws://100.100.1.2:48765"])
    func connectsWithTheTokenInTkn(url: String) async throws {
        let host = try await saved(url, token: token)
        let connector = connector()
        var updates = await connector.statusUpdates(for: host.id).makeAsyncIterator()
        await connector.connect(host.id)
        let seen = await next(&updates) { $0 == connected }

        #expect(seen.prefix(2) == [.idle, .connecting])
        #expect(seen.last == connected)
        let tokenURL = try #require(fakeHosts.urls.withLock { $0.first })
        #expect(tokenURL.absoluteString == url + "?tkn=s3ntinel-a%2Bb%26c%3Dd%25e")
        let query = URLComponents(url: tokenURL, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query == [URLQueryItem(name: "tkn", value: token)])
        let initialize = FakeHosts.Request(method: "initialize", channel: "ahp-root://", subscriptions: ["ahp-root://"])
        #expect(fakeHosts.requests.withLock { $0.first } == initialize)
        expectNoSecret(seen, connector)

        await connector.disconnect(host.id)
        #expect(await connector.status(for: host.id) == .idle)
    }

    @Test func reconnectReadsTheTokenAgain() async throws {
        let host = try await saved(token: token)
        let connector = connector()
        var updates = await connector.statusUpdates(for: host.id).makeAsyncIterator()
        await connector.connect(host.id)
        _ = await next(&updates) { $0 == connected }

        try await tokens.setToken("new+token", for: host.id)
        try await fakeHosts.servers.withLock { $0[0] }.close()
        let seen = await next(&updates) { $0 == connected }

        #expect(seen == [.reconnecting(attempt: 1, reason: nil), connected])
        let urls = fakeHosts.urls.withLock { $0 }
        #expect(urls.count == 2)
        #expect(urls.last?.query == "tkn=new%2Btoken")
        #expect(tokens.reads.withLock { $0 } == 2)
        await connector.disconnect(host.id)
    }

    @Test func reconnectChecksTheTailnetAgain() async throws {
        let host = try await saved("ws://mac.tailnet.ts.net:48765/ahp", token: token)
        let connector = connector()
        var updates = await connector.statusUpdates(for: host.id).makeAsyncIterator()
        await connector.connect(host.id)
        _ = await next(&updates) { $0 == connected }
        #expect(tailnet.interfaceReads.withLock { $0 } == 1)

        tailnet.local.withLock { $0 = ["127.0.0.1", "192.168.1.20"] }
        try await fakeHosts.servers.withLock { $0[0] }.close()
        let seen = await next(&updates, until: isFailed)

        #expect(seen.last == .failed(.notOnTailnet))
        try await Task.sleep(for: .milliseconds(700))
        #expect(tailnet.interfaceReads.withLock { $0 } == 2)
        #expect(fakeHosts.urls.withLock { $0 }.count == 1)
        #expect(tokens.reads.withLock { $0 } == 1)
        #expect(await connector.status(for: host.id) == .failed(.notOnTailnet))
    }

    @Test func connectsThroughHostConnecting() async throws {
        let host = try await saved(token: token)
        let connecting: any HostConnecting = connector()
        var updates = await connecting.statusUpdates(for: host.id).makeAsyncIterator()
        await connecting.connect(host.id)
        #expect(await next(&updates) { $0 == connected }.last == connected)

        await connecting.disconnect(host.id)
        #expect(await updates.next() == .idle)
    }

    @Test func defaultInitStillWorks() async throws {
        let library = HostLibrary(hostStore: HostStore(defaults: temporary.defaults), tokenStore: tokens)
        let connector = HostConnector(library: library)
        #expect(await connector.status(for: UUID()) == .idle)
    }

    @Test(arguments: [
        ("http://mac.tailnet.ts.net", HostURLPolicy.Refusal.unsupportedScheme),
        ("ws://example.com", .insecureHostNotAllowed),
    ])
    func refusedURLReadsNoTokenAndStops(url: String, refusal: HostURLPolicy.Refusal) async throws {
        let host = try await saved(url, token: token)
        let connector = connector()
        var updates = await connector.statusUpdates(for: host.id).makeAsyncIterator()
        await connector.connect(host.id)
        let seen = await next(&updates, until: isFailed)

        #expect(seen.last == .failed(.urlRefused(refusal)))
        #expect(HostConnector.Failure.urlRefused(refusal).message == refusal.message)
        // A fixed URL would connect, so no attempt happens after the refusal.
        try HostStore(defaults: temporary.defaults).save([Host(id: host.id, name: "Mac", url: URL(string: "wss://mac.tailnet.ts.net")!)])
        try await Task.sleep(for: .milliseconds(700))
        #expect(tokens.reads.withLock { $0 } == 0)
        #expect(fakeHosts.urls.withLock { $0 }.isEmpty)
        #expect(await connector.status(for: host.id) == .failed(.urlRefused(refusal)))
        expectNoSecret(seen, connector)
    }

    @Test func missingHostOrTokenFailsWithoutATransport() async throws {
        let host = try await saved()
        let connector = connector()
        for (hostID, failure) in [(UUID(), HostConnector.Failure.hostNotFound), (host.id, .noToken)] {
            var updates = await connector.statusUpdates(for: hostID).makeAsyncIterator()
            await connector.connect(hostID)
            #expect(await next(&updates, until: isFailed).last == .failed(failure))
        }
        try await tokens.setToken(token, for: host.id)
        try await Task.sleep(for: .milliseconds(700))
        #expect(tokens.reads.withLock { $0 } == 1)
        #expect(fakeHosts.urls.withLock { $0 }.isEmpty)
    }

    /// When the client gives up, the status is the last recorded failure, or `.other`.
    @Test(arguments: [(URLError.Code.badServerResponse, false, HostConnector.Failure.other),
                      (.cannotFindHost, true, .hostUnreachable)])
    func givingUpFailsWithTheLastRecordedFailure(code: URLError.Code, records: Bool,
                                                 failure: HostConnector.Failure) async throws {
        let host = try await saved(token: token)
        let connector = connector(policy: .disabled) { url, recorder in
            let error = URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: url])
            if records { recorder.record(error: error, httpStatus: nil) }
            throw error
        }
        var updates = await connector.statusUpdates(for: host.id).makeAsyncIterator()
        await connector.connect(host.id)
        let seen = await next(&updates, until: isFailed)

        #expect(seen.last == .failed(failure))
        expectNoSecret(seen, connector)
    }

    @Test func retriedFailureShowsItsReason() async throws {
        let host = try await saved(token: token)
        let connector = connector { url, recorder in
            let error = URLError(.cannotFindHost, userInfo: [NSURLErrorFailingURLErrorKey: url])
            recorder.record(error: error, httpStatus: nil)
            throw error
        }
        var updates = await connector.statusUpdates(for: host.id).makeAsyncIterator()
        await connector.connect(host.id)
        let seen = await next(&updates) { $0 == .reconnecting(attempt: 2, reason: .hostUnreachable) }

        #expect(seen.contains(.reconnecting(attempt: 1, reason: .hostUnreachable)))
        expectNoSecret(seen, connector)
        await connector.disconnect(host.id)
    }

    @Test(arguments: [HostConnector.Failure.tokenRefused, .protocolVersionMismatch])
    func refusedTokenOrVersionStops(failure: HostConnector.Failure) async throws {
        let host = try await saved(token: token)
        if failure == .tokenRefused {
            fakeHosts.upgradeStatus.withLock { $0 = 401 }
        } else {
            fakeHosts.initializeError.withLock { $0 = AhpErrorCodes.unsupportedProtocolVersion }
        }
        let connector = connector()
        var updates = await connector.statusUpdates(for: host.id).makeAsyncIterator()
        await connector.connect(host.id)
        let seen = await next(&updates, until: isFailed)

        #expect(seen.last == .failed(failure))
        try await Task.sleep(for: .milliseconds(700))
        #expect(fakeHosts.urls.withLock { $0 }.count == 1)
        #expect(await connector.status(for: host.id) == .failed(failure))
        expectNoSecret(seen, connector)
    }
}
