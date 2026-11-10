import SwiftUI

struct SyncEnableConfirmationView: View {
    @Environment(\.dismiss) private var dismiss

    let preflight: SyncEnablePreflight
    var platform: RunningPlatform = .iOS
    let onConfirm: () async -> Bool
    @State private var isPreparingRecoveryCopy = false

    @ViewBuilder
    var body: some View {
        if platform.isMac {
            confirmationContent.macSheetFrame()
        } else {
            confirmationContent
                .presentationDetents([.medium, .large])
                .presentationSizing(.fitted)
        }
    }

    private var confirmationContent: some View {
        NavigationStack {
            List {
                Section(platform.isMac
                    ? String(localized: "On This Mac")
                    : String(localized: "On This Device")) {
                    LabeledContent("Trips", value: preflight.tripCount.formatted())
                    if let dateRange {
                        LabeledContent("Trip Dates", value: dateRange)
                    }
                    if preflight.rawSampleCount > 0 {
                        LabeledContent("Raw Tracking Samples", value: preflight.rawSampleCount.formatted())
                    }
                    LabeledContent("Vehicles", value: preflight.vehicleCount.formatted())
                }

                Section {
                    Label {
                        Text(combineExplanation)
                    } icon: {
                        Image(systemName: "arrow.trianglehead.merge")
                    }

                    Label {
                        Text("Trip details, business-purpose choices, Notes, routes and maps, fees, vehicles, and report settings are included. Different trips are kept together, and anything uncertain is preserved for review.")
                    } icon: {
                        Image(systemName: "checklist")
                    }

                    Label {
                        Text("Vehicles saved here will also be combined with vehicles already in iCloud. Similar names stay separate; Mileager does not merge them automatically.")
                    } icon: {
                        Image(systemName: "car.2.fill")
                    }

                    // A Mac never captures, so the raw-samples note would
                    // describe data that cannot exist there.
                    if !platform.isMac {
                        Label {
                            Text("Raw tracking samples stay on this device and are not uploaded to iCloud.")
                        } icon: {
                            Image(systemName: "iphone")
                        }
                    }

                    Label {
                        Text(platform.isMac
                            ? String(localized: "Before combining, Mileager saves a recovery copy of this Mac's mileage data on this Mac.")
                            : String(localized: "Before combining, Mileager saves a recovery copy of this device's mileage data on this device."))
                    } icon: {
                        Image(systemName: "externaldrive.badge.checkmark")
                    }
                } header: {
                    Text("What Will Happen")
                } footer: {
                    Text(platform.isMac
                        ? String(localized: "Sync starts after you quit and reopen Mileager.")
                        : String(localized: "Sync starts after you close and reopen Mileager. Drive capture continues to work without an internet connection."))
                }
            }
            .navigationTitle("Combine with iCloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isPreparingRecoveryCopy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { @MainActor in
                            isPreparingRecoveryCopy = true
                            if await onConfirm() {
                                dismiss()
                            } else {
                                isPreparingRecoveryCopy = false
                            }
                        }
                    } label: {
                        if isPreparingRecoveryCopy {
                            ProgressView()
                        } else {
                            Text("Combine and Sync")
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(isPreparingRecoveryCopy)
                    .accessibilityLabel("Combine and Sync")
                }
            }
        }
        .interactiveDismissDisabled(isPreparingRecoveryCopy)
    }

    private var combineExplanation: String {
        if preflight.tripCount == 0 {
            return platform.isMac
                ? String(localized: "Trips already in iCloud will be downloaded to this Mac. Nothing in iCloud will be replaced.")
                : String(localized: "Trips already in iCloud will be downloaded to this device. Nothing in iCloud will be replaced.")
        }
        if preflight.tripCount == 1 {
            return String(localized: "Your saved trip will be combined with trips already in iCloud. Neither library will be replaced.")
        }
        return String.localizedStringWithFormat(
            String(localized: "Your %lld saved trips will be combined with trips already in iCloud. Neither library will be replaced."),
            Int64(preflight.tripCount)
        )
    }

    private var dateRange: String? {
        guard let earliest = preflight.earliestTripDate,
              let latest = preflight.latestTripDate else {
            return nil
        }
        return Date.IntervalFormatStyle(
            date: .abbreviated,
            time: .omitted
        ).format(earliest..<max(earliest.addingTimeInterval(1), latest))
    }
}
