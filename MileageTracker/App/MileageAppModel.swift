import AppCore
import AppIntents
import Combine
import CoreData
import CoreLocation
import CoreMotion
import EventKit
import Foundation
import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

enum TrackingPermissionKind: String, CaseIterable, Identifiable, Hashable {
    case motion
    case location
    case bluetooth
    case notifications

    var id: Self { self }
}

enum PermissionChecklistState: String, CaseIterable, Equatable {
    case notDetermined
    case requesting
    case authorized
    case partial
    case denied
    case restricted
    case unavailable

    var isReady: Bool {
        self == .authorized
    }

    var requiresSettings: Bool {
        switch self {
        case .denied, .restricted:
            true
        case .notDetermined, .requesting, .authorized, .partial, .unavailable:
            false
        }
    }
}

enum PermissionRequestResult: Equatable {
    case requested
    case alreadyAuthorized
    case openSettingsNeeded
    case unavailable
}

/// A request — from a deep link or a Live Activity / widget button — to open the
/// current drive's fee sheet with a category pre-selected. The `tripID` is matched
/// against the active drive's `pendingTripID` before presenting so a stale link
/// can't open a fee sheet for a drive that has already ended.
struct CurrentDriveFeeRequest: Equatable {
    var tripID: UUID
    var category: TripFeeCategory
}

/// A vehicle decision deferred until the app is safely in the foreground.
/// Unknown local connections train a future mapping; conflicts only confirm
/// the just-finished trip because both connection mappings already exist.
struct PendingVehicleConnectionDecision: Equatable, Identifiable {
    enum Kind: Equatable {
        case unknownConnection(
            hint: BluetoothDriveHint,
            suggestion: VehicleConnectionSuggestion?
        )
        case conflictingVehicles(vehicleIDs: [UUID], latchedVehicleID: UUID?)
    }

    var tripID: UUID
    var kind: Kind
    var id: UUID { tripID }
}

/// Keeps network-backed Maps behavior available to manual QA launches that use
/// `--uitesting` for an isolated store. UI-test search and route fixtures require
/// this explicit opt-in; app previews keep their route resolver offline separately.
enum MapKitTestFixturePolicy {
    static let optInArgument = "--uitesting-mapkit-fixtures"
    private static let uiTestingArgument = "--uitesting"

    static func isEnabled(arguments: [String]) -> Bool {
        arguments.contains(uiTestingArgument) && arguments.contains(optInArgument)
    }
}

@MainActor
@Observable
final class MileageAppModel {
    private static let uiTestingArgument = "--uitesting"
    private static let resetDataArgument = "--reset-data"
    private static let resetPreferencesArgument = "--reset-preferences"
    private static let skipOnboardingArgument = "--skip-onboarding"
    private static let resetOnboardingArgument = "--reset-onboarding"
    private static let enableSyncForUITestingArgument = "--enable-sync-for-uitesting"
    private static let seedDataArgument = "--seed-mileage-data"
    private static let seedAppStoreScreenshotDataArgument = "--seed-app-store-screenshot-data"
    private static let driveSelfTestArgument = "--drive-self-test"
    private static let seedCurrentDriveArgument = "--seed-current-drive"
    private static let seedVehiclesArgument = "--seed-vehicles"
    private static let seedVehicleConnectionDecisionArgument = "--seed-vehicle-connection-decision"
    private static let debugTripSnapshotArgument = "--debug-write-trip-snapshot"
    private static let seedTripSuggestionsArgument = "--seed-trip-suggestions"
    /// Seeds the review states the base fixture cannot produce. Every trip made
    /// by `createManualTrip` ends in `normalizeReviewState` and lands
    /// `.readyToExport`, so the default seed's Need Review count is zero —
    /// which left the unresolved predicate, Resolve, the badges, and the
    /// caught-up state with no fixture to be exercised against at all.
    private static let seedUnresolvedMixArgument = "--seed-unresolved-mix"
    /// DEBUG-only demo using the isolated UI-test store. Never seed the
    /// normal library, even when it is empty: it may sync to personal iCloud.
    private static let seedSuggestionDemoArgument = "--debug-seed-suggestion-demo"
    /// Selects which locale's slice of AppStoreScreenshotSeeds.json the
    /// screenshot seeder loads (e.g. `--screenshot-locale=de-DE`).
    private static let screenshotLocaleArgumentPrefix = "--screenshot-locale="
    /// Live Activities are normally forced off under `--uitesting`; screenshot
    /// runs opt back in so the Lock Screen card can be captured.
    private static let enableLiveActivityForScreenshotsArgument = "--enable-live-activity-for-screenshots"
    private static let testStoreSuffixPrefix = "--test-store-suffix="
    private static let permissionStateArgumentPrefix = "--permission-states="
    /// Forces which navigation shell mounts, regardless of device or width
    /// (e.g. `--ui-shell=split`). Lets the split-view suite run on an iPhone
    /// simulator for a fast loop, while the iPad destination proves the
    /// natural, unforced path lands in the same place.
    private static let shellOverrideArgumentPrefix = "--ui-shell="
    /// Forces Mac mode on or off (e.g. `--mac-mode=on`). `platformOverride` is
    /// reachable only from unit tests, so without this nothing above the model
    /// layer — no view, no Settings branch, no empty state — could be exercised
    /// as a Mac from a UI test. `=on|off` rather than a bare flag so a suite
    /// can force it OFF symmetrically.
    private static let macModeArgumentPrefix = "--mac-mode="

    @ObservationIgnored let mapWarming = DriveMapWarmingCoordinator()
    /// Replaced wholesale on every refresh and never edited in place, so one
    /// `didSet` is enough to keep the lookup and map warming inputs current.
    var trips: [TripSummary] = [] {
        didSet {
            tripLookupCache = nil
            mapWarming.updateTrips(trips)
        }
    }
    /// Lazily rebuilt index over `trips`. `trip(id:)` used to be a linear scan,
    /// and the root and the trip list call it once per selected row per render.
    @ObservationIgnored private var tripLookupCache: TripLookup?
    /// Becomes true only after the first real-store refresh. The navigation shell
    /// uses it to distinguish a genuinely empty install from the transient empty
    /// array before startup (and from the before-first-unlock placeholder store).
    private(set) var hasLoadedInitialTrips = false
    private(set) var odometerCheckpoints: [OdometerCheckpoint] = []
    private(set) var vehicles: [Vehicle] = []
    private(set) var primaryVehicleID: UUID?
    var health: TrackingHealth = .unknown {
        didSet {
            startTrackingByDefaultIfReady()
            refreshPermissionStates()
        }
    }
    var syncStatus: SyncStatus = .unknown
    var errorAlert: AppErrorAlert?
    var businessPurposePresets: [String] = []
    var feePresets: [TripFeePreset] = []
    var mileageRate: MileageRate = .default
    var mileageRateSchedule: MileageRateSchedule = .default
    var irsRateIsChecking = false
    var irsRateLastSuccessfulCheck: Date?
    var irsRateStatusMessage: String?
    var irsRatePendingPeriods: [IRSBusinessRatePeriod] = []
    var irsRateHasConflicts = false
    var irsRateExportStatusMessage: String?
    @ObservationIgnored var irsRateClient: any IRSBusinessRateFetching
    @ObservationIgnored let irsRateClientIsInjected: Bool
    #if DEBUG
    @ObservationIgnored private var irsRateUITestArguments: [String] = []
    #endif
    @ObservationIgnored var irsRateNow: @Sendable () -> Date = { Date() }
    @ObservationIgnored var irsRateCheckTimeout: Duration = .seconds(15)
    @ObservationIgnored var irsRateRefreshID: UUID?
    @ObservationIgnored var irsRateRefreshAdopts = false
    @ObservationIgnored var irsRatePreviousAttempt: Date?
    @ObservationIgnored var irsRateRefreshTask: Task<Void, Never>?
    @ObservationIgnored var irsRateDeadlineTask: Task<Void, Never>?
    @ObservationIgnored var irsRateRefreshWaiters: [CheckedContinuation<Bool, Never>] = []
    var legacyReportArtifactCount = 0
    var reportArtifactCleanupDecision: ReportArtifactCleanupDecision?
    var distanceUnitPreference: DistanceUnitPreference = .system
    var currencyCode: String = UnitsCurrencyStore.defaultCurrencyCode()
    /// One-shot hint shown by the Settings rate row after a currency switch:
    /// the rate's number is deliberately kept (no FX), so it may need updating.
    var trackingActive: Bool {
        didSet { preferences.automaticTrackingEnabled = trackingActive }
    }
    var automaticTripStartMode: AutomaticTripStartMode {
        didSet {
            guard automaticTripStartMode != oldValue else { return }
            preferences.automaticTripStartMode = automaticTripStartMode
            tracker?.setAutomaticTripStartMode(automaticTripStartMode)
        }
    }
    var lastVehicleAutomationReceivedAt: Date?
    var vehicleBluetoothHintsEnabled: Bool {
        didSet {
            preferences.vehicleBluetoothHintsEnabled = vehicleBluetoothHintsEnabled
            bluetoothSignalService?.setEnabled(vehicleBluetoothHintsEnabled)
            refreshPermissionStates()
        }
    }
    var syncEnabled: Bool {
        didSet {
            guard syncEnabled != oldValue else { return }
            preferences.syncEnabled = syncEnabled
            syncChangeRequiresRelaunch = sync.requiresRelaunch(forNewPreference: syncEnabled)
                || (syncAvailabilityOverrideForUITesting && syncEnabled != sync.isEnabledThisLaunch)
            checkSyncStatus()
        }
    }
    var syncChangeRequiresRelaunch = false
    var resetInProgress = false
    var resetError: String?
    var resetStatusMessage: String?
    var hasCompletedOnboarding: Bool {
        didSet { preferences.hasCompletedOnboarding = hasCompletedOnboarding }
    }
    var notificationsAuthorized = false {
        didSet { refreshPermissionStates() }
    }
    private(set) var currentDrive: CurrentDriveSummary? {
        didSet {
            reconcileLiveActivity()
            if oldValue?.pendingTripID != currentDrive?.pendingTripID {
                if let expired = oldValue?.pendingTripID { intentDonations.removeCurrentDrive(expired) }
                refreshShortcutParametersIfReady()
            }
        }
    }
    var currentDriveLiveActivitiesEnabled: Bool {
        didSet {
            preferences.currentDriveLiveActivitiesEnabled = currentDriveLiveActivitiesEnabled
            reconcileLiveActivity()
        }
    }
    var detailedDiagnosticsEnabled: Bool {
        didSet {
            guard detailedDiagnosticsEnabled != oldValue else { return }
            preferences.detailedDiagnosticsEnabled = detailedDiagnosticsEnabled
            applyDiagnosticsRecordingPolicy()
        }
    }
    var siriIndexingEnabled: Bool {
        didSet {
            preferences.siriIndexingEnabled = siriIndexingEnabled
            intentDonations.setEnabled(siriIndexingEnabled)
            spotlightIndexer?.setEnabled(siriIndexingEnabled) { [weak self] in
                try Self.spotlightFetchAllTrips(from: self)
            }
        }
    }
    /// Lock Screen "Drive finished" prompts with Business / Personal / Not a
    /// Drive actions. The Settings row requests notification permission when
    /// this turns on; the model only persists the choice.
    var tripCompletionNotificationsEnabled: Bool {
        didSet {
            guard tripCompletionNotificationsEnabled != oldValue else { return }
            preferences.tripCompletionNotificationsEnabled = tripCompletionNotificationsEnabled
            if !tripCompletionNotificationsEnabled, !isUITesting {
                TripCompletionNotifier.removeAll()
            }
        }
    }
    @ObservationIgnored private var retiredTripMaintenanceTask:
        Task<RetiredTripMaintenance.Result, Error>?
    @ObservationIgnored private var retiredTripMaintenanceTaskControllerID: ObjectIdentifier?
    @ObservationIgnored private var retiredTripMaintenanceCompletedControllerID: ObjectIdentifier?
    /// True once `startup()` has published its initial `refresh()`. The
    /// foreground maintenance retry must not run before this: it awaits the
    /// same coalesced maintenance task as the launch pass, and when its
    /// continuation resumed first its `refresh()` published
    /// `hasLoadedInitialTrips` against a store the launch pass had not yet
    /// seeded — consuming the one-shot Need Review launch redirect with zero
    /// unresolved trips (UI-test fixtures seed between the two refreshes).
    @ObservationIgnored var hasCompletedStartupDataLoad = false
    @ObservationIgnored private(set) var intentCaptureReady = false
    @ObservationIgnored let intentDonations: TripIntentDonations

    private func refreshShortcutParametersIfReady() {
        guard intentCaptureReady, !Self.isRunningHostedUnitTests else { return }
        MileageAppShortcuts.updateAppShortcutParameters()
    }

