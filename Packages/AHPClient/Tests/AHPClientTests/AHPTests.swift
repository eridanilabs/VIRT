import AHPClient
import Testing

struct AHPTests {
    @Test func rootChannelIsTheHostRoot() {
        #expect(AHP.rootChannel == "ahp-root://")
    }

    @Test func offersNewestProtocolVersionFirst() {
        #expect(AHP.supportedProtocolVersions == ["1.1.0", "1.0.0"])
    }
}
