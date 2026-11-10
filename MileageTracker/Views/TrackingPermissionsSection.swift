import SwiftUI

struct TrackingPermissionsSection: View {
    enum Context {
        case onboarding
        case settings

        var identifierPrefix: String {
            switch self {
            case .onboarding: "onboarding"
            case .settings: "settings"
            }
        }

        var header: String? {
            switch self {
            case .onboarding, .settings: nil
            }
        }

        var intro: String? {
            switch self {
            case .onboarding, .settings:
                String(localized: "Automatic tracking uses Motion & Fitness to recognize driving and Location to record distance. Bluetooth can improve trip starts, and Notifications can remind you to review trips. Manual entry and exports work without granting these permissions.")
            }
        }

        var introIdentifier: String? {
            switch self {
            case .onboarding: "onboardingPermissionsIntroText"
            case .settings: "settingsPermissionsIntroText"
            }
        }

        var footer: String? {
            switch self {
            case .onboarding: nil
            case .settings: nil
            }
        }
    }

    enum Presentation {
        case section
        case embedded
    }

    @Environment(MileageAppModel.self) private var model
    @State private var presentedDialog: PermissionDialog?

    var context: Context
    var presentation: Presentation = .section

    var body: some View {
        Group {
            switch presentation {
            case .section:
                if context.header != nil || context.footer != nil {
                    Section {
                        content
                    } header: {
                        if let header = context.header {
                            Text(header)
                        }
                    } footer: {
                        if let footer = context.footer {
                            Text(footer)
                        }
                    }
                } else {
                    Section {
                        content
                    }
                }
            case .embedded:
                content
            }
        }
        .task {
            model.refreshPermissionStatuses()
            model.refreshConnectedBluetoothHints()
        }
        .alert(
            presentedDialog?.title ?? String(localized: "Permission"),
            isPresented: Binding(
                get: { presentedDialog != nil },
                set: { isPresented in
                    if !isPresented {
                        presentedDialog = nil
                    }
                }
            )
        ) {
            if let presentedDialog {
                switch presentedDialog {
                case .info:
                    Button("OK") {
                        self.presentedDialog = nil
                    }
                case .settings:
                    Button("Open Settings") {
                        self.presentedDialog = nil
                        model.openAppSettings()
                    }
                    Button("Cancel", role: .cancel) {
                        self.presentedDialog = nil
                    }
                case .unavailable:
                    Button("OK") {
                        self.presentedDialog = nil
                    }
                }
            }
        } message: {
            if let presentedDialog {
                Text(presentedDialog.message)
            }
        }
    }

    /// Mac copy wins over the per-context copy: the capture permissions are
    /// filtered out there, so the iPhone intro would describe rows that
    /// don't exist.
    private var introText: String? {
        if model.platform.isMac {
            return String(localized: "On your Mac, Mileager reviews and reports the trips recorded on your iPhone or iPad. Notifications can remind you to review and export mileage. Automatic drive tracking runs on iPhone and iPad.")
        }
        return context.intro
    }

    @ViewBuilder
    private var content: some View {
        if let intro = introText {
            Text(intro)
                .accessibilityIdentifier(context.introIdentifier ?? "")
        }

        ForEach(model.availableTrackingPermissionKinds) { permission in
            TrackingPermissionRow(
                permission: permission,
                state: model.permissionState(for: permission),
                identifierPrefix: context.identifierPrefix,
                action: { perform(permission) },
                infoAction: { presentedDialog = .info(permission) }
            )
        }
    }

    private func perform(_ permission: TrackingPermissionKind) {
        switch model.requestPermission(permission) {
        case .requested, .alreadyAuthorized:
            break
        case .openSettingsNeeded:
            presentedDialog = .settings(permission)
        case .unavailable:
            presentedDialog = .unavailable(permission)
        }
    }
}

private enum PermissionDialog: Identifiable {
    case info(TrackingPermissionKind)
    case settings(TrackingPermissionKind)
    case unavailable(TrackingPermissionKind)

    var id: String {
        switch self {
        case .info(let permission):
            "info-\(permission.rawValue)"
        case .settings(let permission):
            "settings-\(permission.rawValue)"
        case .unavailable(let permission):
            "unavailable-\(permission.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .info(let permission):
            permission.title
        case .settings(let permission):
            String(localized: "\(permission.title) Access")
        case .unavailable(let permission):
            String(localized: "\(permission.title) Unavailable")
        }
    }

