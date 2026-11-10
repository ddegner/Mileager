import SwiftUI

struct CurrentDriveActionTile: View {
    enum Axis {
        case vertical
        case horizontal
    }

    enum Surface {
        case standard
        case classification
    }

    var title: String
    var systemImage: String
    var tint: Color
    var symbolTint: Color? = nil
    var selectionTint: Color? = nil
    var isSelected = false
    var axis: Axis = .vertical
    var surface: Surface = .standard

    @ScaledMetric(relativeTo: .body) private var actionHeight = 60.0

    var body: some View {
        Group {
            if axis == .horizontal {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .foregroundStyle(symbolTint ?? foregroundStyle)
                    Text(title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.60)
                }
                .font(.body.bold())
            } else {
                VStack(spacing: 4) {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(symbolTint ?? foregroundStyle)
                    Text(title)
                        .font(.body.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.60)
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: actionHeight
        )
        .foregroundStyle(foregroundStyle)
        .glassEffect(
            .regular.tint(.black.opacity(0.45)).interactive(),
            in: .rect(cornerRadius: 16)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(borderStyle, lineWidth: isSelected ? 2 : 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(selectionStyle, .white)
                    .padding(7)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect(cornerRadius: 16))
    }

    private var foregroundStyle: Color {
        tint
    }

    private var borderStyle: LinearGradient {
        let colors: [Color]

        if isSelected {
            colors = [selectionStyle, selectionStyle.opacity(0.72)]
        } else {
            colors = surface == .classification
                ? [.white.opacity(0.32), .white.opacity(0.15)]
                : [.white.opacity(0.24), .white.opacity(0.12)]
        }

        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var selectionStyle: Color {
        selectionTint ?? tint
    }
}
