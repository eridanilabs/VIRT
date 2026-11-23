import SwiftUI
import VIRTKit

/// The presenter's current alert as a banner at the top of the screen: an icon, the kind in words
/// and the session's title as plain text. Tapping it calls `open`.
struct SessionAlertBanner: View {
    let presenter: SessionAlertPresenter
    let open: () -> Void

    var body: some View {
        Group {
            if let alert = presenter.current {
                Button(action: open) {
                    HStack {
                        Image(systemName: alert.symbol)
                            .font(.title2)
                            .foregroundStyle(alert.kind == .failed ? Color.red : Color.accentColor)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(verbatim: alert.kindText)
                                .font(.headline)
                            Text(verbatim: alert.title)
                                .font(.subheadline)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: alert.announcement))
                .accessibilityHint("Opens this session's chat")
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: presenter.current)
    }
}

private extension SessionAlert {
    var symbol: String {
        switch kind {
        case .finished: "checkmark.circle.fill"
        case .inputNeeded: "questionmark.bubble.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}