    var message: String {
        switch self {
        case .info(let permission):
            permission.explanation
        case .settings(let permission):
            String(localized: "Mileager cannot request this again from inside the app. You can change \(permission.title) access in Settings.")
        case .unavailable(let permission):
            String(localized: "\(permission.title) is not available on this device.")
        }
    }
}

private extension TrackingPermissionKind {
    var title: String {
        switch self {
        case .location: String(localized: "Location")
        case .motion: String(localized: "Motion & Fitness")
        case .notifications: String(localized: "Notifications")
        case .bluetooth: String(localized: "Bluetooth")
        }
    }

    var explanation: String {
        switch self {
        case .location:
            String(localized: "Gives Mileager precise coordinates so it can detect movement, save trip start and end points, estimate distance, and continue recording in the background.")
        case .motion:
            String(localized: "Helps confirm the phone is in a vehicle instead of walking, running, or sitting still, which improves start and stop decisions.")
        case .notifications:
            String(localized: "Does not detect trips. It lets Mileager remind you to review and export mileage so trips do not get forgotten.")
        case .bluetooth:
            String(localized: "Bluetooth helps Mileager recognize your car and improve automatic trip starts. Movement is still required.")
        }
    }

    var identifierBase: String {
        switch self {
        case .location: "Location"
        case .motion: "Motion"
        case .notifications: "Notifications"
        case .bluetooth: "Bluetooth"
        }
    }

    func rowIdentifier(prefix: String) -> String {
        "\(prefix)\(identifierBase)PermissionRow"
    }

    func infoIdentifier(prefix: String) -> String {
        "\(prefix)\(identifierBase)PermissionInfoButton"
    }

    func setUpIdentifier(prefix: String) -> String {
        "\(prefix)\(identifierBase)PermissionSetUpButton"
    }
}

private extension PermissionChecklistState {
    var accessibilityValue: String {
        switch self {
        case .notDetermined:
            String(localized: "Not Determined")
        case .requesting:
            String(localized: "Requesting")
        case .authorized:
            String(localized: "Authorized")
        case .partial:
            String(localized: "Partial")
        case .denied:
            String(localized: "Denied")
        case .restricted:
            String(localized: "Restricted")
        case .unavailable:
            String(localized: "Unavailable")
        }
    }
}

private enum PermissionDisplayStatus {
    case on
    case off

    init(state: PermissionChecklistState) {
        self = state.isReady ? .on : .off
    }

    var title: String {
        switch self {
        case .on: String(localized: "On")
        case .off: String(localized: "Off")
        }
    }

    var systemImage: String {
        switch self {
        case .on: "checkmark.circle.fill"
        case .off: "circle"
        }
    }

    var foregroundStyle: Color {
        switch self {
        case .on:
            .green
        case .off:
            .secondary
        }
    }

    var titleStyle: AnyShapeStyle {
        switch self {
        case .on:
            AnyShapeStyle(.primary)
        case .off:
            AnyShapeStyle(.tint)
        }
    }
}

private struct TrackingPermissionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var statusIconWidth: CGFloat = 24

    var permission: TrackingPermissionKind
    var state: PermissionChecklistState
    var identifierPrefix: String
    var action: () -> Void
    var infoAction: () -> Void

    private var status: PermissionDisplayStatus {
        PermissionDisplayStatus(state: state)
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            permissionButton

            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    if status == .off { setUpButton }
                    Spacer(minLength: 0)
                    infoButton
                }
            } else {
                if status == .off { setUpButton }
                infoButton
            }
        }
        .fullWidthListRowSeparator()
    }

    private var permissionButton: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: status.systemImage)
                    .imageScale(.large)
                    .foregroundStyle(status.foregroundStyle)
                    .frame(width: statusIconWidth)

                Text(permission.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(status.titleStyle)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(permission.title)
        .accessibilityValue(state.accessibilityValue)
        .accessibilityIdentifier(permission.rowIdentifier(prefix: identifierPrefix))
    }

    private var setUpButton: some View {
        Button("Set Up", action: action)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .font(.subheadline.weight(.medium))
            .accessibilityLabel("Set Up \(permission.title)")
            .accessibilityIdentifier(permission.setUpIdentifier(prefix: identifierPrefix))
    }

    private var infoButton: some View {
        Button(action: infoAction) {
            Image(systemName: "info.circle")
                .imageScale(.large)
                .frame(
                    minWidth: dynamicTypeSize.isAccessibilitySize ? 44 : nil,
                    minHeight: dynamicTypeSize.isAccessibilitySize ? 44 : nil
                )
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(permission.title) Info")
        .accessibilityIdentifier(permission.infoIdentifier(prefix: identifierPrefix))
    }
}
