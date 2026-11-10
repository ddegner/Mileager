import SwiftUI

struct ShortcutAutomationSetupLink: View {
    @Environment(MileageAppModel.self) private var model
    var accessibilityPrefix: String
    var showsReceipt = true

    var body: some View {
        if model.platform.capturesDrives {
            NavigationLink {
                ShortcutAutomationSetupView(showsReceipt: showsReceipt)
            } label: {
                HStack {
                    Text("Set Up Bluetooth")
                    Spacer()
                    if showsReceipt, model.lastVehicleAutomationReceivedAt != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MileageTheme.businessAccent)
                            .accessibilityLabel(Text("Shortcut received"))
                    }
                }
            }
            .accessibilityIdentifier("\(accessibilityPrefix)ShortcutSetupLink")
        }
    }
}
