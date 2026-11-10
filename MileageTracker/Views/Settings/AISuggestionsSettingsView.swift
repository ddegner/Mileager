import SwiftUI

/// Drill-in page for the AI suggestion evidence sources, shown once Trip
/// Suggestions is on: calendar events, contact addresses, and the user's own
/// card. Follows the Settings subpage pattern — the main page stays shallow.
struct AISuggestionsSettingsView: View {
    @Environment(MileageAppModel.self) private var model
    @State private var showingUserCardPicker = false

    var body: some View {
        @Bindable var model = model
        Form {
            if model.privateCloudComputeSuggestionsSupported {
                Section {
                    Toggle("Use Private Cloud Compute", isOn: $model.privateCloudComputeSuggestionsEnabled)
                        .accessibilityIdentifier("settingsPrivateCloudComputeToggle")
                } footer: {
                    Text("Off by default. When enabled, trip details, notes, purpose presets, and any enabled calendar or contact evidence may be sent to Apple’s Private Cloud Compute to create suggestions. Apple does not store this data. If unavailable, Mileager uses the on-device model. Suggestions are never applied automatically.")
                }
            }
            Section {
                Toggle("Use Calendar Events", isOn: $model.calendarSuggestionEvidenceEnabled)
                    .accessibilityIdentifier("settingsCalendarEvidenceToggle")

                if model.calendarEvidencePermissionDenied {
                    openSettingsGuidance(
                        "Calendar access is off in Settings.",
                        systemImage: "calendar.badge.exclamationmark",
                        identifier: "settingsCalendarOpenSettingsButton"
                    )
                }
            } footer: {
                Text("Checks your calendar for events around each trip; a matching event names the suggestion.")
            }

            Section {
                Toggle("Use Contacts", isOn: $model.contactSuggestionEvidenceEnabled)
                    .accessibilityIdentifier("settingsContactsEvidenceToggle")

                if model.contactsEvidencePermissionDenied {
                    openSettingsGuidance(
                        "Contacts access is off in Settings.",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        identifier: "settingsContactsOpenSettingsButton"
                    )
                }

                Button {
                    showingUserCardPicker = true
                } label: {
                    LabeledContent("Share My Contact Information", value: model.userCardName ?? String(localized: "Set Up"))
                }
                .disabled(!model.contactSuggestionEvidenceEnabled)
                .accessibilityIdentifier("settingsMyCardButton")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Matches trip locations to your contacts’ addresses. Your own card identifies your home and work, so commutes and home trips are judged sensibly.")
                    Text("Apple Intelligence creates suggestions for your review. They are never applied automatically.")
                }
            }
        }
        .navigationTitle("Suggestion Sources")
        .navigationBarTitleDisplayMode(.inline)
        .mileageGroupedBackground(MileageTheme.settingsGroupedBackground)
        .sheet(isPresented: $showingUserCardPicker) {
            UserCardPicker(
                onSelect: { contact in
                    model.applyUserCard(contact)
                },
                onFinished: {
                    showingUserCardPicker = false
                }
            )
        }
    }

    private func openSettingsGuidance(_ message: LocalizedStringKey, systemImage: String, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(message, systemImage: systemImage)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button("Open Settings") {
                model.openAppSettings()
            }
            .font(.footnote.weight(.semibold))
            .accessibilityIdentifier(identifier)
        }
    }
}
