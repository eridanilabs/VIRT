import AgentHostProtocolClient
import Foundation

/// Connects to saved hosts through the client's `MultiHostClient`.
///
/// Before every attempt, reconnects included, it reads the host from the `HostLibrary` and
/// checks its URL with `HostURLPolicy`. Only a URL that passes gets the token, read from the
/// library at that moment, as its one `tkn` query item. A refused URL, a missing host or a
/// missing token stops the host: no transport, no retries. The token and the URL that carries
/// it never appear in a `Status`, a `Failure` or a log line.
public actor HostConnector {
    /// Opens a transport to a URL that carries the token. Never log or keep the URL.
    public typealias TransportMaker = @Sendable (URL) throws -> any AHPTransport

    /// A host's connection status.
    public enum Status: Sendable, Equatable {
        case idle
        case connecting
        case connected(protocolVersion: String)
        case failed(Failure)
    }

    /// Why a host isn't connected. It never holds the token, the URL or a client error string.
    public enum Failure: Error, Sendable, Equatable {
        case urlRefused(HostURLPolicy.Refusal)
        case hostNotFound
        case noToken
        case other

        /// A short explanation to show the user.
        public var message: String {
            switch self {
            case .urlRefused(let refusal): refusal.message
            case .hostNotFound: "The host isn't saved."
            case .noToken: "The host has no token. Edit the host to add one."
            case .other: "Couldn't connect to the host."
            }
        }
    }

    private let library: HostLibrary
    private let transportMaker: TransportMaker
    private let reconnectPolicy: ReconnectPolicy
    private let policy = HostURLPolicy()
    private let client = MultiHostClient()
    private var statuses: [UUID: Status] = [:]
    /// Each connecting host's id in `client`, new on every `connect`, so events from a
    /// removed registration never change the status of a later one.
    private var registrations: [UUID: HostId] = [:]
    private var listeners: [UUID: [UUID: AsyncStream<Status>.Continuation]] = [:]
    private var eventsTask: Task<Void, Never>?

    public init(
        library: HostLibrary,
        transportMaker: @escaping TransportMaker = { URLSessionWebSocketTransport(url: $0) }
    ) {
        self.init(library: library, transportMaker: transportMaker, reconnectPolicy: .exponential)
    }

    /// Lets tests pick a reconnect policy.
    init(library: HostLibrary, transportMaker: @escaping TransportMaker, reconnectPolicy: ReconnectPolicy) {
        self.library = library
        self.transportMaker = transportMaker
        self.reconnectPolicy = reconnectPolicy
    }

    deinit {
        eventsTask?.cancel()
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

    /// Starts connecting to the saved host, and keeps reconnecting until `disconnect`.
    /// Does nothing if the host is already connecting or connected.
    public func connect(_ hostID: UUID) async {
        guard registrations[hostID] == nil else { return }
        let id = HostId(UUID().uuidString)
        registrations[hostID] = id
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
        } catch {
            stop(hostID, id, .other)
        }
    }

    /// Drops the host's connection and stops reconnecting. Its status becomes `.idle`.
    public func disconnect(_ hostID: UUID) async {
        let id = registrations.removeValue(forKey: hostID)
        publish(.idle, for: hostID)
        if let id { try? await client.remove(id) }
    }

    /// The `transportFactory` behind every attempt: host, then policy, then token.
    private func openTransport(_ hostID: UUID, _ id: HostId) async throws -> any AHPTransport {
        guard registrations[hostID] == id else { throw Failure.other }
        do {
            guard let host = try await library.hosts().first(where: { $0.id == hostID }) else {
                throw Failure.hostNotFound
            }
            if let refusal = policy.evaluate(host.url).refusal { throw Failure.urlRefused(refusal) }
            guard let token = try await library.token(for: hostID) else { throw Failure.noToken }
            return try transportMaker(try Self.tokenURL(host.url, token: token))
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
        publish(.failed(failure), for: hostID)
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

    /// Maps a client state to a status. `lastError` and `failed(reason:)` are dropped:
    /// they can quote a transport error that holds the token URL.
    private func handle(_ event: HostEvent) async {
        guard case .stateChanged(let id, let state, _) = event,
              let hostID = registrations.first(where: { $0.value == id })?.key
        else { return }
        switch state {
        case .disconnected, .connecting, .reconnecting:
            publish(.connecting, for: hostID)
        case .connected:
            let version = await client.host(id)?.protocolVersion ?? ""
            if registrations[hostID] == id { publish(.connected(protocolVersion: version), for: hostID) }
        case .failed:
            stop(hostID, id, .other)
        }
    }

    private func publish(_ status: Status, for hostID: UUID) {
        statuses[hostID] = status
        listeners[hostID]?.values.forEach { $0.yield(status) }
    }

    private func removeListener(_ key: UUID, for hostID: UUID) {
        listeners[hostID]?[key] = nil
    }
}

extension HostConnector.Failure: LocalizedError {
    public var errorDescription: String? { message }
}
