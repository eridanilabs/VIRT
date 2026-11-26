import SwiftUI
import Testing
import UIKit
import VIRTKit
@testable import VIRT

@MainActor
private final class SessionChatLayoutCapture {
    var frames: [String: CGRect] = [:]
}

/// Hosts the real chat destination in the app's layout, with a bottom navigation bar and a
/// keyboard-sized region that represents the viewport taken by the software keyboard.
private struct SessionChatLayoutHost: View {
    let model: SessionChatViewModel
    let capture: SessionChatLayoutCapture

    var body: some View {
        NavigationStack {
            SessionChatView(model: model)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                SessionChatComposer(model: model)
                Text("Bottom navigation")
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: SessionChatLayoutPreferenceKey.self,
                                value: ["navigation": geometry.frame(in: .named("SessionChatLayout"))]
                            )
                        }
                    }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: 260)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: SessionChatLayoutPreferenceKey.self,
                            value: ["keyboard": geometry.frame(in: .named("SessionChatLayout"))]
                        )
                    }
                }
                .accessibilityLabel("Keyboard area")
        }
        .coordinateSpace(name: "SessionChatLayout")
        .onPreferenceChange(SessionChatLayoutPreferenceKey.self) { capture.frames = $0 }
    }
}

@MainActor
struct SessionChatViewTests {
    @Test func composerIsAboveNavigationAndRemainsInTheKeyboardAdjustedViewport() async throws {
        let hostID = UUID()
        let row = SessionRow(resource: "ahp-session:/layout", title: "Layout", state: .idle,
                             folder: nil, modifiedAt: "")
        let capture = SessionChatLayoutCapture()
        let controller = UIHostingController(
            rootView: SessionChatLayoutHost(
                model: SessionChatViewModel(hostID: hostID, row: row, connector: FakeConnector()),
                capture: capture
            )
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        window.layoutIfNeeded()

        for _ in 0..<30 where capture.frames["keyboard"] == nil { await Task.yield() }
        let composer = try #require(capture.frames["composer"])
        let navigation = try #require(capture.frames["navigation"])
        let keyboard = try #require(capture.frames["keyboard"])
        #expect(composer.maxY <= navigation.minY + 1)
        #expect(composer.maxY <= keyboard.minY + 1)
        #expect(composer.minY >= controller.view.safeAreaInsets.top)
    }
}
