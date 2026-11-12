import AgentHostProtocol
import AgentHostProtocolClient
import Foundation

/// Connects and disconnects saved hosts, and reports each host's status and sessions.
/// `HostConnector` is the real one; tests of the app's view models use a fake.
public protocol HostConnecting: Sendable {
    /// Starts connecting to the saved host. Does nothing if it's already connecting or connected.
    func connect(_ hostID: UUID) async
    /// Drops the host's connection and stops reconnecting. Its status becomes `.idle`.
    func disconnect(_ hostID: UUID) async
    /// The host's current status, then each change.
    func statusUpdates(for hostID: UUID) async -> AsyncStream<HostConnector.Status>
    /// The host's current session rows, newest first, then each change. `[]` while the host
    /// isn't connected, and again after `disconnect` or a failure that stops it.
    func sessionUpdates(for hostID: UUID) async -> AsyncStream<[SessionRow]>
    /// Asks the connected host for its sessions once, and gives them to `sessionUpdates`.
    /// On any failure the rows stay as they are.
    func refreshSessions(_ hostID: UUID) async
}

/// Connects to saved hosts through the client's `MultiHostClient`.
///
/// Before every attempt, reconnects included, it reads the host from the `HostLibrary` and
/// checks its URL with `HostURLPolicy`, then a plain `ws://` URL that isn't loopback with
/// `TailnetCheck`, which swaps its host for the checked address. Only a URL that passes gets
/// the token, read from the library at that moment, as its one `tkn` query item. A refused URL,
/// a host off the tailnet, a missing host or a missing token stops the host: no transport, no
/// retries. So does a refused token or a protocol version mismatch, which a
/// `ConnectionErrorRecorder` records. The token and the URL that carries
/// it never appear in a `Status`, a `Failure` or a log line.
public actor HostConnector: HostConnecting {
    /// Opens a transport to a URL that carries the token, and reports the attempt's errors to
    /// the recorder. Never log or keep the URL.
    public typealias TransportMaker = @Sendable (URL, ConnectionErrorRecorder) throws -> any AHPTransport

    /// A `URLSessionWebSocketTransport` on its own ephemeral `URLSession`, with the recorder as
    /// its delegate. The recorder ends the session when the attempt's task completes.
    public static let webSocketTransport: TransportMaker = { url, recorder in
        let session = URLSession(configuration: .ephemeral, delegate: recorder, delegateQueue: nil)
        return URLSessionWebSocketTransport(url: url, session: session)
    }

    /// A host's connection status.
    public enum Status: Sendable, Equatable {
        case idle
        case connecting
        case connected(protocolVersion: String)
        /// After a drop, until the host connects again. `reason` is why the last attempt failed.
        case reconnecting(attempt: Int, reason: Failure?)
        case failed(Failure)
    }

    /// Why a host isn't connected. It never holds the token, the URL or a client error string.
    public enum Failure: Error, Sendable, Equatable {
        case urlRefused(HostURLPolicy.Refusal)
        case hostNotFound
        case noToken
        /// A `ws://` host whose address, or this device, isn't on a Tailscale range.
        case notOnTailnet
        /// The host answered the upgrade with HTTP 401 or 403.
        case tokenRefused
        case hostUnreachable
        case tlsFailed
        case protocolVersionMismatch
        /// App Transport Security blocked a plain connection.
        case blockedByATS
        case other

        /// A short explanation to show the user.
        public var message: String {
            switch self {
            case .urlRefused(let refusal): refusal.message
            case .hostNotFound: "The host isn't saved."
            case .noToken: "The host has no token. Edit the host to add one."
            case .notOnTailnet: "This address isn't on your tailnet. Is Tailscale on?"
            case .tokenRefused: "The host refused the token. Edit the host to update it."
            case .hostUnreachable: "Can't reach the host. Check that it's running and on your network."
            case .tlsFailed: "The secure connection failed. Check the host's certificate."
            case .protocolVersionMismatch: "The host uses a protocol version VIRT doesn't support."
            case .blockedByATS: "iOS blocked this plain connection. Use wss:// or a .ts.net name."
            case .other: "Couldn't connect to the host."
            }
        }
    }

    private let library: HostLibrary
    private let transportMaker: TransportMaker
    private let reconnectPolicy: ReconnectPolicy
    private let policy = HostURLPolicy()
    private let tailnet: TailnetCheck
    private let client = MultiHostClient()
    private var statuses: [UUID: Status] = [:]
    /// Each connecting host's id in `client`, new on every `connect`, so events from a
    /// removed registration never change the status of a later one.
    private var registrations: [UUID: HostId] = [:]
    /// Each registration's recorder, shared by all its attempts.
    private var recorders: [HostId: ConnectionErrorRecorder] = [:]
    private var listeners: [UUID: [UUID: AsyncStream<Status>.Continuation]] = [:]
    private var sessionRows: [UUID: [SessionRow]] = [:]
    private var rowListeners: [UUID: [UUID: AsyncStream<[SessionRow]>.Continuation]] = [:]
    /// Each registration's watcher of the client's session summaries.
    private var summaryTasks: [HostId: Task<Void, Never>] = [:]
    private var eventsTask: Task<Void, Never>?

    /// `resolver` and `interfaces` feed the tailnet check that a plain `ws://` host must pass.
    public init(
        library: HostLibrary,
        transportMaker: @escaping TransportMaker = webSocketTransport,
        resolver: HostResolver = .system,
        interfaces: LocalInterfaces = .system
    ) {
        self.init(library: library, transportMaker: transportMaker, reconnectPolicy: .exponential,
                  resolver: resolver, interfaces: interfaces)
    }

    /// Lets tests pick a reconnect policy.
    init(library: HostLibrary, transportMaker: @escaping TransportMaker, reconnectPolicy: ReconnectPolicy,
         resolver: HostResolver = .system, interfaces: LocalInterfaces = .system) {
        self.library = library
        self.transportMaker = transportMaker
        self.reconnectPolicy = reconnectPolicy
        self.tailnet = TailnetCheck(resolver: resolver, interfaces: interfaces)
    }

    deinit {
        eventsTask?.cancel()
        summaryTasks.values.forEach { $0.cancel() }
        Task { [client] in await client.shutdown() }
    }

    /// The host's current status: `.idle` if it isn't connecting.
    public func status(for hostID: UUID) -> Status {
        statuses[hostID] ?? .idle
    }

    /// The host's current status, then each change.
    public func statusUpdates(for hostID: UUID) -> AsyncStream<Status> {
        let (stream, continuation) = AsyncStream<Status>.makeStream()
        let key = UUID()
        listeners[hostID, default: [:]][key] = continuation
        continuation.yield(status(for: hostID))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(key, for: hostID) }
        }
        return stream
    }

    /// The host's current session rows, then the rows each time the client's session
    /// summaries change: the `listSessions` on connect and the host's `root/session*`
    /// notifications. VIRT sends no `listSessions` of its own here.
    public func sessionUpdates(for hostID: UUID) -> AsyncStream<[SessionRow]> {
        let (stream, continuation) = AsyncStream<[SessionRow]>.makeStream()
        let key = UUID()
        rowListeners[hostID, default: [:]][key] = continuation
        continuation.yield(sessionRows[hostID] ?? [])
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(key, for: hostID) }
        }
        return stream
    }

    /// Sends one `listSessions` to the connected host and publishes its items. An error
    /// reply, a reconnect since the handle was taken or a host that isn't connected changes
    /// nothing. The client's cache keeps its own list, so its next change replaces these rows.
    public func refreshSessions(_ hostID: UUID) async {
        guard let id = registrations[hostID], let handle = await client.client(for: id),
              let result: ListSessionsResult = try? await handle.request(
                  method: "listSessions", params: ListSessionsParams(channel: VIRTKit.rootChannel)),
              registrations[hostID] == id
        else { return }
        publishRows(result.items, for: hostID)
    }

    /// Starts connecting to the saved host, and keeps reconnecting until `disconnect`.
    /// Does nothing if the host is already connecting or connected.
    public func connect(_ hostID: UUID) async {
        guard registrations[hostID] == nil else { return }
        let id = HostId(UUID().uuidString)
        registrations[hostID] = id
        recorders[id] = ConnectionErrorRecorder { [weak self] failure in
            Task { await self?.recorded(failure, hostID, id) }
        }
        publish(.connecting, for: hostID)
        await watchEvents()
        let config = HostConfig(id: id, label: hostID.uuidString) { [weak self] _ in
            guard let self else { throw Failure.other }
            return try await self.openTransport(hostID, id)
        }
        .withReconnectPolicy(reconnectPolicy)
        guard registrations[hostID] == id else { return }
        do {
            try await client.add(config)
            if registrations[hostID] != id { try? await client.remove(id) }
            await watchSummaries(hostID, id)
        } catch {
            stop(hostID, id, .other)
        }
    }

    /// Drops the host's connection and stops reconnecting. Its status becomes `.idle`.
    public func disconnect(_ hostID: UUID) async {
        let id = registrations.removeValue(forKey: hostID)
        publish(.idle, for: hostID)
        publishRows([], for: hostID)
        if let id {
            recorders[id] = nil
            summaryTasks.removeValue(forKey: id)?.cancel()
            try? await client.remove(id)
        }
    }

    /// The `transportFactory` behind every attempt: host, then policy, then the tailnet check
    /// for a `ws://` host, then token.
    private func openTransport(_ hostID: UUID, _ id: HostId) async throws -> any AHPTransport {
        guard registrations[hostID] == id, let recorder = recorders[id] else { throw Failure.other }
        do {
            guard let host = try await library.hosts().first(where: { $0.id == hostID }) else {
                throw Failure.hostNotFound
            }
            if let refusal = policy.evaluate(host.url).refusal { throw Failure.urlRefused(refusal) }
            guard let url = await tailnet.connectURL(for: host.url) else { throw Failure.notOnTailnet }
            guard let token = try await library.token(for: hostID) else { throw Failure.noToken }
            let transport = try transportMaker(try Self.tokenURL(url, token: token), recorder)
            return RecordingTransport(transport, recorder: recorder)
        } catch let failure as Failure {
            stop(hostID, id, failure)
            throw failure
        }
    }

    /// `url` with `tkn=<token>` as its only query item. Only RFC 3986 unreserved characters
    /// stay as they are, so `+`, `&`, `=` and `%` reach the host unchanged.
    static func tokenURL(_ url: URL, token: String) throws -> URL {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = token.addingPercentEncoding(withAllowedCharacters: unreserved)
        else { throw Failure.other }
        components.percentEncodedQuery = "tkn=" + value
        guard let tokenURL = components.url else { throw Failure.other }
        return tokenURL
    }

    /// Fails the registration and removes it from `client`, which would otherwise retry.
    /// Removal waits for the supervisor, which may be the caller, so it runs on its own.
    private func stop(_ hostID: UUID, _ id: HostId, _ failure: Failure) {
        guard registrations[hostID] == id else { return }
        registrations[hostID] = nil
        recorders[id] = nil
        summaryTasks.removeValue(forKey: id)?.cancel()
        publish(.failed(failure), for: hostID)
        publishRows([], for: hostID)
        Task { [client] in try? await client.remove(id) }
    }

    private func watchEvents() async {
        guard eventsTask == nil else { return }
        let events = await client.hostEvents()
        guard eventsTask == nil else { return }
        eventsTask = Task { [weak self] in
            for await event in events { await self?.handle(event) }
        }
    }

    /// Publishes the registration's rows each time the client's session summaries change.
    private func watchSummaries(_ hostID: UUID, _ id: HostId) async {
        guard registrations[hostID] == id, let summaries = await client.sessionSummaries(host: id),
              registrations[hostID] == id
        else { return }
        summaryTasks[id] = Task { [weak self] in
            for await items in summaries { await self?.received(items, hostID, id) }
        }
    }

    private func received(_ summaries: [SessionSummary], _ hostID: UUID, _ id: HostId) {
        guard registrations[hostID] == id else { return }
        publishRows(summaries, for: hostID)
    }

    /// Maps a client state to a status, with the recorder's failure as the reason. `lastError`
    /// and `failed(reason:)` are dropped: they can quote a transport error that holds the token URL.
    private func handle(_ event: HostEvent) async {
        guard case .stateChanged(let id, let state, _) = event,
              let hostID = registrations.first(where: { $0.value == id })?.key
        else { return }
        let recorded = recorders[id]?.failure
        switch state {
        case .disconnected, .connecting:
            publish(.connecting, for: hostID)
        case .reconnecting(let attempt):
            if let recorded, recorded.stopsRetrying { return stop(hostID, id, recorded) }
            publish(.reconnecting(attempt: attempt, reason: recorded), for: hostID)
        case .connected:
            recorders[id]?.reset()
            let version = await client.host(id)?.protocolVersion ?? ""
            if registrations[hostID] == id { publish(.connected(protocolVersion: version), for: hostID) }
        case .failed:
            stop(hostID, id, recorded ?? .other)
        }
    }

    /// A failure recorded after the client's state event: it stops the host, or becomes the
    /// reason of the current reconnecting status.
    private func recorded(_ failure: Failure, _ hostID: UUID, _ id: HostId) {
        guard registrations[hostID] == id else { return }
        if failure.stopsRetrying {
            stop(hostID, id, failure)
        } else if case .reconnecting(let attempt, _) = statuses[hostID] {
            publish(.reconnecting(attempt: attempt, reason: failure), for: hostID)
        }
    }

    private func publish(_ status: Status, for hostID: UUID) {
        statuses[hostID] = status
        listeners[hostID]?.values.forEach { $0.yield(status) }
    }

    private func publishRows(_ summaries: [SessionSummary], for hostID: UUID) {
        let rows = SessionRow.sorted(summaries.map(SessionRow.init))
        sessionRows[hostID] = rows
        rowListeners[hostID]?.values.forEach { $0.yield(rows) }
    }

    private func removeListener(_ key: UUID, for hostID: UUID) {
        listeners[hostID]?[key] = nil
        rowListeners[hostID]?[key] = nil
    }
}

extension HostConnector.Failure: LocalizedError {
    public var errorDescription: String? { message }
}
