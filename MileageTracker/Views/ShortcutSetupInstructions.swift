import SwiftUI
import UIKit

struct ShortcutSetupInstructions: View {
    var accessibilityPrefix: String
    /// Intro for the Shortcuts setup page.
    static let introText = String(localized: "Adding a \"Shortcuts automation\" can start a trip when your phone connects to your car's bluetooth or Carplay.")

    private let steps = [
        String(localized: "In Shortcuts, open the Automation tab and tap New Automation (or +)."),
        String(localized: "Choose Bluetooth, tap Choose, and select your car."),
        String(localized: "Make sure Is Connected is selected, then tap Next."),
        String(localized: "Select Run Immediately."),
        String(localized: "Add Mileager's Check for Drive action, set Trigger to Vehicle Bluetooth, then tap Done.")
    ]
    private let variationNote = String(localized: "Using CarPlay? Choose CarPlay and Connects, then set the Check for Drive action's Trigger to CarPlay.")
    private let screenshots = [
        ShortcutSetupScreenshot(
            id: 1,
            assetName: "ShortcutAutomationStep1",
            caption: String(localized: "Tap New Automation"),
            accessibilityLabel: String(localized: "Tap New Automation in Shortcuts")
        ),
        ShortcutSetupScreenshot(
            id: 2,
            assetName: "ShortcutAutomationStep2",
            caption: String(localized: "Choose Bluetooth"),
            accessibilityLabel: String(localized: "Choose the Bluetooth trigger")
        ),
        ShortcutSetupScreenshot(
            id: 3,
            assetName: "ShortcutAutomationStep3",
            caption: String(localized: "Select Run Immediately"),
            accessibilityLabel: String(localized: "Select Run Immediately")
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            instructionText

            ShortcutScreenshotCarousel(
                screenshots: screenshots,
                accessibilityPrefix: accessibilityPrefix
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("\(accessibilityPrefix)ShortcutSetupInstructions")
    }

    private var instructionText: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                    Text(step)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("\(accessibilityPrefix)ShortcutStep\(index + 1)")
            }

            Text(variationNote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("\(accessibilityPrefix)ShortcutVariationNote")

        }
    }

}

/// Caption above ``ShortcutSetupInstructions``.
/// Identifier resolves to `<prefix>ShortcutSetupText`.
struct ShortcutSetupIntroText: View {
    var accessibilityPrefix: String

    var body: some View {
        Text(ShortcutSetupInstructions.introText)
            .accessibilityIdentifier("\(accessibilityPrefix)ShortcutSetupText")
    }
}

/// Opens the Shortcuts app. Identifier resolves to
/// `<prefix>OpenShortcutsButton`.
struct OpenShortcutsButton: View {
    @Environment(MileageAppModel.self) private var model
    var accessibilityPrefix: String

    var body: some View {
        Button {
            model.openShortcutsApp()
        } label: {
            Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
        }
        .accessibilityIdentifier("\(accessibilityPrefix)OpenShortcutsButton")
    }
}

private struct ShortcutSetupScreenshot: Identifiable {
    let id: Int
    let assetName: String
    let caption: String
    let accessibilityLabel: String
}

private struct ShortcutScreenshotCarousel: View {
    var screenshots: [ShortcutSetupScreenshot]
    var accessibilityPrefix: String

    @State private var selectedScreenshotID: Int? = 1

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(screenshots) { screenshot in
                        Image(screenshot.assetName)
                            .resizable()
                            .scaledToFit()
                            .containerRelativeFrame(.horizontal) { width, _ in
                                width * 0.78
                            }
                            .tag(screenshot.id)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(String(localized: "Screenshot \(screenshot.id) of \(screenshots.count): \(screenshot.accessibilityLabel)"))
                            .accessibilityIdentifier("\(accessibilityPrefix)ShortcutScreenshot\(screenshot.id)")
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 28, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $selectedScreenshotID)
            .scrollTargetBehavior(.viewAligned)
            .frame(height: 360)

            Text(selectedScreenshot.caption)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            SystemPageControl(
                numberOfPages: screenshots.count,
                currentPage: currentPage
            )
            .frame(height: 14)
        }
        .padding(.top, 4)
        .accessibilityIdentifier("\(accessibilityPrefix)ShortcutScreenshotCarousel")
    }

    private var selectedScreenshot: ShortcutSetupScreenshot {
        screenshots.first { $0.id == selectedScreenshotID } ?? screenshots[0]
    }

    private var currentPage: Binding<Int> {
        Binding {
            screenshots.firstIndex { $0.id == selectedScreenshotID } ?? 0
        } set: { newPage in
            guard screenshots.indices.contains(newPage) else { return }
            selectedScreenshotID = screenshots[newPage].id
        }
    }
}

private struct SystemPageControl: UIViewRepresentable {
    let numberOfPages: Int
    @Binding var currentPage: Int

    func makeUIView(context: Context) -> UIPageControl {
        let pageControl = UIPageControl()
        pageControl.numberOfPages = numberOfPages
        pageControl.currentPage = currentPage
        pageControl.currentPageIndicatorTintColor = .label
        pageControl.pageIndicatorTintColor = .tertiaryLabel
        pageControl.isUserInteractionEnabled = false
        return pageControl
    }

    func updateUIView(_ pageControl: UIPageControl, context: Context) {
        pageControl.numberOfPages = numberOfPages
        pageControl.currentPage = currentPage
    }
}
