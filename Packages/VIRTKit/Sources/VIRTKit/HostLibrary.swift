import Foundation

/// The saved hosts and their tokens, kept in step: a host is saved only after its token,
/// and its token is deleted before the host.
public actor HostLibrary {
    private let hostStore: HostStore
    private let tokenStore: any TokenStore
    private let policy: HostURLPolicy

    public init(hostStore: HostStore, tokenStore: any TokenStore, policy: HostURLPolicy = HostURLPolicy()) {
        self.hostStore = hostStore
        self.tokenStore = tokenStore
        self.policy = policy
    }

    /// The saved hosts.
    public func hosts() throws -> [Host] {
        try hostStore.load()
    }

    /// Saves `token`, then adds `host` or replaces the saved host with its id.
    ///
    /// Throws a `HostURLPolicy.Refusal`, saving nothing, if the policy refuses the URL.
    /// If the token write fails, the host isn't saved.
    /// - Returns: The policy's warning for the URL, if any.
    @discardableResult
    public func save(_ host: Host, token: String) async throws -> HostURLPolicy.Warning? {
        let outcome = policy.evaluate(host.url)
        if let refusal = outcome.refusal { throw refusal }
        try await tokenStore.setToken(token, for: host.id)
        var hosts = try hostStore.load()
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        try hostStore.save(hosts)
        return outcome.warning
    }

    /// The token for the host with `hostID`, or `nil` if it has none.
    public func token(for hostID: UUID) async throws -> String? {
        try await tokenStore.token(for: hostID)
    }

    /// Deletes the host's token, then the host. If the token delete fails, the host stays.
    public func delete(_ hostID: UUID) async throws {
        try await tokenStore.deleteToken(for: hostID)
        var hosts = try hostStore.load()
        hosts.removeAll { $0.id == hostID }
        try hostStore.save(hosts)
    }
}
