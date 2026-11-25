import SwiftUI

struct BackSwipe: ViewModifier {
    var enabled = true
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if enabled && Self.matches(startX: value.startLocation.x,
                                                   translationX: value.translation.width,
                                                   translationY: value.translation.height) {
                            withAnimation { dismiss() }
                        }
                    }
            )
            .accessibilityAction(.escape) {
                if enabled { dismiss() }
            }
    }

    static func matches(startX: Double, translationX: Double, translationY: Double) -> Bool {
        (0...24).contains(startX) && translationX >= 80 && translationX > abs(translationY)
    }
}
