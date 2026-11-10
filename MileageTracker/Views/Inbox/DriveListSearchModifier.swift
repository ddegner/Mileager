import SwiftUI

/// System search owns its field, focus, and close button. The scope picker
/// lives above the results because toolbar search does not render searchScopes
/// consistently with the supported iOS toolbar placement.
struct DriveListSearchModifier: ViewModifier {
    @Binding var text: String

    func body(content: Content) -> some View {
        content
            .searchable(text: $text, placement: .toolbar, prompt: Text("Search Trips"))
            // A narrow split column uses the system's expanding search button.
            // A full-width resting field would extend beneath the sidebar.
            .searchToolbarBehavior(UIDevice.current.userInterfaceIdiom == .phone ? .automatic : .minimize)
    }
}

struct DriveSearchScopePicker: View {
    @Binding var selection: DriveSearchScope
    var mailbox: DriveListScope

    var body: some View {
        Picker("Search Trips", selection: $selection) {
            Text(verbatim: mailbox.title).tag(DriveSearchScope.currentMailbox)
            Text("All Trips").tag(DriveSearchScope.allTrips)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("tripSearchScopePicker")
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.background)
    }
}
