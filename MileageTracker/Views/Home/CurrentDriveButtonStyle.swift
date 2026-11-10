import SwiftUI

struct CurrentDriveButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .brightness(configuration.isPressed ? 0.07 : 0)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.14),
                value: configuration.isPressed
            )
    }
}
