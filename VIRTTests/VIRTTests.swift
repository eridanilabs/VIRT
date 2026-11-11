import Testing
import VIRTKit

struct VIRTTests {
    @Test func appLinksVIRTKit() {
        #expect(VIRTKit.rootChannel == "ahp-root://")
    }
}
