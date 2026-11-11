/// Constants of the Agent Host Protocol (https://github.com/microsoft/agent-host-protocol)
/// that VIRT's client speaks.
public enum AHP {
    /// The channel of the host's root state, which a client subscribes to on `initialize`.
    public static let rootChannel = "ahp-root://"

    /// The protocol versions the client offers in `initialize`, newest first.
    public static let supportedProtocolVersions = ["1.1.0", "1.0.0"]
}
