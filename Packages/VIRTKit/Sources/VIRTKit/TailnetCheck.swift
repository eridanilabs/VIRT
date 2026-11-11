import Darwin
import Foundation

/// Returns the numeric addresses a host name resolves to, in the order to try them.
public struct HostResolver: Sendable {
    private let resolve: @Sendable (String) async throws -> [String]

    public init(_ resolve: @escaping @Sendable (String) async throws -> [String]) {
        self.resolve = resolve
    }

    public func addresses(for host: String) async throws -> [String] {
        try await resolve(host)
    }

    /// Resolves with `getaddrinfo`, on a dispatch queue so the call never blocks an actor.
    public static let system = HostResolver { host in
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try getaddrinfoAddresses(host) })
            }
        }
    }

    struct ResolveError: Error {}

    private static func getaddrinfoAddresses(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0 else { throw ResolveError() }
        defer { freeaddrinfo(list) }
        var addresses: [String] = []
        var entry = list
        while let info = entry?.pointee {
            if let address = numericHost(info.ai_addr, info.ai_addrlen), !addresses.contains(address) {
                addresses.append(address)
            }
            entry = info.ai_next
        }
        return addresses
    }
}

/// Returns the addresses of this device's network interfaces that are up.
public struct LocalInterfaces: Sendable {
    private let list: @Sendable () -> [String]

    public init(_ list: @escaping @Sendable () -> [String]) {
        self.list = list
    }

    public func addresses() -> [String] {
        list()
    }

    /// Lists the IPv4 and IPv6 addresses `getifaddrs` reports.
    public static let system = LocalInterfaces {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var addresses: [String] = []
        var entry = list
        while let interface = entry?.pointee {
            if interface.ifa_flags & UInt32(IFF_UP) != 0, let address = interface.ifa_addr,
               [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)),
               let numeric = numericHost(address, socklen_t(address.pointee.sa_len)) {
                addresses.append(numeric)
            }
            entry = interface.ifa_next
        }
        return addresses
    }
}

/// `address` as a numeric host string, such as `100.101.2.3` or `fd7a:115c:a1e0::1`.
private func numericHost(_ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> String? {
    guard let address else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
        return nil
    }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Checks that a plain `ws://` host really is on the tailnet before it gets the token.
///
/// `HostURLPolicy` accepts `ws://` to a `.ts.net` name or a `100.64.0.0/10` address, but with
/// Tailscale off a name can resolve elsewhere and the address can reach another network in
/// plain text. So the check needs the host's address, the literal or every resolved one, in a
/// Tailscale range, and this device to have an address in one too.
struct TailnetCheck: Sendable {
    let resolver: HostResolver
    let interfaces: LocalInterfaces

    /// The URL to connect to, or `nil` if `url` isn't on the tailnet. A `wss://` or loopback
    /// URL comes back unchanged. Any other `ws://` URL comes back with the checked address as
    /// its host, so the connection goes to the address that was checked.
    func connectURL(for url: URL) async -> URL? {
        guard url.scheme?.lowercased() == "ws" else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawHost = components.percentEncodedHost
        else { return nil }
        let host = HostURLPolicy.normalizedHost(rawHost)
        if HostURLPolicy.loopbackHosts.contains(host) { return url }

        guard interfaces.addresses().contains(where: Self.isTailnetAddress) else { return nil }
        let addresses: [String]
        if HostURLPolicy.ipv4Octets(host) != nil {
            addresses = [host]
        } else {
            guard let resolved = try? await resolver.addresses(for: host) else { return nil }
            addresses = resolved
        }
        guard let address = addresses.first, addresses.allSatisfy(Self.isTailnetAddress) else { return nil }
        components.percentEncodedHost = address.contains(":") ? "[\(address)]" : address
        return components.url
    }

    /// A numeric address in Tailscale's IPv4 range `100.64.0.0/10` or IPv6 range `fd7a:115c:a1e0::/48`.
    static func isTailnetAddress(_ address: String) -> Bool {
        if HostURLPolicy.isCarrierGradeNAT(address) { return true }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, address, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: ipv6) { $0.prefix(6).elementsEqual([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]) }
    }
}
