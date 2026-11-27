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
    /// The host's current session rows, newest first, then each change. `[]` until the host
    /// first lists its sessions, and again after disconnect or a failure that stops it. While the
    /// host is reconnecting, the last rows stay.
    func sessionUpdates(for hostID: UUID) async -> AsyncStream<[SessionRow]>
    /// Asks the connected host for its sessions once, and gives them to `sessionUpdates`.
    /// On any failure the rows stay as they are.
    func refreshSessions(_ hostID: UUID) async
    /// The session's chat once seeded, then after each change. It finishes without a value if
    /// the host isn't connected or the chat can't be opened. Stop listening to unsubscribe.
    func chatUpdates(for hostID: UUID, session: String) async -> AsyncStream<SessionChat>
    /// Sends a user message to the session's default chat, or its first chat if none is marked.
    func sendMessage(_ text: String, to hostID: UUID, session: String) async throws
    func sessionProviders(for hostID: UUID) async throws -> [SessionProvider]
    func createSession(on hostID: UUID, provider: String, workingDirectory: String) async throws -> SessionRow
}

/// A safe, user-readable failure to send a chat message.
public enum ChatSendingError: Error, Sendable {
    case notConnected
    case noChat
    case requestFailed

    public var message: String {
        switch self {
        case .notConnected: "This host is no longer connected."
        case .noChat: "This session has no chat to send a message to."
        case .requestFailed: "The message couldn't be sent. Check the connection and try again."
        }
    }
}

