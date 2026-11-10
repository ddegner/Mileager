import AppCore
import AppIntents
import Foundation

enum DriveStartTriggerAppEnum: String, AppEnum {
    case vehicleBluetooth
    case carPlay
    case charger
    case manual

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Drive Start Trigger")
    static let caseDisplayRepresentations: [DriveStartTriggerAppEnum: DisplayRepresentation] = [
        .vehicleBluetooth: DisplayRepresentation(
            title: "Vehicle Bluetooth",
            synonyms: ["Car Bluetooth", "Bluetooth"]
        ),
        .carPlay: "CarPlay",
        .charger: "Charger",
        .manual: "Manual"
    ]

    var domainTrigger: DriveStartExternalTrigger {
        switch self {
        case .vehicleBluetooth:
            .vehicleBluetooth
        case .carPlay:
            .carPlay
        case .charger:
            .charger
        case .manual:
            .manual
        }
    }
}

struct ArmDriveStartIntent: AppIntent {
    static let title: LocalizedStringResource = "Check for Drive"
    static let description = IntentDescription(
        "Starts a short watch window and confirms the trip only after driving movement is detected."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Trigger")
    var trigger: DriveStartTriggerAppEnum

    init() {
        trigger = .vehicleBluetooth
    }

    init(trigger: DriveStartTriggerAppEnum) {
        self.trigger = trigger
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Check for a drive after \(\.$trigger)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try DriveStartIntentPerformer.armDriveStart(trigger: trigger)
        return .result()
    }
}

struct StartDriveOpeningAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Mileager and Start Drive"
    static let description = IntentDescription("Checks for a drive and opens Mileager.")
    static let openAppWhenRun = true

    @Parameter(title: "Trigger")
    var trigger: DriveStartTriggerAppEnum

    init() {
        trigger = .vehicleBluetooth
    }

    init(trigger: DriveStartTriggerAppEnum) {
        self.trigger = trigger
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Start drive from \(\.$trigger)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try DriveStartIntentPerformer.armDriveStart(trigger: trigger)
        return .result()
    }
}

enum DriveStartIntentError: Error, CustomLocalizedStringResourceConvertible {
    case captureUnavailableOnMac

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .captureUnavailableOnMac:
            "Mileager records drives on iPhone and iPad. Run this shortcut on either device instead."
        }
    }
}

enum DriveStartIntentPerformer {
    @MainActor
    static func armDriveStart(
        trigger: DriveStartTriggerAppEnum,
        platform: RunningPlatform = .current,
        preferences: Preferences = Preferences(),
        spool: PendingSignalSpool = PendingSignalSpool()
    ) throws {
        // A Mac never captures: startup refuses to bootstrap the tracker and
        // the spooled-signal drain sits behind the same guard, so a signal
        // written here would report success and then expire unread. Fail the
        // automation honestly instead of writing anything.
        guard platform.capturesDrives else { throw DriveStartIntentError.captureUnavailableOnMac }
        let now = Date()
        let stack: IntentDataStack
        do {
            stack = try IntentDataProvider.makeStack()
        } catch {
            // Before first unlock after a reboot the Class C stores cannot be
            // opened. Spool the signal to an unprotected sidecar (drained by
            // the next successful bootstrap) instead of throwing — a thrown
            // intent marks the user's automation failed for a condition they
            // cannot act on, and loses the signal entirely. Only the opaque
            try spool.save(trigger: trigger.domainTrigger, at: now)
            NotificationCenter.default.post(name: .pendingDriveStartSignalCreated, object: nil)
            return
        }
        let pending = try stack.pendingDriveStartSignalStore.save(
            trigger: trigger.domainTrigger,
            at: now,
            policy: .balanced
        )
        if preferences.detailedDiagnosticsEnabled {
            try stack.captureEventStore.save(DriveCaptureJournalEntry(
                date: now,
                category: "startSignal",
                message: "App Intent trigger \(trigger.rawValue)",
                wakeReason: trigger.rawValue,
                sampleTimestamp: pending.createdAt,
                detectionReason: "expiresAt=\(pending.expiresAt)",
                expiresAt: Calendar.current.date(
                    byAdding: .day,
                    value: DriveCaptureJournalEntry.retentionDays,
                    to: now
                ) ?? now.addingTimeInterval(Double(DriveCaptureJournalEntry.retentionDays) * 24 * 60 * 60)
            ))
        }
        // This confirms the action reached Mileager, independent of whether
        // tracking is paused or movement later becomes a recorded drive.
        preferences.recordVehicleAutomationReceipt(trigger: trigger.domainTrigger, at: now)
        NotificationCenter.default.post(name: .pendingDriveStartSignalCreated, object: nil)
    }
}

