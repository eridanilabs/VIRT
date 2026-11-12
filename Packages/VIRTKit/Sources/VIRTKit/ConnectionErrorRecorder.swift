import AgentHostProtocol
import AgentHostProtocolClient
import Foundation
import Synchronization

/// Records why a host's connection attempts fail, as a `HostConnector.Failure`.
///
/// `MultiHostClient` reports errors only as strings, so the connector learns the typed error
/// here: as the delegate of each attempt's `URLSession` it sees URLErrors and the upgrade's
/// HTTP status, and `RecordingTransport` sees a -32005 reply. It keeps only the mapped
/// `Failure`, never the error or its failing URL, which holds the token.
public final class ConnectionErrorRecorder: NSObject, URLSessionTaskDelegate, Sendable {
    private let recorded = Mutex<HostConnector.Failure?>(nil)
    private let onRecord: @Sendable (HostConnector.Failure) -> Void

    init(onRecord: @escaping @Sendable (HostConnector.Failure) -> Void = { _ in }) {
        self.onRecord = onRecord
    }

    /// The last failure recorded since the host last connected.
    var failure: HostConnector.Failure? { recorded.withLock { $0 } }

    /// Maps and records a connection error and the upgrade's HTTP status, if any.
    public func record(error: (any Error)?, httpStatus: Int?) {
        if let failure = HostConnector.Failure(error: error, httpStatus: httpStatus) { record(failure) }
    }

    func record(_ failure: HostConnector.Failure) {
        // A later error, such as the close after a refused token, doesn't hide a stop case.
        recorded.withLock { if $0?.stopsRetrying != true { $0 = failure } }
        onRecord(failure)
    }

    func reset() {
        recorded.withLock { $0 = nil }
    }

    /// Records how the attempt's task ended, then ends the attempt's session.
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        record(error: error, httpStatus: (task.response as? HTTPURLResponse)?.statusCode)
        session.finishTasksAndInvalidate()
    }
}

extension HostConnector.Failure {
    /// The failure for a connection error and the upgrade's HTTP status, or nil if there's
    /// nothing to report: no error, or a task that VIRT cancelled itself.
    init?(error: (any Error)?, httpStatus: Int?) {
        if httpStatus == 401 || httpStatus == 403 {
            self = .tokenRefused
            return
        }
        guard let error else { return nil }
        switch (error as? URLError)?.code {
        case .cancelled?:
            return nil
        case .cannotFindHost?, .cannotConnectToHost?, .timedOut?, .notConnectedToInternet?, .networkConnectionLost?:
            self = .hostUnreachable
        case .secureConnectionFailed?, .serverCertificateHasBadDate?, .serverCertificateUntrusted?,
             .serverCertificateHasUnknownRoot?, .serverCertificateNotYetValid?, .clientCertificateRejected?,
             .clientCertificateRequired?:
            self = .tlsFailed
        case .appTransportSecurityRequiresSecureConnection?:
            self = .blockedByATS
        default:
            self = .other
        }
    }

    /// Retrying can't help: the host stops.
    var stopsRetrying: Bool { self == .tokenRefused || self == .protocolVersionMismatch }
}

/// Passes every message through, and records `protocolVersionMismatch` when the host replies
/// with an `unsupportedProtocolVersion` (-32005) error.
final class RecordingTransport: AHPTransport {
    private let inner: any AHPTransport
    private let recorder: ConnectionErrorRecorder

    init(_ inner: any AHPTransport, recorder: ConnectionErrorRecorder) {
        self.inner = inner
        self.recorder = recorder
    }

    func send(_ message: TransportMessage) async throws { try await inner.send(message) }

    func recv() async throws -> TransportMessage? {
        let message = try await inner.recv()
        if let message, Self.isVersionMismatch(message) { recorder.record(.protocolVersionMismatch) }
        return message
    }

    func close() async throws { try await inner.close() }

    private static func isVersionMismatch(_ message: TransportMessage) -> Bool {
        let code = AhpErrorCodes.unsupportedProtocolVersion
        // Only a frame that holds the code is decoded a second time.
        switch message {
        case .text(let text) where !text.contains(String(code)): return false
        case .binary(let data) where !String(decoding: data, as: UTF8.self).contains(String(code)): return false
        default: break
        }
        guard case .errorResponse(_, let error)? = try? message.intoParsed() else { return false }
        return error.code == code
    }
}
