import AgentHostProtocol
import AgentHostProtocolClient
import Foundation
import Testing
@testable import VIRTKit

struct ConnectionErrorRecorderTests {
    typealias Failure = HostConnector.Failure

    @Test(arguments: [
        (-1003, nil, Failure.hostUnreachable), (-1004, nil, .hostUnreachable), (-1001, nil, .hostUnreachable),
        (-1009, nil, .hostUnreachable), (-1005, nil, .hostUnreachable),
        (-1200, nil, .tlsFailed), (-1201, nil, .tlsFailed), (-1202, nil, .tlsFailed), (-1203, nil, .tlsFailed),
        (-1204, nil, .tlsFailed), (-1205, nil, .tlsFailed), (-1206, nil, .tlsFailed),
        (-1022, nil, .blockedByATS),
        (nil, 401, .tokenRefused), (nil, 403, .tokenRefused), (-1011, 401, .tokenRefused), (-1011, 403, .tokenRefused),
        (-1011, 500, .other), (-1011, nil, .other), (-1, nil, .other),
    ] as [(Int?, Int?, Failure)])
    func mapsErrorsAndStatuses(code: Int?, status: Int?, failure: Failure) {
        let error = code.map { URLError(URLError.Code(rawValue: $0)) }
        #expect(Failure(error: error, httpStatus: status) == failure)
    }

    @Test func ignoresNoErrorAndCancelling() {
        #expect(Failure(error: nil, httpStatus: nil) == nil)
        #expect(Failure(error: nil, httpStatus: 101) == nil)
        #expect(Failure(error: URLError(.cancelled), httpStatus: nil) == nil)
    }

    @Test(arguments: [
        (Failure.tokenRefused, "The host refused the token. Edit the host to update it."),
        (.hostUnreachable, "Can't reach the host. Check that it's running and on your network."),
        (.tlsFailed, "The secure connection failed. Check the host's certificate."),
        (.protocolVersionMismatch, "The host uses a protocol version VIRT doesn't support."),
        (.blockedByATS, "iOS blocked this plain connection. Use wss:// or a .ts.net name."),
        (.other, "Couldn't connect to the host."),
    ])
    func hasAFixedMessage(failure: Failure, message: String) {
        #expect(failure.message == message)
        #expect(failure.localizedDescription == message)
    }

    @Test func delegateRecordsTheMappedFailure() throws {
        let recorder = ConnectionErrorRecorder()
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: try #require(URL(string: "wss://mac.tailnet.ts.net/?tkn=s3ntinel")))
        recorder.urlSession(session, task: task, didCompleteWithError: URLError(.cannotConnectToHost))
        #expect(recorder.failure == .hostUnreachable)
        // A later error doesn't hide a stop case.
        recorder.record(.tokenRefused)
        recorder.record(error: URLError(.timedOut), httpStatus: nil)
        #expect(recorder.failure == .tokenRefused)
    }

    @Test(arguments: [(AhpErrorCodes.unsupportedProtocolVersion, Failure.protocolVersionMismatch),
                      (-32603, nil)] as [(Int, Failure?)])
    func transportRecordsAVersionMismatch(code: Int, failure: Failure?) async throws {
        let recorder = ConnectionErrorRecorder()
        let (client, server) = InMemoryTransport.pair()
        let transport = RecordingTransport(client, recorder: recorder)
        let reply = #"{"jsonrpc":"2.0","id":1,"error":{"code":\#(code),"message":"no"}}"#
        try await server.send(.text(reply))
        guard case .text(let text)? = try await transport.recv() else { Issue.record("no reply"); return }

        #expect(text == reply)
        #expect(recorder.failure == failure)
    }
}
