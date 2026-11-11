import Foundation

/// Decides which host URLs may carry a connection token.
///
/// `wss://` is accepted to any host. Plain `ws://` is accepted only to loopback
/// (`localhost`, `127.0.0.1`, `::1`), a tailnet name (`<label>.ts.net`), whose traffic
/// WireGuard encrypts, or a Tailscale address in `100.64.0.0/10`, with a warning.
public struct HostURLPolicy: Sendable {
    public init() {}

    /// The result of evaluating a URL.
    public enum Outcome: Sendable, Equatable {
        case accepted(warning: Warning?)
        case refused(Refusal)

        public var isAccepted: Bool {
            if case .accepted = self { return true }
            return false
        }

        public var warning: Warning? {
            if case .accepted(let warning) = self { return warning }
            return nil
        }

        public var refusal: Refusal? {
            if case .refused(let refusal) = self { return refusal }
            return nil
        }
    }

    /// Why a URL is refused.
    public enum Refusal: Error, Sendable, Equatable, CaseIterable {
        /// The scheme isn't `wss://` or `ws://`; `http://` and `https://` included.
        case unsupportedScheme
        /// The URL has no host.
        case missingHost
        /// A `ws://` URL to a host that isn't loopback, a `.ts.net` name or a `100.64.0.0/10` address.
        case insecureHostNotAllowed
        /// The URL has a user name or password.
        case userInfo
        /// The URL has a query.
        case query
        /// The URL has a fragment.
        case fragment

        /// A short explanation to show the user.
        public var message: String {
            switch self {
            case .unsupportedScheme:
                "Use a wss:// URL. Plain ws:// works only to this device, a .ts.net name or a Tailscale address."
            case .missingHost:
                "The URL has no host."
            case .insecureHostNotAllowed:
                "Plain ws:// works only to localhost, a .ts.net name or a Tailscale 100.64.0.0/10 address. Use wss:// for this host."
            case .userInfo:
                "Remove the user name and password from the URL. VIRT sends the token itself."
            case .query:
                "Remove the query (the part after ?) from the URL. VIRT sends the token itself."
            case .fragment:
                "Remove the fragment (the part after #) from the URL."
            }
        }
    }

    /// A risk in an accepted URL that the user should know about.
    public enum Warning: Sendable, Equatable, CaseIterable {
        /// A `ws://` URL to a carrier-grade NAT (`100.64.0.0/10`) address.
        case carrierGradeNAT

        /// A short explanation to show the user.
        public var message: String {
            switch self {
            case .carrierGradeNAT:
                "This is a carrier-grade NAT address. With Tailscale off, the token goes in plain text over whatever network uses this address. Use the host's .ts.net name instead."
            }
        }
    }

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
    static let tailnetSuffix = ".ts.net"

    /// Evaluates `url` against the policy.
    public func evaluate(_ url: URL) -> Outcome {
        let scheme = url.scheme?.lowercased()
        guard scheme == "wss" || scheme == "ws" else { return .refused(.unsupportedScheme) }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawHost = components.percentEncodedHost, !rawHost.isEmpty
        else { return .refused(.missingHost) }
        if components.percentEncodedUser != nil || components.percentEncodedPassword != nil {
            return .refused(.userInfo)
        }
        if components.percentEncodedQuery != nil { return .refused(.query) }
        if components.percentEncodedFragment != nil { return .refused(.fragment) }
        if scheme == "wss" { return .accepted(warning: nil) }

        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if Self.loopbackHosts.contains(host) || Self.isTailnetName(host) {
            return .accepted(warning: nil)
        }
        if Self.isCarrierGradeNAT(host) { return .accepted(warning: .carrierGradeNAT) }
        return .refused(.insecureHostNotAllowed)
    }

    /// `<label>.ts.net` with one or more non-empty ASCII letter, digit or hyphen labels.
    /// Percent-encoded, IDN (`xn--`) and trailing-dot hosts don't match.
    static func isTailnetName(_ host: String) -> Bool {
        guard host.hasSuffix(tailnetSuffix) else { return false }
        let labels = host.dropLast(tailnetSuffix.count).split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("xn--")
                && label.utf8.allSatisfy { isASCIIDigit($0) || (0x61...0x7A).contains($0) || $0 == 0x2D }
        }
    }

    /// A dotted-quad IPv4 address in `100.64.0.0/10`.
    static func isCarrierGradeNAT(_ host: String) -> Bool {
        guard let octets = ipv4Octets(host) else { return false }
        return octets[0] == 100 && octets[1] & 0xC0 == 64
    }

    /// Exactly four decimal parts of 0–255, with no leading zeros.
    static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.utf8.count), part.utf8.allSatisfy(isASCIIDigit),
                  part.utf8.count == 1 || part.utf8.first != 0x30,
                  let octet = UInt8(part)
            else { return nil }
            octets.append(octet)
        }
        return octets
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
}

extension HostURLPolicy.Refusal: LocalizedError {
    public var errorDescription: String? { message }
}
