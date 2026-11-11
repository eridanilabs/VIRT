import Testing
import VIRTKit

struct VIRTKitTests {
    @Test func rootChannelIsTheHostRoot() {
        #expect(VIRTKit.rootChannel == "ahp-root://")
    }
}