public struct SessionProvider: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Connects to saved hosts through the client's `MultiHostClient`.
///
/// Before every attempt, reconnects included, it reads the host from the `HostLibrary` and
/// checks its URL with `HostURLPolicy`, then a plain `ws://` URL that isn't loopback with
/// `TailnetCheck`, which swaps its host for the checked address. Only a URL that passes gets
/// the token, read from the library at that moment, as its one `tkn` query item. A refused URL,
/// a host off the tailnet, a missing host or a missing token stops the host: no transport, no
/// retries. So does a refused token, a protocol version mismatch or an oversized message, which a
/// `ConnectionErrorRecorder` records. The token and the URL that carries it never appear in a
/// `Status`, a `Failure` or a log line.
public actor HostConnector: HostConnecting {
    public enum SessionCreationError: Error, Sendable {
        case notConnected
        case noProvider
        case invalidDirectory
        case requestFailed

        public var message: String {
            switch self {
            case .notConnected: "This host is no longer connected."
            case .noProvider: "This host has no available session provider."
            case .invalidDirectory: "Enter an absolute working-directory path on the host."
            case .requestFailed: "The host couldn't create the session. Check its configuration and try again."
            }
        }
    }

    /// Opens a transport to a URL that carries the token, and reports the attempt's errors to
    /// the recorder. Never log or keep the URL.
    public typealias TransportMaker = @Sendable (URL, ConnectionErrorRecorder) throws -> any AHPTransport

    /// A `URLSessionWebSocketTransport` on its own ephemeral `URLSession`, with the recorder as
    /// its delegate. The recorder ends the session when the attempt's task completes. A transport
    /// closed before any `send` or `recv` starts no task, so it ends the session itself.
    public static let webSocketTransport: TransportMaker = { url, recorder in
        let session = URLSession(configuration: .ephemeral, delegate: recorder, delegateQueue: nil)
        return SessionEndingTransport(URLSessionWebSocketTransport(url: url, session: session), session: session)
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
        case tokenReadFailed
        /// A `ws://` host whose address, or this device, isn't on a Tailscale range.
        case notOnTailnet
        /// The host answered the upgrade with HTTP 401 or 403.
        case tokenRefused
        case hostUnreachable
        case tlsFailed
        case protocolVersionMismatch
        /// App Transport Security blocked a plain connection.
        case blockedByATS
        case messageTooLarge
        case other

        /// A short explanation to show the user.
        public var message: String {
            switch self {
            case .urlRefused(let refusal): refusal.message
            case .hostNotFound: "The host isn't saved."
            case .noToken: "The host has no token. Edit the host to add one."
            case .tokenReadFailed: "VIRT couldn't read the host's token from the Keychain. Unlock your device and try again."
            case .notOnTailnet: "This address isn't on your tailnet. Is Tailscale on?"
            case .tokenRefused: "The host refused the token. Edit the host to update it."
            case .hostUnreachable: "Can't reach the host. Check that it's running and on your network."
            case .tlsFailed: "The secure connection failed. Check the host's certificate."
            case .protocolVersionMismatch: "The host uses a protocol version VIRT doesn't support."
            case .blockedByATS: "iOS blocked this plain connection. Use wss:// or a .ts.net name."
            case .messageTooLarge: "The host sent a message larger than VIRT's 16 MiB limit."
            case .other: "Couldn't connect to the host."
            }
        }
    }

    private let library: HostLibrary
    private let transportMaker: TransportMaker
    private let reconnectPolicy: ReconnectPolicy
    private let policy = HostURLPolicy()
    private let tailnet: TailnetCheck
    /// Internal, with `registrations` and `handle(_:)`, so tests can remove a host behind the
    /// connector's back.
    let client = MultiHostClient()
    private var statuses: [UUID: Status] = [:]
    /// Each connecting host's id in `client`, new on every `connect`, so events from a
    /// removed registration never change the status of a later one.
    private(set) var registrations: [UUID: HostId] = [:]
    /// Each registration's recorder, shared by all its attempts.
    private var recorders: [HostId: ConnectionErrorRecorder] = [:]
    private var listeners: [UUID: [UUID: AsyncStream<Status>.Continuation]] = [:]
    private var sessionRows: [UUID: [SessionRow]] = [:]
    private var rowListeners: [UUID: [UUID: AsyncStream<[SessionRow]>.Continuation]] = [:]
    /// The open chat stream's default-chat target and whether that chat has an active turn.
    private var chatDestinations: [UUID: [String: (registration: HostId, resource: String, hasActiveTurn: Bool)]] = [:]
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
    /// notifications. VIRT sends no `listSessions` of its own here. `[]` until the host first
    /// lists its sessions, and again after disconnect or a failure that stops it. While the host
    /// is reconnecting, the last rows stay.
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

    public func sessionProviders(for hostID: UUID) async throws -> [SessionProvider] {
        guard case .connected = status(for: hostID), let id = registrations[hostID] else {
            throw SessionCreationError.notConnected
        }
        let agents = await client.aggregatedAgents()
        guard registrations[hostID] == id, case .connected = status(for: hostID) else {
            throw SessionCreationError.notConnected
        }
        return agents.filter { $0.hostId == id }.map {
            SessionProvider(id: $0.agent.provider, name: $0.agent.displayName)
        }
    }

    public func createSession(on hostID: UUID, provider: String, workingDirectory: String) async throws -> SessionRow {
        guard workingDirectory.hasPrefix("/"), !workingDirectory.contains("\0") else {
            throw SessionCreationError.invalidDirectory
        }
        guard try await sessionProviders(for: hostID).contains(where: { $0.id == provider }) else {
            throw SessionCreationError.noProvider
        }
        guard let id = registrations[hostID], let handle = await client.client(for: id),
              case .connected = status(for: hostID) else {
            throw SessionCreationError.notConnected
        }
        let resource = "\(provider):/\(UUID().uuidString)"
        do {
            let _: AnyCodable? = try await handle.request(
                method: "createSession",
                params: CreateSessionParams(channel: resource, provider: provider,
                                            workingDirectories: [workingDirectory])
            )
        } catch {
            // Host errors can contain secrets. Only expose a fixed, actionable message.
            throw SessionCreationError.requestFailed
        }
        await refreshSessions(hostID)
        return SessionRow(resource: resource, title: "New session", state: .idle,
                          folder: workingDirectory, modifiedAt: Date().ISO8601Format())
    }

    /// Subscribes to the session, then to its `defaultChat`, or else its first chat, and yields
    /// the chat after the seed and after each of its actions, through an `AHPStateMirror`. A
    /// session with no chat yields an empty chat. A host that isn't connected, or a subscribe
    /// that fails, finishes the stream without a value. A seed or an action that would trap the
    /// client's reducer (see `ChatReducerGuard`) finishes it too. When the stream ends, VIRT
    /// unsubscribes from the chat, then the session.
    public func chatUpdates(for hostID: UUID, session: String) -> AsyncStream<SessionChat> {
        let (stream, continuation) = AsyncStream<SessionChat>.makeStream()
        guard case .connected = status(for: hostID), let id = registrations[hostID] else {
            continuation.finish()
            return stream
        }
        let task = Task { [weak self] in
            await self?.followChat(session, hostID: hostID, on: id, into: continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func sendMessage(_ text: String, to hostID: UUID, session: String) async throws {
        guard case .connected = status(for: hostID), let id = registrations[hostID],
              let handle = await client.client(for: id)
        else { throw ChatSendingError.notConnected }
        guard let destination = chatDestinations[hostID]?[session], destination.registration == id else {
            throw ChatSendingError.noChat
        }

        do {
            guard registrations[hostID] == id, case .connected = status(for: hostID) else {
                throw ChatSendingError.notConnected
            }
            let message = Message(text: text, origin: MessageOrigin(kind: .user))
            let action: StateAction
            if destination.hasActiveTurn {
                action = .chatPendingMessageSet(ChatPendingMessageSetAction(
                    type: .chatPendingMessageSet, kind: .queued, id: UUID().uuidString, message: message
                ))
            } else {
                action = .chatTurnStarted(ChatTurnStartedAction(
                    type: .chatTurnStarted, turnId: UUID().uuidString,
                    startedAt: Date().ISO8601Format(), message: message
                ))
            }
            try await handle.dispatch(action, channel: destination.resource)
            if registrations[hostID] == id,
               chatDestinations[hostID]?[session]?.resource == destination.resource {
                chatDestinations[hostID]?[session] = (id, destination.resource, true)
            }
        } catch let error as ChatSendingError {
            throw error
        } catch {
            // Host errors can contain private details. Never expose them to the screen.
            throw ChatSendingError.requestFailed
        }
    }

    private func followChat(_ session: String, hostID: UUID, on id: HostId,
                            into continuation: AsyncStream<SessionChat>.Continuation) async {
        var subscribed = [session]
        var chatResource: String?
        defer {
            if let chatResource,
               chatDestinations[hostID]?[session]?.registration == id,
               chatDestinations[hostID]?[session]?.resource == chatResource {
                chatDestinations[hostID]?[session] = nil
            }
            // Its own task, so the caller's cancellation doesn't stop it. Unsubscribing a channel
            // whose subscribe failed also drops it from the client's replay set.
            let channels = subscribed
            Task { [client] in for uri in channels.reversed() { try? await client.unsubscribe(host: id, uri: uri) } }
        }
        guard let result = try? await client.subscribe(host: id, uri: session),
              case .session(let state)? = result.snapshot?.state
        else { return }
        guard let chat = state.defaultChat ?? state.chats.first?.resource else {
            continuation.yield(SessionChat())
            return
        }
        // The listener goes first, so no action between the subscribe reply and the loop is lost.
        guard let events = await client.events(host: id, uri: chat) else { return }
        subscribed.append(chat)
        guard let snapshot = try? await client.subscribe(host: id, uri: chat).snapshot else { return }
        let mirror = AHPStateMirror()
        await mirror.applySnapshot(snapshot)
        guard var state = await mirror.chats[chat], ChatReducerGuard.canSeed(state) else { return }
        chatResource = chat
        chatDestinations[hostID, default: [:]][session] = (id, chat, state.activeTurn != nil)
        continuation.yield(SessionChat(state: state))
        for await event in events {
            // Actions up to `fromSeq` are already in the snapshot.
            guard case .action(let envelope) = event, envelope.serverSeq > snapshot.fromSeq else { continue }
            // An action that would trap the reducer ends the chat: skipping it would leave the
            // mirror out of step with the host.
            guard ChatReducerGuard.canApply(envelope.action, to: state) else { return }
            await mirror.apply(envelope)
            guard let next = await mirror.chats[chat] else { return }
            state = next
            chatDestinations[hostID, default: [:]][session] = (id, chat, state.activeTurn != nil)
            continuation.yield(SessionChat(state: state))
        }
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
        chatDestinations[hostID] = nil
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
            let token: String?
            do {
                token = try await library.token(for: hostID)
            } catch let error as TokenStoreError {
                recorder.record(.tokenReadFailed)
                throw error
            }
            guard let token else { throw Failure.noToken }
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
        chatDestinations[hostID] = nil
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
    /// A `.connected` host that the client no longer has publishes nothing.
    func handle(_ event: HostEvent) async {
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
            guard let version = await client.host(id)?.protocolVersion, registrations[hostID] == id else { return }
            publish(.connected(protocolVersion: version), for: hostID)
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
