import AgentHostProtocolClient

/// VIRT's non-UI layer over the official Agent Host Protocol Swift client
/// (`AgentHostProtocolClient`, from https://github.com/microsoft/agent-host-protocol).
public enum VIRTKit {
    /// The channel of a host's root state, which a client subscribes to on `initialize`.
    public static let rootChannel = RootResourceURI
}
