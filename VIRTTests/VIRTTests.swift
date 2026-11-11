import AHPClient
import Testing

struct VIRTTests {
    @Test func appLinksTheAHPClient() {
        #expect(AHP.rootChannel == "ahp-root://")
    }
}