    /// Called after launch capture restoration, before slower enrichment/sync.
    private func markIntentCaptureReady() {
        guard !isAwaitingProtectedData else {
            intentCaptureReady = false
            return
        }
        refreshCurrentDriveSnapshot()
        intentCaptureReady = true
        intentDonations.setEnabled(siriIndexingEnabled)
        refreshShortcutParametersIfReady()
    }
    @ObservationIgnored private var remoteChangesObservedControllerID: ObjectIdentifier?
    @ObservationIgnored private let retiredTripMaintenanceRunner:
        @MainActor (PersistenceController) async throws -> RetiredTripMaintenance.Result
    /// Shared vehicle scope for pushed trip lists. The Mailboxes root clears it
    /// because that screen has no visible scope control and owns period-wide
    /// totals/exports; a hidden filter there would produce incomplete reports.
    /// Session-scoped on purpose — a filter that survives relaunch is a filter
    /// you forget is on.
    var vehicleFilter: TripVehicleFilter = .all
    var aiSuggestionsEnabled: Bool {
        didSet {
            guard aiSuggestionsEnabled != oldValue else { return }
            suggestionEngine.invalidateSuggestionPermissionRequests()
            preferences.aiSuggestionsEnabled = aiSuggestionsEnabled
            if aiSuggestionsEnabled {
                requestContactsAccessForSuggestions()
                scheduleSuggestionBackfill()
            } else {
                invalidateSuggestionWork(clearSuggestions: true)
            }
        }
    }
    var privateCloudComputeSuggestionsEnabled: Bool {
        didSet {
            guard privateCloudComputeSuggestionsEnabled != oldValue else { return }
            preferences.privateCloudComputeSuggestionsEnabled = privateCloudComputeSuggestionsEnabled
            (suggestionProvider as? FoundationModelsSuggestionProvider)?.preferPrivateCloudCompute = privateCloudComputeSuggestionsEnabled
            invalidateSuggestionWork(clearSuggestions: true)
            scheduleSuggestionBackfill()
        }
    }
    var privateCloudComputeSuggestionsSupported: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }
    var calendarSuggestionEvidenceEnabled: Bool {
        didSet {
            guard calendarSuggestionEvidenceEnabled != oldValue else { return }
            suggestionEngine.invalidateSuggestionPermissionRequests()
            preferences.calendarSuggestionEvidenceEnabled = calendarSuggestionEvidenceEnabled
            if calendarSuggestionEvidenceEnabled {
                requestCalendarAccessForSuggestions()
            }
            // Cached suggestions were generated with different evidence.
            regenerateSuggestions()
        }
    }
    var contactSuggestionEvidenceEnabled: Bool {
        didSet {
            guard contactSuggestionEvidenceEnabled != oldValue else { return }
            suggestionEngine.invalidateSuggestionPermissionRequests()
            preferences.contactSuggestionEvidenceEnabled = contactSuggestionEvidenceEnabled
            // Endpoint annotations changed for every cached suggestion.
            regenerateSuggestions()
        }
    }
    /// Display name of the user's own contact card ("My Card" in Settings),
    /// the source of the home/work addresses used as suggestion evidence.
    var userCardName: String?
    /// Master gate for every suggestion surface: false on devices without
    /// Apple Intelligence (or unsupported locales), where the feature must be
    /// invisible.
    var tripSuggestionsAvailable: Bool { suggestionProvider?.isAvailable ?? false }
    var tripSuggestionsConfigurable: Bool { suggestionProvider?.supportsConfiguration ?? false }
    private(set) var currentDrivePresentationRequestID: UUID?
    private(set) var currentDriveFeeRequest: CurrentDriveFeeRequest?
    private(set) var currentDriveVehicleRequestID: UUID?
    /// A Live Activity "New Leg" tap, held until the app is unlocked and the
    /// link still targets the active drive. Stored unconditionally on arrival
    /// like its siblings: the model records *what* was asked, `ContentView`
    /// decides *when* — and whether — it happens.
    private(set) var currentDriveNewLegRequestID: UUID?
    var pendingVehicleConnectionDecision: PendingVehicleConnectionDecision?
    var vehicleBluetoothAuthorizationStatus: VehicleBluetoothAuthorizationStatus = .notDetermined {
        didSet { refreshPermissionStates() }
    }
    private(set) var trackingPermissionStates: [TrackingPermissionKind: PermissionChecklistState] =
        Dictionary(uniqueKeysWithValues: TrackingPermissionKind.allCases.map { ($0, .notDetermined) })
    var driveSelfTestStatus: String?
    let appLock: AppLockController

    // Persistence and the stores derived from it are reassignable so the
    // before-first-unlock fallback (see makePersistence) can be swapped for
    // the real on-disk store once the device is unlocked. The store
    // properties are implicitly unwrapped because wireStores() assigns them
    // from init rather than inline.
    @ObservationIgnored private(set) var persistence: PersistenceController
    /// Drives shake / three-finger / ⌘Z undo. Owned here rather than being a
    /// singleton because hosted tests build many models and a shared stack
    /// would leak state between them.
    @ObservationIgnored let undoCoordinator = TripUndoCoordinator()
    @ObservationIgnored private(set) var tripStore: TripStore!
    @ObservationIgnored private var businessPurposePresetStore: BusinessPurposePresetStore!
    @ObservationIgnored private var tripFeePresetStore: TripFeePresetStore!
    @ObservationIgnored private var mileageRateStore: MileageRateStore!
    @ObservationIgnored var mileageRateScheduleStore: MileageRateScheduleStore!
    @ObservationIgnored private var reportArtifactCleanupStore: ReportArtifactCleanupStore!
    @ObservationIgnored var unitsCurrencyStore: UnitsCurrencyStore!
    @ObservationIgnored private(set) var bluetoothHintStore: BluetoothDriveHintStore!
    @ObservationIgnored private(set) var vehicleStore: VehicleStore!
    @ObservationIgnored private var diagnosticSampleStore: DiagnosticSampleStore!
    @ObservationIgnored private var captureEventStore: DriveCaptureEventStore!
    @ObservationIgnored private var pendingDriveStartSignalStore: PendingDriveStartSignalStore!
    @ObservationIgnored private var activeDriveStore: ActiveDriveStore!
    @ObservationIgnored private var automaticTripEnrichmentCoordinator: AutomaticTripEnrichmentCoordinator!
    // Internal get: MileageAppModel+Reports.swift drives report generation.
    @ObservationIgnored private(set) var reportGenerator: ReportGenerator!
    @ObservationIgnored private(set) var spotlightIndexer: TripSpotlightIndexer?
    let persistenceStoreDirectory: URL?
    /// True when running on the throwaway in-memory store because the device
    /// was still locked (before first unlock) at launch. Reset once the real
    /// store loads.
    private(set) var isAwaitingProtectedData = false
    /// False while the store is the in-memory placeholder or App Lock is
    /// engaged (locked or mid-authentication). Menu/keyboard dispatch bypasses
    /// the lock overlay's hitTest gate and the root's allowsHitTesting shield,
    /// so every `.focusedSceneValue` publication must consult this — a nil
    /// publication is what grays the ⌘-menu out.
    var isCommandSurfaceAvailable: Bool {
        !isAwaitingProtectedData && !(appLock.isEnabled && appLock.lockState != .unlocked)
    }
    @ObservationIgnored private var hasReloadedAfterProtectedData = false
    @ObservationIgnored private var deferredProtectedDataLaunchReason: MileageAppLaunchReason?
    @ObservationIgnored private var protectedDataObserver: NSObjectProtocol?
    @ObservationIgnored private var vehicleAutomationReceiptObserver: AnyCancellable?
    private let diagnostics = DiagnosticsService()
    // Internal (not private) so MileageAppModel extensions in sibling files
    // can read stored preference values.
    let preferences: Preferences
    private let sync: SyncCoordinator
    private let geocoder = EndpointGeocoder()
    private let routeResolver: any ManualRouteResolving
    @ObservationIgnored private let automaticEnrichmentScheduleOverride: ((Bool) -> Void)?
    private let permissionLocationManager = CLLocationManager()
    @ObservationIgnored private let permissionLocationAuthorizationObserver =
        PermissionLocationAuthorizationObserver()
    // Internal (not private) so MileageAppModel extensions in sibling files
    // can gate behavior for automated runs.
    let isUITesting: Bool
    // Internal (not private) so views and sibling-file extensions can adapt
    // to the review/report role the app plays on a Mac: no drive capture, no
    // capture permissions, sync-forward onboarding.
    let platform: RunningPlatform
    var driveCaptureSuppressed: Bool { isUITesting || !platform.capturesDrives }
    private let shouldSeedUITestData: Bool
    private let shouldSeedVehicles: Bool
    private let shouldSeedVehicleConnectionDecision: Bool
    private let shouldSeedAppStoreScreenshotData: Bool
    private let screenshotSeedLocale: String
    private let liveActivityScreenshotOverride: Bool
    private let shouldRunDriveSelfTest: Bool
    private let shouldSeedCurrentDrive: Bool
    private let shouldSeedTripSuggestions: Bool
    private let shouldSeedUnresolvedMix: Bool
    private let shouldSeedSuggestionDemoData: Bool
    private let shouldWriteDebugTripSnapshot: Bool
    private let syncAvailabilityOverrideForUITesting: Bool
    private let permissionStateOverridesForUITesting: [TrackingPermissionKind: PermissionChecklistState]
    /// A `let`, like `platform`: the shell must be constant for the process, or
    /// a mid-session swap could discard view state the same way a sheet's
    /// structural identity change does.
    let shellOverrideForUITesting: NavigationShell?
    @ObservationIgnored let calendarFullAccessProvider: @Sendable () -> Bool
    @ObservationIgnored private(set) var suggestionProvider: (any TripSuggestionProviding)?
    @ObservationIgnored let suggestionCacheStore: TripSuggestionCacheStore?
    @ObservationIgnored let derivedArtifactTestSuffix: String?
    /// The shared suggestion orchestrator; the model exposes its state through
    /// read-write forwarders in MileageAppModel+Suggestions. Constructed at
    /// the end of init (its dependencies capture self weakly).
    @ObservationIgnored private(set) var suggestionEngine: TripSuggestionEngine!
    @ObservationIgnored private var tracker: DriveCaptureRuntime?
    @ObservationIgnored var bluetoothSignalService: BluetoothDriveSignalService?
    @ObservationIgnored var queuedVehicleConnectionDecisions: [PendingVehicleConnectionDecision] = []
    @ObservationIgnored private var isRequestingBluetoothAuthorization = false
    @ObservationIgnored private var requestingPermissions: Set<TrackingPermissionKind> = []
    @ObservationIgnored private var permissionRefreshTasks: [TrackingPermissionKind: Task<Void, Never>] = [:]
    @ObservationIgnored private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @ObservationIgnored private var currentDriveRefreshCancellable: AnyCancellable?
    private let liveActivityController = LiveActivityController()
    // Internal (not private) so MileageAppModel extensions in sibling files
    // can gate work to the foreground.
    @ObservationIgnored var sceneIsActive = false
    private let restartAdvisor = RestartTrackingAdvisor()

    var syncToggleAvailable: Bool { sync.isAvailableInThisBuild || syncAvailabilityOverrideForUITesting }
    var syncRunningThisLaunch: Bool { sync.isEnabledThisLaunch }
    var defaultBusinessPurpose: String { businessPurposePresets.first ?? "" }
    static var isRunningHostedUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestBundlePath"]?.contains("MileageTrackerTests.xctest") == true
    }

    init(
        previewMode: Bool = false,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        preferences: Preferences? = nil,
        protectedDataAvailableOverride: Bool? = nil,
        intentDonationsOverride: TripIntentDonations? = nil,
        platformOverride: RunningPlatform? = nil,
        suggestionProvider: (any TripSuggestionProviding)? = nil,
        suggestionCacheStoreOverride: TripSuggestionCacheStore? = nil,
        irsRateClient: (any IRSBusinessRateFetching)? = nil,
        automaticEnrichmentScheduleOverride: ((Bool) -> Void)? = nil,
        calendarFullAccessProvider: @escaping @Sendable () -> Bool = {
            EKEventStore.authorizationStatus(for: .event) == .fullAccess
        },
        retiredTripMaintenanceRunner: @escaping @MainActor (
            PersistenceController
        ) async throws -> RetiredTripMaintenance.Result = { controller in
            try await RetiredTripMaintenance(persistence: controller).run()
        }
    ) {
        let isUITesting = previewMode || arguments.contains(Self.uiTestingArgument)
        self.isUITesting = isUITesting
        #if DEBUG
        let irsFixture = IRSRateUITestFixture.configuration(arguments: arguments)
        self.irsRateClient = irsRateClient ?? irsFixture?.client ?? IRSBusinessRateClient()
        self.irsRateClientIsInjected = irsRateClient != nil || irsFixture != nil
        if let irsFixture {
            self.irsRateNow = { irsFixture.now }
            self.irsRateUITestArguments = arguments
        }
        #else
        self.irsRateClient = irsRateClient ?? IRSBusinessRateClient()
        self.irsRateClientIsInjected = irsRateClient != nil
        #endif
        intentDonations = intentDonationsOverride ?? TripIntentDonations()
        // The Swift init parameter wins over the launch argument, which wins
        // over the process. Parameter-first keeps every existing unit test
        // byte-identical.
        let platform = platformOverride
            ?? (isUITesting ? Self.macModeOverride(from: arguments) : nil)
            ?? .current
        self.platform = platform
        let fixtureSeedingEnabled = Self.allowsFixtureSeeding(
            previewMode: previewMode,
            arguments: arguments
        )
        shouldSeedUITestData = fixtureSeedingEnabled && arguments.contains(Self.seedDataArgument)
        shouldSeedVehicles = fixtureSeedingEnabled && arguments.contains(Self.seedVehiclesArgument)
        shouldSeedVehicleConnectionDecision = isUITesting
            && arguments.contains(Self.seedVehicleConnectionDecisionArgument)
        shouldSeedAppStoreScreenshotData = fixtureSeedingEnabled
            && arguments.contains(Self.seedAppStoreScreenshotDataArgument)
        screenshotSeedLocale = arguments.first { $0.hasPrefix(Self.screenshotLocaleArgumentPrefix) }
            .map { String($0.dropFirst(Self.screenshotLocaleArgumentPrefix.count)) } ?? "en-US"
        liveActivityScreenshotOverride = isUITesting && arguments.contains(Self.enableLiveActivityForScreenshotsArgument)
        permissionStateOverridesForUITesting = isUITesting ? Self.permissionStateOverrides(from: arguments) : [:]
        shellOverrideForUITesting = isUITesting ? Self.shellOverride(from: arguments) : nil
        #if DEBUG
        shouldRunDriveSelfTest = isUITesting && arguments.contains(Self.driveSelfTestArgument)
        shouldWriteDebugTripSnapshot = arguments.contains(Self.debugTripSnapshotArgument)
        shouldSeedSuggestionDemoData = fixtureSeedingEnabled
            && arguments.contains(Self.seedSuggestionDemoArgument)
        #else
        shouldRunDriveSelfTest = false
        shouldWriteDebugTripSnapshot = false
        shouldSeedSuggestionDemoData = false
        #endif
        shouldSeedCurrentDrive = isUITesting && arguments.contains(Self.seedCurrentDriveArgument)
        shouldSeedTripSuggestions = isUITesting && arguments.contains(Self.seedTripSuggestionsArgument)
        shouldSeedUnresolvedMix = fixtureSeedingEnabled
            && arguments.contains(Self.seedUnresolvedMixArgument)
        syncAvailabilityOverrideForUITesting = isUITesting
            && !arguments.contains(Self.skipOnboardingArgument)
            && (arguments.contains(Self.resetOnboardingArgument) || arguments.contains(Self.enableSyncForUITestingArgument))
        let usesMapKitFixtures = previewMode || MapKitTestFixturePolicy.isEnabled(arguments: arguments)
        routeResolver = usesMapKitFixtures ? UITestManualRouteResolver() : AppleManualRouteResolver()
        self.automaticEnrichmentScheduleOverride = automaticEnrichmentScheduleOverride
        self.calendarFullAccessProvider = calendarFullAccessProvider
        self.retiredTripMaintenanceRunner = retiredTripMaintenanceRunner

        let resolvedPreferences = preferences ?? Self.makePreferences(isUITesting: isUITesting)
        self.preferences = resolvedPreferences
        irsRateLastSuccessfulCheck = resolvedPreferences.irsRateLastSuccessfulCheck
        if isUITesting, arguments.contains(Self.resetPreferencesArgument) {
            resolvedPreferences.clearAll()
            resolvedPreferences.hasCompletedOnboarding = false
        }
        if isUITesting, arguments.contains(Self.resetOnboardingArgument) {
            resolvedPreferences.hasCompletedOnboarding = false
        }
        if previewMode || (isUITesting && arguments.contains(Self.skipOnboardingArgument)) {
            resolvedPreferences.hasCompletedOnboarding = true
        }
        if shouldSeedSuggestionDemoData {
            resolvedPreferences.hasCompletedOnboarding = true
        }
        let storedSyncEnabled = previewMode ? false : resolvedPreferences.syncEnabled
        let sync = SyncCoordinator(isUITesting: isUITesting, storedSyncEnabled: storedSyncEnabled)
        self.sync = sync

        syncEnabled = storedSyncEnabled
        hasCompletedOnboarding = resolvedPreferences.hasCompletedOnboarding
        trackingActive = Self.initialTrackingActive(
            preferences: resolvedPreferences,
            isUITesting: isUITesting,
            capturesDrives: platform.capturesDrives
        )
        vehicleBluetoothHintsEnabled = previewMode ? false : resolvedPreferences.vehicleBluetoothHintsEnabled
        automaticTripStartMode = resolvedPreferences.automaticTripStartMode
        if fixtureSeedingEnabled, arguments.contains("--seed-vehicle-shortcut-receipt") {
            resolvedPreferences.recordVehicleAutomationReceipt(trigger: .vehicleBluetooth, at: Date())
        }
        lastVehicleAutomationReceivedAt = resolvedPreferences.lastVehicleAutomationReceivedAt
        currentDriveLiveActivitiesEnabled = if previewMode {
            false
        } else if isUITesting {
            // Normally off so Activities never interfere with automated runs;
            // screenshot captures opt back in for the Lock Screen card.
            arguments.contains(Self.enableLiveActivityForScreenshotsArgument)
        } else {
            resolvedPreferences.currentDriveLiveActivitiesEnabled
        }
        detailedDiagnosticsEnabled = previewMode
            ? false
            : resolvedPreferences.detailedDiagnosticsEnabled
        siriIndexingEnabled = isUITesting || previewMode
            ? false
            : resolvedPreferences.siriIndexingEnabled
        tripCompletionNotificationsEnabled = isUITesting || previewMode
            ? false
            : resolvedPreferences.tripCompletionNotificationsEnabled
        aiSuggestionsEnabled = resolvedPreferences.aiSuggestionsEnabled
        privateCloudComputeSuggestionsEnabled = resolvedPreferences.privateCloudComputeSuggestionsEnabled
        calendarSuggestionEvidenceEnabled = resolvedPreferences.calendarSuggestionEvidenceEnabled
        contactSuggestionEvidenceEnabled = resolvedPreferences.contactSuggestionEvidenceEnabled
        userCardName = resolvedPreferences.userCardName
        // Injected fakes (unit tests) win; UI-test runs opt in to a canned
        // provider via launch argument. The production Foundation Models
        // provider is installed at the end of init (it captures the
        // diagnostics service). Nil keeps every suggestion surface hidden.
        if let suggestionProvider {
            self.suggestionProvider = suggestionProvider
        } else if isUITesting, arguments.contains(Self.seedTripSuggestionsArgument) {
            self.suggestionProvider = UITestTripSuggestionProvider()
        }
        // UI-testing and preview runs get an authenticator that can never
        // engage, so the lock cannot interfere with automated runs. Screenshot
        // runs instead get a presentation-only authenticator so the App Lock
        // toggle renders in its normal Face ID state for capture.
        let authenticator: any DeviceAuthenticating = if shouldSeedAppStoreScreenshotData {
            ScreenshotPresentationAuthenticator()
        } else if isUITesting {
            UnavailableAuthenticator()
        } else {
            DeviceAuthenticator()
        }
        appLock = AppLockController(
            preferences: resolvedPreferences,
            authenticator: authenticator,
            platform: platform
        )

        let testStoreSuffix = Self.testStoreSuffix(from: arguments)
        derivedArtifactTestSuffix = isUITesting ? (testStoreSuffix ?? "ui-testing") : nil
        suggestionCacheStore = previewMode
            ? nil
            : suggestionCacheStoreOverride
                ?? TripSuggestionCacheStore(testSuffix: derivedArtifactTestSuffix)
        let storeDirectory: URL? = previewMode
            ? nil
            : (isUITesting ? ResetCoordinator.storeDirectoryForUITesting(suffix: testStoreSuffix) : nil)
        if isUITesting, arguments.contains(Self.resetDataArgument), let storeDirectory {
            try? FileManager.default.removeItem(at: storeDirectory)
            try? DerivedArtifactCacheRoot.removeAll(testSuffix: derivedArtifactTestSuffix)
        }

        persistenceStoreDirectory = storeDirectory
        let setup = Self.makePersistence(
            mode: sync.persistenceMode(),
            inMemory: previewMode,
            storeDirectory: storeDirectory,
            simulateBeforeFirstUnlock: protectedDataAvailableOverride == false
        )
        persistence = setup.controller
        isAwaitingProtectedData = setup.awaitingProtectedData

        // The indexer must exist before wireStores so the store's change
        // observer is attached from the first save onward. Preferences gate
        // every operation, so creating it while the toggle is off is inert.
        spotlightIndexer = TripSpotlightIndexer(
            isEnabled: { [preferences = resolvedPreferences] in
                !isUITesting && preferences.siriIndexingEnabled
            },
            vehicleName: { [weak self] vehicleID in
                self?.vehicleName(for: vehicleID)
            }
        )
        wireStores(context: persistence.container.viewContext, allowFreshRateDefaults: !isAwaitingProtectedData)

        if let initialStatus = sync.initialStatus(syncEnabledPreference: syncEnabled) {
            syncStatus = initialStatus
        }
        observeProtectedDataAvailabilityIfNeeded()
        observeLocationAuthorizationChanges()
        refreshPermissionStates()

        if self.suggestionProvider == nil, (!isUITesting || shouldSeedSuggestionDemoData), !previewMode {
            self.suggestionProvider = FoundationModelsSuggestionProvider(record: { [diagnostics] message in
                diagnostics.record(DiagnosticEvent(category: "suggestion", message: message))
            }, preferPrivateCloudCompute: privateCloudComputeSuggestionsEnabled)
        }
        suggestionEngine = makeSuggestionEngine()
        vehicleAutomationReceiptObserver = NotificationCenter.default
            .publisher(for: .pendingDriveStartSignalCreated)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshVehicleAutomationReceipt()
                }
            }
        #if DEBUG
        if fixtureSeedingEnabled, arguments.contains("--seed-tracking-paused") {
            trackingActive = true
            health.trackingPausedUntil = Date().addingTimeInterval(24 * 60 * 60)
        }
        #endif
    }

    /// Persistent fixtures are an automation capability, never a production
    /// launch-argument feature. Kept as a pure policy so Release gating has a
    /// focused regression test without opening the user's real persistent store.
    static func allowsFixtureSeeding(previewMode: Bool, arguments: [String]) -> Bool {
        !previewMode && arguments.contains(Self.uiTestingArgument)
    }

    /// Creates the stores derived from a managed object context and loads the
    /// initial published values from them. Called from `init` and again when
    /// the real store replaces the locked-launch fallback.
    private func wireStores(context: NSManagedObjectContext, allowFreshRateDefaults: Bool = true) {
        automaticTripEnrichmentCoordinator?.cancel()
        // Before any store writes: re-pointing the manager also drops a stack
        // built against the locked-launch placeholder context.
        undoCoordinator.model = self
        undoCoordinator.install(on: context)
        tripStore = TripStore(context: context)
        tripStore.changeObserver = spotlightIndexer
        businessPurposePresetStore = BusinessPurposePresetStore(context: context)
        tripFeePresetStore = TripFeePresetStore(context: context)
        mileageRateStore = MileageRateStore(context: context)
        mileageRateScheduleStore = MileageRateScheduleStore(context: context)
        reportArtifactCleanupStore = ReportArtifactCleanupStore(context: context)
        unitsCurrencyStore = UnitsCurrencyStore(context: context)
        bluetoothHintStore = BluetoothDriveHintStore(context: context)
        vehicleStore = VehicleStore(context: context)
        diagnosticSampleStore = DiagnosticSampleStore(context: context)
        captureEventStore = DriveCaptureEventStore(context: context)
        pendingDriveStartSignalStore = PendingDriveStartSignalStore(context: context)
        activeDriveStore = ActiveDriveStore(context: context)
        reportGenerator = ReportGenerator()
        distanceUnitPreference = (try? unitsCurrencyStore.fetchDistanceUnitPreference()) ?? .system
        currencyCode = (try? unitsCurrencyStore.fetchCurrencyCode()) ?? UnitsCurrencyStore.defaultCurrencyCode()
        if allowFreshRateDefaults {
            mileageRateSchedule = (try? mileageRateScheduleStore.initializeDefaultScheduleIfNeeded(
                currencyCode: currencyCode, now: irsRateNow()
            )) ?? (try? mileageRateScheduleStore.fetchSchedule()) ?? .default
        } else {
            mileageRateSchedule = (try? mileageRateScheduleStore.fetchSchedule()) ?? .default
        }
        mileageRate = mileageRateSchedule.rate(on: irsRateNow())
        normalizeLegacyTripEnrichmentStates()
        reconcileTripEnrichmentAttempts()
        automaticTripEnrichmentCoordinator = AutomaticTripEnrichmentCoordinator(
            store: tripStore,
            geocoder: geocoder,
            routeResolver: routeResolver,
            didApply: { [weak self] (tripID: UUID) in
                guard let self else { return }
                tripSuggestions[tripID] = nil
                refresh()
                scheduleSpotlightReconcile()
            }
        )

        businessPurposePresets = (try? businessPurposePresetStore.fetchPurposes()) ?? BusinessPurposePresetStore.defaultPurposes
        feePresets = (try? tripFeePresetStore.fetchPresets()) ?? []
        refreshLegacyReportArtifacts()
        reloadVehicles()
        preferences.displayDistanceUnitRaw = distanceUnit.rawValue
        try? bluetoothHintStore.migrateManualTrustOverridesIfNeeded()
        let now = Date()
        applyDiagnosticsRecordingPolicy(now: now)
        _ = try? captureEventStore.purgeExpiredEvents(now: now)
        _ = try? tripStore.purgeExpiredRawSamples(now: now)
        let pendingCutoff = Calendar.current.date(
            byAdding: .day,
            value: -PendingDriveStartSignal.retentionDays,
            to: now
        ) ?? now.addingTimeInterval(-Double(PendingDriveStartSignal.retentionDays) * 24 * 60 * 60)
        _ = try? pendingDriveStartSignalStore.purgeResolved(before: pendingCutoff)

        // Month-report donations bake the live unit/rate/currency in; the
        // indexer diffs content digests, so re-wiring after the real store
        // replaces the locked-launch fallback is idempotent.
        spotlightIndexer?.monthReportSource = TripSpotlightIndexer.MonthReportSource(
            fetchAll: { [weak self] in try Self.spotlightFetchAllTrips(from: self) },
            project: { [weak self] trips in
                guard let self else { return [] }
                return MonthlyMileageReportEntity.entities(
                    for: trips,
                    distanceUnit: distanceUnit,
                    rate: mileageRate,
                    rateSchedule: mileageRateSchedule,
                    currencyCode: currencyCode
                )
            }
        )
    }

    private func normalizeLegacyTripEnrichmentStates() {
        do {
            let changedTripCount = try tripStore.normalizeLegacyEnrichmentStates()
            if changedTripCount > 0 {
                diagnostics.record(DiagnosticEvent(
                    category: "enrichment",
                    message: "Initialized enrichment provenance for \(changedTripCount) historical trips"
                ))
            }
        } catch {
            diagnostics.record(DiagnosticEvent(
                category: "enrichment",
                message: "Historical enrichment-state migration failed: \(error.localizedDescription)"
            ))
        }
    }

    private func reconcileTripEnrichmentAttempts() {
        do {
            let removedAttemptCount = try tripStore.reconcileEnrichmentAttempts()
            if removedAttemptCount > 0 {
                diagnostics.record(DiagnosticEvent(
                    category: "enrichment",
                    message: "Removed \(removedAttemptCount) stale local enrichment attempts"
                ))
            }
        } catch {
            diagnostics.record(DiagnosticEvent(
                category: "enrichment",
                message: "Enrichment-attempt reconciliation failed: \(error.localizedDescription)"
            ))
        }
    }

    private func scheduleAutomaticTripEnrichment(startingNewSession: Bool = false) {
        guard !isAwaitingProtectedData else { return }
        if let automaticEnrichmentScheduleOverride {
            automaticEnrichmentScheduleOverride(startingNewSession)
            return
        }
        guard !isUITesting else { return }
        if startingNewSession {
            automaticTripEnrichmentCoordinator.beginEnrichmentSession()
        } else {
            automaticTripEnrichmentCoordinator.schedulePendingEnrichment()
        }
    }

    private var driveCaptureDiagnosticsMode: DriveCaptureDiagnosticsMode {
        detailedDiagnosticsEnabled ? .detailed : .standard
    }

    private func applyDiagnosticsRecordingPolicy(now: Date = Date()) {
        tracker?.setDiagnosticsMode(driveCaptureDiagnosticsMode)
        guard diagnosticSampleStore != nil,
              captureEventStore != nil,
              activeDriveStore != nil else {
            return
        }
        do {
            if !detailedDiagnosticsEnabled {
                _ = try captureEventStore.deleteAll()
            }
            let activeState = try activeDriveStore.load()
            let activeStart = [
                activeState?.candidateStartedAt,
                activeState?.startedAt,
                activeState?.pendingCompletionDraft?.startDate
            ].compactMap { $0 }.min()
            let preserveFrom = activeStart?.addingTimeInterval(-TransitTripClassifier.preTripLookbackSeconds)
            _ = try diagnosticSampleStore.applyRetentionPolicy(
                retentionDays: driveCaptureDiagnosticsMode.sampleRetentionDays,
                now: now,
                preservingFrom: preserveFrom
            )
        } catch {
            diagnostics.record(DiagnosticEvent(
                category: "diagnostics",
                message: "Failed to apply standard diagnostics retention: \(error.localizedDescription)"
            ))
        }
    }

    // MARK: - Spotlight indexing

    /// Full-store fetch used by index reconciles. Throws while the store is
    /// unavailable (before first unlock) instead of returning [] — an empty
    /// answer would make the reconcile delete every donated trip.
    private struct SpotlightStoreUnavailableError: Error {}

    private static func spotlightFetchAllTrips(from model: MileageAppModel?) throws -> [TripSummary] {
        guard let model, !model.isAwaitingProtectedData else {
            throw SpotlightStoreUnavailableError()
        }
        return try model.tripStore.fetchTrips()
    }

    private func scheduleSpotlightReconcile() {
        guard !isAwaitingProtectedData else { return }
        spotlightIndexer?.scheduleReconcile { [weak self] in
            try Self.spotlightFetchAllTrips(from: self)
        }
    }

    /// Full re-donation, for changes that alter donated snippet content without
    /// touching any trip row (vehicle rename, primary handoff on create/delete).
    // Internal: vehicle mutations in MileageAppModel+Vehicles.swift invalidate
    // the index when projected vehicle names change.
    func invalidateSpotlightIndex() {
        guard !isAwaitingProtectedData else { return }
        spotlightIndexer?.invalidateAndReconcile { [weak self] in
            try Self.spotlightFetchAllTrips(from: self)
        }
    }

    private static func makePreferences(isUITesting: Bool) -> Preferences {
        guard isUITesting,
              let defaults = UserDefaults(suiteName: "com.daviddegner.MileageTracker.UITesting") else {
            return Preferences()
        }
        return Preferences(defaults: defaults)
    }

    private static func defaultPermissionStates() -> [TrackingPermissionKind: PermissionChecklistState] {
        Dictionary(uniqueKeysWithValues: TrackingPermissionKind.allCases.map { ($0, .notDetermined) })
    }

    /// Parses `--ui-shell=stack|split`.
    ///
    /// Routed through `NavigationShell(rawValue:)` so the enum and the argument
    /// grammar cannot drift apart. An unrecognized value returns nil AND trips
    /// an assertion in DEBUG: a typo that silently fell back to the device's
    /// natural shell would make a split-view test quietly pass on the stack,
    /// which is the exact failure this argument exists to prevent.
    private static func shellOverride(from arguments: [String]) -> NavigationShell? {
        guard let argument = arguments.first(where: { $0.hasPrefix(shellOverrideArgumentPrefix) }) else {
            return nil
        }
        let raw = String(argument.dropFirst(shellOverrideArgumentPrefix.count))
        guard let shell = NavigationShell(rawValue: raw) else {
            assertionFailure("Unrecognized \(shellOverrideArgumentPrefix) value: \(raw)")
            return nil
        }
        return shell
    }

    /// Parses `--mac-mode=on|off`. An unrecognized value is ignored, so the
    /// process value still decides.
    private static func macModeOverride(from arguments: [String]) -> RunningPlatform? {
        guard let argument = arguments.first(where: { $0.hasPrefix(macModeArgumentPrefix) }) else {
            return nil
        }
        switch String(argument.dropFirst(macModeArgumentPrefix.count)) {
        case "on": return .mac
        case "off": return .iOS
        default:
            assertionFailure("Unrecognized \(macModeArgumentPrefix) value")
            return nil
        }
    }

    private static func permissionStateOverrides(
        from arguments: [String]
    ) -> [TrackingPermissionKind: PermissionChecklistState] {
        guard let argument = arguments.first(where: { $0.hasPrefix(permissionStateArgumentPrefix) }) else {
            return [:]
        }
        let rawPairs = argument.dropFirst(permissionStateArgumentPrefix.count)
            .split(separator: ",")
        var overrides: [TrackingPermissionKind: PermissionChecklistState] = [:]
        for rawPair in rawPairs {
            let parts = rawPair.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let kind = TrackingPermissionKind(rawValue: String(parts[0])),
                  let state = PermissionChecklistState(rawValue: String(parts[1])) else {
                continue
            }
            overrides[kind] = state
        }
        return overrides
    }

    // MARK: - Lifecycle

    func startup(launchReason: MileageAppLaunchReason = .foreground) async {
        refreshNotificationPermissionStatus()
        bootstrapTrackingForLaunch(reason: launchReason)
        if !isUITesting { markIntentCaptureReady() }
        if !isAwaitingProtectedData {
            do {
                let result = try await performRetiredTripMaintenance(on: persistence)
                recordRetiredTripMaintenance(result)
                observeRemoteChangesIfReady(on: persistence)
            } catch {
                // Degrade, don't abort: returning here blanked the entire app
                // (no seeding, refresh, Spotlight, or sync) on every launch as
                // long as one row kept the cleanup throwing. Continue against
                // the un-maintained store — worst case a retired row resurfaces
                // until the foreground retry in appDidBecomeActive completes
                // the purge and re-runs refresh.
                present(error, .loadData)
            }
        }
        seedAppStoreScreenshotDataIfNeeded()
        seedUITestDataIfNeeded()
        #if DEBUG
        configureIRSRateUITestScenarioIfNeeded(arguments: irsRateUITestArguments)
        #endif
        seedUnresolvedMixIfNeeded()
        seedSuggestionDemoDataIfNeeded()
        seedVehiclesIfNeeded()
        createDefaultVehicleIfNeeded()
        seedCurrentDriveIfNeeded()
        runDriveSelfTestIfNeeded()
        refreshBusinessPurposePresets()
        refreshFeePresets()
        refresh()
        hasCompletedStartupDataLoad = true
        #if DEBUG
        if isUITesting, ProcessInfo.processInfo.arguments.contains("--irs-live-self-test") {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await IRSRateLiveSelfTest.run(model: self)
            }
        }
        #endif
        scheduleIRSRateCheckOnForeground()
        if isUITesting { markIntentCaptureReady() }
        #if DEBUG
        if isUITesting,
           let search = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--open-trip-search=") }) {
            requestTripSearch(String(search.dropFirst("--open-trip-search=".count)))
        }
        TripCompletionNotifier.scheduleUITestNotificationIfNeeded(for: trips)
        #endif
        await waitForSuggestionCacheHydration()
        seedVehicleConnectionDecisionIfNeeded()
        scheduleSpotlightReconcile()
        writeDebugTripSnapshotIfNeeded()
        checkSyncStatus()
        sync.checkForRemoteChanges()
    }

    func appDidBecomeActive() {
        refreshVehicleAutomationReceipt()
        let isGenuineActivation = !sceneIsActive
        sceneIsActive = true
        reconcileSuggestionPermissionsOnForeground()
        // One foreground pass per boot is what restores background location
        // sessions after a restart — record it so the restart notice stands down.
        restartAdvisor.recordForegrounded()
        if isAwaitingProtectedData {
            // Belt-and-braces: the protected-data notification can be missed by
            // a suspended process; a foreground pass guarantees the reload runs.
            Task { @MainActor [weak self] in
                await self?.reloadPersistenceForProtectedData()
            }
        } else if hasCompletedStartupDataLoad, !hasCompletedRetiredTripMaintenance(for: persistence) {
            // Retry only for maintenance that failed on a *previous* pass.
            // During the launch activation `startup()` still owns this work:
            // joining its in-flight maintenance from here raced our
            // `refresh()` against the not-yet-run fixture seeding (see
            // `hasCompletedStartupDataLoad`).
            let controller = persistence
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await performRetiredTripMaintenance(on: controller)
                    guard persistence === controller else { return }
                    recordRetiredTripMaintenance(result)
                    observeRemoteChangesIfReady(on: controller)
                    refresh()
                    sync.checkForRemoteChanges()
                } catch {
                    // A launch error already explains the failed cleanup. Keep
                    // the task retryable for the next foreground activation.
                }
            }
        }
        if trackingActive {
            tracker?.sceneBecameActive()
            tracker?.startMonitoring()
        }
        refreshCurrentDriveSnapshot()
        // Reconcile even when both the restored and published drive are nil.
        // In that case `refreshCurrentDriveSnapshot()` is intentionally a
        // no-op, but ActivityKit may still own an orphan left by the previous
        // process. This also closes the relaunch path when the preference was
        // already turned off before launch.
        reconcileLiveActivity()
        startCurrentDriveRefreshTimer()
        if hasCompletedRetiredTripMaintenance(for: persistence) {
            refresh()
        }
        presentQueuedVehicleConnectionDecisionIfPossible()
        bluetoothSignalService?.refreshConnectedHints()
        recoverRecentVehicleConnectionDecisionIfNeeded()
        refreshTrackingHealth()
        checkSyncStatus()
        refreshNotificationPermissionStatus()
        refreshBluetoothAuthorizationStatus()
        sync.checkForRemoteChanges()
        if isGenuineActivation {
            scheduleAutomaticTripEnrichment(startingNewSession: true)
            if hasCompletedStartupDataLoad { scheduleIRSRateCheckOnForeground() }
        }
        // Donations that failed while backgrounded/locked otherwise only heal
        // at relaunch or on a CloudKit remote change; the reconcile is
        // debounced and diff-based, so this is cheap when nothing is stale.
        scheduleSpotlightReconcile()
    }

    func appDidBecomeInactive() {
        sceneIsActive = false
        invalidateSuggestionWork(clearSuggestions: false)
        automaticTripEnrichmentCoordinator?.cancel()
        tracker?.sceneBecameInactive()
    }

    func appEnteredBackground() {
        sceneIsActive = false
        cancelIRSRateCheck()
        invalidateSuggestionWork(clearSuggestions: false)
        automaticTripEnrichmentCoordinator?.cancel()
        stopCurrentDriveRefreshTimer()
        tracker?.sceneEnteredBackground()
    }

    func configureTracker() {
        guard !driveCaptureSuppressed else { return }
        guard tracker == nil else { return }
        reconcileVehicleConnectionMappings()
        let bluetoothService = BluetoothDriveSignalService(
            store: bluetoothHintStore,
            diagnostics: diagnostics,
            enabled: vehicleBluetoothHintsEnabled
        )
        bluetoothSignalService = bluetoothService

        let completionCoordinator = DriveCompletionCoordinator(
            tripStore: tripStore,
            activeDriveStore: activeDriveStore,
            diagnosticSampleStore: diagnosticSampleStore,
            bluetoothHintStore: bluetoothHintStore,
            configuration: .automatic
        )
        let service = DriveCaptureRuntime(
            activeDriveStore: activeDriveStore,
            completionCoordinator: completionCoordinator,
            diagnostics: diagnostics,
            diagnosticSampleStore: diagnosticSampleStore,
            captureEventStore: captureEventStore,
            pendingStartSignalStore: pendingDriveStartSignalStore,
            bluetoothVehicleHintProvider: { [weak self] in
                self?.bluetoothSignalService?.trustedVehicleHintActive() ?? false
            },
            routeObservationRequest: { [weak self] in
                self?.bluetoothSignalService?.refreshConnectedHints()
            },
            configuration: .automatic,
            diagnosticsMode: driveCaptureDiagnosticsMode,
            automaticTripStartMode: automaticTripStartMode
        )
        bluetoothService.onVehicleRouteObserved = { [weak service] source, date in
            service?.vehicleRouteObserved(source: source, at: date)
        }
        bluetoothService.onObservationsRecorded = { [weak service] observations in
            service?.journalVehicleRouteObservations(observations)
        }
        bluetoothService.onConnectedHintsChanged = { [weak self] hints in
            self?.handleConnectedVehicleHints(hints)
        }
        bluetoothService.onVehicleConnectionChanged = { [weak service] active, source, date in
            service?.vehicleConnectionChanged(active: active, source: source, at: date)
        }
        bluetoothService.onAuthorizationChanged = { [weak self] status in
            self?.handleBluetoothAuthorizationChanged(status)
        }
        service.onHealthChanged = { [weak self] health in
            self?.health = health
        }
        service.onActiveDriveChanged = { [weak self] currentDrive in
            guard let self else { return }
            self.publishCurrentDriveSnapshot(currentDrive)
            if currentDrive != nil {
                self.handleConnectedVehicleHints(bluetoothService.connectedHints)
            }
        }
        service.onOutput = { [weak self] output in
            if case .ignored(let reason) = output {
                self?.diagnostics.record(DiagnosticEvent(category: "detection", message: reason))
            }
        }
        service.onTripCompleted = { [weak self] saved, _, conflictingVehicleIDs in
            guard let self else { return }
            self.refresh()
            self.postTripCompletionNotificationIfNeeded(for: saved)
            self.queueVehicleConnectionDecision(
                for: saved,
                conflictingVehicleIDs: conflictingVehicleIDs
            )
            self.scheduleAutomaticTripEnrichment(startingNewSession: !self.sceneIsActive)
        }
        service.onServiceSessionUnfulfilled = { [weak self] diagnostic in
            self?.handleServiceSessionUnfulfilled(diagnostic)
        }
        service.onTrackingRestorationNeeded = { [weak self] advice in
            self?.handleTrackingRestorationNeeded(advice)
        }
        tracker = service
        handleBluetoothAuthorizationChanged(bluetoothService.authorizationStatus)
        bluetoothService.refreshConnectedHints(forceNotify: true)
        refreshCurrentDriveSnapshot()
    }

    // MARK: - Tracking controls

    /// The permission rows that make sense on this device. A Mac never
    /// captures drives, so location/motion/Bluetooth would prompt for access
    /// that can never pay off; notifications stay for review reminders.
    var availableTrackingPermissionKinds: [TrackingPermissionKind] {
        platform.capturesDrives ? TrackingPermissionKind.allCases : [.notifications]
    }

    @discardableResult
    func requestPermission(_ kind: TrackingPermissionKind) -> PermissionRequestResult {
        // Checked before beginSystemPermissionPrompt() so the overlay
        // suppression flag is never set for a prompt that won't appear.
        guard availableTrackingPermissionKinds.contains(kind) else { return .unavailable }
        refreshPermissionStatuses()
        let state = permissionState(for: kind)
        if state.isReady {
            return .alreadyAuthorized
        }
        if state.requiresSettings {
            return .openSettingsNeeded
        }
        if state == .unavailable {
            return .unavailable
        }

        requestingPermissions.insert(kind)
        refreshPermissionStates()
        // The imminent system prompt drives the scene to `.inactive`; flag it as
        // self-inflicted so the security overlay doesn't flash the privacy cover
        // behind the dialog. Cleared in `finishPermissionRequest` and when the
        // app returns to the foreground.
        appLock.beginSystemPermissionPrompt()
        switch kind {
        case .location:
            requestLocationPermission()
        case .motion:
            requestMotionPermission()
        case .notifications:
            requestNotificationPermission()
        case .bluetooth:
            requestBluetoothPermission()
        }
        schedulePostRequestPermissionRefresh(for: kind)
        return .requested
    }

    func permissionState(for kind: TrackingPermissionKind) -> PermissionChecklistState {
        trackingPermissionStates[kind] ?? .notDetermined
    }

    func refreshPermissionStatuses() {
        refreshNotificationPermissionStatus()
        refreshTrackingHealth()
        refreshBluetoothAuthorizationStatus()
        refreshPermissionStates()
    }

    func openAppSettings() {
        guard !isUITesting else { return }
        #if canImport(UIKit)
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
        #endif
    }

    private func requestLocationPermission() {
        configureTracker()
        tracker?.requestLocationPermission()
    }

    /// Refreshes the permission checklist as soon as Core Location reports an
    /// authorization or accuracy change. The polling fallback can expire during
    /// the two-step When-In-Use to Always flow and otherwise leave the row stale.
    private func observeLocationAuthorizationChanges() {
        guard !isUITesting else { return }
        permissionLocationAuthorizationObserver.onChange = { [weak self] in
            self?.refreshPermissionStatuses()
        }
        permissionLocationManager.delegate = permissionLocationAuthorizationObserver
    }

    private func requestMotionPermission() {
        configureTracker()
        tracker?.requestMotionPermission()
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        // On iPhone/iPad the onboarding odometer reading is saved with a nil
        // vehicleID, which resolves to this newly created primary vehicle. Mac
        // onboarding never creates a vehicle implicitly.
        createDefaultVehicleIfNeeded()
        refreshTrackingHealth()
        startTrackingByDefaultIfReady()
    }

    func startTracking() {
        guard platform.capturesDrives else { return }
        configureTracker()
        trackingActive = true
        tracker?.startMonitoring(rearmNoAnchorPriming: true)
    }

    /// Only background completions get a Lock Screen prompt: in the
    /// foreground the Trips list already shows the new drive, and a drive the
    /// classifier already settled has nothing to ask.
    private func postTripCompletionNotificationIfNeeded(for trip: TripSummary) {
        guard tripCompletionNotificationsEnabled,
              !isUITesting,
              !sceneIsActive,
              trip.isUnresolved else { return }
        TripCompletionNotifier.post(
            for: trip,
            unit: distanceUnit,
            businessPurposes: businessPurposePresets
        )
    }

    func refreshNotificationPermissionStatus() {
        guard !isUITesting else {
            notificationsAuthorized = false
            refreshPermissionStates()
            return
        }
        ReminderScheduler.authorizationState { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.notificationAuthorizationStatus = status
                self.notificationsAuthorized = Self.isNotificationAuthorized(status)
                if status != .notDetermined {
                    self.finishPermissionRequest(.notifications)
                }
                self.refreshPermissionStates()
            }
        }
    }

    private func requestNotificationPermission() {
        guard !isUITesting else { return }
        ReminderScheduler.requestAuthorization { [weak self] in
            Task { @MainActor in
                self?.refreshNotificationPermissionStatus()
            }
        }
    }

    func openShortcutsApp() {
        guard !isUITesting else { return }
        #if canImport(UIKit)
        guard let shortcutsURL = URL(string: "shortcuts://") else { return }
        UIApplication.shared.open(shortcutsURL)
        #endif
    }

    func refreshTrackingHealth() {
        configureTracker()
        tracker?.refreshTrackingHealth()
    }

    func stopTracking() {
        tracker?.stopMonitoring()
        trackingActive = false
    }

    func pauseUntil(_ date: Date) { tracker?.pause(until: date) }
    func pauseToday() { tracker?.pauseToday() }
    func resume() { tracker?.resume() }

    func setCurrentDriveClassification(_ classification: TripClassification?) {
        guard let id = currentDrive?.pendingTripID else { return }
        do {
            let updated = try commitCurrentDriveEdit(.classification(classification), expectedID: id)
            if classification != nil { intentDonations.classifiedCurrentDrive(updated) }
        } catch { present(error, .saveChanges) }
    }

    func setCurrentDriveBusinessPurpose(_ purpose: String?) {
        guard let id = currentDrive?.pendingTripID else { return }
        do {
            let previous = currentDrive?.classification
            let updated = try commitCurrentDriveEdit(.purpose(purpose), expectedID: id)
            if previous != updated.classification { intentDonations.classifiedCurrentDrive(updated) }
        } catch { present(error, .saveChanges) }
    }

    /// Shared by UI and intents. Callers donate only UI actions, after this
    /// transaction returns; system-invoked intents already donate themselves.
    @discardableResult
    func commitCurrentDriveEdit(_ edit: CurrentDriveEdit, expectedID: UUID) throws -> CurrentDriveSummary {
        guard isCommandSurfaceAvailable else { throw TripIntentError.appLocked }
        let updated: CurrentDriveSummary
        if let tracker {
            updated = try tracker.commitCurrentDriveEdit(edit, expectedID: expectedID)
        } else {
            guard let activeDriveStore, let state = try activeDriveStore.load() else {
                throw CurrentDriveEditError.driveNoLongerCurrent
            }
            var reducer = DriveCaptureReducer(state: state)
            updated = try reducer.commitCurrentDriveEdit(edit, expectedID: expectedID) { state in
                try activeDriveStore.save(state)
            }
        }
        refreshCurrentDriveSnapshot()
        return updated
    }

    func setCurrentDriveVehicle(_ vehicleID: UUID?) {
        if let tracker {
            tracker.setCurrentDriveVehicle(vehicleID)
        } else {
            mutateStoredCurrentDrive { reducer in
                reducer.setCurrentDriveVehicle(vehicleID)
            }
        }
        refreshCurrentDriveSnapshot()
    }

    /// Applies an already user-confirmed CarPlay/Bluetooth mapping without
    /// turning it into a manual override. Reducer policy latches the first
    /// vehicle and records later disagreements without switching.
    func observeMappedVehicleConnection(_ vehicleID: UUID?) {
        if let tracker {
            tracker.observeMappedVehicleConnection(vehicleID)
        } else {
            mutateStoredCurrentDrive { reducer in
                reducer.observeMappedVehicleConnection(vehicleID)
            }
        }
        refreshCurrentDriveSnapshot()
    }

    func setCurrentDriveNote(_ note: String?) {
        guard let id = currentDrive?.pendingTripID else { return }
        do { _ = try commitCurrentDriveEdit(.note(note), expectedID: id) }
        catch { present(error, .saveChanges) }
    }

    func addCurrentDriveFee(_ fee: TripFee) {
        if let tracker {
            tracker.addCurrentDriveFee(fee)
        } else {
            mutateStoredCurrentDrive { reducer in
                reducer.appendCurrentDriveFee(fee)
            }
        }
        refreshCurrentDriveSnapshot()
    }

    /// Saves the drive recorded so far as a completed trip and keeps recording a
    /// new leg from the same moment ("New Leg" in the live drive bar).
    /// Saves the drive recorded so far as a completed trip and keeps recording a
    /// new leg from the same moment ("New Leg" on the live drive bar and on the
    /// Live Activity).
    ///
    /// The `tracker == nil` branch is the capture-suppressed fixture path —
    /// `driveCaptureSuppressed` is `isUITesting || !platform.capturesDrives`, and
    /// on a Mac the bar never renders because the active-drive store is
    /// Local-only. It splits the reducer state and saves it, which is what
    /// `testNewLegKeepsBarRecordingAndResetsClassification` asserts, but the
    /// finished leg only reaches `state.pendingCompletionDraft`; no `TripEntity`
    /// is written until a `DriveCaptureRuntime` runs
    /// `completePendingDraftIfNeeded()`, which by definition never happens while
    /// capture is suppressed. That is deliberate — materializing the trip here
    /// would mean reimplementing `DriveCompletionCoordinator`'s discard rules and
    /// vehicle attribution in the model, where the two copies would drift.
    ///
    /// The Live Activity's deep link never reaches that branch: the link
    /// foregrounds the app, where `bootstrapTrackingForLaunch` has already
    /// configured a tracker.
    func startNewLegNow() {
        if let tracker {
            tracker.splitCurrentDriveNow()
        } else {
            // Not an assertion — this branch is the seeded UI-test path, where
            // firing would be a false alarm. A diagnostic instead means a real
            // on-device occurrence shows up in the capture log rather than
            // vanishing.
            if !isUITesting {
                diagnostics.record(DiagnosticEvent(
                    category: "detection",
                    message: "Split requested with no capture runtime; leg parked as a pending draft"
                ))
            }
            mutateStoredCurrentDrive { reducer in
                reducer.splitCurrentRecording(at: Date())
            }
        }
        refreshCurrentDriveSnapshot()
        refresh()
    }

    func handleOpenURL(_ url: URL) {
        switch DeepLinkRoute.parse(url) {
        case .currentDrive(let tripID):
            currentDrivePresentationRequestID = tripID
        case .currentDriveVehicle(let tripID):
            currentDriveVehicleRequestID = tripID
        case .currentDriveFee(let tripID, let category):
            currentDriveFeeRequest = CurrentDriveFeeRequest(tripID: tripID, category: category)
        case .currentDriveNewLeg(let tripID):
            // Queue only. `.onOpenURL` fires while the app may still be locked,
            // mid-onboarding, or on the pre-first-unlock placeholder store;
            // splitting here would be exactly the App Lock bypass this route
            // exists to avoid. ContentView performs it once the gates pass.
            currentDriveNewLegRequestID = tripID
        case nil:
            return
        }
    }

    func clearCurrentDrivePresentationRequest() {
        currentDrivePresentationRequestID = nil
    }

    func clearCurrentDriveFeeRequest() {
        currentDriveFeeRequest = nil
    }

    func clearCurrentDriveVehicleRequest() {
        currentDriveVehicleRequestID = nil
    }

    func clearCurrentDriveNewLegRequest() {
        currentDriveNewLegRequestID = nil
    }

    private func refreshCurrentDriveSnapshot() {
        let next: CurrentDriveSummary?
        if let tracker {
            next = tracker.activeDriveSummary
        } else if let activeDriveStore {
            next = (try? activeDriveStore.load())?.currentDriveSummary()
        } else {
            next = nil
        }
        // Assign only on change: the 15s refresh timer otherwise republishes an
        // identical value, invalidating every view bound to the model and re-running
        // Live Activity reconciliation for nothing.
        publishCurrentDriveSnapshot(next)
    }

    private func publishCurrentDriveSnapshot(_ summary: CurrentDriveSummary?) {
        let next = hydrateCurrentDriveVehicle(in: summary)
        guard next != currentDrive else { return }
        currentDrive = next
    }

    private func hydrateCurrentDriveVehicle(in summary: CurrentDriveSummary?) -> CurrentDriveSummary? {
        guard var summary else { return nil }

        let resolvedVehicle: Vehicle?
        if let vehicleID = summary.vehicleID {
            resolvedVehicle = vehicles.first { $0.id == vehicleID }
        } else if vehicles.count == 1 {
            // A sole configured vehicle is unambiguous even though the trip can
            // retain nil as its implicit/default vehicle assignment.
            resolvedVehicle = vehicles.first
        } else {
            resolvedVehicle = nil
        }

        summary.vehicle = resolvedVehicle.map {
            CurrentDriveVehicleSnapshot(
                id: $0.id,
                name: $0.name,
                symbolName: $0.symbolName,
                colorHex: $0.colorHex,
                isConfirmed: summary.vehicleID != nil || vehicles.count == 1
            )
        }
        return summary
    }

    private func startCurrentDriveRefreshTimer() {
        currentDriveRefreshCancellable?.cancel()
        currentDriveRefreshCancellable = Timer
            .publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshCurrentDriveSnapshot()
            }
    }

    private func stopCurrentDriveRefreshTimer() {
        currentDriveRefreshCancellable?.cancel()
        currentDriveRefreshCancellable = nil
    }

    private func reconcileLiveActivity() {
        guard platform.hasLockScreen else { return }
        guard !isUITesting || liveActivityScreenshotOverride else { return }
        liveActivityController.reconcile(
            currentDrive: currentDrive,
            sceneIsActive: sceneIsActive,
            enabled: currentDriveLiveActivitiesEnabled,
            distanceUnit: distanceUnit
        )
    }

    private func mutateStoredCurrentDrive(_ mutation: (inout DriveCaptureReducer) -> [DriveCaptureOutput]) {
        do {
            // Guarded like every sibling read (`:723`, the snapshot refresh, and
            // the seeding path): the store is an implicitly-unwrapped optional
            // only because it is assigned after init and swapped again when the
            // pre-first-unlock fallback stack is replaced.
            guard let activeDriveStore, let state = try activeDriveStore.load() else { return }
            var reducer = DriveCaptureReducer(state: state)
            // Outputs are an emptiness test only — this path has no runtime to
            // hand them to. Note `splitCurrentRecording` returns `[.ignored]`,
            // not `[]`, when it refuses an empty leg, so that case falls through
            // to a save of byte-identical state. Harmless.
            let outputs = mutation(&reducer)
            guard !outputs.isEmpty else { return }
            try activeDriveStore.save(reducer.state)
        } catch {
            present(error, .saveChanges)
        }
    }


    // MARK: - Bluetooth

    private func requestBluetoothPermission() {
        configureTracker()
        guard !isUITesting else {
            vehicleBluetoothAuthorizationStatus = .notDetermined
            vehicleBluetoothHintsEnabled = false
            return
        }

        isRequestingBluetoothAuthorization = true
        bluetoothSignalService?.requestBluetoothAuthorization()
    }

    func refreshBluetoothAuthorizationStatus() {
        guard !isUITesting else {
            vehicleBluetoothAuthorizationStatus = .notDetermined
            return
        }
        configureTracker()
        bluetoothSignalService?.refreshBluetoothAuthorizationStatus()
    }

    func refreshConnectedBluetoothHints() {
        bluetoothSignalService?.refreshConnectedHints()
    }

    func refreshPermissionStates() {
        if isUITesting, !permissionStateOverridesForUITesting.isEmpty {
            trackingPermissionStates = Self.defaultPermissionStates()
                .merging(permissionStateOverridesForUITesting) { _, override in override }
            return
        }

        trackingPermissionStates = Dictionary(uniqueKeysWithValues: TrackingPermissionKind.allCases.map { kind in
            (kind, computedPermissionState(for: kind))
        })
    }

    private func handleBluetoothAuthorizationChanged(_ status: VehicleBluetoothAuthorizationStatus) {
        vehicleBluetoothAuthorizationStatus = status
        switch status {
        case .allowed:
            if isRequestingBluetoothAuthorization || vehicleBluetoothHintsEnabled {
                vehicleBluetoothHintsEnabled = true
                bluetoothSignalService?.refreshConnectedHints()
            }
            isRequestingBluetoothAuthorization = false
            finishPermissionRequest(.bluetooth)
        case .denied, .restricted:
            isRequestingBluetoothAuthorization = false
            vehicleBluetoothHintsEnabled = false
            finishPermissionRequest(.bluetooth)
        case .notDetermined, .unknown:
            break
        }
    }

    private func computedPermissionState(for kind: TrackingPermissionKind) -> PermissionChecklistState {
        let state = basePermissionState(for: kind)
        if requestingPermissions.contains(kind),
           !state.isReady,
           !state.requiresSettings,
           state != .unavailable {
            return .requesting
        }
        return state
    }

    private func basePermissionState(for kind: TrackingPermissionKind) -> PermissionChecklistState {
        switch kind {
        case .location:
            locationPermissionState()
        case .motion:
            motionPermissionState()
        case .bluetooth:
            bluetoothPermissionState()
        case .notifications:
            notificationPermissionState()
        }
    }

    private func locationPermissionState() -> PermissionChecklistState {
        guard !isUITesting else {
            if health.alwaysLocationAuthorized && health.preciseLocationEnabled {
                return .authorized
            }
            if health.alwaysLocationAuthorized || health.preciseLocationEnabled {
                return .partial
            }
            return .notDetermined
        }

        switch permissionLocationManager.authorizationStatus {
        case .authorizedAlways:
            return permissionLocationManager.accuracyAuthorization == .fullAccuracy ? .authorized : .partial
        case .authorizedWhenInUse:
            return .partial
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unavailable
        }
    }

    private func motionPermissionState() -> PermissionChecklistState {
        guard !isUITesting else {
            return health.motionAuthorized ? .authorized : .notDetermined
        }
        guard CMMotionActivityManager.isActivityAvailable() else {
            return .unavailable
        }

        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unavailable
        }
    }

    private func bluetoothPermissionState() -> PermissionChecklistState {
        switch vehicleBluetoothAuthorizationStatus {
        case .allowed:
            return vehicleBluetoothHintsEnabled ? .authorized : .partial
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        case .unknown:
            return .unavailable
        }
    }

    private func notificationPermissionState() -> PermissionChecklistState {
        guard !isUITesting else {
            return notificationsAuthorized ? .authorized : .notDetermined
        }

        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unavailable
        }
    }

    private static func isNotificationAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            true
        case .denied, .notDetermined:
            false
        @unknown default:
            false
        }
    }

    private func schedulePostRequestPermissionRefresh(for kind: TrackingPermissionKind) {
        permissionRefreshTasks[kind]?.cancel()
        permissionRefreshTasks[kind] = Task { [weak self] in
            let delays: [UInt64] = [
                250_000_000,
                750_000_000,
                1_500_000_000,
                3_000_000_000
            ]
            for delay in delays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.refreshPermissionStatuses()
                }
            }
            await MainActor.run {
                self?.finishPermissionRequest(kind)
            }
        }
    }

    private func finishPermissionRequest(_ kind: TrackingPermissionKind) {
        requestingPermissions.remove(kind)
        permissionRefreshTasks[kind]?.cancel()
        permissionRefreshTasks[kind] = nil
        if requestingPermissions.isEmpty {
            appLock.endSystemPermissionPrompt()
        }
        refreshPermissionStates()
    }

    // MARK: - Trips

    /// Adopts unit/currency/rate values synced in from another device (they
    /// live in the CloudKit-backed preference store); without this the UI,
    /// mirror, and Live Activity keep the old unit until relaunch.
    private func reloadRemoteCloudPreferences() {
        refreshBusinessPurposePresets()
        refreshFeePresets()
        reloadRemoteUnitsCurrency()
        refreshLegacyReportArtifacts()
    }

    // Internal so lifecycle tests can prove foreground CloudKit imports wake
    // pending enrichment without requiring a live CloudKit container.
    func handleRemoteCloudChange() {
        // A foreign import can rewrite or delete any trip, and Core Data
        // registers merged changes on the context's undo manager. Dropping the
        // stack keeps a shake from reverting someone else's sync. Idempotent by
        // design: PersistentHistoryMonitor can replay one logical import across
        // its retry delays.
        undoCoordinator.invalidate()
        normalizeLegacyTripEnrichmentStates()
        reconcileTripEnrichmentAttempts()
        refresh()
        reconcileVehicleConnectionMappings()
        reloadRemoteCloudPreferences()
        checkSyncStatus()
        scheduleSpotlightReconcile()
        if sceneIsActive {
            scheduleAutomaticTripEnrichment()
        }
    }

    private func reloadRemoteUnitsCurrency() {
        let oldUnit = distanceUnit
        distanceUnitPreference = (try? unitsCurrencyStore.fetchDistanceUnitPreference()) ?? distanceUnitPreference
        currencyCode = (try? unitsCurrencyStore.fetchCurrencyCode()) ?? currencyCode
        mileageRateSchedule = (try? mileageRateScheduleStore.fetchSchedule())
            ?? mileageRateSchedule
        mileageRate = mileageRateSchedule.rate(on: irsRateNow())
        if currencyCode != "USD", mileageRateSchedule.irsFollowingFrom != nil {
            stopFollowingIRSRate()
        }
        if distanceUnit != oldUnit {
            preferences.displayDistanceUnitRaw = distanceUnit.rawValue
            reconcileLiveActivity()
        }
    }

    @discardableResult
    func refresh() -> Bool {
        do {
            let refreshedTrips = try tripStore.fetchTrips()
            let removed = Set(trips.map(\.id)).subtracting(refreshedTrips.map(\.id))
            for id in removed { intentDonations.removeTrip(id) }
            trips = refreshedTrips
            odometerCheckpoints = try tripStore.fetchOdometerCheckpoints()
            reloadVehicles()
            let unresolvedCount = trips.filter(\.isUnresolved).count
            if !isUITesting {
                ReminderScheduler.scheduleMonthEndReview(unresolvedCount: unresolvedCount)
                ReminderScheduler.scheduleOdometerReadingReminders(multipleVehicles: multiVehicleUIActive)
            }
            if !isAwaitingProtectedData {
                // Never reconcile against the pre-unlock placeholder store: its
                // empty trip list would read as "everything settled" and wipe
                // prompts the user hasn't acted on yet.
                if !isUITesting {
                    TripCompletionNotifier.reconcileDelivered(
                        unresolvedTripIDs: Set(trips.filter(\.isUnresolved).map(\.id))
                    )
                }
                hasLoadedInitialTrips = true
                scheduleSuggestionCacheHydrationIfNeeded()
            }
            scheduleSuggestionBackfill()
            return true
        } catch {
            present(error, .loadData)
            return false
        }
    }

    /// Rebuilds published state after a Core Data undo or redo.
    ///
    /// A context-level undo bypasses `TripStore.transaction`, so no
    /// `TripChangeSet` is emitted: the published trip list and the Spotlight
    /// index would keep showing the pre-undo world without this. Stale
    /// suggestions need no explicit handling — `refresh()` schedules the
    /// suggestion backfill, whose synchronous fingerprint sweep drops any
    /// suggestion whose trip was reverted underneath it. Spotlight gets a full
    /// reconcile rather than a synthesized change set because undo can move an
    /// arbitrary set of rows in both directions at once.
    func refreshAfterUndo() {
        refresh()
        scheduleSpotlightReconcile()
    }

    private func hasCompletedRetiredTripMaintenance(
        for controller: PersistenceController
    ) -> Bool {
        retiredTripMaintenanceCompletedControllerID == ObjectIdentifier(controller)
    }

    /// Coalesces launch and foreground callers while the private-context cleanup
    /// is in flight. Completion is tied to one persistence controller so the
    /// before-first-unlock placeholder can never satisfy the real store's gate.
    private func performRetiredTripMaintenance(
        on controller: PersistenceController
    ) async throws -> RetiredTripMaintenance.Result {
        let controllerID = ObjectIdentifier(controller)
        if retiredTripMaintenanceCompletedControllerID == controllerID {
            return .init(deletedArchivedTripRows: 0, clearedRetiredAttentionRows: 0)
        }

        let task: Task<RetiredTripMaintenance.Result, Error>
        if let existing = retiredTripMaintenanceTask,
           retiredTripMaintenanceTaskControllerID == controllerID {
            task = existing
        } else {
            retiredTripMaintenanceTask?.cancel()
            let runner = retiredTripMaintenanceRunner
            task = Task { @MainActor in
                try await runner(controller)
            }
            retiredTripMaintenanceTask = task
            retiredTripMaintenanceTaskControllerID = controllerID
        }

        do {
            let result = try await task.value
            retiredTripMaintenanceCompletedControllerID = controllerID
            if retiredTripMaintenanceTaskControllerID == controllerID {
                retiredTripMaintenanceTask = nil
                retiredTripMaintenanceTaskControllerID = nil
            }
            return result
        } catch {
            if retiredTripMaintenanceTaskControllerID == controllerID {
                retiredTripMaintenanceTask = nil
                retiredTripMaintenanceTaskControllerID = nil
            }
            throw error
        }
    }

    private func recordRetiredTripMaintenance(_ result: RetiredTripMaintenance.Result) {
        guard result.deletedArchivedTripRows > 0 || result.clearedRetiredAttentionRows > 0 else {
            return
        }
        // Ran on a private background context that merges into the view
        // context, so rows moved with no change notification we could scope to.
        undoCoordinator.invalidate()
        diagnostics.record(DiagnosticEvent(
            category: "sync",
            message: "Retired trip maintenance deleted "
                + "\(result.deletedArchivedTripRows) archived rows and cleared "
                + "\(result.clearedRetiredAttentionRows) obsolete attention rows"
        ))
    }

    /// Observation starts only after retired-state maintenance has completed for
    /// this exact store. Persistent history is drained immediately by the
    /// caller, so imports received during launch are recovered without allowing
    /// two cleanup passes to overlap.
    private func observeRemoteChangesIfReady(
        on controller: PersistenceController
    ) {
        let controllerID = ObjectIdentifier(controller)
        guard hasCompletedRetiredTripMaintenance(for: controller),
              remoteChangesObservedControllerID != controllerID else {
            return
        }
        sync.observeRemoteChanges(in: controller) { [weak self] in
            self?.handleRemoteCloudChange()
        }
        remoteChangesObservedControllerID = controllerID
    }

    @discardableResult
    func loadSampleData() -> Bool {
        guard !isAwaitingProtectedData else { return false }
        // Never on a Mac: sample trips seed the Cloud-configuration store, so
        // with sync enabled (or enabled later) they would merge into the
        // user's production CloudKit library on the relaunch onboarding just
        // instructed — the same seeding-vs-import hazard
        // createDefaultVehicleIfNeeded guards. The Mac empty state hides the
        // button; this is the belt behind it.
        guard !platform.isMac else { return false }
        do {
            guard try tripStore.fetchTrips().isEmpty else {
                present(
                    String(localized: "Sample data can only be loaded when there are no trips."),
                    .sampleData
                )
                return false
            }
            try seedSampleTrips()
            refreshBusinessPurposePresets()
            refresh()
            return true
        } catch {
            present(error, .sampleData)
            refresh()
            return false
        }
    }

    func trip(id: UUID?) -> TripSummary? {
        guard let id else { return nil }
        return tripLookup.byID[id]
    }

    /// Every loaded trip's identifier as one set — what selection pruning and
    /// the reading pane check membership against, without rebuilding it per
    /// render.
    var tripIDs: Set<UUID> { tripLookup.ids }

    private var tripLookup: TripLookup {
        if let tripLookupCache { return tripLookupCache }
        let lookup = TripLookup(trips: trips)
        tripLookupCache = lookup
        return lookup
    }

    private struct TripLookup {
        let byID: [UUID: TripSummary]
        let ids: Set<UUID>

        init(trips: [TripSummary]) {
            // First wins, never a crash: a duplicate id is a store bug to fix
            // elsewhere, not a reason to take the app down at lookup time.
            byID = Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            ids = Set(byID.keys)
        }
    }

    /// Set by the Open Trip App Intent or a completed-drive notification tap;
    /// ContentView opens the trip detail screen, then clears the request.
    var requestedTripSearch: TripSearchRequest?

    struct TripSearchRequest: Equatable {
        let id = UUID()
        let text: String
    }

    func requestTripSearch(_ text: String) {
        refresh()
        requestedTripSearch = TripSearchRequest(text: text)
    }

    func requestOpenCurrentDrive(id: UUID) {
        currentDrivePresentationRequestID = id
    }

    var requestedTripDetailID: UUID?

    func requestOpenTrip(id: UUID) {
        refresh()
        requestedTripDetailID = id
    }

    /// Set by the Open Mileage Report App Intent; ContentView observes it and
    /// pushes that month's screen, then clears the request.
    ///
    /// The Reports sheet this used to open no longer exists — the Mailboxes
    /// root is the report index and a month screen carries its own roll-up and
    /// Export menu, so the intent lands somewhere strictly more useful.
    var requestedReportsMonthStart: Date?

    func requestOpenReports(monthStart: Date) {
        refresh()
        requestedReportsMonthStart = monthStart
    }

    /// Set by the Open Need Review App Intent; ContentView observes it and
    /// pushes the inbox, then clears the request.
    ///
    /// New with the Mail-metaphor redesign: the drives awaiting a decision are
    /// now a named destination rather than a section of the Trips list, so Siri
    /// can take you straight to the work.
    var requestedNeedsReview = false

    func requestOpenNeedsReview() {
        refresh()
        requestedNeedsReview = true
    }

    func classify(_ trip: TripSummary, as classification: TripClassification?, purpose: String? = nil) {
        undoCoordinator.perform(String(localized: "Classify Trip")) {
            do {
                let updated = try applyClassification(to: trip, classification: classification, purpose: purpose)
                if classification != nil { intentDonations.classifiedTrip(entity(for: updated)) }
            } catch {
                present(error, .saveChanges)
            }
        }
    }

    /// Shared classification core used by the in-app UI and the Classify Trip
    /// App Intent: purpose defaulting, review-state update, and vehicle-trust
    /// learning stay identical no matter which surface made the change.
    @discardableResult
    func applyClassification(
        to trip: TripSummary,
        classification: TripClassification?,
        purpose: String? = nil
    ) throws -> TripSummary {
        let resolvedPurpose: String?
        if classification == .notADrive {
            resolvedPurpose = nil
        } else if let purpose {
            resolvedPurpose = purpose
        } else {
            let defaultPurpose = defaultBusinessPurposeIfNeeded(
                currentPurpose: trip.businessPurpose ?? "",
                classification: classification
            )
            resolvedPurpose = defaultPurpose.isEmpty ? nil : defaultPurpose
        }
        let updated = try tripStore.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(
                classification: classification,
                clearClassification: classification == nil,
                reviewStatus: classification == nil ? .needsReview : .readyToExport,
                businessPurpose: resolvedPurpose
            )
        )
        recordClassificationLearning(previous: trip.classification, new: classification, for: trip)
        tripSuggestions[trip.id] = nil
        refresh()
        return updated
    }

    // MARK: - Vehicle trust learning

    /// Review decisions are the training signal for the trusted vehicle
    /// engine: confirming a drive vouches for the Bluetooth devices observed
    /// at its start, "Not a Drive" votes against them.
    private func recordClassificationLearning(
        previous: TripClassification?,
        new: TripClassification?,
        for trip: TripSummary
    ) {
        // Re-saving the same value (e.g. detail-view autosave) trains nothing.
        guard previous != new else { return }
        // A machine-made classification never trained the counters, so
        // changing it away must not emit an undo outcome — treat as unreviewed.
        let isMachineMadeClassification = trip.classificationSource != nil
        let effectivePrevious = isMachineMadeClassification ? nil : previous
        let outcomes = Self.vehicleReviewOutcomes(previous: effectivePrevious, new: new)
        guard !outcomes.isEmpty else { return }
        let hashes = startBluetoothHintHashes(for: trip)
        guard !hashes.isEmpty else { return }
        for outcome in outcomes {
            let updated = (try? bluetoothHintStore.applyReviewOutcome(identifierHashes: hashes, outcome: outcome)) ?? []
            // Counter movements are otherwise invisible in device pulls; this
            // explains every trust change after the fact.
            for hint in updated {
                diagnostics.record(DiagnosticEvent(
                    category: "bluetooth",
                    message: "Applied review outcome \(outcome) to \(hint.displayName ?? "unknown device"): confirmed=\(hint.correlationCount) notADrive=\(hint.notADriveCount) trusted=\(hint.trusted)"
                ))
            }
        }
        if let bluetoothSignalService {
            // Re-evaluate connected routes so a trust change for the
            // currently-connected car takes effect immediately instead of
            // waiting for the next audio route change.
            bluetoothSignalService.refreshHints()
            bluetoothSignalService.refreshConnectedHints()
        }
    }

    static func vehicleReviewOutcomes(
        previous: TripClassification?,
        new: TripClassification?
    ) -> [VehicleReviewOutcome] {
        guard previous != new else { return [] }
        var outcomes: [VehicleReviewOutcome] = []
        switch previous {
        case .notADrive:
            outcomes.append(.undoNotADrive)
        case .business, .personal:
            // business <-> personal swaps don't change drive evidence.
            if new == .notADrive || new == nil {
                outcomes.append(.undoConfirmedDrive)
            }
        case nil:
            break
        }
        switch new {
        case .notADrive:
            outcomes.append(.notADrive)
        case .business, .personal:
            if previous == .notADrive || previous == nil {
                outcomes.append(.confirmedDrive)
            }
        case nil:
            break
        }
        return outcomes
    }

    private func startBluetoothHintHashes(for trip: TripSummary) -> [String] {
        if !trip.startBluetoothHintHashes.isEmpty {
            return trip.startBluetoothHintHashes
        }
        // Legacy trips predate hash stamping; observations are retained for
        // 7 days, so recent captures can still train.
        return ((try? bluetoothHintStore.observations(near: trip.startDate)) ?? []).map(\.identifierHash)
    }

    @discardableResult
    func update(
        _ trip: TripSummary,
        classification: TripClassification?,
        purpose: String,
        notes: String,
        tolls: Double? = nil,
        parking: Double? = nil,
        correctedDistanceMiles: Double?,
        distanceWasEdited: Bool = true,
        clearManualDistanceOverride: Bool = false,
        startDate: Date,
        endDate: Date,
        origin: String,
        destination: String,
        resolvedRoute: ResolvedManualRoute? = nil,
        clearRouteMap: Bool = false
    ) -> Bool {
        return undoCoordinator.perform(String(localized: "Edit Trip")) {
            do {
                let correctedDistanceMeters = correctedDistanceMiles.map(DistanceConversion.meters(fromMiles:))
                let businessPurpose = defaultBusinessPurposeIfNeeded(
                    currentPurpose: purpose,
                    classification: classification
                )
                let reviewedTrip = try tripStore.updateReview(
                    tripID: trip.id,
                    update: ReviewUpdate(
                        classification: classification,
                        clearClassification: classification == nil,
                        reviewStatus: classification == nil ? .needsReview : .readyToExport,
                        businessPurpose: businessPurpose,
                        notes: notes,
                        tollsAmount: tolls,
                        parkingAmount: parking,
                        manualDistanceOverrideMeters: distanceWasEdited ? correctedDistanceMeters : nil,
                        clearManualDistanceOverride: clearManualDistanceOverride,
                        startDate: startDate,
                        endDate: endDate
                    )
                )
                if reviewedTrip.classification != trip.classification, reviewedTrip.classification != nil {
                    intentDonations.classifiedTrip(entity(for: reviewedTrip))
                }
                recordClassificationLearning(previous: trip.classification, new: classification, for: trip)
                _ = try tripStore.updateAddresses(
                    tripID: trip.id,
                    startAddress: origin,
                    endAddress: destination
                )
                if clearRouteMap {
                    _ = try tripStore.clearRouteMap(tripID: trip.id)
                } else if let resolvedRoute {
                    _ = try tripStore.updateRoute(
                        tripID: trip.id,
                        startCoordinate: resolvedRoute.startCoordinate,
                        endCoordinate: resolvedRoute.endCoordinate,
                        routePolyline: resolvedRoute.routePolyline,
                        distanceMeters: resolvedRoute.distanceMeters
                    )
                    if distanceWasEdited, resolvedRoute.distanceMeters != nil, let correctedDistanceMeters {
                        _ = try tripStore.updateReview(
                            tripID: trip.id,
                            update: ReviewUpdate(manualDistanceOverrideMeters: correctedDistanceMeters)
                        )
                    }
                }
                refresh()
                return true
            } catch {
                present(error, .saveChanges)
                refresh()
                return false
            }
        }
    }

    func updateQuickNotes(_ trip: TripSummary, notes: String?) {
        undoCoordinator.perform(String(localized: "Edit Notes")) {
            do {
                _ = try tripStore.updateReview(
                    tripID: trip.id,
                    update: ReviewUpdate(notes: notes)
                )
                refresh()
            } catch {
                present(error, .saveChanges)
            }
        }
    }

    func updateQuickPurpose(_ trip: TripSummary, purpose: String) {
        let trimmed = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        // Assigning a business purpose implies the drive is business, so route a
        // non-empty purpose through `classify` to also set the classification,
        // mark it ready to export, and train the trusted-vehicle learning.
        // Clearing the purpose only edits the field and leaves classification alone.
        guard trimmed.isEmpty else {
            classify(trip, as: .business, purpose: trimmed)
            return
        }
        undoCoordinator.perform(String(localized: "Clear Purpose")) {
            do {
                _ = try tripStore.updateReview(tripID: trip.id, update: ReviewUpdate(businessPurpose: ""))
                refresh()
            } catch {
                present(error, .saveChanges)
            }
        }
    }

    func updatePurpose(tripIDs: [UUID], purpose: String) {
        undoCoordinator.perform(String(localized: "Change Purpose")) {
            do {
                let normalizedPurpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
                let previousTrips = try tripIDs.map { try tripStore.fetchTrip(id: $0) }
                let updated = try tripStore.updateTrips(
                    tripIDs: tripIDs,
                    update: TripBulkUpdate(
                        classification: normalizedPurpose.isEmpty ? .unchanged : .set(.business),
                        businessPurpose: normalizedPurpose
                    )
                )
                for (previous, current) in zip(previousTrips, updated) {
                    recordClassificationLearning(
                        previous: previous.classification,
                        new: current.classification,
                        for: previous
                    )
                    tripSuggestions[current.id] = nil
                    if current.classification != nil { intentDonations.classifiedTrip(entity(for: current)) }
                }
                refresh()
            } catch {
                present(error, .saveChanges)
                refresh()
            }
        }
    }

    /// Bulk classification. Mirrors the single-trip `classify(_:as:purpose:)`
    /// so vehicle-trust learning and suggestion clearing keep happening — a
    /// bulk path that skipped `recordClassificationLearning` would silently
    /// stop training Bluetooth attribution.
    func classify(tripIDs: [UUID], as classification: TripClassification?, purpose: String? = nil) {
        undoCoordinator.perform(String(localized: "Classify Trips")) {
            guard !tripIDs.isEmpty else { return }
            do {
                let normalizedPurpose = purpose?.trimmingCharacters(in: .whitespacesAndNewlines)
                let previousTrips = try tripIDs.map { try tripStore.fetchTrip(id: $0) }
                let update = TripBulkUpdate(
                    classification: classification.map { .set($0) } ?? .clear,
                    // TripStore throws invalidBusinessPurpose if a purpose arrives
                    // for a non-business classification, so only pass it through
                    // when it can legally land.
                    businessPurpose: classification == .business ? normalizedPurpose : nil
                )
                let updated = try tripStore.updateTrips(tripIDs: tripIDs, update: update)
                for (previous, current) in zip(previousTrips, updated) {
                    recordClassificationLearning(
                        previous: previous.classification,
                        new: current.classification,
                        for: previous
                    )
                    tripSuggestions[current.id] = nil
                }
                refresh()
            } catch {
                present(error, .saveChanges)
                refresh()
            }
        }
    }

    func assignVehicle(tripIDs: [UUID], vehicleID: UUID?) {
        guard !tripIDs.isEmpty else { return }
        undoCoordinator.perform(String(localized: "Assign Vehicle")) {
            do {
                _ = try tripStore.updateTrips(
                    tripIDs: tripIDs,
                    update: TripBulkUpdate(vehicle: vehicleID.map { .set($0) } ?? .clear)
                )
                refresh()
            } catch {
                present(error, .saveChanges)
                refresh()
            }
        }
    }

    func delete(_ trip: TripSummary) {
        undoCoordinator.perform(String(localized: "Delete Trip")) {
            do {
                try tripStore.deleteTrip(id: trip.id)
                refresh()
            } catch {
                present(error, .saveChanges)
            }
        }
    }

    func delete(tripIDs: [UUID]) {
        undoCoordinator.perform(String(localized: "Delete Trips")) {
            do {
                try tripStore.deleteTrips(ids: tripIDs)
                refresh()
            } catch {
                present(error, .saveChanges)
                refresh()
            }
        }
    }

    @discardableResult
    func addReturnTrip(_ trip: TripSummary) -> Bool {
        do {
            _ = try tripStore.duplicateTrip(id: trip.id, reversed: true)
            refresh()
            return true
        } catch {
            present(error, .saveChanges)
            return false
        }
    }

    func canMergeAdjacentTrips(_ first: TripSummary, _ second: TripSummary) -> Bool {
        TripMergePolicy.canMergeAdjacentTrips(first, second)
    }

    func merge(tripIDs: [UUID]) {
        undoCoordinator.perform(String(localized: "Merge Trips")) {
            do {
                _ = try tripStore.mergeTrips(ids: tripIDs)
                refresh()
            } catch {
                present(error, .saveChanges)
            }
        }
    }

    @discardableResult
    func unmerge(_ trip: TripSummary) -> Bool {
        return undoCoordinator.perform(String(localized: "Unmerge Trip")) {
            do {
                _ = try tripStore.unmergeTrip(id: trip.id)
                refresh()
                return true
            } catch {
                present(error, .saveChanges)
                return false
            }
        }
    }

    func exportTripPDF(_ trip: TripSummary) async -> URL? {
        irsRateExportStatusMessage = await prepareIRSRateForExport()
        guard isCommandSurfaceAvailable else { return nil }
        do {
            let currentTrip = try tripStore.fetchTrip(id: trip.id)
            let pdfData = try await reportGenerator.makeTripPDF(
                for: currentTrip,
                rate: mileageRateSchedule.rate(on: currentTrip.startDate),
                formatting: reportFormattingContext,
                rateSchedule: mileageRateSchedule
            )
            guard isCommandSurfaceAvailable else { return nil }
            return try TripPDFExportFileWriter.write(trip: currentTrip, pdfData: pdfData)
        } catch {
            present(error, .export)
            return nil
        }
    }

    // MARK: - Manual trips & routes

    func resolveManualRoute(origin: ManualRouteEndpoint, destination: ManualRouteEndpoint) async throws -> ResolvedManualRoute {
        try await routeResolver.resolveRoute(origin: origin, destination: destination)
    }

    @discardableResult
    func createManualTrip(
        startDate: Date,
        endDate: Date,
        distanceMiles: Double,
        distanceWasEdited: Bool = true,
        origin: String,
        destination: String,
        resolvedRoute: ResolvedManualRoute? = nil,
        classification: TripClassification?,
        purpose: String,
        notes: String,
        tolls: Double,
        parking: Double,
        vehicleID: UUID? = nil,
        fees: [TripFee] = []
    ) -> TripSummary? {
        guard !isAwaitingProtectedData else { return nil }
        do {
            let enteredDistanceMeters = DistanceConversion.meters(fromMiles: distanceMiles)
            let storedDistanceMeters = resolvedRoute?.distanceMeters ?? enteredDistanceMeters
            let businessPurpose = classification == .business
                ? defaultBusinessPurposeIfNeeded(
                    currentPurpose: purpose,
                    classification: classification
                )
                : nil
            var creationFees = fees
            if tolls > 0 {
                creationFees.append(TripFee(
                    tripID: nil,
                    category: .toll,
                    amount: tolls,
                    occurredAt: startDate,
                    label: TripFeeCategory.toll.displayName,
                    source: .manual
                ))
            }
            if parking > 0 {
                creationFees.append(TripFee(
                    tripID: nil,
                    category: .parking,
                    amount: parking,
                    occurredAt: endDate,
                    label: TripFeeCategory.parking.displayName,
                    source: .manual
                ))
            }
            let trip = try tripStore.createManualTrip(ManualTripInput(
                startDate: startDate,
                endDate: endDate,
                startCoordinate: resolvedRoute?.startCoordinate,
                endCoordinate: resolvedRoute?.endCoordinate,
                startAddress: origin,
                endAddress: destination,
                distanceMeters: storedDistanceMeters,
                routePolyline: resolvedRoute?.routePolyline,
                manualDistanceOverrideMeters: resolvedRoute?.distanceMeters != nil && distanceWasEdited
                    ? enteredDistanceMeters
                    : nil,
                classification: classification,
                businessPurpose: businessPurpose,
                notes: notes,
                vehicleID: vehicleID
            ), fees: creationFees)
            refresh()
            return (try? tripStore.fetchTrip(id: trip.id)) ?? trip
        } catch {
            present(error, .saveChanges)
            refresh()
            return nil
        }
    }

    // MARK: - Fees, business purposes & EZ-Pass

    func fees(for trip: TripSummary) -> [TripFee] {
        do {
            return try tripStore.fetchFees(tripID: trip.id)
        } catch {
            present(error, .loadData)
            return []
        }
    }

    @discardableResult
    func addFee(
        to trip: TripSummary,
        category: TripFeeCategory,
        amount: Double,
        occurredAt: Date = Date(),
        label: String? = nil,
        source: TripFeeSource = .manual,
        presetID: UUID? = nil
    ) -> TripFee? {
        return undoCoordinator.perform(String(localized: "Add Fee")) {
            do {
                let fee = try tripStore.addFee(
                    tripID: trip.id,
                    category: category,
                    amount: amount,
                    occurredAt: occurredAt,
                    label: label,
                    source: source,
                    presetID: presetID
                )
                refresh()
                return fee
            } catch {
                present(error, .saveChanges)
                refresh()
                return nil
            }
        }
    }

    @discardableResult
    func updateFee(_ fee: TripFee) -> TripFee? {
        return undoCoordinator.perform(String(localized: "Edit Fee")) {
            do {
                let updated = try tripStore.updateFee(fee)
                refresh()
                return updated
            } catch {
                present(error, .saveChanges)
                refresh()
                return nil
            }
        }
    }

    func deleteFee(_ fee: TripFee) {
        undoCoordinator.perform(String(localized: "Delete Fee")) {
            do {
                try tripStore.deleteFee(id: fee.id)
                refresh()
            } catch {
                present(error, .saveChanges)
                refresh()
            }
        }
    }

    func refreshFeePresets() {
        do {
            feePresets = try tripFeePresetStore.fetchPresets()
        } catch {
            feePresets = []
            present(error, .loadData)
        }
    }

    func saveFeePresets(_ presets: [TripFeePreset]) {
        do {
            feePresets = try tripFeePresetStore.savePresets(presets)
        } catch {
            present(error, .saveSettings)
        }
    }

    func applyFeePreset(_ preset: TripFeePreset, to trip: TripSummary) {
        _ = addFee(
            to: trip,
            category: preset.category,
            amount: preset.amount,
            label: preset.label,
            source: .preset,
            presetID: preset.id
        )
    }

    func refreshBusinessPurposePresets() {
        let previous = businessPurposePresets
        do {
            businessPurposePresets = try businessPurposePresetStore.fetchPurposes()
        } catch {
            businessPurposePresets = BusinessPurposePresetStore.defaultPurposes
            present(error, .loadData)
        }
        if businessPurposePresets != previous {
            regenerateSuggestions()
        }
    }

    func saveMileageRate(amountPerUnit: Double) {
        do {
            let rate = MileageRate(amountPerUnit: amountPerUnit, unit: distanceUnit)
            mileageRateSchedule = try mileageRateScheduleStore.saveBaseRate(rate)
            mileageRate = mileageRateSchedule.rate(on: Date())
            // Donated month-report snippets bake the reimbursement in; the
            // digest diff re-donates only the affected months.
            scheduleSpotlightReconcile()
        } catch {
            present(error, .saveSettings)
        }
    }

    @discardableResult
    func saveMileageRateSchedule(_ schedule: MileageRateSchedule, presentErrors: Bool = true) -> Bool {
        do {
            mileageRateSchedule = try mileageRateScheduleStore.saveSchedule(schedule)
            mileageRate = mileageRateSchedule.rate(on: Date())
            scheduleSpotlightReconcile()
            return true
        } catch {
            if presentErrors { present(error, .saveSettings) }
            return false
        }
    }

    /// Custom rate, currency, and display units become one saved choice. The
    /// editor works on a draft; neither opening it nor cancelling changes IRS.
    @discardableResult
    func saveCustomMileageRate(
        amount: Double,
        currency: String,
        unit: DistanceUnit,
        effectiveFrom: Date,
        editingRuleID: UUID? = nil,
        expectedEditingRule: MileageRateRule? = nil,
        editingBase: Bool = false
    ) -> Bool {
        do {
            let now = irsRateNow()
            var schedule = try mileageRateScheduleStore.fetchSchedule()
            let effectiveDate = MileageRateEffectiveDate(effectiveFrom)
            if let editingRuleID = editingRuleID ?? expectedEditingRule?.id {
                guard let edited = schedule.normalizedRules.first(where: { $0.id == editingRuleID }),
                      expectedEditingRule == nil || expectedEditingRule == edited,
                      !schedule.normalizedRules.contains(where: {
                          $0.id != editingRuleID && $0.effectiveFrom == effectiveDate && $0.irsSource == nil
                      }) else {
                    throw NSError(domain: "MileageRate", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        String(localized: "This rate changed. Reopen the editor and try again.")])
                }
                if edited.effectiveFrom != effectiveDate {
                    schedule.deletedRuleIDs[editingRuleID] = max(now, edited.updatedAt)
                    schedule.rules.removeAll { $0.id == editingRuleID }
                }
            }
            if editingBase, schedule.normalizedRules.contains(where: { $0.effectiveFrom <= effectiveDate }) {
                throw NSError(domain: "MileageRate", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    String(localized: "This rate changed. Reopen the editor and try again.")])
            }
            let rate = MileageRate(amountPerUnit: amount, unit: unit)
            // The first configured rate also covers trips recorded while the
            // amount was unset, regardless of a stale draft's proposed date.
            let configuresBaseRate = editingBase || schedule.requiresCustomRate
            if configuresBaseRate { schedule.baseRate = rate }
            schedule = try IRSBusinessRateScheduleUpdater.applyCustomRate(
                rate, to: schedule, effectiveFrom: effectiveDate, now: now
            )
            if configuresBaseRate {
                // The fallback already represents this interval; do not add a
                // duplicate dated entry merely because the editor saved it.
                schedule.rules.removeAll { $0.effectiveFrom == effectiveDate }
            }
            let preference: DistanceUnitPreference = unit == distanceUnit
                ? distanceUnitPreference : (unit == .miles ? .miles : .kilometers)
            let oldUnit = distanceUnit
            let saved = try mileageRateScheduleStore.saveSchedule(
                schedule, currencyCode: currency, distanceUnitPreference: preference, now: now
            )
            cancelIRSRateCheck(clearStatus: true)
            mileageRateSchedule = saved
            currencyCode = currency
            distanceUnitPreference = preference
            preferences.displayDistanceUnitRaw = unit.rawValue
            mileageRate = saved.rate(on: now)
            preferences.irsRateCheckNeedsRetry = false
            if oldUnit != unit { reconcileLiveActivity() }
            scheduleSpotlightReconcile()
            return true
        } catch {
            present(error, .saveSettings)
            return false
        }
    }

    func confirmLegacyReportArtifactCleanup() {
        do {
            _ = try reportArtifactCleanupStore.confirmAndDelete()
            refreshLegacyReportArtifacts()
        } catch {
            present(error, .saveSettings)
        }
    }

    func deferLegacyReportArtifactCleanup() {
        do {
            try reportArtifactCleanupStore.keepForNow()
            refreshLegacyReportArtifacts()
        } catch {
            present(error, .saveSettings)
        }
    }

    private func refreshLegacyReportArtifacts() {
        reportArtifactCleanupDecision = try? reportArtifactCleanupStore.fetchDecision()
        if reportArtifactCleanupDecision?.deletesArtifacts == true {
            _ = try? reportArtifactCleanupStore.deleteAgainIfConfirmed()
        }
        legacyReportArtifactCount = (try? reportArtifactCleanupStore.legacyArtifactCount()) ?? 0
    }

    // MARK: - Units & currency

    /// The unit all distances are displayed and entered in right now.
    var distanceUnit: DistanceUnit {
        distanceUnitPreference.resolved()
    }

    var reportFormattingContext: ReportFormattingContext {
        ReportFormattingContext(distanceUnit: distanceUnit, currencyCode: currencyCode)
    }

    func setDistanceUnitPreference(_ preference: DistanceUnitPreference) {
        let oldUnit = distanceUnit
        do {
            let convertedRate: MileageRate
            if mileageRateSchedule.isAutomaticIRSDefault || mileageRateSchedule.requiresCustomRate {
                // A display-unit change is not a saved Custom-rate choice.
                try unitsCurrencyStore.saveDistanceUnitPreference(preference)
                convertedRate = mileageRate.converted(to: preference.resolved())
            } else {
                convertedRate = try unitsCurrencyStore.saveDistanceUnitPreference(
                    preference, preservingValueOf: mileageRate
                )
            }
            distanceUnitPreference = preference
            let newUnit = preference.resolved()
            preferences.displayDistanceUnitRaw = newUnit.rawValue
            // Re-quote the rate in the same Core Data transaction so payouts are
            // unchanged and another device never imports a mismatched pair.
            mileageRate = convertedRate
            if newUnit != oldUnit {
                reconcileLiveActivity()
                // Donated Spotlight snippets bake the old unit in; the format
                // stamp marks them all stale, the reconcile re-donates them.
                scheduleSpotlightReconcile()
            }
        } catch {
            present(error, .saveSettings)
        }
    }

    func setCurrencyCode(_ code: String) {
        guard code != currencyCode else { return }
        do {
            try unitsCurrencyStore.saveCurrencyCode(code)
            currencyCode = code
            if code != "USD" { stopFollowingIRSRate() }
            // Month-report snippets bake the currency symbol in; the digest
            // diff re-donates only the affected months.
            scheduleSpotlightReconcile()
        } catch {
            present(error, .saveSettings)
        }
    }

    func saveBusinessPurposePresets(_ purposes: [String]) {
        do {
            let saved = try businessPurposePresetStore.savePurposes(purposes)
            guard saved != businessPurposePresets else { return }
            businessPurposePresets = saved
            regenerateSuggestions()
        } catch {
            present(error, .saveSettings)
        }
    }

    func addBusinessPurposePreset(_ purpose: String) {
        saveBusinessPurposePresets(businessPurposePresets + [purpose])
    }

    func defaultBusinessPurposeIfNeeded(currentPurpose: String, classification: TripClassification?) -> String {
        let trimmedPurpose = currentPurpose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard classification == .business, trimmedPurpose.isEmpty else {
            return currentPurpose
        }
        return defaultBusinessPurpose
    }

    // MARK: - Vehicles (wiring)
    // Vehicle CRUD and attribution live in MileageAppModel+Vehicles.swift;
    // these two stay here because they set private(set) state / run in the
    // launch path.

    func reloadVehicles() {
        vehicles = (try? vehicleStore.fetchVehicles()) ?? []
        primaryVehicleID = try? vehicleStore.primaryVehicleID()
        if let currentDrive {
            publishCurrentDriveSnapshot(currentDrive)
        }
    }

    /// Every configured iPhone/iPad install owns at least one vehicle. Creates
    /// the localized default when onboarding is complete and none exist. Skipped
    /// while awaiting protected data — a vehicle created on the in-memory
    /// fallback would vanish. Always skipped on a Mac: its vehicles come from
    /// iCloud or an explicit Settings action, so a backfilled "My Car" can never
    /// race a later CloudKit import or duplicate an existing vehicle by name.
    private func createDefaultVehicleIfNeeded() {
        guard hasCompletedOnboarding,
              !isAwaitingProtectedData,
              !platform.isMac,
              (try? vehicleStore.fetchVehicles(includeArchived: true))?.isEmpty == true else { return }
        _ = createVehicle(
            name: String(localized: "My Car"),
            colorHex: VehicleAppearance.defaultColorHex,
            symbolName: VehicleAppearance.defaultSymbol
        )
    }

    // MARK: - Odometer checkpoint mutations
    // Report generation and odometer read accessors live in
    // MileageAppModel+Reports.swift; the mutations stay here because they set
    // private(set) state.

    func addOdometerCheckpoint(_ miles: Double, vehicleID: UUID? = nil) {
        do {
            _ = try tripStore.addOdometerCheckpoint(
                OdometerCheckpoint(date: Date(), odometerMiles: miles, vehicleID: vehicleID)
            )
            odometerCheckpoints = try tripStore.fetchOdometerCheckpoints()
        } catch {
            present(error, .saveChanges)
        }
    }

    func deleteOdometerCheckpoint(id: UUID) {
        do {
            try tripStore.deleteOdometerCheckpoint(id: id)
            odometerCheckpoints = try tripStore.fetchOdometerCheckpoints()
        } catch {
            present(error, .saveChanges)
        }
    }

    // MARK: - Diagnostics exports

    /// No production callers; retained as the launch-test diagnostics probe
    /// (ProtectedDataLaunchTests / MileageAppModelLaunchTests decode this JSON
    /// to assert capture state after protected-data launches).
    func exportDiagnostics() -> Data? {
        do {
            let now = Date()
            let since = now.addingTimeInterval(-Double(DiagnosticLocationSample.retentionDays) * 24 * 60 * 60)
            let samples = try diagnosticSampleStore.fetchSamples(since: since, until: now)
            let events = try captureEventStore.fetchEvents(since: since, until: now)
            let pendingSignals = try pendingDriveStartSignalStore.fetchSignals(since: since, until: now)
            return try diagnostics.export(
                health: health,
                activeDriveState: try activeDriveStore.load(),
                diagnosticSamples: samples,
                captureEvents: events,
                pendingDriveStartSignals: pendingSignals,
                sampleBursts: DiagnosticDriveAnalyzer.burstSummaries(from: samples),
                possibleDriveCandidates: DiagnosticDriveAnalyzer.possibleDriveCandidates(from: samples)
            )
        } catch {
            present(error, .export)
            return nil
        }
    }

    func prepareDiagnosticsSupportArchive(days: Int) async -> DiagnosticsReportItem? {
        let container = persistence.container
        let metadata = diagnosticsSupportMetadata()
        do {
            return try await Task.detached(priority: .userInitiated) {
                let bundle = try DiagnosticsSupportStoreExporter.makeBundle(
                    from: container,
                    selectedDays: days,
                    metadata: metadata
                )
                return try DiagnosticsReportArchive.makeSupportReport(from: bundle)
            }.value
        } catch {
            present(error, .export)
            return nil
        }
    }

    private func diagnosticsSupportMetadata() -> DiagnosticsSupportExportMetadata {
        let info = Bundle.main.infoDictionary
        return DiagnosticsSupportExportMetadata(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: info?["CFBundleVersion"] as? String ?? "unknown",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            backgroundRefreshAvailable: health.backgroundRefreshAvailable,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            detailedDiagnosticsEnabled: detailedDiagnosticsEnabled,
            diagnosticSampleRetentionDays: driveCaptureDiagnosticsMode.sampleRetentionDays
        )
    }

    // MARK: - Reset

    func resetApp() async {
        guard !resetInProgress else { return }
        cancelIRSRateCheck()
        let shouldRestartTracking = trackingActive
        resetInProgress = true
        intentDonations.removeAll()
        mapWarming.reset()
        resetError = nil
        resetStatusMessage = nil
        tracker?.stopMonitoring()
        // Nothing on the stack can survive the stores being destroyed, and a
        // failed reset is still a partial wipe.
        undoCoordinator.invalidate()

        suggestionBackfillRerunRequested = false
        suggestionCacheHydrationTask?.cancel()
        suggestionBackfillTask?.cancel()
        await suggestionCacheHydrationTask?.value
        await suggestionBackfillTask?.value
        await waitForSuggestionCacheInvalidations()
        suggestionCacheHydrationTask = nil
        suggestionBackfillTask = nil
        try? await suggestionCacheStore?.removeAll()

        let coordinator = ResetCoordinator(
            persistence: persistence,
            sync: sync,
            preferences: preferences,
            derivedArtifactTestSuffix: derivedArtifactTestSuffix
        )
        switch await coordinator.run() {
        case .success(let message):
            await DriveCardMapSnapshotRenderer.clearCache()
            try? FileManager.default.removeItem(at: firstSyncRecoveryRootURL)
            trackingActive = false
            // `trackingActive`'s didSet just wrote `false` back into preferences,
            // overwriting the `nil` that the reset established. Restore `nil` so a
            // fresh launch / re-onboarding falls back to default-on behavior.
            preferences.automaticTrackingEnabled = nil
            vehicleBluetoothHintsEnabled = false
            automaticTripStartMode = .both
            // didSet wipes the Spotlight index alongside the store contents.
            siriIndexingEnabled = false
            syncEnabled = false
            syncChangeRequiresRelaunch = sync.isEnabledThisLaunch
            syncStatus = .init(state: .disabled)
            trips = []
            tripSuggestions = [:]
            suggestionFingerprints = [:]
            suggestionRefreshNeeded = []
            suggestionEngine.suggestionsInFlight = [:]
            suggestionBackfillRerunRequested = false
            hasHydratedSuggestionCache = suggestionCacheStore == nil
            businessPurposePresets = BusinessPurposePresetStore.defaultPurposes
            feePresets = []
            mileageRate = .default
            mileageRateSchedule = .default
            irsRateLastSuccessfulCheck = nil
            irsRatePendingPeriods = []
            irsRateHasConflicts = false
            irsRateStatusMessage = nil
            irsRateExportStatusMessage = nil
            legacyReportArtifactCount = 0
            reportArtifactCleanupDecision = nil
            distanceUnitPreference = .system
            currencyCode = UnitsCurrencyStore.defaultCurrencyCode()
            mileageRateSchedule = (try? mileageRateScheduleStore.initializeDefaultScheduleIfNeeded(
                currencyCode: currencyCode, now: irsRateNow()
            )) ?? .default
            mileageRate = mileageRateSchedule.rate(on: irsRateNow())
            refreshBusinessPurposePresets()
            refreshFeePresets()
            refresh()
            resetStatusMessage = message
        case .failure(let message):
            resetError = message
            if shouldRestartTracking {
                tracker?.startMonitoring()
            }
        }
        // A partial reset can clear preferences before later cleanup fails.
        refreshVehicleAutomationReceipt()
        resetInProgress = false
    }

    // MARK: - Private helpers

    /// Whether tracking starts out on.
    ///
    /// Both suppressors are parameters rather than reads of `self`, which is
    /// what makes this checkable: it is the only expression of "a Mac never
    /// captures" that a test can reach without constructing a model, and a
    /// model built for a test carries `--uitesting`, whose own `false` masks
    /// the platform's. Every assertion about the Mac guard made through a
    /// model was therefore satisfied by the harness rather than by the guard.
    static func initialTrackingActive(
        preferences: Preferences,
        isUITesting: Bool,
        capturesDrives: Bool
    ) -> Bool {
        guard !isUITesting, capturesDrives else { return false }
        if let stored = preferences.automaticTrackingEnabled {
            return stored
        }
        return CLLocationManager().authorizationStatus == .authorizedAlways
    }

    private func startTrackingByDefaultIfReady() {
        guard platform.capturesDrives,
              hasCompletedOnboarding,
              !trackingActive,
              preferences.automaticTrackingEnabled == nil,
              health.isAllClear else {
            return
        }

        startTracking()
    }

    private static func testStoreSuffix(from arguments: [String]) -> String? {
        arguments.first { $0.hasPrefix(testStoreSuffixPrefix) }
            .map { String($0.dropFirst(testStoreSuffixPrefix.count)) }
    }

    private static func makePersistence(
        mode: PersistenceMode,
        inMemory: Bool,
        storeDirectory: URL?,
        simulateBeforeFirstUnlock: Bool
    ) -> (controller: PersistenceController, awaitingProtectedData: Bool) {
        // Test-only: simulate a before-first-unlock relaunch where the on-disk
        // store files cannot be opened, so the BFU degrade/reload path stays
        // covered without a real locked device.
        if simulateBeforeFirstUnlock, !inMemory,
           let placeholder = try? PersistenceController(mode: .localOnly, inMemory: true) {
            return (placeholder, true)
        }
        do {
            // Open the real store directly. Its files use
            // `.completeUntilFirstUserAuthentication`, so they are readable after
            // the first unlock following a reboot — i.e. on every normal launch,
            // including locked background wakes. Do NOT pre-gate on
            // `UIApplication.isProtectedDataAvailable`: that reflects the
            // Complete-protection/current-lock state and reads false during early
            // launch and ordinary locked wakes, which made trips briefly vanish
            // behind a placeholder even though the store was perfectly readable.
            return (try PersistenceController(mode: mode, inMemory: inMemory, storeDirectory: storeDirectory), false)
        } catch {
            // The on-disk store genuinely failed to open. Before the first unlock
            // after a reboot the store files really are encrypted; fall back to a
            // throwaway in-memory stack so a headless background launch cannot
            // crash, and reload the real store once the device is unlocked.
            #if canImport(UIKit)
            let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
            #else
            let protectedDataAvailable = true
            #endif
            if !inMemory, !protectedDataAvailable,
               let placeholder = try? PersistenceController(mode: .localOnly, inMemory: true) {
                return (placeholder, true)
            }
            do {
                return (try PersistenceController(mode: .localOnly, inMemory: inMemory, storeDirectory: storeDirectory), false)
            } catch {
                // Protected data is available but both stores failed to load —
                // genuine, unrecoverable corruption with the user present.
                // Surfacing it beats silently running on an empty store.
                fatalError("Failed to create persistence stack: \(error)")
            }
        }
    }

    private func observeProtectedDataAvailabilityIfNeeded() {
        guard isAwaitingProtectedData, protectedDataObserver == nil else { return }
        #if canImport(UIKit)
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.reloadPersistenceForProtectedData()
            }
        }
        #endif
    }

    /// Swaps the locked-launch in-memory fallback for the real on-disk store
    /// once the device has been unlocked. No-op in the normal case where the
    /// real store loaded at launch.
    func reloadPersistenceForProtectedData() async {
        guard isAwaitingProtectedData, !hasReloadedAfterProtectedData else { return }
        let controller: PersistenceController
        do {
            controller = try PersistenceController(
                mode: sync.persistenceMode(),
                inMemory: false,
                storeDirectory: persistenceStoreDirectory
            )
        } catch {
            diagnostics.record(DiagnosticEvent(
                category: "lifecycle",
                message: "Persistent store reload failed after unlock: \(error.localizedDescription)"
            ))
            return
        }

        hasReloadedAfterProtectedData = true
        let maintenanceResult: RetiredTripMaintenance.Result
        do {
            maintenanceResult = try await performRetiredTripMaintenance(on: controller)
        } catch {
            hasReloadedAfterProtectedData = false
            diagnostics.record(DiagnosticEvent(
                category: "lifecycle",
                message: "Retired trip maintenance failed after unlock: "
                    + error.localizedDescription
            ))
            return
        }

        guard isAwaitingProtectedData else { return }
        if let token = protectedDataObserver {
            NotificationCenter.default.removeObserver(token)
            protectedDataObserver = nil
        }
        // Before the runtime re-arms: the keeper's region teardown acts on the
        // app-global region set, so releasing it after the runtime registered
        // its geofence would silently remove that registration.
        releaseProtectedDataWakeKeeper()

        persistence = controller
        suggestionCacheHydrationTask?.cancel()
        suggestionCacheHydrationTask = nil
        hasHydratedSuggestionCache = suggestionCacheStore == nil
        tripSuggestions = [:]
        suggestionFingerprints = [:]
        suggestionRefreshNeeded = []
        wireStores(context: controller.container.viewContext)
        isAwaitingProtectedData = false
        observeRemoteChangesIfReady(on: controller)
        // Close the maintenance/observer-registration window immediately.
        // A CloudKit import that landed while the store was opening otherwise
        // had no notification left to wake this process.
        sync.checkForRemoteChanges()
        rebuildTrackerAfterReload()
        if trackingActive {
            let reason = deferredProtectedDataLaunchReason ?? .foreground
            deferredProtectedDataLaunchReason = nil
            diagnostics.record(DiagnosticEvent(
                category: "wakeBootstrap",
                message: "Retrying tracking wake bootstrap after protected data became available"
            ))
            bootstrapTrackingForLaunch(reason: reason)
        }
        markIntentCaptureReady()
        // The launch-time backfill was skipped while protected data was
        // unavailable; now that the real store is open, ensure a vehicle exists.
        createDefaultVehicleIfNeeded()
        refresh()
        await waitForSuggestionCacheHydration()
        recordRetiredTripMaintenance(maintenanceResult)
        checkSyncStatus()
        scheduleSpotlightReconcile()
        scheduleAutomaticTripEnrichment(startingNewSession: true)
        diagnostics.record(DiagnosticEvent(
            category: "lifecycle",
            message: "Loaded persistent store after device unlock"
        ))

    }

    /// Rebuilds the capture runtime so it writes to the real store. Only
    /// needed if the tracker was already configured against the fallback
    /// store; otherwise the unlock bootstrap will build it against the real
    /// one. Monitoring is restarted by `bootstrapTrackingForLaunch(reason:)`
    /// so protected-data retry has a single launch path.
    private func rebuildTrackerAfterReload() {
        guard tracker != nil else { return }
        tracker?.stopMonitoring()
        tracker = nil
        bluetoothSignalService = nil
        configureTracker()
    }

    /// Store-independent wake layer held while `isAwaitingProtectedData`: the
    /// beacon geofence and SLC/visits need no encrypted store, so a deferred
    /// launch stays wakeable, and any location event doubles as a chance to
    /// retry the protected-data reload (the unlock notification is not
    /// delivered to a suspended process).
    private struct ProtectedDataWakeKeeper {
        let idleWake: CoreLocationRegionDriveIdleWakeProvider
        let backgroundWake: CoreLocationBackgroundWakeProvider
    }

    @ObservationIgnored private var protectedDataWakeKeeper: ProtectedDataWakeKeeper?

    private func armProtectedDataWakeKeeper() {
        guard protectedDataWakeKeeper == nil else { return }
        let idleWake = CoreLocationRegionDriveIdleWakeProvider()
        let backgroundWake = CoreLocationBackgroundWakeProvider()
        idleWake.onWake = { [weak self] _ in
            Task { @MainActor in
                await self?.reloadPersistenceForProtectedData()
            }
        }
        backgroundWake.onSignificantChange = { [weak self] _, _ in
            Task { @MainActor in
                await self?.reloadPersistenceForProtectedData()
            }
        }
        backgroundWake.onVisitDeparture = { [weak self] _ in
            Task { @MainActor in
                await self?.reloadPersistenceForProtectedData()
            }
        }
        idleWake.restoreMonitoringIfNeeded()
        backgroundWake.startMonitoring()
        protectedDataWakeKeeper = ProtectedDataWakeKeeper(idleWake: idleWake, backgroundWake: backgroundWake)
        diagnostics.record(DiagnosticEvent(
            category: "wakeBootstrap",
            message: "Armed protected-data wake keeper (beacon geofence + SLC/visits)"
        ))
    }

    private func releaseProtectedDataWakeKeeper() {
        guard let keeper = protectedDataWakeKeeper else { return }
        protectedDataWakeKeeper = nil
        // The keeper's SLC/visit registrations belong to its own manager; the
        // runtime holds its own. While tracking stays on, DETACH the geofence —
        // beacon AND the system-side region survive, so the runtime's provider
        // adopts the persisted registration instead of churning through a
        // remove/re-register/requestState cycle (ADR-005). Only when the user
        // has tracking disabled do we fully stop, so no region is left leaked
        // for an app that should hold none.
        if trackingActive {
            keeper.idleWake.detachMonitoring()
        } else {
            keeper.idleWake.stopMonitoring()
        }
        keeper.backgroundWake.stopMonitoring()
        diagnostics.record(DiagnosticEvent(
            category: "wakeBootstrap",
            message: "Released protected-data wake keeper"
        ))
    }

    /// A drive-start signal the App Intent could not write to the sealed store
    /// (spooled unprotected) is folded into the real store before the wake
    /// bootstrap consumes pending signals.
    func drainSpooledStartSignals(from spool: PendingSignalSpool = PendingSignalSpool()) {
        guard let record = spool.drain(), let trigger = record.trigger else { return }
        do {
            let pending = try pendingDriveStartSignalStore.save(
                trigger: trigger,
                at: record.createdAt,
                policy: .balanced,
                vehicleID: record.vehicleID
            )
            // A pre-unlock queue entry only counts once accepted into the real
            // store while its drive-start window is still usable.
            if pending.expiresAt > Date() {
                preferences.recordVehicleAutomationReceipt(trigger: trigger, at: record.createdAt)
                refreshVehicleAutomationReceipt()
            }
            diagnostics.record(DiagnosticEvent(
                category: "startSignal",
                message: "Drained spooled drive start signal \(trigger.rawValue)"
            ))
        } catch {
            diagnostics.record(DiagnosticEvent(
                category: "startSignal",
                message: "Failed to drain spooled drive start signal: \(error.localizedDescription)"
            ))
        }
    }

    /// The runtime saw an unhonored location session. If that is the
    /// post-restart state (no foreground since boot), post the one-per-boot
    /// notice: a single app-open is what restores background sessions, and
    /// nothing else can (verified platform behavior, WWDC24 10212).
    private func handleServiceSessionUnfulfilled(_ diagnostic: DriveServiceSessionDiagnostic) {
        guard trackingActive, !sceneIsActive else { return }
        guard restartAdvisor.shouldNotifyForCurrentBoot() else { return }
        diagnostics.record(DiagnosticEvent(
            category: "lifecycle",
            message: "Posted restart tracking notice (\(diagnostic.summary))"
        ))
        ReminderScheduler.postRestartTrackingNotice()
    }

    /// The runtime saw an unfulfilled session produce zero samples through the
    /// quiet window while drive evidence was active — the 2026-07-05 state
    /// where a drive is being lost right now and one foreground restores
    /// delivery within seconds. The evidence gate lives runtime-side; this
    /// handler only applies the app-level conditions and the wall-clock ration.
    private func handleTrackingRestorationNeeded(_ advice: DriveTrackingRestorationAdvice) {
        guard trackingActive, !sceneIsActive else { return }
        guard restartAdvisor.shouldNotifyForTrackingRestoration() else { return }
        diagnostics.record(DiagnosticEvent(
            category: "lifecycle",
            message: "Posted restore tracking notice (\(advice.diagnosticSummary) phase=\(advice.phase.rawValue) fallback=\(advice.fallbackEngaged) fallbackSamples=\(advice.fallbackSampleCount) quiet=\(advice.quietForSeconds)s)"
        ))
        ReminderScheduler.postRestoreTrackingNotice()
    }

    private func bootstrapTrackingForLaunch(reason launchReason: MileageAppLaunchReason) {
        // A Mac never captures drives: no wake keeper, no spooled start
        // signals, no tracker bootstrap. Sync and refresh still run from
        // startup(); this skips only the capture arm-up.
        guard platform.capturesDrives else { return }
        if isAwaitingProtectedData {
            // Arm the store-independent wake layer even though the encrypted
            // stores can't open (and `trackingActive` itself may be reading a
            // sealed preference): a deferred launch must never leave the
            // process with zero armed CoreLocation clients — that is the
            // unwakeable-zombie state. Torn down when the reload succeeds.
            armProtectedDataWakeKeeper()
            if trackingActive {
                deferredProtectedDataLaunchReason = launchReason
                diagnostics.record(DiagnosticEvent(
                    category: "wakeBootstrap",
                    message: "Deferred tracking wake bootstrap until protected data is available"
                ))
            } else if launchReason == .locationWake {
                diagnostics.record(DiagnosticEvent(
                    category: "lifecycle",
                    message: "Ignored location wake while tracking disabled"
                ))
            } else if launchReason == .nonLocationBackground {
                diagnostics.record(DiagnosticEvent(
                    category: "lifecycle",
                    message: "Ignored background launch while tracking disabled"
                ))
            }
            return
        }

        drainSpooledStartSignals()
        configureTracker()
        if trackingActive {
            switch launchReason {
            case .foreground:
                tracker?.bootstrapForWake(reason: .foregroundLaunch)
            case .locationWake:
                tracker?.bootstrapForWake(reason: .locationWake)
                diagnostics.record(DiagnosticEvent(
                    category: "lifecycle",
                    message: "Resumed drive capture during location wake"
                ))
            case .nonLocationBackground:
                // A Shortcut automation (BT connect → ArmDriveStartIntent) launches
                // the app this way right as a drive begins. Deferring here left the
                // fresh process with no armed CoreLocation clients, so once iOS
                // suspended it no SLC/visit/geofence event could wake it and the
                // whole drive was lost (2026-07-01). Bootstrapping also consumes the
                // intent's pending start signal; pre-movement confirmation still
                // keeps a parked Bluetooth connect from recording a false trip.
                tracker?.bootstrapForWake(reason: .backgroundLaunch)
                diagnostics.record(DiagnosticEvent(
                    category: "lifecycle",
                    message: "Resumed drive capture during non-location background launch"
                ))
            }
        } else if launchReason == .locationWake {
            diagnostics.record(DiagnosticEvent(
                category: "lifecycle",
                message: "Ignored location wake while tracking disabled"
            ))
        } else if launchReason == .nonLocationBackground {
            diagnostics.record(DiagnosticEvent(
                category: "lifecycle",
                message: "Ignored background launch while tracking disabled"
            ))
        }
    }

    private func checkSyncStatus() {
        sync.checkStatus(syncEnabledPreference: syncEnabled) { [weak self] status in
            guard let self else { return }
            // Multiple triggers can race; ignore an out-of-order completion that is
            // older than the status we already show so a stale account check can't
            // clobber a fresh one. (Timestamps are nil for initial states, which
            // always land.)
            if let incoming = status.lastCheckedAt,
               let current = self.syncStatus.lastCheckedAt,
               incoming < current {
                return
            }
            self.syncStatus = status
        }
    }

    #if DEBUG
    private struct DebugTripSnapshot: Encodable {
        var exportedAt: Date
        var trips: [DebugTripSnapshotTrip]
    }

    private struct DebugTripSnapshotTrip: Encodable {
        var id: UUID
        var startDate: Date
        var endDate: Date
        var distanceMeters: Double
        var captureSource: String
        var reviewStatus: String
        var classification: String?
        var needsAttention: Bool
        var attentionReasons: [String]
        var legCount: Int
        var sourceTripIDs: [UUID]
    }

    private func writeDebugTripSnapshotIfNeeded() {
        guard shouldWriteDebugTripSnapshot else { return }

        do {
            let snapshot = DebugTripSnapshot(
                exportedAt: Date(),
                trips: try tripStore.fetchTrips()
                    .sorted { $0.startDate < $1.startDate }
                    .map { trip in
                        DebugTripSnapshotTrip(
                            id: trip.id,
                            startDate: trip.startDate,
                            endDate: trip.endDate,
                            distanceMeters: trip.reportableDistanceMeters,
                            captureSource: trip.captureSource,
                            reviewStatus: trip.reviewStatus.rawValue,
                            classification: trip.classification?.rawValue,
                            needsAttention: trip.needsAttention,
                            attentionReasons: trip.attentionReasons,
                            legCount: trip.legs.count,
                            sourceTripIDs: trip.legs.compactMap(\.sourceTripID)
                        )
                    }
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            guard let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return
            }
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let url = supportDirectory.appendingPathComponent("MileageTrackerDebugTripSnapshot.json")
            // Xcode-launched debug tooling only (DEBUG + launch argument);
            // never runs on lock-screen background wakes.
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            diagnostics.record(DiagnosticEvent(category: "debug", message: "Wrote trip snapshot to \(url.lastPathComponent)"))
        } catch {
            diagnostics.record(DiagnosticEvent(category: "debug", message: "Trip snapshot failed: \(error.localizedDescription)"))
        }
    }
    #else
    private func writeDebugTripSnapshotIfNeeded() {}
    #endif

    /// Writes an in-progress recording state to the active-drive store so UI tests
    /// can exercise the current-drive glass bar. Uses the same two-sample arming
    /// recipe the reducer tests rely on to reach `.recording`. Only runs under
    /// `--seed-current-drive` in UI testing, where the real tracker is never
    /// configured, so the store is the sole source of `currentDrive`.
    private func seedCurrentDriveIfNeeded() {
        guard shouldSeedCurrentDrive, let activeDriveStore else { return }
        let start = Date().addingTimeInterval(-8 * 60)
        let context = TripDetectionContext(trustedBluetoothVehicleHint: true)
        let first = LocationSample(
            timestamp: start,
            latitude: 40.7411,
            longitude: -73.9897,
            horizontalAccuracy: 5,
            speedMetersPerSecond: 13,
            motionHint: .automotive
        )
        let second = LocationSample(
            timestamp: start.addingTimeInterval(45),
            latitude: 40.7536,
            longitude: -73.9897,
            horizontalAccuracy: 5,
            speedMetersPerSecond: 13,
            motionHint: .automotive
        )
        var reducer = DriveCaptureReducer()
        _ = reducer.apply(.location(first, receivedAt: first.timestamp, context: context, options: .normal))
        _ = reducer.apply(.location(second, receivedAt: second.timestamp, context: context, options: .normal))
        guard reducer.state.currentDriveSummary() != nil else {
            diagnostics.record(DiagnosticEvent(category: "ui-test", message: "Seed current drive did not enter recording"))
            return
        }
        do {
            try activeDriveStore.save(reducer.state)
            refreshCurrentDriveSnapshot()
        } catch {
            present(error, .saveChanges)
        }
    }

    private func runDriveSelfTestIfNeeded() {
        guard shouldRunDriveSelfTest else { return }
        #if DEBUG
        driveSelfTestStatus = String(localized: "Drive self-test running")
        diagnostics.record(DiagnosticEvent(category: "self-test", message: "Drive self-test started"))

        do {
            let locationProvider = SelfTestDriveLocationProvider()
            let runtime = DriveCaptureRuntime(
                activeDriveStore: activeDriveStore,
                completionCoordinator: DriveCompletionCoordinator(
                    tripStore: tripStore,
                    activeDriveStore: activeDriveStore,
                    diagnosticSampleStore: diagnosticSampleStore,
                    bluetoothHintStore: bluetoothHintStore,
                    configuration: .automatic
                ),
                diagnostics: diagnostics,
                diagnosticSampleStore: diagnosticSampleStore,
                captureEventStore: captureEventStore,
                pendingStartSignalStore: pendingDriveStartSignalStore,
                bluetoothVehicleHintProvider: { true },
                configuration: .automatic,
                locationProvider: locationProvider,
                motionEvidenceProvider: SelfTestMotionEvidenceProvider(),
                idleWakeProvider: SelfTestDriveIdleWakeProvider(),
                backgroundWakeProvider: SelfTestDriveBackgroundWakeProvider(),
                backgroundActivitySessionProvider: SelfTestBackgroundActivitySessionProvider(),
                locationServiceSessionProvider: SelfTestLocationServiceSessionProvider(),
                healthStatusProvider: SelfTestHealthStatusProvider(),
                diagnosticsMode: .detailed
            )
            runtime.onHealthChanged = { [weak self] health in
                self?.health = health
            }
            defer { runtime.stopMonitoring() }

            let samples = Self.driveSelfTestSamples()
            guard let startDate = samples.first?.timestamp else {
                throw DriveSelfTestError.noSamples
            }
            runtime.startMonitoring(rearmNoAnchorPriming: true)
            runtime.armDriveStart(trigger: .vehicleBluetooth, at: startDate)
            for sample in samples {
                locationProvider.emit(sample)
            }
            runtime.flush()
            refresh()
            guard let saved = trips.first(where: { $0.captureSource == "automatic" }) else {
                throw DriveSelfTestError.noTripCaptured
            }
            diagnostics.record(DiagnosticEvent(
                category: "self-test",
                message: "Drive self-test saved trip \(saved.id) with \(saved.miles) mi"
            ))
            refresh()
            driveSelfTestStatus = String(
                format: String(localized: "Drive self-test complete: %.1f mi"),
                saved.miles
            )
        } catch {
            driveSelfTestStatus = String(
                localized: "Drive self-test failed: \(error.localizedDescription)"
            )
            diagnostics.record(DiagnosticEvent(category: "self-test", message: error.localizedDescription))
            present(error, .generic)
        }
        #endif
    }

    #if DEBUG
    private enum DriveSelfTestError: LocalizedError {
        case noSamples
        case noTripCaptured

        var errorDescription: String? {
            switch self {
            case .noSamples:
                "no samples available"
            case .noTripCaptured:
                "no trip captured"
            }
        }
    }

    private static func driveSelfTestSamples() -> [LocationSample] {
        let start = Date().addingTimeInterval(-5 * 60)
        return [
            LocationSample(
                timestamp: start,
                latitude: 40,
                longitude: -73,
                horizontalAccuracy: 10,
                speedMetersPerSecond: 12,
                motionHint: .automotive
            ),
            LocationSample(
                timestamp: start.addingTimeInterval(90),
                latitude: 40.01,
                longitude: -73,
                horizontalAccuracy: 10,
                speedMetersPerSecond: 12,
                motionHint: .automotive
            ),
            LocationSample(
                timestamp: start.addingTimeInterval(275),
                latitude: 40.011,
                longitude: -73,
                horizontalAccuracy: 10,
                speedMetersPerSecond: 0,
                motionHint: .stationary
            )
        ]
    }
    #endif

    private func seedUITestDataIfNeeded() {
        guard shouldSeedUITestData else { return }
        guard (try? tripStore.fetchTrips().isEmpty) == true else { return }
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2026, month: 5, day: 24, hour: 8, minute: 30)) ?? Date()
        do {
            _ = try tripStore.createManualTrip(ManualTripInput(
                startDate: base,
                endDate: base.addingTimeInterval(30 * 60),
                startAddress: "Home",
                endAddress: "Client",
                distanceMeters: DistanceConversion.meters(fromMiles: 12.3),
                classification: .business,
                businessPurpose: "Client meeting",
                notes: "Seed business trip"
            ))
            _ = try tripStore.createManualTrip(ManualTripInput(
                startDate: base.addingTimeInterval(-86_400),
                endDate: base.addingTimeInterval(-86_400 + 20 * 60),
                startAddress: "Gym",
                endAddress: "Home",
                distanceMeters: DistanceConversion.meters(fromMiles: 4.2),
                classification: .personal,
                notes: "Seed personal trip"
            ))
            // The suggestion scenario needs a trip in To Review: the base
            // seed set is fully classified, so add one unclassified trip for
            // the canned provider to suggest on.
            if shouldSeedTripSuggestions {
                _ = try tripStore.createManualTrip(ManualTripInput(
                    startDate: base.addingTimeInterval(4 * 3_600),
                    endDate: base.addingTimeInterval(4 * 3_600 + 33 * 60),
                    startAddress: "111 Example St, Brooklyn",
                    endAddress: "350 5th Ave, New York",
                    distanceMeters: DistanceConversion.meters(fromMiles: 12.4),
                    classification: nil
                ))
            }
        } catch {
            present(error, .generic)
        }
    }

    /// Seeds one trip per review state so the Need Review surfaces have
    /// something to be exercised against: unclassified, business-without-a-
    /// purpose, engine-flagged, auto-marked, and fully resolved.
    /// Real Columbus addresses, matching the project's rule that fixtures and
    /// captures never use placeholder locations.
    private func seedUnresolvedMixIfNeeded() {
        guard shouldSeedUnresolvedMix else { return }
        // Idempotent: only seeds into a store this seeder has not filled.
        guard (try? tripStore.fetchTrips().count) ?? 1 <= 2 else { return }
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2026, month: 7, day: 24, hour: 14, minute: 41)) ?? Date()

        // Real Columbus coordinates so the row's map thumbnail actually
        // renders — `hasMapContent` needs endpoints, and a fixture without
        // them hides the very element the row layout is built around.
        let places: [String: Coordinate] = [
            "COSI": Coordinate(latitude: 39.9580, longitude: -83.0075),
            "North Market": Coordinate(latitude: 39.9714, longitude: -83.0032),
            "Franklin Park Conservatory": Coordinate(latitude: 39.9640, longitude: -82.9490),
            "Home": Coordinate(latitude: 40.0430, longitude: -83.0180),
            "German Village": Coordinate(latitude: 39.9455, longitude: -82.9950),
            "Easton Town Center": Coordinate(latitude: 40.0510, longitude: -82.9150),
            "Short North": Coordinate(latitude: 39.9800, longitude: -83.0030),
            "John Glenn Columbus Intl": Coordinate(latitude: 39.9980, longitude: -82.8920),
            "Ohio Theatre": Coordinate(latitude: 39.9605, longitude: -83.0000),
            "Whetstone Park": Coordinate(latitude: 40.0390, longitude: -83.0210),
            "Bexley": Coordinate(latitude: 39.9690, longitude: -82.9370),
            "Clintonville": Coordinate(latitude: 40.0430, longitude: -83.0180),
            "Wexner Center": Coordinate(latitude: 39.9970, longitude: -83.0090)
        ]

        /// A route drawn as a single straight segment reads as a scratch on the
        /// map rather than a drive, so each seeded trip carries a handful of
        /// waypoints that follow Columbus's actual street grid — enough for the
        /// row thumbnail and the detail map to look like something that was
        /// driven.
        func polyline(from origin: Coordinate, to destination: Coordinate) -> String {
            // Two dog-legs along the grid: out on one axis, across, then in.
            let first = Coordinate(latitude: origin.latitude, longitude: origin.longitude
                + (destination.longitude - origin.longitude) * 0.35)
            let second = Coordinate(
                latitude: origin.latitude + (destination.latitude - origin.latitude) * 0.55,
                longitude: origin.longitude + (destination.longitude - origin.longitude) * 0.45
            )
            let third = Coordinate(
                latitude: origin.latitude + (destination.latitude - origin.latitude) * 0.8,
                longitude: destination.longitude
            )
            return EncodedPolyline.encode([origin, first, second, third, destination])
        }

        func make(
            _ offsetDays: Int,
            _ minutes: Int,
            _ from: String,
            _ to: String,
            _ miles: Double,
            classification: TripClassification? = nil,
            purpose: String? = nil
        ) throws -> TripSummary {
            let start = base.addingTimeInterval(Double(offsetDays) * -86_400)
            let origin = places[from]
            let destination = places[to]
            return try tripStore.createManualTrip(ManualTripInput(
                startDate: start,
                endDate: start.addingTimeInterval(Double(minutes) * 60),
                startCoordinate: origin,
                endCoordinate: destination,
                startAddress: from,
                endAddress: to,
                distanceMeters: DistanceConversion.meters(fromMiles: miles),
                routePolyline: origin.flatMap { o in destination.map { polyline(from: o, to: $0) } },
                classification: classification,
                businessPurpose: purpose
            ))
        }

        do {
            // Engine-flagged and unclassified — the row that proves Resolve.
            let flagged = try make(0, 22, "COSI", "North Market", 6.4)
            _ = try tripStore.appendAttentionReason(
                tripID: flagged.id,
                reason: TransitTripClassifier.impossibleJumpReason
            )
            // Unclassified, clean.
            _ = try make(1, 26, "Franklin Park Conservatory", "Home", 11.2)
            // Business with no purpose: unresolved but NOT unclassified — the
            // state the old `classification == nil` list could not see.
            _ = try make(2, 31, "German Village", "Easton Town Center", 14.8, classification: .business)
            // Unclassified, older month, so month badges differ.
            _ = try make(37, 19, "Short North", "John Glenn Columbus Intl", 9.7)
            // Fully resolved, so "read" rows render beside unread ones.
            _ = try make(58, 24, "Home", "Ohio Theatre", 7.2, classification: .business, purpose: "Portrait session")
            _ = try make(59, 14, "Home", "Whetstone Park", 3.8, classification: .personal)
            // Auto-marked, so the "Auto ·" provenance prefix has a subject.
            _ = try make(59, 4, "Bexley", "Bexley", 0.3, classification: .notADrive)
            _ = try make(60, 12, "Clintonville", "Wexner Center", 4.9, classification: .personal)
            refresh()
        } catch {
            present(error, .generic)
        }
    }

    /// DEBUG demo data for exercising the REAL Foundation Models suggestion
    /// provider (`--uitesting --debug-seed-suggestion-demo`). Trips and
    /// preferences stay in the isolated test library. Calendar evidence must
    /// be supplied separately; this helper never writes to EventKit.
    private func seedSuggestionDemoDataIfNeeded() {
        #if DEBUG
        guard shouldSeedSuggestionDemoData else { return }
        guard (try? tripStore.fetchTrips().isEmpty) == true else { return }

        // Example endpoints for the isolated demo store.
        let home = Coordinate(latitude: 40.702, longitude: -73.988)
        let homeAddress = "111 Example St, Brooklyn"
        let homeComponents = TripEndpointAddressComponents(
            streetNumber: "111", streetName: "Example St", city: "Brooklyn"
        )
        let grandCentral = Coordinate(latitude: 40.75273, longitude: -73.97723)
        let grandCentralAddress = "89 E 42nd St, New York"
        let grandCentralComponents = TripEndpointAddressComponents(
            streetNumber: "89", streetName: "E 42nd St", city: "New York"
        )

        let now = Date()
        do {
            func seed(
                start: Date,
                from: (Coordinate, String, TripEndpointAddressComponents?),
                to: (Coordinate, String, TripEndpointAddressComponents?),
                miles: Double,
                classification: TripClassification?,
                purpose: String? = nil
            ) throws {
                let trip = try tripStore.createManualTrip(ManualTripInput(
                    startDate: start,
                    endDate: start.addingTimeInterval(30 * 60),
                    startCoordinate: from.0,
                    endCoordinate: to.0,
                    startAddress: from.1,
                    endAddress: to.1,
                    distanceMeters: DistanceConversion.meters(fromMiles: miles),
                    classification: classification,
                    businessPurpose: purpose
                ))
                _ = try tripStore.updateAddresses(
                    tripID: trip.id,
                    startAddress: from.1, endAddress: to.1,
                    startAddressComponents: from.2, endAddressComponents: to.2
                )
            }

            // Unclassified: to Grand Central (calendar-location evidence).
            try seed(
                start: now.addingTimeInterval(-65 * 60),
                from: (home, homeAddress, homeComponents),
                to: (grandCentral, grandCentralAddress, grandCentralComponents),
                miles: 5.8, classification: nil
            )
        } catch {
            present(error, .generic)
        }

        // My Card path needs no Contacts grant: home comes from preferences.
        preferences.userHomeStreetLine = "111 Example St"
        preferences.userHomeCity = "Brooklyn"
        // Through the model property so its didSet runs the permission flow
        // (calendar access is pre-granted via `simctl privacy`).
        calendarSuggestionEvidenceEnabled = true

        // Never create fixtures in EventKit: the default calendar may sync
        // to the user's personal account, even on a developer simulator.
        #endif
    }

    /// UI-test seeding for the multi-vehicle surfaces: two vehicles plus a
    /// deterministic attribution of the seeded trips. Runs only under
    /// `--seed-vehicles`; it runs before `createDefaultVehicleIfNeeded()` so the
    /// seeded pair wins and the default "My Car" backfill no-ops.
    private func seedVehiclesIfNeeded() {
        guard shouldSeedVehicles else { return }
        guard (try? vehicleStore.fetchVehicles(includeArchived: true).isEmpty) == true else { return }
        do {
            let honda = try vehicleStore.createVehicle(
                name: "Honda Odyssey",
                colorHex: VehicleAppearance.colorHexOptions[0],
                symbolName: "car.fill"
            )
            let ford = try vehicleStore.createVehicle(
                name: "Ford F-150",
                colorHex: VehicleAppearance.colorHexOptions[1],
                symbolName: "truck.box.fill"
            )
            reloadVehicles()
            // Assign seeded trips deterministically: the Home → Client business
            // trip to the Honda, the Gym → Home personal trip to the Ford. The
            // connection-decision fixture leaves its target unassigned so the
            // production choice path can apply and expose automatic provenance.
            let seededTrips = (try? tripStore.fetchTrips()) ?? []
            for trip in seededTrips {
                if trip.endAddress == "Client", !shouldSeedVehicleConnectionDecision {
                    _ = try? tripStore.assignVehicle(tripID: trip.id, vehicleID: honda.id)
                } else if trip.startAddress == "Gym" {
                    _ = try? tripStore.assignVehicle(tripID: trip.id, vehicleID: ford.id)
                }
            }
        } catch {
            present(error, .generic)
        }
    }

    /// Presents a deterministic, stable Bluetooth-to-vehicle decision for the
    /// focused UI test. The observation is stored through the production path
    /// so choosing a vehicle exercises the real atomic mapping transaction.
    private func seedVehicleConnectionDecisionIfNeeded() {
        guard shouldSeedVehicleConnectionDecision,
              pendingVehicleConnectionDecision == nil,
              let trip = trips.first(where: { $0.endAddress == "Client" }) ?? trips.first else {
            return
        }
        do {
            let observation = try bluetoothHintStore.recordObservation(
                identifier: "ui-test-subaru-bt",
                displayName: "SUBARU BT",
                source: .audioRoute,
                connectionKind: .bluetooth,
                identityQuality: .stablePortIdentifier,
                observedAt: trip.startDate
            )
            guard let hint = try bluetoothHintStore.fetchHints(
                matching: [observation.identifierHash]
            ).first else {
                return
            }
            pendingVehicleConnectionDecision = PendingVehicleConnectionDecision(
                tripID: trip.id,
                kind: .unknownConnection(hint: hint, suggestion: nil)
            )
        } catch {
            present(error, .saveChanges)
        }
    }

    private func seedAppStoreScreenshotDataIfNeeded() {
        guard shouldSeedAppStoreScreenshotData else { return }
        guard (try? tripStore.fetchTrips().isEmpty) == true else { return }
        do {
            try seedSampleTrips()
        } catch {
            present(error, .generic)
        }
    }

    private func seedSampleTrips() throws {
        let seed = try AppStoreScreenshotSeedCatalog.seed(for: screenshotSeedLocale)
        let calendar = Calendar(identifier: .gregorian)
        func date(month: Int, day: Int, hour: Int, minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)) ?? Date()
        }

        // Locale-appropriate rate so Reports never shows the US default in a
        // metric/foreign-currency capture.
        mileageRateSchedule = try mileageRateScheduleStore.saveSchedule(
            MileageRateSchedule(baseRate: MileageRate(
                amountPerUnit: seed.mileageRate.amountPerUnit,
                unit: seed.mileageRate.unit
            ))
        )
        mileageRate = mileageRateSchedule.rate(on: Date())
        businessPurposePresets = try businessPurposePresetStore.savePurposes(seed.businessPurposePresets)
        // Force kilometers for metric-market seeds so their screenshots show km.
        // The app's `.system` default should resolve metric locales to km, but
        // under the UI-test locale override it doesn't, so pin it explicitly.
        // en-US keeps `.system` (→ miles, "Automatic (mi)"); the rate is already
        // seeded in km, so setDistanceUnitPreference's re-quote is a no-op here.
        if seed.mileageRate.unit == .kilometers {
            setDistanceUnitPreference(.kilometers)
        }
        // Pin the locale's currency directly (not setCurrencyCode, which raises
        // the "review your rate" hint banner that would show in the settings
        // screenshot). Deterministic so metric markets never show USD.
        if let currencyCode = seed.currencyCode {
            try unitsCurrencyStore.saveCurrencyCode(currencyCode)
            self.currencyCode = currencyCode
        }

        for (index, tripSeed) in seed.trips.enumerated() {
            let routeCoordinates = EncodedPolyline.decode(tripSeed.encodedRoute) ?? []
            let startDate = date(
                month: tripSeed.month,
                day: tripSeed.day,
                hour: tripSeed.hour,
                minute: tripSeed.minute
            )
            let endDate = startDate.addingTimeInterval(tripSeed.durationMinutes * 60)
            let trip = try tripStore.createManualTrip(ManualTripInput(
                startDate: startDate,
                endDate: endDate,
                startCoordinate: routeCoordinates.first,
                endCoordinate: routeCoordinates.last,
                startAddress: tripSeed.origin,
                endAddress: tripSeed.destination,
                distanceMeters: tripSeed.distanceMeters,
                routePolyline: tripSeed.encodedRoute,
                classification: tripSeed.classification,
                businessPurpose: tripSeed.businessPurpose,
                notes: tripSeed.notes
            ), id: isUITesting
                ? UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!
                : UUID())
            if tripSeed.tolls > 0 {
                _ = try tripStore.addFee(
                    tripID: trip.id,
                    category: .toll,
                    amount: tripSeed.tolls,
                    occurredAt: startDate,
                    label: TripFeeCategory.toll.displayName,
                    source: .manual
                )
            }
            if tripSeed.parking > 0 {
                _ = try tripStore.addFee(
                    tripID: trip.id,
                    category: .parking,
                    amount: tripSeed.parking,
                    occurredAt: endDate,
                    label: TripFeeCategory.parking.displayName,
                    source: .manual
                )
            }
            // Replayed by the UI-test provider so the To Review banner shows
            // the same advisory suggestion Foundation Models would produce.
            if let suggestion = tripSeed.suggestion {
                (suggestionProvider as? UITestTripSuggestionProvider)?.register(
                    UITestTripSuggestionProvider.Fixture(
                        classification: suggestion.classification,
                        businessPurpose: suggestion.businessPurpose,
                        evidence: [.calendarEvent(title: suggestion.calendarEventTitle)]
                    ),
                    for: trip.id
                )
            }
        }
    }
}