struct MileageAppShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    /// Capped at ten by App Intents — an eleventh fails the build with
    /// "Found 11 App Shortcuts, but each app may have at most 10".
    ///
    /// `OpenNeedsReviewIntent` is deliberately NOT here. It ships as a plain
    /// `AppIntent`, which Siri and the Shortcuts app still discover; only the
    /// pre-registered spoken phrase needs a slot. Giving it one means deleting
    /// a shipped shortcut, which is a product decision, not a build fix.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDriveOpeningAppIntent(trigger: .vehicleBluetooth),
            phrases: [
                "Start drive in \(.applicationName)",
                "Open \(.applicationName) for my drive"
            ],
            shortTitle: "Start Drive",
            systemImageName: "car.circle.fill"
        )
        AppShortcut(
            intent: ArmDriveStartIntent(),
            phrases: [
                "Check for a drive after \(\.$trigger) in \(.applicationName)",
                "\(\.$trigger) connected in \(.applicationName)"
            ],
            shortTitle: "Check for Drive",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: GetMonthlyBusinessMilesIntent(month: .thisMonth),
            phrases: [
                "What are my business miles in \(.applicationName)",
                "Business miles for \(\.$month) in \(.applicationName)",
                "What were my \(\.$month) business miles in \(.applicationName)",
                "How many business miles did I drive in \(\.$month) in \(.applicationName)"
            ],
            shortTitle: "Business Miles",
            systemImageName: "chart.bar.fill"
        )
        AppShortcut(
            intent: OpenMileageReportIntent(month: .thisMonth),
            phrases: [
                "Open my mileage report in \(.applicationName)",
                "Open my \(\.$month) mileage report in \(.applicationName)",
                "Show my \(\.$month) report in \(.applicationName)"
            ],
            shortTitle: "Mileage Report",
            systemImageName: "doc.richtext.fill"
        )
        AppShortcut(
            intent: AddCurrentDriveFeeIntent(),
            phrases: [
                "Add a fee to my current drive in \(.applicationName)",
                "Add \(\.$category) to my current drive in \(.applicationName)",
                "Add a fee to this drive in \(.applicationName)",
                "Add \(\.$category) to this drive in \(.applicationName)",
                "Add a fee to my current trip in \(.applicationName)",
                "Add \(\.$category) to this trip in \(.applicationName)",
                "Add a fee to \(\.$drive) in \(.applicationName)",
                "\(.applicationName) add \(\.$category) to this drive"
            ],
            shortTitle: "Drive Fee",
            systemImageName: "dollarsign.circle.fill"
        )
        AppShortcut(
            intent: ClassifyCurrentDriveIntent(),
            phrases: [
                "Classify my current drive in \(.applicationName)",
                "Mark my current drive as \(\.$classification) in \(.applicationName)",
                "Classify this drive in \(.applicationName)",
                "Mark this drive as \(\.$classification) in \(.applicationName)",
                "Classify my current trip in \(.applicationName)",
                "Mark this trip as \(\.$classification) in \(.applicationName)",
                "Classify \(\.$drive) in \(.applicationName)",
                "\(.applicationName) mark this drive as \(\.$classification)"
            ],
            shortTitle: "Classify Drive",
            systemImageName: "tag.fill"
        )
        AppShortcut(
            intent: SetCurrentDrivePurposeIntent(),
            phrases: [
                "Set current drive purpose in \(.applicationName)",
                "Set my current drive purpose in \(.applicationName)",
                "Set this drive purpose in \(.applicationName)",
                "Set my current trip purpose in \(.applicationName)",
                "Set this trip purpose in \(.applicationName)",
                "Set purpose for \(\.$drive) in \(.applicationName)",
                "Set active drive purpose in \(.applicationName)",
                "\(.applicationName) set this drive purpose"
            ],
            shortTitle: "Drive Purpose",
            systemImageName: "briefcase.fill"
        )
        AppShortcut(
            intent: AddCurrentDriveNoteIntent(),
            phrases: [
                "Add a note to my current drive in \(.applicationName)",
                "Note my current drive in \(.applicationName)",
                "Add a note to this drive in \(.applicationName)",
                "Note this drive in \(.applicationName)",
                "Add a note to my current trip in \(.applicationName)",
                "Note this trip in \(.applicationName)",
                "Add a note to \(\.$drive) in \(.applicationName)",
                "\(.applicationName) add a note to this drive"
            ],
            shortTitle: "Drive Note",
            systemImageName: "note.text"
        )
        AppShortcut(
            intent: LastDriveDurationIntent(),
            phrases: [
                "How long was my last drive in \(.applicationName)"
            ],
            shortTitle: "Last Drive Duration",
            systemImageName: "clock.arrow.circlepath"
        )
        AppShortcut(
            intent: ClassifyMostRecentTripIntent(),
            phrases: [
                "Mark my last drive as \(\.$classification) in \(.applicationName)",
                "Mark my previous drive as \(\.$classification) in \(.applicationName)",
                "Mark my latest drive as \(\.$classification) in \(.applicationName)",
                "Mark my most recent drive as \(\.$classification) in \(.applicationName)",
                "Mark my last trip as \(\.$classification) in \(.applicationName)",
                "Mark my previous trip as \(\.$classification) in \(.applicationName)",
                "Mark my latest trip as \(\.$classification) in \(.applicationName)",
                "Mark my most recent trip as \(\.$classification) in \(.applicationName)",
                "Mark the drive I just finished as \(\.$classification) in \(.applicationName)",
                "\(.applicationName) mark my last drive as \(\.$classification)"
            ],
            shortTitle: "Classify Last Trip",
            systemImageName: "tag.circle.fill"
        )
    }
}
