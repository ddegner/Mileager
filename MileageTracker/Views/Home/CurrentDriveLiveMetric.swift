import SwiftUI

struct CurrentDriveLiveMetric: View {
    var title: String
    var value: String?
    var startedAt: Date?

    init(title: String, value: String) {
        self.title = title
        self.value = value
        startedAt = nil
    }

    init(title: String, startedAt: Date) {
        self.title = title
        value = nil
        self.startedAt = startedAt
    }

    var body: some View {
        Group {
            if let value {
                Text(value)
                    .accessibilityLabel(Text(title))
                    .accessibilityValue(Text(value))
            } else if let startedAt {
                Text(startedAt, style: .timer)
                    .accessibilityLabel(Text(title))
                    .accessibilityValue(Text(startedAt, style: .timer))
            }
        }
        .font(.callout.bold().monospacedDigit())
        .foregroundStyle(.white)
        .lineLimit(1)
    }
}
