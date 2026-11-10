import SwiftUI

/// Drill-in page for the Shortcuts automation that makes trip starts more
/// reliable. Reuses the intro text, Open Shortcuts button, and step-by-step
/// instructions from the vehicle and Automatic Tracking settings.
struct ShortcutAutomationSetupView: View {
    @Environment(MileageAppModel.self) private var model
    var showsReceipt = true

    var body: some View {
        Form {
            Section {
                ShortcutSetupIntroText(accessibilityPrefix: "settings")

                OpenShortcutsButton(accessibilityPrefix: "settings")

                if showsReceipt, let receivedAt = model.lastVehicleAutomationReceivedAt {
                    LabeledContent("Last received") {
                        Text(receivedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                    }
                    .accessibilityIdentifier("settingsShortcutLastReceived")
                }
            }

            Section("How to set it up") {
                ShortcutSetupInstructions(accessibilityPrefix: "settings")
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settingsShortcutSetupContent")
            }
        }
        .navigationTitle("Create a Shortcuts Automation")
        .navigationBarTitleDisplayMode(.inline)
        .mileageGroupedBackground(MileageTheme.settingsGroupedBackground)
    }
}
