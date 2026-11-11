import VIRTKit
import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No agent host",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text("VIRT isn't connected to an Agent Host Protocol host yet.")
            )
            .navigationTitle("VIRT")
        }
    }
}

#Preview {
    ContentView()
}