/// Bridges Core Location authorization and accuracy changes into a callback so
/// the permission checklist does not depend solely on a bounded polling window.
@MainActor
private final class PermissionLocationAuthorizationObserver: NSObject, CLLocationManagerDelegate {
    var onChange: (@MainActor () -> Void)?

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.onChange?()
        }
    }
}

#if DEBUG
@MainActor
private final class SelfTestDriveLocationProvider: DriveLocationProvider {
    var onUpdate: (@MainActor (DriveLocationUpdate) -> Void)?
    private(set) var isActive = false

    func start(configuration _: DriveLocationLiveConfiguration) {
        isActive = true
    }

    func stop() {
        isActive = false
    }

    func emit(_ sample: LocationSample) {
        onUpdate?(DriveLocationUpdate(
            sample: sample,
            receivedAt: sample.timestamp,
            stationary: sample.motionHint == .stationary
        ))
    }
}

@MainActor
private final class SelfTestMotionEvidenceProvider: MotionEvidenceProvider {
    var onActivity: (@MainActor (MotionActivitySnapshot) -> Void)?

    func snapshot(around _: Date) async -> MotionActivitySnapshot? {
        nil
    }

    func primeHistory() {}
    func startLiveUpdates() {}
    func stopLiveUpdates() {}
}

