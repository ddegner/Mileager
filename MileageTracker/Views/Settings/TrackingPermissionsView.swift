import SwiftUI

/// Drill-in page for the Automatic Tracking permission checklist. The rows,
/// intro text, and permission dialogs live in `TrackingPermissionsSection`,
/// shared with onboarding.
struct TrackingPermissionsView: View {
    var body: some View {
        Form {
            TrackingPermissionsSection(context: .settings, presentation: .section)
        }
        .accessibilityIdentifier("settingsPermissionsForm")
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
        .mileageGroupedBackground(MileageTheme.settingsGroupedBackground)
    }
}
