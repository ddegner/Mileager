import AppCore
import SwiftUI

/// First-run setup as a push-driven wizard (the Apple setup-assistant idiom):
/// a permissions screen, then the shared vehicle setup screen (`VehicleDetailView`
/// in `.onboarding` mode) so first-run, "Add Vehicle", and editing a car are all
/// the same view. Each step has a prominent bottom button.
///
/// On a Mac the wizard leads with iCloud Sync instead of permissions: capture
/// happens on the iPhone or iPad, so the one decision that matters is whether this
/// install joins the iCloud library. Declining completes setup with an empty
/// vehicle list; a Mac user can add a local vehicle explicitly from Settings.
struct OnboardingView: View {
    private enum Step: Hashable {
        case vehicle
        case macRelaunch
    }

    @Environment(MileageAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step] = []
    @State private var syncPreflight: SyncEnablePreflight?

    var onFinish: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            rootStep
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .vehicle:
                        VehicleDetailView(mode: .onboarding, onComplete: finishOnboarding)
                    case .macRelaunch:
                        macRelaunchStep
                    }
                }
        }
        .sheet(item: $syncPreflight) { preflight in
            SyncEnableConfirmationView(preflight: preflight, platform: model.platform) {
                do {
                    try await model.confirmSyncEnablement()
                    path.append(.macRelaunch)
                    return true
                } catch {
                    model.present(error, .saveSettings)
                    return false
                }
            }
        }
    }

    @ViewBuilder
    private var rootStep: some View {
        if model.platform.isMac {
            macSyncStep
        } else {
            permissionsStep
        }
    }

    private var permissionsStep: some View {
        Form {
            TrackingPermissionsSection(context: .onboarding)
        }
        .accessibilityIdentifier("onboardingForm")
        .navigationTitle(Text("Permissions"))
        .navigationBarTitleDisplayMode(.inline)
        .mileageGroupedBackground()
        .onAppear {
            model.refreshConnectedBluetoothHints()
        }
        .safeAreaBar(edge: .bottom) {
            OnboardingPrimaryButton(title: String(localized: "Continue"), identifier: "onboardingNextButton") {
                path.append(.vehicle)
            }
        }
    }

    private var macSyncStep: some View {
        Form {
            Section {
                Text("Mileager on your Mac shows and reports the trips your iPhone or iPad records. Turn on iCloud Sync to see them here.")
                    .accessibilityIdentifier("onboardingMacSyncIntroText")
            }
        }
        .accessibilityIdentifier("onboardingForm")
        .navigationTitle(Text("iCloud Sync"))
        .navigationBarTitleDisplayMode(.inline)
        .mileageGroupedBackground()
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 8) {
                OnboardingPrimaryButton(
                    title: String(localized: "Use iCloud Sync"),
                    identifier: "onboardingUseSyncButton"
                ) {
                    beginSyncEnablement()
                }
                Button(String(localized: "Set Up Without iCloud")) {
                    finishOnboarding()
                }
                .accessibilityIdentifier("onboardingSkipSyncButton")
            }
        }
    }

    private var macRelaunchStep: some View {
        Form {
            Section {
                Label {
                    Text("Sync is ready. Quit and reopen Mileager to start downloading your trips.")
                } icon: {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.icloud")
                }
            }
        }
        .navigationTitle(Text("iCloud Sync"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .mileageGroupedBackground()
        .safeAreaBar(edge: .bottom) {
            OnboardingPrimaryButton(title: String(localized: "Done"), identifier: "onboardingSyncDoneButton") {
                finishOnboarding()
            }
        }
    }

    private func beginSyncEnablement() {
        do {
            switch try model.requestSyncPreferenceChange(to: true) {
            case .applied:
                // Sync is already running this launch (onboarding re-run after
                // the enabling relaunch) — nothing left to explain.
                finishOnboarding()
            case .confirmationRequired(let preflight):
                syncPreflight = preflight
            }
        } catch {
            model.present(error, .saveSettings)
        }
    }

    private func finishOnboarding() {
        onFinish()
        dismiss()
    }
}

/// The full-width prominent button used at the bottom of each onboarding step
/// (and the onboarding vehicle setup's "Done").
struct OnboardingPrimaryButton: View {
    let title: String
    let identifier: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(disabled)
        .padding(.horizontal)
        .accessibilityIdentifier(identifier)
    }
}