@MainActor
private final class SelfTestDriveIdleWakeProvider: DriveIdleWakeProvider {
    var onWake: (@MainActor (Date) -> Void)?
    private(set) var isMonitoring = false
    var isConsumingEvents: Bool { isMonitoring }

    func startMonitoring(anchor _: LocationSample) {
        isMonitoring = true
    }

    func stopMonitoring() {
        isMonitoring = false
    }

    func restoreMonitoringIfNeeded() {}
}

@MainActor
private final class SelfTestDriveBackgroundWakeProvider: DriveBackgroundWakeProvider {
    var onSignificantChange: (@MainActor (Date, LocationSample?) -> Void)?
    var onVisitDeparture: (@MainActor (Date) -> Void)?
    private(set) var isMonitoring = false

    func startMonitoring() {
        isMonitoring = true
    }

    func stopMonitoring() {
        isMonitoring = false
    }
}

@MainActor
private final class SelfTestBackgroundActivitySessionProvider: DriveBackgroundActivitySessionProvider {
    private(set) var isActive = false

    func start() {
        isActive = true
    }

    func stop() {
        isActive = false
    }
}

@MainActor
private final class SelfTestLocationServiceSessionProvider: DriveLocationServiceSessionProvider {
    private(set) var isActive = false
    var onDiagnostic: (@MainActor (DriveServiceSessionDiagnostic) -> Void)?

    func startAlways(fullAccuracyPurposeKey _: String) {
        isActive = true
    }

    func stop() {
        isActive = false
    }
}

@MainActor
private final class SelfTestHealthStatusProvider: DriveCaptureHealthStatusProvider {
    var alwaysLocationAuthorized: Bool { true }
    var preciseLocationEnabled: Bool { true }
    var motionAuthorized: Bool { true }
    var backgroundRefreshAvailable: Bool { true }
}
#endif
