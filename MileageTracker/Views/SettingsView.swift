import AppCore
#if canImport(MessageUI)
import MessageUI
#endif
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(MileageAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var trackingButtonContentSize: CGFloat = 32
    @State private var showingVacationPause = false
    @State private var showingResetConfirmation = false
    @State private var showingDiagnosticsConsent = false
    @State private var showingReportCleanup = false
    @State private var syncEnablePreflight: SyncEnablePreflight?
    @State private var diagnosticsDayRange: DiagnosticsDayRange = .seven
    @State private var diagnosticsReport: DiagnosticsReportItem?
    /// Mac-only adapter feeding the shared `exportShare` save-panel modifier.
    /// The share item owns the report directory for terminal cleanup.
    @State private var macDiagnosticsShare: ActivityShareItem?
    @State private var pendingDiagnosticsReport: DiagnosticsReportItem?
    @State private var diagnosticsExportInProgress = false
    @State private var legalPage: LegalPage?
    @State private var vacationRestartDate = Calendar.current.date(
        byAdding: .day,
        value: 7,
        to: Date()
    ) ?? Date()

    var body: some View {
        NavigationStack {
            Form {
                productionCloudKitWarningSection
                trackingControlsSection
                lockScreenSection
                tripsSection
                aiSuggestionsSection
                moneyDistanceSection
                dataSection
                supportLegalSection
            }
            .listSectionSpacing(24)
            .accessibilityIdentifier("settingsForm")
            // Keep the Permissions row's "N of 4 on" summary fresh.
            .task { model.refreshPermissionStatuses() }
            .onAppear {
                showingReportCleanup = model.legacyReportArtifactCount > 0
                    && model.reportArtifactCleanupDecision == nil
            }
            .navigationDestination(item: $legalPage) { page in
                switch page {
                case .privacy: PrivacyPolicyView()
                case .terms: TermsAccuracyAndNoticesView()
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .mileageGroupedBackground(MileageTheme.settingsGroupedBackground)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    CheckmarkConfirmationButton(
                        action: { dismiss() },
                        accessibilityLabel: String(localized: "Done"),
                        accessibilityIdentifier: "settingsDone"
                    )
                }
            }
            .sheet(isPresented: $showingVacationPause) {
                VacationPausePickerView(
                    restartDate: $vacationRestartDate,
                    onConfirm: { restartDate in
                        model.pauseUntil(restartDate)
                        showingVacationPause = false
                    }
                )
                // One graphical date picker doesn't need a full-height sheet.
                .presentationDetents([.medium, .large])
                .presentationSizing(.fitted)
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingDiagnosticsConsent) {
                DiagnosticsConsentView(
                    selectedRange: $diagnosticsDayRange,
                    isPreparing: diagnosticsExportInProgress,
                    platform: model.platform
                ) { days in
                    prepareDiagnosticsReport(days: days)
                }
            }
            .sheet(item: $syncEnablePreflight) { preflight in
                SyncEnableConfirmationView(preflight: preflight, platform: model.platform) {
                    do {
                        try await model.confirmSyncEnablement()
                        return true
                    } catch {
                        model.present(error, .saveSettings)
                        return false
                    }
                }
            }
            // On the Mac the diagnostics zip goes through the shared
            // save-panel modifier via an ActivityShareItem adapter (the user
            // mails it themselves); elsewhere the mail-compose/share sheet
            // flow is unchanged. Both paths end in the same cleanup.
            .sheet(item: model.platform.exportsThroughSavePanel ? .constant(nil) : $diagnosticsReport) { item in
                diagnosticsReportSheet(for: item)
            }
            .exportShare(item: $macDiagnosticsShare, onComplete: {
                diagnosticsReport = nil
            })
            .onChange(of: diagnosticsReport?.id, initial: true) { _, _ in
                guard model.platform.exportsThroughSavePanel, let report = diagnosticsReport else { return }
                macDiagnosticsShare = ActivityShareItem(
                    url: report.url,
                    cleanupURLs: [report.cleanupDirectory ?? report.url.deletingLastPathComponent()]
                )
            }
            .alert("Remove Old Saved Reports?", isPresented: $showingReportCleanup) {
                Button("Remove from iCloud", role: .destructive) {
                    model.confirmLegacyReportArtifactCleanup()
                }
                Button("Not Now", role: .cancel) {
                    model.deferLegacyReportArtifactCleanup()
                }
            } message: {
                Text("Trips and files you already exported are not affected. Reports can be generated again from Months.")
            }
            .onChange(of: showingDiagnosticsConsent) { _, isPresented in
                guard !isPresented, let pendingDiagnosticsReport else { return }
                diagnosticsReport = pendingDiagnosticsReport
                self.pendingDiagnosticsReport = nil
            }
            .alert(
                "Reset app?",
                isPresented: $showingResetConfirmation
            ) {
                Button("Reset App", role: .destructive) {
                    Task {
                        await model.resetApp()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes local mileage data and attempts to delete Mileager data from iCloud when iCloud Sync is active.")
            }
        }
    }

    /// Says out loud what `MileageTracker-Debug.entitlements` does:
    /// `com.apple.developer.icloud-container-environment = Production`, so a
    /// Debug build edits the real iCloud library rather than a sandbox. That is
    /// deliberate — testing sync against the sandbox proves nothing about the
    /// data people actually have — but it means a throwaway build deletes real
    /// trips, and nothing on screen said so.
    ///
    /// A warning did exist; it lived in the native Mac app and was deleted with
    /// it on 2026-08-31, which left the rule in CLAUDE.md pointing at a view
    /// that no longer existed. Here it reaches all three machines. Release
    /// omits the entitlement and this section compiles away entirely.
    @ViewBuilder
    private var productionCloudKitWarningSection: some View {
        #if DEBUG
        Section {
            Label {
                // Verbatim, like the warning this replaces: it is addressed to
                // whoever installed a debug build, never to a customer, so it
                // stays out of the string catalog and out of translation.
                Text(verbatim: "Debug build. This reads and writes your real iCloud trips, not a sandbox copy.")
                    .font(.footnote)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MileageTheme.attentionAccent)
            }
            .accessibilityIdentifier("settingsProductionCloudKitWarning")
        }
        #endif
    }

    private var trackingControlsSection: some View {
        Section {
            // The Mac keeps Permissions without offering capture controls.
            if model.platform.capturesDrives {
                trackingActionRows

                AutomaticTripStartsPicker()

                ShortcutAutomationSetupLink(accessibilityPrefix: "settings")
            }

            NavigationLink {
                TrackingPermissionsView()
            } label: {
                LabeledContent("Permissions", value: permissionsSummary)
            }
            .accessibilityIdentifier("settingsTrackingPermissionsLink")
        } header: {
            if model.platform.capturesDrives {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout())
                layout {
                    Text("Automatic Tracking")
                        .fixedSize(horizontal: false, vertical: true)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    trackingStatusLabel
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settingsAutomaticTrackingStatus")
                }
            }
        }
    }

    @ViewBuilder
    private var trackingStatusLabel: some View {
        if !model.trackingActive {
            Text("Off")
                .foregroundStyle(.secondary)
        } else if activePauseUntil != nil {
            Text("Paused")
                .foregroundStyle(MileageTheme.attentionAccent)
        } else {
            Text("On")
                .foregroundStyle(MileageTheme.businessAccent)
        }
    }

    @ViewBuilder
    private var lockScreenSection: some View {
        if model.platform.hasLockScreen {
            @Bindable var model = model
            Section {
                Toggle("Show Current Drive on Lock Screen", isOn: $model.currentDriveLiveActivitiesEnabled)
                    .accessibilityIdentifier("settingsCurrentDriveLiveActivityToggle")
            }
        }
    }

    private var tripsSection: some View {
        Section {
            NavigationLink {
                TripPurposesSettingsView()
            } label: {
                LabeledContent("Trip Purposes", value: purposesSummary)
            }
            .accessibilityIdentifier("settingsTripPurposesLink")

            NavigationLink {
                FeePresetsSettingsView()
            } label: {
                LabeledContent("Fee Presets", value: "\(model.feePresets.count)")
            }
            .accessibilityIdentifier("settingsFeePresetsLink")

            NavigationLink {
                VehiclesListView()
            } label: {
                LabeledContent("Vehicles", value: "\(model.vehicles.count)")
            }
            .accessibilityIdentifier("settingsVehiclesLink")
        }
    }

    /// Keep configuration reachable while models load or cloud quota resets;
    /// ineligible devices still hide the section.
    private var aiSuggestionsSection: some View {
        @Bindable var model = model
        return Group {
            if model.tripSuggestionsConfigurable {
                Section {
                    Toggle(isOn: $model.aiSuggestionsEnabled) {
                        HStack(spacing: 8) {
                            Text("Trip Suggestions")
                            Text("Beta")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color(.systemGray5), in: Capsule())
                                .accessibilityLabel(Text("Beta"))
                        }
                    }
                    .accessibilityIdentifier("settingsAISuggestionsToggle")

                    if model.aiSuggestionsEnabled {
                        NavigationLink {
                            AISuggestionsSettingsView()
                        } label: {
                            LabeledContent("Suggestion Sources", value: suggestionSourcesSummary)
                        }
                        .accessibilityIdentifier("settingsSuggestionSourcesLink")
                    }
                }
            }
        }
    }

    private var suggestionSourcesSummary: String {
        var sources = [String(localized: "Trip")]
        if model.calendarSuggestionEvidenceEnabled {
            sources.append(String(localized: "Calendar"))
        }
        if model.contactSuggestionEvidenceEnabled {
            sources.append(String(localized: "Contacts"))
        }
        return sources.joined(separator: ", ")
    }

    private var permissionsSummary: String {
        // Counted over the kinds the Permissions page actually shows — on a
        // Mac that is notifications alone, and "1 of 4 on" beside a
        // one-row page read as three broken permissions.
        let kinds = model.availableTrackingPermissionKinds
        let readyCount = kinds.filter { model.permissionState(for: $0).isReady }.count
        return String(localized: "\(readyCount) of \(kinds.count) on")
    }

    private var moneyDistanceSection: some View {
        Section {
            NavigationLink {
                MileageRateSettingsView()
            } label: {
                LabeledContent("Mileage Rates", value: MileageRateSettingsView.rowSummary(for: model))
            }
            .accessibilityIdentifier("settingsMileageRateLink")

            Picker("Distance", selection: distanceUnitBinding) {
                Text("Automatic (\(DistanceFormatting.unitSymbol(DistanceUnit.systemDefault())))")
                    .tag(DistanceUnitPreference.system)
                Text("Miles").tag(DistanceUnitPreference.miles)
                Text("Kilometers").tag(DistanceUnitPreference.kilometers)
            }
            .accessibilityIdentifier("settingsDistanceUnitPicker")


        }
    }

    private var distanceUnitBinding: Binding<DistanceUnitPreference> {
        Binding(
            get: { model.distanceUnitPreference },
            set: { model.setDistanceUnitPreference($0) }
        )
    }

    private var dataSection: some View {
        @Bindable var model = model
        return Section {
            Toggle("iCloud Sync", isOn: syncEnabledBinding)
                .disabled(!model.syncToggleAvailable)
                .accessibilityIdentifier("settingsSyncToggle")

            AppLockToggleRow(appLock: model.appLock)

            Toggle("Show Trips in Siri & Search", isOn: $model.siriIndexingEnabled)
                .accessibilityIdentifier("settingsSiriIndexingToggle")

            // Mac windows have no Lock Screen, and drive completions only
            // happen on the capturing iPhone.
            if model.platform.hasLockScreen {
                Toggle("Classify Drives from Lock Screen", isOn: tripCompletionNotificationsBinding)
                    .accessibilityIdentifier("settingsTripCompletionNotificationsToggle")
            }

            if model.legacyReportArtifactCount > 0 {
                Button("Remove Old Saved Reports…", role: .destructive) {
                    showingReportCleanup = true
                }
                .accessibilityIdentifier("settingsRemoveOldReports")
            }
        } footer: {
            if model.syncChangeRequiresRelaunch {
                Text(syncRelaunchMessage)
            }
        }
    }

    /// Turning the Lock Screen prompt on is the permission request: the
    /// system dialog appears if undecided, and a prior denial jumps straight
    /// to the app's page in Settings (the toggle stays on so the preference
    /// takes effect once permission is granted there).
    private var tripCompletionNotificationsBinding: Binding<Bool> {
        Binding(
            get: { model.tripCompletionNotificationsEnabled },
            set: { enabled in
                model.tripCompletionNotificationsEnabled = enabled
                guard enabled else { return }
                if model.requestPermission(.notifications) == .openSettingsNeeded,
                   let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
        )
    }

    private var syncEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.syncEnabled },
            set: { enabled in
                do {
                    switch try model.requestSyncPreferenceChange(to: enabled) {
                    case .applied:
                        break
                    case .confirmationRequired(let preflight):
                        syncEnablePreflight = preflight
                    }
                } catch {
                    model.present(error, .saveSettings)
                }
            }
        )
    }

    private var syncRelaunchMessage: String {
        switch (model.platform.isMac, model.syncEnabled) {
        case (true, true):
            String(localized: "Quit and reopen Mileager to begin combining with iCloud.")
        case (true, false):
            String(localized: "Quit and reopen Mileager to stop iCloud Sync on this Mac.")
        case (false, true):
            String(localized: "Close and reopen Mileager to begin combining with iCloud.")
        case (false, false):
            String(localized: "Close and reopen Mileager to stop iCloud Sync on this device.")
        }
    }

    private var purposesSummary: String {
        model.businessPurposePresets.first ?? String(localized: "None")
    }

    private var supportLegalSection: some View {
        @Bindable var model = model
        return Section {
            Toggle("Detailed Diagnostics", isOn: $model.detailedDiagnosticsEnabled)
                .accessibilityIdentifier("settingsDetailedDiagnosticsToggle")

            Button {
                showingDiagnosticsConsent = true
            } label: {
                if diagnosticsExportInProgress {
                    ProgressView("Preparing Report")
                } else {
                    Text("Report Issue")
                }
            }
            .disabled(diagnosticsExportInProgress)
            .accessibilityIdentifier("settingsReportIssueButton")
            .fullWidthListRowSeparator()

            Button(role: .destructive) {
                showingResetConfirmation = true
            } label: {
                Text("Reset App")
            }
            .disabled(model.resetInProgress)
            .accessibilityIdentifier("settingsResetAppButton")

            if model.resetInProgress {
                ProgressView("Resetting...")
                    .fullWidthListRowSeparator()
            }

            if let resetStatusMessage = model.resetStatusMessage {
                Text(resetStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let resetError = model.resetError {
                Text(resetError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } footer: {
            appVersionFooter
        }
    }

    private var appVersionFooter: some View {
        VStack(spacing: 4) {
            Text(appVersionText)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settingsAppVersion")

            Link("Created by David Degner", destination: Self.creatorWebsiteURL)
                .tint(MileageTheme.appTint)
                .accessibilityIdentifier("settingsCreatorLink")

            // One line where it fits (wider phones), stacked on narrow ones.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    privacyPolicyLink
                    Text("·").foregroundStyle(.secondary)
                    termsAccuracyNoticesLink
                }
                VStack(spacing: 4) {
                    privacyPolicyLink
                    termsAccuracyNoticesLink
                }
            }
            .tint(MileageTheme.appTint)

            Text("These are estimates for your own records, not tax advice.")
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .accessibilityIdentifier("settingsEstimateDisclaimer")
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
        .padding(.top, 12)
    }

    private var privacyPolicyLink: some View {
        Button("Privacy Policy") { legalPage = .privacy }
            .accessibilityIdentifier("settingsPrivacyPolicyLink")
    }

    private var termsAccuracyNoticesLink: some View {
        Button("Terms, Accuracy & Notices") { legalPage = .terms }
            .accessibilityIdentifier("settingsTermsLink")
    }

    private enum LegalPage: Hashable, Identifiable {
        case privacy
        case terms
        var id: Self { self }
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (.some(version), .some(build)):
            return String(localized: "Version \(version) (\(build))")
        case let (.some(version), .none):
            return String(localized: "Version \(version)")
        case let (.none, .some(build)):
            return String(localized: "Build \(build)")
        case (.none, .none):
            return String(localized: "Version unknown")
        }
    }

    private var trackingActionRows: some View {
        let canPauseTracking = model.trackingActive && activePauseUntil == nil
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Button(role: canPauseTracking ? .destructive : nil) {
                if canPauseTracking {
                    model.stopTracking()
                } else if model.trackingActive {
                    model.resume()
                } else {
                    model.startTracking()
                }
            } label: {
                Image(systemName: canPauseTracking ? "stop.fill" : "play.fill")
                    .font(.title2.weight(.semibold))
                    .frame(width: trackingButtonContentSize, height: trackingButtonContentSize)
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel(trackingActionAccessibilityLabel)
            .accessibilityIdentifier("settingsStartStopTrackingButton")

            Button {
                model.pauseToday()
            } label: {
                Label("Today", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity, minHeight: trackingButtonContentSize)
            }
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Pause Until Midnight")
            .accessibilityIdentifier("settingsPauseTodayButton")
            .disabled(!canPauseTracking)

            Button {
                vacationRestartDate = defaultVacationRestartDate
                showingVacationPause = true
            } label: {
                Label("Vacation", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity, minHeight: trackingButtonContentSize)
            }
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Vacation Pause")
            .accessibilityIdentifier("settingsVacationPauseButton")
            .disabled(!canPauseTracking)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .fullWidthListRowSeparator()
    }

    private var trackingActionAccessibilityLabel: String {
        if !model.trackingActive { return String(localized: "Start Tracking") }
        if activePauseUntil != nil { return String(localized: "Resume Tracking") }
        return String(localized: "Stop Tracking")
    }

    private var defaultVacationRestartDate: Date {
        Calendar.current.startOfDay(for: Date().addingTimeInterval(7 * 24 * 60 * 60))
    }

    // Deliberately no `> Date()` filter: an expired-but-unsettled pause must
    // show as paused rather than masquerade as active tracking — auto-resume
    // clears `trackingPausedUntil` moments later, but never lie in the gap.
    private var activePauseUntil: Date? {
        model.health.trackingPausedUntil
    }

    private func prepareDiagnosticsReport(days: Int) {
        guard !diagnosticsExportInProgress else { return }
        diagnosticsExportInProgress = true
        Task { @MainActor in
            defer { diagnosticsExportInProgress = false }
            await Task.yield()
            guard let report = await model.prepareDiagnosticsSupportArchive(days: days) else { return }
            pendingDiagnosticsReport = report
            showingDiagnosticsConsent = false
        }
    }

    @ViewBuilder
    private func diagnosticsReportSheet(for item: DiagnosticsReportItem) -> some View {
        #if canImport(MessageUI)
        if DiagnosticsMailComposeView.canSendMail {
            DiagnosticsMailComposeView(report: item) {
                item.removeTemporaryFiles()
                diagnosticsReport = nil
            }
        } else {
            ActivityShareSheet(items: [item.messageBody, item.url]) {
                item.removeTemporaryFiles()
                diagnosticsReport = nil
            }
        }
        #else
        ActivityShareSheet(items: [item.messageBody, item.url]) {
            item.removeTemporaryFiles()
            diagnosticsReport = nil
        }
        #endif
    }

    private static let creatorWebsiteURL = URL(string: "https://www.daviddegner.com")!
}

private struct AppLockToggleRow: View {
    var appLock: AppLockController

    var body: some View {
        Toggle(toggleTitle, isOn: Binding(
            get: { appLock.isEnabled },
            set: { newValue in Task { await appLock.requestSetEnabled(newValue) } }
        ))
        .disabled(!appLock.isAvailable)
        .accessibilityIdentifier("settingsAppLockToggle")
        .task { appLock.refreshAvailability() }
    }

    private var toggleTitle: String {
        switch appLock.biometryType {
        case .faceID: String(localized: "Require Face ID")
        case .touchID: String(localized: "Require Touch ID")
        default: String(localized: "App Lock")
        }
    }
}
