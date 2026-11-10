import AppCore
import SwiftUI
import UIKit

/// The app's root. It owns the navigation path and every modal surface; the
/// screens themselves live in `MailboxesList` and `DriveListView`.
///
/// Modals stay concentrated here on purpose. `canSafelyPresentVehicleConnectionDecision`
/// is a hand-written enumeration of every other presentation, and the live
/// drive's deep-link gates depend on one presenter — spreading sheets across
/// pushed screens would silently break both.
struct ContentView: View {
    /// Root-level modal surfaces that are mutually exclusive; one item-bound
    /// sheet replaces a flag per surface. Onboarding stays separate because it
    /// is driven both ways by `hasCompletedOnboarding`.
    fileprivate enum HomeSheet: String, Identifiable {
        case settings
        case manualTripEditor
        case bulkCustomPurpose

        var id: String { rawValue }
    }

    @Environment(MileageAppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    /// Where the user is, as one array, whichever shell is mounted: an optional
    /// leading `.scope` (the selected mailbox) followed by an optional `.trip`.
    ///
    /// The compact shell binds this to its stack. The split shell uses its
    /// leading scope as sidebar selection and keeps an optional trip only as
    /// canonical context for resizing, exports, and new-trip defaults; the
    /// detail column itself is not driven by this path.
    @State private var path: [TripsRoute] = []
    /// Mail shows its three columns; `.automatic` decides for itself and on
    /// iPad settles on the reading pane alone.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// User-dragged column widths, persisted so the layout survives relaunch
    /// the way Mail's does (the system does not remember them itself).
    /// Frozen at launch: feeding live measurements back into `ideal` mid-drag
    /// re-laid-out the columns underneath the drag. Device-local UI state,
    /// deliberately not in `Preferences`.
    @State private var launchSidebarWidth = SplitColumnWidthSpec.sidebar.storedWidth()
    @State private var launchContentWidth = SplitColumnWidthSpec.content.storedWidth()
    /// How far the floating sidebar overlaps the content column, measured from
    /// that column's leading safe area. Zero whenever the sidebar is hidden,
    /// which is what makes the list's consumer switch itself off.
    @State private var contentColumnUnderlap: CGFloat = 0
    @State private var activeSheet: HomeSheet?
    @State private var quickEntryRequest: QuickTripEntryRequest?
    @State private var feeEntryRequest: FeeEntryRequest?
    @State private var activeShare: ActivityShareItem?
    @State private var isPreparingReportExport = false
    @State private var tripPendingDeletion: TripSummary?
    @State private var bulkTripsPendingDeletion: [TripSummary] = []
    @State private var showingOnboarding = false
    @State private var showingSampleDataConfirmation = false
    @State private var driveFeeEntryRequest: FeeEntryRequest?
    @State private var showingCurrentDriveVehiclePicker = false
    @State private var showingRememberCurrentConnectionPicker = false
    /// Set by whichever pushed list opened the custom-purpose sheet, so the
    /// typed purpose lands on that list's selection rather than a stale one.
    @State private var bulkCustomPurposeHandler: ((String) -> Void)?
    /// The run of drives the Trip Detail chevrons walk, captured once when the
    /// detail screen is pushed.
    ///
    /// Snapshotted rather than derived live for two reasons. Correctness:
    /// resolving the drive you are reading would otherwise drop it out of the
    /// queue and dissolve the "next" target under you. Performance: deriving it
    /// inside `navigationDestination` re-sorted every trip on every render of
    /// that screen, which is enough to hang the app under sustained scrolling.
    @State private var reviewQueue: [UUID] = []
    /// Guards the launch push so returning to the root does not re-open the
    /// inbox under the user.
    @State private var hasOpenedInbox = false
    /// Seeds the manual editor when Add Trip is used from a past month.
    @State private var manualTripDefaultDate: Date?
    /// Root-owned map context survives navigation away from a list.
    @State private var mapMailbox: DriveMapMailboxContext?
    @State private var mapHeroWidth: CGFloat = 0
    @State private var mapCompactRows = false
    @State private var tripMapNavigation = TripMapNavigationPreparation()
    /// The order the pushed list is currently rendering, reported by it.
    @State private var visibleTripOrder: [UUID] = []
    /// One system-owned selection for every list shell. On Mac the expanded
    /// reading pane is a direct presentation of this set. On touch platforms
    /// it remains independent from the trip opened by a primary action, so
    /// Select-mode checkmarks never navigate unexpectedly.
    ///
    /// On the Mac this is the ONE selection fact: the trailing `.trip` route
    /// in `path` is derived from it by `synchronizeMacRouteToSelection`, run
    /// from a single observer in `withStateResets` — never written alongside
    /// a selection change by hand.
    @State private var selectedTripIDs: Set<UUID> = []
    /// Compact-Mac-only fallback for the host's primary-action delivery. That
    /// path can report A → ∅ → B, so an empty write waits two turns for the
    /// primary action that identifies B. The expanded Mac list bypasses this
    /// timing code and writes its native `List(selection:)` Set directly.
    @State private var pendingEmptyCompactMacSelectionTask: Task<Void, Never>?
    /// Holds compact Mac's freshly-opened selection across the trailing empty
    /// write that can follow a context-menu primary action. Expanded Mac has
    /// no primary action and therefore never creates a settle task.
    @State private var compactMacPrimaryActionSettleTask: Task<Void, Never>?
    /// Monotonic ownership token for both compact-Mac deferred tasks. Every
    /// schedule, cancellation, and replacement advances it, so a canceled
    /// task that resumes after `Task.yield()` cannot mutate newer shared state.
    @State private var compactSelectionGeneration: UInt64 = 0
    /// A deterministic UI-test witness for reading-pane transitions. Screen
    /// sampling can miss a one-frame placeholder; this records the resolved
    /// presentation values themselves, and is exposed only under --uitesting.
    @State private var readingPanePresentationTrace: [String] = []
    /// Trip Detail owns a few presentation surfaces locally. It reports their
    /// aggregate state here so root-level deep links do not present over them.
    @State private var tripDetailIsPresentingModal = false
    /// The live bar owns its purpose editor visually, but reports that sheet
    /// here so deferred Live Activity actions remain serialized with every
    /// other presentation.
    @State private var currentDriveBarIsPresentingPurposeEditor = false
    /// A scene-local preference that survives mailbox navigation and new legs.
    @State private var currentDriveBarIsMinimized = false

    var body: some View {
        // The split shell's sidebar is always on screen beside a
        // possibly-filtered list, so its totals never narrow; the compact
        // root keeps the filtered directory (invisible in practice — the
        // scope-change reset holds the root at .all — but byte-identical to
        // what shipped).
        let directory = MailboxDirectory(
            trips: model.trips,
            vehicleFilter: usesSplitView ? .all : model.vehicleFilter,
            primaryVehicleID: model.primaryVehicleID
        )

        // Split so the type-checker sees three bounded expressions instead of
        // one: the navigation shell, its lifecycle/deep-link handlers, and the
        // modal pile below.
        mapWarmingShell(directory: directory)
            .modifier(HomeSheetsModifier(
            showingOnboarding: $showingOnboarding,
            activeSheet: $activeSheet,
            quickEntryRequest: $quickEntryRequest,
            feeEntryRequest: $feeEntryRequest,
            driveFeeEntryRequest: $driveFeeEntryRequest,
            activeShare: $activeShare,
            manualTripDefaultDate: manualTripDefaultDate,
            onBulkPurpose: { purpose in
                bulkCustomPurposeHandler?(purpose)
                bulkCustomPurposeHandler = nil
            }
        ))
        .overlay {
            if isPreparingReportExport {
                ProgressView("Preparing Report")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("preparingMileageReportExport")
            }
        }
        .confirmationDialog(
            "Vehicle for this drive",
            isPresented: $showingCurrentDriveVehiclePicker,
            titleVisibility: .visible
        ) {
            Button("Automatic") {
                model.setCurrentDriveVehicle(nil)
            }
            ForEach(model.vehicles) { vehicle in
                Button(vehicle.name) {
                    model.setCurrentDriveVehicle(vehicle.id)
                }
            }
            if !model.currentDriveConnectionRememberCandidates.isEmpty {
                Button("Remember car connection…") {
                    Task { @MainActor in
                        await Task.yield()
                        showingRememberCurrentConnectionPicker = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected vehicle applies to the entire current drive.")
        }
        .confirmationDialog(
            rememberCurrentConnectionTitle,
            isPresented: $showingRememberCurrentConnectionPicker,
            titleVisibility: .visible
        ) {
            if let vehicleID = model.currentDrive?.vehicleID {
                ForEach(model.currentDriveConnectionRememberCandidates) { hint in
                    Button(vehicleConnectionLabel(for: hint)) {
                        model.rememberCurrentConnection(hint, for: vehicleID)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(rememberCurrentConnectionMessage)
        }
        .sheet(item: pendingVehicleConnectionDecisionItemBinding) { decision in
            VehicleConnectionDecisionSheet(
                decision: decision,
                vehicles: model.vehicles,
                trip: model.trip(id: decision.tripID),
                distanceUnit: model.distanceUnit,
                chooseVehicle: model.chooseVehicleForPendingConnection,
                ignoreConnection: model.ignorePendingVehicleConnection
            )
        }
        .alert(
            "Delete this trip?",
            isPresented: Binding(
                get: { tripPendingDeletion != nil },
                set: { if !$0 { tripPendingDeletion = nil } }
            ),
            presenting: tripPendingDeletion
        ) { trip in
            Button("Delete Trip", role: .destructive) {
                closeTrip(trip.id)
                model.delete(trip)
            }
            Button("Cancel", role: .cancel) {}
        } message: { trip in
            Text(deleteConfirmationMessage(for: trip))
        }
        .alert(
            bulkDeleteConfirmationTitle,
            isPresented: Binding(
                get: { !bulkTripsPendingDeletion.isEmpty },
                set: { if !$0 { bulkTripsPendingDeletion = [] } }
            )
        ) {
            Button(bulkDeleteButtonTitle, role: .destructive) {
                deletePendingSelection()
            }
            Button("Cancel", role: .cancel) {
                bulkTripsPendingDeletion = []
            }
        } message: {
            Text(bulkDeleteConfirmationMessage)
        }
        .alert("Load sample data?", isPresented: $showingSampleDataConfirmation) {
            Button("Load Sample Data") {
                model.loadSampleData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This adds fictional trips so you can try review, maps, reports, and exports before recording a real drive.")
        }
        .onChange(of: model.currentDrive) { _, currentDrive in
            if currentDrive == nil {
                driveFeeEntryRequest = nil
                showingCurrentDriveVehiclePicker = false
                showingRememberCurrentConnectionPicker = false
                currentDriveBarIsPresentingPurposeEditor = false
                currentDriveBarIsMinimized = false
            } else {
                presentDeferredCurrentDriveRequestIfPossible()
            }
        }
        .onChange(of: model.currentDrivePresentationRequestID) { _, _ in
            presentDeferredCurrentDriveRequestIfPossible()
        }
        .onChange(of: model.currentDriveFeeRequest) { _, _ in
            presentDeferredCurrentDriveRequestIfPossible()
        }
        .onChange(of: model.currentDriveVehicleRequestID) { _, _ in
            presentDeferredCurrentDriveRequestIfPossible()
        }
        .onChange(of: model.currentDriveNewLegRequestID) { _, _ in
            presentDeferredCurrentDriveRequestIfPossible()
        }
        .onChange(of: model.appLock.lockState) { _, _ in
            presentDeferredCurrentDriveRequestIfPossible()
        }
        .onChange(of: hasBlockingPresentation) { _, isBlocked in
            guard !isBlocked else { return }
            presentDeferredCurrentDriveRequestIfPossible()
        }
        .alert(
            model.errorAlert?.title ?? "",
            isPresented: Binding(
                get: { model.errorAlert != nil },
                set: { if !$0 { model.errorAlert = nil } }
            ),
            presenting: model.errorAlert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .overlay(alignment: .bottom) {
            if let driveSelfTestStatus = model.driveSelfTestStatus {
                Text(driveSelfTestStatus)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("driveSelfTestStatus")
                    .padding(.bottom, 12)
            }
        }
        .allowsHitTesting(!model.isAwaitingProtectedData)
        .overlay {
            if model.isAwaitingProtectedData {
                ContentUnavailableView(
                    "Unlock Your Device to Continue",
                    systemImage: "lock",
                    description: Text("Mileager will load your trips automatically after this device is unlocked.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground).ignoresSafeArea())
                .accessibilityIdentifier("protectedDataWaitingView")
            }
        }
        .background {
            // Which shell mounted, published for UI tests.
            //
            // The alternative is inferring it from the device or from how many
            // navigation bars exist, and both are exactly the vacuous-pass trap
            // this marker exists to close: a collapsed split view mounts every
            // column, so "the list appeared" says nothing about which column is
            // fronted. The test asks the app instead of guessing.
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier(
                    shell == .split ? "navigationShellSplit" : "navigationShellStack"
                )
                .allowsHitTesting(false)
        }
    }

    /// One navigation state, two shells. Split from `body` (with
    /// `withNavigationLifecycle` and the modal pile) so the type-checker sees
    /// bounded expressions.
    @ViewBuilder
    private func navigationShell(directory: MailboxDirectory) -> some View {
        if usesSplitView {
            splitShell(directory: directory)
        } else {
            compactShell(directory: directory)
        }
    }

    /// Everything the shell decision consults, gathered in one place.
    ///
    /// This is the ONLY site in the app that reads `horizontalSizeClass` or
    /// the interface idiom — the rule itself, and the long explanation of why
    /// a phone never gets a split view, live on `NavigationShellResolution`
    /// where they can be unit-tested.
    private var shellContext: NavigationShellContext {
        NavigationShellContext(
            horizontalSizeClass: horizontalSizeClass,
            idiom: UIDevice.current.userInterfaceIdiom,
            forcedShell: model.shellOverrideForUITesting
        )
    }

    private var shell: NavigationShell {
        NavigationShellResolution.shell(for: shellContext)
    }

    /// Width-dependent behavior gates on the SHELL, never on the raw size
    /// class: a landscape Max-class iPhone reports regular width while
    /// mounting the stack.
    private var usesSplitView: Bool { shell == .split }

    /// The iPhone shell: Mailboxes → list → trip in one stack, where a pop is
    /// an ordinary pop and a push is an array assignment.
    private func compactShell(directory: MailboxDirectory) -> some View {
        NavigationStack(path: $path) {
            MailboxesList(
                directory: directory,
                onLoadSampleData: { showingSampleDataConfirmation = true },
                // Mailbox rows carry no filter indication, so their exports
                // are always the full period.
                onExportMonth: { exportMonth($0, format: $1, vehicleFilter: .all) },
                onOpenSettings: { activeSheet = .settings }
            )
            // Suppressed whenever anything is shown above the root, so only
            // the visible screen publishes the current-drive controls.
            .currentDriveBar(
                suppressed: !path.isEmpty,
                isMinimized: $currentDriveBarIsMinimized,
                isPresentingPurposeEditor: $currentDriveBarIsPresentingPurposeEditor,
                onAddFee: { category in driveFeeEntryRequest = .draft(category: category) },
                onChooseVehicle: { showingCurrentDriveVehiclePicker = true }
            )
            .toolbar { rootToolbarContent() }
            .navigationDestination(for: TripsRoute.self) { route in
                destination(for: route)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { mapHeroWidth = $0 }
        .focusedSceneValue(\.driveExportCommandActions, exportCommandActions(directory: directory))
        .focusedSceneValue(\.driveSceneCommandActions, sceneCommandActions())
    }

    /// The Mac and iPad shell: Mail's three columns, mounted only at regular
    /// width and therefore never collapsed.
    private func splitShell(directory: MailboxDirectory) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MailboxesList(
                directory: directory,
                selection: scopeSelection,
                showsSettingsRow: true,
                onLoadSampleData: { showingSampleDataConfirmation = true },
                // The sidebar sits beside a possibly-filtered list with no
                // filter indication of its own — its exports are always the
                // full period.
                onExportMonth: { exportMonth($0, format: $1, vehicleFilter: .all) },
                onOpenSettings: { activeSheet = .settings }
            )
            // Applied directly to the column content, ahead of the bar/toolbar
            // wrappers, so the width preference registers reliably.
            // A min/ideal/max RANGE, not a fixed width: the range is what
            // makes the divider user-draggable (Mail-style column resizing).
            // The ideal is the persisted user width; measuring the column
            // keeps it current (there is no drag-ended callback).
            .navigationSplitViewColumnWidth(
                min: SplitColumnWidthSpec.sidebar.range.lowerBound,
                ideal: launchSidebarWidth,
                max: SplitColumnWidthSpec.sidebar.range.upperBound
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                recordColumnWidth(width, spec: .sidebar)
            }
            .toolbar { rootToolbarContent() }
        } content: {
            // The Mail shape: the trip list is its own mid-width column, the
            // reading pane gets the rest. The live bar rides the list or the
            // no-selection pane here — never the sidebar, which always has a
            // column beside it at this width.
            contentColumn
                // Measured HERE and consumed by the list itself, never both in
                // one place: the consumer drops this very inset, so anything
                // measuring from inside it reads zero and drives the value
                // straight back to nothing. `SidebarUnderlapConsumed` says why
                // the trip list needs it gone.
                .environment(\.sidebarUnderlap, contentColumnUnderlap)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.safeAreaInsets.leading
                } action: { leading in
                    contentColumnUnderlap = leading
                }
                .navigationSplitViewColumnWidth(
                    min: SplitColumnWidthSpec.content.range.lowerBound,
                    ideal: launchContentWidth,
                    max: SplitColumnWidthSpec.content.range.upperBound
                )
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    recordColumnWidth(width, spec: .content)
                }
        } detail: {
            // Peer trips are root presentations, not destinations pushed onto
            // a detail stack. Replacing A with B therefore has no intermediate
            // empty route and no horizontal navigation transition.
            NavigationStack {
                readingPane
            }
            // Measure the column, including when the empty state's intrinsic
            // width is narrower than the Form that will occupy it.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { mapHeroWidth = $0 }
        }
        .onAppear {
            // The ideal widths are frozen at launch on purpose — feeding live
            // measurements back mid-drag re-lays out the columns underneath
            // the drag. Re-reading them when this shell mounts keeps a width
            // dragged earlier in the session from reverting after a trip
            // through compact width (a narrowed and re-widened Mac window).
            launchSidebarWidth = SplitColumnWidthSpec.sidebar.storedWidth()
            launchContentWidth = SplitColumnWidthSpec.content.storedWidth()
        }
        .focusedSceneValue(\.driveExportCommandActions, exportCommandActions(directory: directory))
        .focusedSceneValue(\.driveSceneCommandActions, sceneCommandActions())
    }

    /// The sidebar's selection: the scope at the root of `path`, if any.
    /// Selecting a mailbox replaces the whole path, which is what the stack
    /// shell's `open(scope:)` does too.
    private var scopeSelection: Binding<TripsRoute?> {
        Binding(
            get: { selectedScope },
            set: { newValue in
                guard let newValue, case .scope = newValue else {
                    closeScope()
                    return
                }
                selectedTripIDs = []
                path = [newValue]
            }
        )
    }

    private func mapWarmingShell(directory: MailboxDirectory) -> some View {
        withNavigationLifecycle(navigationShell(directory: directory))
            .modifier(DriveMapWarmingModifier(mailboxIDs: visibleTripOrder, mailbox: mapMailbox, selectedID: openTripID,
                compactRows: mapCompactRows, heroWidth: mapHeroWidth))
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { tripMapNavigation.cancel() }
            }
            .onChange(of: model.isCommandSurfaceAvailable) { _, available in
                if !available { tripMapNavigation.cancel() }
            }
            .onDisappear { tripMapNavigation.cancel() }
    }

    private var selectedScope: TripsRoute? {
        if case .scope = path.first { return path.first }
        return nil
    }

    /// The canonical trip route: a pushed destination in the compact shell and
    /// the primary-action trip in the expanded iPad shell. On Mac the reading
    /// pane resolves from `selectedTripIDs`; its singleton is synchronized to
    /// this route only for compact transitions and command context.
    private var openTripID: UUID? {
        if case let .trip(tripID) = path.last { return tripID }
        return nil
    }

    /// The deep-link, launch, and selection lifecycle handlers.
    ///
    /// Two functions, not one, and the split is load-bearing rather than
    /// cosmetic: at eleven chained modifiers the Swift type-checker gave up on
    /// this expression ("unable to type-check in reasonable time"), which is a
    /// build failure rather than a slow build. Keep each half short.
    private func withNavigationLifecycle(_ content: some View) -> some View {
        withStateResets(content)
            .onChange(of: model.requestedTripSearch) { _, requested in
                guard model.isCommandSurfaceAvailable, requested != nil else { return }
                open(scope: .allTrips)
            }
            .onChange(of: model.requestedTripDetailID) { _, requested in
                guard !model.isAwaitingProtectedData, let requested else { return }
                model.requestedTripDetailID = nil
                openTrip(requested)
            }
            .onChange(of: model.requestedReportsMonthStart) { _, requested in
                guard !model.isAwaitingProtectedData, let requested else { return }
                model.requestedReportsMonthStart = nil
                open(scope: .month(DriveMonthSummary.monthInterval(containing: requested).start))
            }
            .onChange(of: model.requestedNeedsReview) { _, requested in
                guard !model.isAwaitingProtectedData, requested else { return }
                model.requestedNeedsReview = false
                open(scope: .needsReview)
            }
            .onAppear {
                if model.isAwaitingProtectedData {
                    showingOnboarding = false
                } else {
                    resumeAfterProtectedDataLoad()
                }
            }
            .onChange(of: model.hasCompletedOnboarding) { _, completed in
                showingOnboarding = !model.isAwaitingProtectedData && !completed
            }
            .onChange(of: model.isAwaitingProtectedData) { _, isAwaiting in
                if isAwaiting {
                    showingOnboarding = false
                } else {
                    resumeAfterProtectedDataLoad()
                }
            }
            .onChange(of: model.hasLoadedInitialTrips, initial: true) { _, hasLoaded in
                guard hasLoaded else { return }
                openInboxOnFirstAppearance()
            }
    }

    /// The half that clears state a navigation change has invalidated.
    ///
    /// The parameter is `content`, not `shell`: this view already has a `shell`
    /// property (the `NavigationShell` one of these handlers observes), and a
    /// parameter of that name shadowed it silently — `onChange(of: shell)`
    /// compiled as an attempt to observe the VIEW and failed with "requires
    /// that 'some View' conform to 'Equatable'".
    private func withStateResets(_ content: some View) -> some View {
        content
            .onChange(of: model.vehicles) { _, _ in
                resetVehicleFilterIfNeeded()
            }
            .onChange(of: selectedScope) { _, _ in
                // The vehicle filter belongs to the selected list where it is
                // visible, and the reported row order describes only the list
                // that reported it — every scope change resets both. The
                // Mailboxes sidebar has no filter control, so a carried-over
                // filter would silently narrow its month/year totals and
                // exports.
                model.vehicleFilter = .all
                visibleTripOrder = []
                mapMailbox = nil
                // A selection belongs to its mailbox. The root owns it now,
                // so it must explicitly clear what the outgoing list selected.
                selectedTripIDs = []
            }
            .onChange(of: shell) { _, newShell in
                if model.platform.isMac {
                    // A trip pushed while the Mac window was narrow becomes
                    // the split view's singleton selection when it widens.
                    // Multi-selection survives a resize because its state is
                    // root-owned rather than recreated with the list.
                    if newShell == .split {
                        if let openTripID {
                            selectedTripIDs = [openTripID]
                        }
                        synchronizeMacRouteToSelection()
                    }
                } else {
                    // Touch Select mode itself is list-local and ends when a
                    // shell swap destroys that list.
                    selectedTripIDs = []
                }
            }
            .onChange(of: model.tripIDs) { _, availableIDs in
                selectedTripIDs.formIntersection(availableIDs)
                if let openTripID, !availableIDs.contains(openTripID) {
                    closeTrip(openTripID)
                }
            }
            // The one place the Mac's route follows its selection. Every
            // selection write — a click, a chord, a prune, a deep link, a
            // delete — lands here, so no writer has to remember to sync.
            .onChange(of: selectedTripIDs) { _, _ in
                synchronizeMacRouteToSelection()
            }
            .onChange(of: path) { oldPath, newPath in
                tripMapNavigation.cancel()
                // Capture on entry only; leaving the detail screen clears it so
                // the next push re-reads the list the user came from.
                if case let .trip(tripID) = newPath.last {
                    captureReviewQueue(for: tripID)
                } else {
                    reviewQueue = []
                    tripDetailIsPresentingModal = false
                    // Leaving a trip in the stack shell — the system Back
                    // button, a swipe — is a plain pop that never touched the
                    // selection. Clear it here, or a Mac window narrowed,
                    // backed out of the trip, and widened again re-opens the
                    // trip the user just closed from the stale singleton.
                    if !usesSplitView, case .trip = oldPath.last {
                        selectedTripIDs = []
                    }
                }
            }
    }

    /// The content column: the selected scope's trip list, or the placeholder
    /// pane. `.id(scope)` gives each scope a fresh list (sort, selection,
    /// scroll), matching what a push used to provide.
    private var compactTripSelection: Binding<Set<UUID>> {
        Binding(
            get: { selectedTripIDs },
            set: { updateCompactTripSelection($0) }
        )
    }

    /// Expanded lists publish their authoritative Set immediately. In
    /// particular, the Mac reading pane never waits for a primary action or a
    /// deferred empty-selection repair.
    private var expandedTripSelection: Binding<Set<UUID>> {
        Binding(
            get: { selectedTripIDs },
            set: { setExpandedTripSelection($0) }
        )
    }

    @ViewBuilder
    private var contentColumn: some View {
        if case let .scope(scope) = path.first {
            DriveListView(
                scope: scope,
                selection: expandedTripSelection,
                presentedTripID: openTripID,
                // Unconditionally true: this column only exists inside
                // `splitShell`, which only mounts on a wide, non-phone
                // window. Same reasoning as `showsSettingsRow: true` above.
                showsSelection: true,
                currentDriveBarIsPresentingPurposeEditor: $currentDriveBarIsPresentingPurposeEditor,
                currentDriveBarIsMinimized: $currentDriveBarIsMinimized,
                perform: handle,
                onPrimaryAction: performPrimaryAction,
                onMapMailboxChange: { mapMailbox = $0 },
                onMapCompactLayoutChange: { mapCompactRows = $0 }
            ) { order in
                visibleTripOrder = order
            }
            .id(scope)
        } else {
            EmbossedEmptyState(
                title: Text("No Selection"),
                systemImage: "sidebar.left"
            )
                .accessibilityIdentifier("noScopeSelectedPane")
                // The only bar site for the no-selection pane: no list exists
                // here, so this is what keeps Live Activity re-entry visible
                // on a fresh iPad or Mac launch. Never coexists with the
                // list's own application.
                .currentDriveBar(
                    suppressed: false,
                    isMinimized: $currentDriveBarIsMinimized,
                    isPresentingPurposeEditor: $currentDriveBarIsPresentingPurposeEditor,
                    onAddFee: { category in driveFeeEntryRequest = .draft(category: category) },
                    onChooseVehicle: { showingCurrentDriveVehiclePicker = true }
                )
                .toolbar {
                    minimizedCurrentDriveToolbarItem
                    if currentDriveBarIsMinimized, model.currentDrive != nil {
                        ToolbarSpacer(.flexible, placement: .bottomBar)
                    }
                }
        }
    }

    /// Compact Mac retains the primary-action fallback because no adjacent
    /// reading pane exists there. Touch stacks take the direct branch below.
    private func updateCompactTripSelection(_ newSelection: Set<UUID>) {
        let validSelection = newSelection.intersection(model.tripIDs)
        cancelPendingEmptyCompactMacSelection()

        if model.platform.isMac, validSelection.isEmpty, !selectedTripIDs.isEmpty {
            // Inside a programmatic open's settle window: the trailing empty
            // write that follows the proxy's primary action. Not the user's.
            if compactMacPrimaryActionSettleTask != nil { return }
            let selectionBeforeEmptyWrite = selectedTripIDs
            let generation = advanceCompactSelectionGeneration()
            pendingEmptyCompactMacSelectionTask = Task { @MainActor in
                // Two turns: the proxy's primary action lands one yield after
                // its empty write. Cancellation is cooperative, so both the
                // cancellation flag and the original selection must still
                // match before the deferred deselection is allowed to land.
                await Task.yield()
                await Task.yield()
                guard CompactMacSelectionGenerationPolicy.canCommit(
                    captured: generation,
                    current: compactSelectionGeneration,
                    isCancelled: Task.isCancelled,
                    selectionUnchanged: selectedTripIDs == selectionBeforeEmptyWrite
                )
                else { return }
                selectedTripIDs = []
                pendingEmptyCompactMacSelectionTask = nil
            }
            return
        }

        if model.platform.isMac {
            replaceCompactMacSelection(with: validSelection)
        } else {
            selectedTripIDs = validSelection
        }
    }

    private func setExpandedTripSelection(_ newSelection: Set<UUID>) {
        cancelCompactMacSelectionWork()
        selectedTripIDs = newSelection.intersection(model.tripIDs)
    }

    private var readingPanePresentation: ReadingPanePresentation {
        ReadingPanePresentationResolver.resolve(
            isMac: model.platform.isMac,
            selection: selectedTripIDs,
            // The list's rendered order alone: the resolver appends any
            // selected row the list has not reported yet in a deterministic
            // order, so a deep-linked singleton renders before the list does
            // without concatenating every trip id on every pass.
            orderedTripIDs: visibleTripOrder,
            presentedTripID: openTripID,
            availableTripIDs: model.tripIDs
        )
    }

    /// The reading pane's root. Its switch moves directly from `.trip(A)` to
    /// `.trip(B)`; no empty route exists between peer details.
    @ViewBuilder
    private var readingPane: some View {
        // Resolved once per pass: the switch and the trace observer read the
        // same value rather than each running the resolver.
        let presentation = readingPanePresentation
        Group {
            switch presentation {
            case .empty:
                EmbossedEmptyState(
                    title: Text("No Trip Selected"),
                    systemImage: "car"
                )
                    .accessibilityIdentifier("noTripSelectedPane")
            case let .multiple(tripIDs):
                MultiTripSelectionPane(
                    trips: tripIDs.compactMap { model.trip(id: $0) },
                    rateSchedule: model.mileageRateSchedule,
                    currencyCode: model.currencyCode
                )
            case let .trip(tripID):
                if let trip = model.trip(id: tripID) {
                    tripDetail(trip) {
                        closeTrip(tripID)
                    }
                } else {
                    ContentUnavailableView("Trip Not Found", systemImage: "exclamationmark.triangle")
                        .onAppear { closeTrip(tripID) }
                }
            }
        }
        .onAppear {
            recordReadingPanePresentation(presentation)
        }
        .onChange(of: presentation) { _, presentation in
            recordReadingPanePresentation(presentation)
        }
        .overlay(alignment: .topLeading) {
            if model.isUITesting {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("readingPanePresentationTrace")
                        // Verbatim: --uitesting furniture, not a string to translate.
                        .accessibilityLabel(Text(verbatim: "Reading pane presentation trace"))
                        .accessibilityValue(readingPanePresentationTrace.joined(separator: "|"))
                        .allowsHitTesting(false)

                    if model.platform.isMac {
                        // The iPad simulator cannot synthesize Mac multi-click
                        // semantics: its Command-click replaces the selection.
                        // This test-only driver verifies the real zero/one/many
                        // presentation sequence without teaching production
                        // code to infer keyboard intent from set differences.
                        Button(action: advanceReadingPaneTestSelection) {
                            Rectangle()
                                .fill(Color.black.opacity(0.01))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: "Advance reading pane test selection"))
                        .accessibilityIdentifier("advanceReadingPaneTestSelection")

                        // The App Store capture wants a selection that reads as
                        // "several", which the three-state driver above never
                        // produces: it stops at two. Selects the first four
                        // visible trips in one write.
                        Button(action: selectManyForReadingPaneTest) {
                            Rectangle()
                                .fill(Color.black.opacity(0.01))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(y: 28)
                        .accessibilityLabel(Text(verbatim: "Select many trips for reading pane test"))
                        .accessibilityIdentifier("selectManyReadingPaneTestSelection")
                    }
                }
            }
        }
    }

    private func recordReadingPanePresentation(_ presentation: ReadingPanePresentation) {
        guard model.isUITesting else { return }
        let token: String
        switch presentation {
        case .empty:
            token = "empty"
        case let .trip(tripID):
            token = "trip:\(tripID.uuidString)"
        case let .multiple(tripIDs):
            token = "multiple:\(tripIDs.map(\.uuidString).joined(separator: ","))"
        }
        guard readingPanePresentationTrace.last != token else { return }
        readingPanePresentationTrace.append(token)
        if readingPanePresentationTrace.count > 32 {
            readingPanePresentationTrace.removeFirst(readingPanePresentationTrace.count - 32)
        }
    }

    private func advanceReadingPaneTestSelection() {
        guard model.isUITesting, model.platform.isMac, usesSplitView else { return }
        let order = visibleTripOrder.isEmpty ? model.trips.map(\.id) : visibleTripOrder
        let orderedIDs = DriveListSelectionProjection.ordered(model.tripIDs, visibleOrder: order)
        guard orderedIDs.count >= 2 else { return }
        switch selectedTripIDs.count {
        case 0:
            setExpandedTripSelection([orderedIDs[0]])
        case 1:
            setExpandedTripSelection([orderedIDs[0], orderedIDs[1]])
        default:
            setExpandedTripSelection([orderedIDs[1]])
        }
    }

    private func selectManyForReadingPaneTest() {
        guard model.isUITesting, model.platform.isMac, usesSplitView else { return }
        let order = visibleTripOrder.isEmpty ? model.trips.map(\.id) : visibleTripOrder
        let orderedIDs = DriveListSelectionProjection.ordered(model.tripIDs, visibleOrder: order)
        guard orderedIDs.count >= 2 else { return }
        setExpandedTripSelection(Set(orderedIDs.prefix(4)))
    }

    /// Persists a user-dragged column width for the NEXT launch. Regular
    /// width only — collapsed columns span the screen and would clobber the
    /// remembered layout — and clamped to the column's own range so a
    /// mid-transition measurement cannot store a nonsense value. Writes go
    /// straight to defaults, never back into this launch's `ideal`.
    private func recordColumnWidth(_ width: CGFloat, spec: SplitColumnWidthSpec) {
        // Only the split shell has columns to measure. Redundant today (every
        // caller is inside `splitShell`) but it states the precondition.
        guard usesSplitView else { return }
        let clamped = Swift.min(
            Swift.max(Double(width.rounded()), spec.range.lowerBound),
            spec.range.upperBound
        )
        if abs(clamped - (UserDefaults.standard.object(forKey: spec.key) as? Double ?? -1)) >= 1 {
            UserDefaults.standard.set(clamped, forKey: spec.key)
        }
    }

    /// Opens a scope, discarding anything pushed above it. One assignment in
    /// either shell: the stack replaces its whole path, and the split view
    /// reads the same leading element as its sidebar selection.
    private func open(scope: DriveListScope) {
        selectedTripIDs = []
        path = [.scope(scope)]
    }

    private func closeScope() {
        selectedTripIDs = []
        path = []
    }

    /// The navigation state as one route array, for the helpers that reason
    /// about "what is the user looking at" (export scope, new-trip date).
    private var effectiveRoutes: [TripsRoute] { path }

    @ViewBuilder
    private func destination(for route: TripsRoute) -> some View {
        switch route {
        case let .scope(scope):
            // Reachable in the stack shell, where a mailbox row pushes its
            // scope. In the split view the scope is the sidebar selection
            // instead and the content column renders this same list.
            DriveListView(
                scope: scope,
                selection: compactTripSelection,
                // Edit mode is true multi-selection, not the compact Mac
                // browse primary-action sequence that `compactTripSelection`
                // coalesces. Its writes must land synchronously.
                editModeSelection: expandedTripSelection,
                presentedTripID: openTripID,
                currentDriveBarIsPresentingPurposeEditor: $currentDriveBarIsPresentingPurposeEditor,
                currentDriveBarIsMinimized: $currentDriveBarIsMinimized,
                perform: handle,
                onPrimaryAction: performPrimaryAction,
                onMapMailboxChange: { mapMailbox = $0 },
                onMapCompactLayoutChange: { mapCompactRows = $0 }
            ) { order in
                visibleTripOrder = order
            }
        case let .trip(tripID):
            if let trip = model.trip(id: tripID) {
                tripDetail(trip) { closeTrip(tripID) }
            } else {
                // The pushed trip no longer exists — un-merged, deleted, or
                // removed by a sync import. Pop the zombie route instead of
                // stranding the user here: the live-resolving destination
                // replaces the detail screen the moment the mutation lands,
                // which outraces the screen's own dismiss().
                ContentUnavailableView("Trip Not Found", systemImage: "exclamationmark.triangle")
                    .onAppear {
                        closeTrip(tripID)
                    }
            }
        }
    }

    private func tripDetail(
        _ trip: TripSummary,
        onClose: @escaping () -> Void
    ) -> some View {
        TripDetailView(
            trip: trip,
            reviewQueue: reviewQueue,
            isPresentingModal: $tripDetailIsPresentingModal,
            onNavigate: { openTrip($0) },
            onClose: onClose
        )
        // A direct root replacement must not carry Trip A's editing state into
        // Trip B. The old instance's onDisappear autosave still runs first.
        .id(trip.id)
    }

    /// Opens a trip from a row, deep link, or detail chevron. Compact shells
    /// still push/replace their top route. The expanded split view merely
    /// records the same route for context while its root content reads the
    /// selection (Mac) or primary-action trip (iPad) directly.
    ///
    /// Opening the trip you are already reading used to append a second,
    /// identical Trip Detail — two views with the same `.id` in one stack, and
    /// two taps of Back to get out. Consecutive Spotlight opens stacked without
    /// bound for the same reason.
    private func openTrip(_ tripID: UUID) {
        tripMapNavigation.cancel()
        // Reading-pane selection remains immediate. For a touch stack push,
        // bring an existing disk image into memory before changing the path.
        // Launch/deep-link routing behind the privacy cover stays immediate.
        guard !usesSplitView, !model.platform.isMac,
              scenePhase == .active, model.isCommandSurfaceAvailable, !model.resetInProgress,
              let trip = model.trip(id: tripID),
              let content = RouteMapContent(trip: trip), !content.segments.isEmpty,
              let request = DriveCardMapSnapshotRenderer.request(
                for: content, identityToken: TripHeroMapLayout.identityToken,
                pointSize: CGSize(width: mapHeroWidth, height: TripHeroMapLayout.imageHeight),
                displayScale: displayScale, colorScheme: colorScheme, presentation: .hero
              ) else {
            openPreparedTrip(tripID)
            return
        }
        let originalPath = path
        tripMapNavigation.open {
            let cached = await DriveCardMapSnapshotRenderer.prepareCachedImage(for: request)
            #if DEBUG
            if cached != nil, !Task.isCancelled, DriveMapWarmingDiagnostics.enabled {
                DriveMapWarmingDiagnostics.shared.navigationHits += 1
            }
            #endif
        } then: {
            guard path == originalPath, scenePhase == .active,
                  model.isCommandSurfaceAvailable, !model.resetInProgress else { return }
            openPreparedTrip(tripID)
        }
    }

    private func openPreparedTrip(_ tripID: UUID) {
        // The queue is captured BEFORE the path moves, so the very first
        // render of Trip Detail already carries it. Captured only afterwards
        // — in the path observer — the detail column built the view with an
        // empty queue, and `navigationDestination` does not re-evaluate its
        // content for a state change the closure merely read: no ↑/↓
        // chevrons until something else happened to re-render the screen.
        // The observer's own call stays as the guard for the routes that do
        // not come through here. (3e30ddd, merged alongside this fix.)
        guard model.tripIDs.contains(tripID) else {
            closeTrip(tripID)
            return
        }
        captureReviewQueue(for: tripID)
        if model.platform.isMac {
            if usesSplitView {
                // External opens and chevrons move the expanded Mac list and
                // reading pane with one direct selection assignment.
                setExpandedTripSelection([tripID])
            } else {
                // The compact list still opens through its primary-action
                // fallback and absorbs that host path's trailing empty write.
                replaceCompactMacSelection(with: [tripID])
            }
        }
        setOpenTripRoute(tripID)
    }

    private func performPrimaryAction(_ trip: TripSummary) {
        openTrip(trip.id)
    }

    private func setOpenTripRoute(_ tripID: UUID) {
        let route = TripsRoute.trip(tripID)
        if case .trip = path.last {
            guard path.last != route else { return }
            path[path.count - 1] = route
        } else {
            path.append(route)
        }
    }

    private func clearOpenTripRoute() {
        path.removeAll {
            if case .trip = $0 { return true }
            return false
        }
        reviewQueue = []
        tripDetailIsPresentingModal = false
    }

    private func closeTrip(_ tripID: UUID) {
        selectedTripIDs.remove(tripID)
        path.removeAll { $0 == .trip(tripID) }
    }

    /// Compact-Mac primary actions land here. Expanded Mac selection never
    /// uses this settle window.
    private func replaceCompactMacSelection(with newSelection: Set<UUID>) {
        cancelPendingEmptyCompactMacSelection()
        cancelCompactMacPrimaryActionSettle()
        advanceCompactSelectionGeneration() // replacement
        selectedTripIDs = newSelection
        let capturedSelection = newSelection
        let generation = advanceCompactSelectionGeneration() // schedule
        compactMacPrimaryActionSettleTask = Task { @MainActor in
            await Task.yield()
            await Task.yield()
            guard CompactMacSelectionGenerationPolicy.canCommit(
                captured: generation,
                current: compactSelectionGeneration,
                isCancelled: Task.isCancelled,
                selectionUnchanged: selectedTripIDs == capturedSelection
            ) else { return }
            compactMacPrimaryActionSettleTask = nil
        }
    }

    private func cancelCompactMacSelectionWork() {
        cancelPendingEmptyCompactMacSelection()
        cancelCompactMacPrimaryActionSettle()
    }

    private func cancelPendingEmptyCompactMacSelection() {
        guard let task = pendingEmptyCompactMacSelectionTask else { return }
        task.cancel()
        pendingEmptyCompactMacSelectionTask = nil
        advanceCompactSelectionGeneration()
    }

    private func cancelCompactMacPrimaryActionSettle() {
        guard let task = compactMacPrimaryActionSettleTask else { return }
        task.cancel()
        compactMacPrimaryActionSettleTask = nil
        advanceCompactSelectionGeneration()
    }

    @discardableResult
    private func advanceCompactSelectionGeneration() -> UInt64 {
        compactSelectionGeneration = CompactMacSelectionGenerationPolicy.advanced(
            from: compactSelectionGeneration
        )
        return compactSelectionGeneration
    }

    /// Derives the Mac's trailing trip route from its selection: exactly one
    /// selected trip is the route, anything else clears it. Run from the
    /// `selectedTripIDs` observer, plus the shell observer for a widen that
    /// changes no selection.
    private func synchronizeMacRouteToSelection() {
        guard usesSplitView, model.platform.isMac else { return }
        let validSelection = selectedTripIDs.intersection(model.tripIDs)
        guard validSelection.count == 1, let tripID = validSelection.first else {
            clearOpenTripRoute()
            return
        }
        captureReviewQueue(for: tripID)
        setOpenTripRoute(tripID)
    }

    /// Opens straight into the inbox, once per launch, when work is waiting.
    ///
    /// An unresolved queue is the highest-frequency action, so it earns the
    /// direct launch. A resolved-only or empty history stays on Mailboxes, where
    /// the user can naturally choose All Trips, a year, or a month.
    private func openInboxOnFirstAppearance() {
        guard !hasOpenedInbox, model.hasLoadedInitialTrips else { return }
        // A nil size class means the environment has not settled — the shell
        // choice itself is still undecided — so the one-shot stays armed for
        // the pass where the redirect can actually be evaluated.
        guard NavigationShellResolution.isEnvironmentSettled(shellContext) else { return }
        // Consume the launch redirect the moment the first real trip load is
        // evaluated — whether or not it navigates. A suppressed redirect
        // (deep link, queued navigation) must not stay armed: the trip-list
        // change from a completed drive or a CloudKit import hours later
        // would otherwise yank the user into Need Review mid-session.
        hasOpenedInbox = true
        guard launchRedirectIsClear else { return }
        let target: DriveListScope? = if model.trips.contains(where: \.isUnresolved) {
            .needsReview
        } else if usesSplitView, !model.trips.isEmpty {
            // Only the split view never launches to a blank detail pane; the
            // stack — including a regular-width landscape Max iPhone — keeps
            // the stay-on-Mailboxes behavior (a preselect would push).
            .allTrips
        } else {
            nil
        }
        guard let target else { return }
        // One assignment, deferred a turn past the trip load that triggered it.
        //
        // This used to be a five-attempt "confirmed retry" that treated the
        // list reporting its row order as proof the push had landed, and on a
        // miss flipped the selection back through nil to re-drive it. The
        // signal is wrong: in a collapsed split view every column is mounted,
        // so the list reports its rows whether or not it is fronted. A report
        // arriving later than the attempt's short deadline made the loop clear
        // the selection it had just made — turning a slow push into a
        // permanent landing on Mailboxes (deterministic on a loaded machine:
        // LaunchSmoke and three TripEditing tests).
        Task { @MainActor in
            await Task.yield()
            // Re-checked after the yield: a deep link or a user tap landing
            // in the deferred turn must not be clobbered by this wholesale
            // path replacement.
            guard launchRedirectIsClear else { return }
            open(scope: target)
        }
    }

    /// True while nothing has claimed navigation — the launch redirect's
    /// precondition, checked both when it is scheduled and again when the
    /// deferred assignment fires.
    private var launchRedirectIsClear: Bool {
        path.isEmpty
            && !tripMapNavigation.isPreparing
            && model.requestedTripDetailID == nil
            && model.requestedTripSearch == nil
            && model.requestedReportsMonthStart == nil
            && !model.requestedNeedsReview
    }

    /// Publishes launch navigation only after the real persistent store is
    /// available. Requests stay queued during a before-first-unlock launch
    /// instead of being consumed against the throwaway placeholder.
    private func resumeAfterProtectedDataLoad() {
        showingOnboarding = !model.hasCompletedOnboarding
        openInboxOnFirstAppearance()
        if model.requestedTripSearch != nil, model.isCommandSurfaceAvailable {
            open(scope: .allTrips)
        }
        if let requested = model.requestedTripDetailID {
            model.requestedTripDetailID = nil
            openTrip(requested)
        }
        if let requested = model.requestedReportsMonthStart {
            model.requestedReportsMonthStart = nil
            open(scope: .month(DriveMonthSummary.monthInterval(containing: requested).start))
        }
        if model.requestedNeedsReview {
            model.requestedNeedsReview = false
            open(scope: .needsReview)
        }
        presentDeferredCurrentDriveRequestIfPossible()
    }

    /// Captures the ordered run of drives behind the pushed detail screen, once.
    /// Ordered by the scope the user actually came from, so "next" means next on
    /// the screen they were just looking at.
    private func captureReviewQueue(for tripID: UUID) {
        guard !reviewQueue.contains(tripID) else { return }
        // The detail column's root IS the selected scope, so "the list the
        // user came from" is simply the sidebar selection. A deep-link push
        // with nothing selected (Spotlight/Siri) must not inherit the last
        // list or filter the user happened to visit — it falls back to the
        // full ledger.
        let sourceScope: DriveListScope? = if case let .scope(scope) = path.first { scope } else { nil }
        let scope = sourceScope ?? .allTrips
        // Prefer what the list actually rendered: it owns the sort, the
        // classification filter, and the visibility filter, so a queue derived
        // independently here would disagree with the screen the user tapped —
        // "next" pointing at a row above, or at a row the filter had hidden.
        if sourceScope != nil, visibleTripOrder.contains(tripID) {
            reviewQueue = visibleTripOrder
            return
        }
        let queue = DriveSortOption.newestFirst.sorted(
            model.trips.filter {
                scope.contains($0)
                    && model.vehicleFilter.matches($0, primaryVehicleID: model.primaryVehicleID)
            }
        ).map(\.id)
        reviewQueue = queue.contains(tripID) ? queue : [tripID]
    }

    /// The single place a pushed drive list's requests become presentations.
    ///
    /// Keeping this as one switch is what lets
    /// `canSafelyPresentVehicleConnectionDecision` stay a truthful enumeration:
    /// if a new modal appears, it appears here.
    private func handle(_ request: DriveListRequest) {
        switch request {
        case let .editPurpose(trip):
            quickEntryRequest = QuickTripEntryRequest(trip: trip, field: .purpose)
        case let .editNotes(trip):
            quickEntryRequest = QuickTripEntryRequest(trip: trip, field: .notes)
        case let .addFee(trip, category):
            feeEntryRequest = .trip(trip, category: category)
        case let .exportTrip(trip):
            Task { await exportTripPDF(trip) }
        case let .exportMonth(monthStart, format):
            // List-originated: the filter is visible right above the rows.
            exportMonth(monthStart, format: format, vehicleFilter: model.vehicleFilter)
        case let .exportYear(yearStart, format):
            exportYear(yearStart, format: format, vehicleFilter: model.vehicleFilter)
        case let .bulkPurpose(tripIDs):
            // Reached from Business ▸ Custom…: a purpose is a Business trip's
            // detail, so the typed purpose classifies the trips Business too.
            bulkCustomPurposeHandler = { model.classify(tripIDs: tripIDs, as: .business, purpose: $0) }
            activeSheet = .bulkCustomPurpose
        case let .confirmDelete(trip):
            tripPendingDeletion = trip
        case let .confirmBulkDelete(trips):
            bulkTripsPendingDeletion = trips
        case let .addManualTrip(defaultDate):
            manualTripDefaultDate = defaultDate
            activeSheet = .manualTripEditor
        case let .currentDriveFee(category):
            driveFeeEntryRequest = .draft(category: category)
        case .currentDriveVehicle:
            showingCurrentDriveVehiclePicker = true
        }
    }

    @ToolbarContentBuilder
    private func rootToolbarContent() -> some ToolbarContent {
        // Stack shell only: the expanded sidebar's toolbar sits in the Mac
        // window's titlebar strip, which never delivers clicks — the gear is
        // dead furniture there. The split view gets the sidebar Settings row
        // and the app menu's Settings… ⌘, instead. Gated on the SHELL, not
        // the raw size class: a landscape Max iPhone reports regular width
        // while mounting the stack, and it has none of those substitutes.
        if !usesSplitView {
            ToolbarItem(placement: .topBarTrailing) {
                Button { activeSheet = .settings } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("settingsButton")
            }
        }
        // A single group with a plain `Spacer()` rather than `ToolbarSpacer`.
        // `ToolbarSpacer(.flexible, placement: .bottomBar)` is what emitted
        // "Adding 'UIKitToolbar' as a subview of UIHostingController.view is
        // not supported" — verified by removing it and watching the warning
        // count go from 2 to 0. This produces the same layout without it.
        //
        // Add Trip is the missed-drive exception, so it stays at ordinary
        // toolbar weight: the engine composes, the user only disposes. It sits
        // where Mail puts Compose, but is never tinted prominent.
        //
        // Stack shell only: in the expanded split view (iPad, Mac) the
        // bottom-bar UIToolbar is laid invisibly across the ENTIRE sidebar
        // column and swallows every click — the sidebar was completely inert
        // until this was gated. The list column's "+" and File > Add Trip ⌘N
        // cover the affordance there. Stack hosting is fine at any width
        // (landscape Max iPhones included): swapping this for a
        // `safeAreaBar` strip changed no UI-test outcome.
        if !usesSplitView {
            minimizedCurrentDriveToolbarItem
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                Button { manualTripDefaultDate = nil; activeSheet = .manualTripEditor } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add missed trip")
                .accessibilityIdentifier("addTripButton")
            }
        }
    }

    @ToolbarContentBuilder
    private var minimizedCurrentDriveToolbarItem: some ToolbarContent {
        if currentDriveBarIsMinimized, let summary = model.currentDrive {
            ToolbarItem(placement: .bottomBar) {
                CurrentDriveMinimizedButton(summary: summary) {
                    currentDriveBarIsMinimized = false
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    // MARK: - Commands

    private func exportCommandActions(directory: MailboxDirectory) -> DriveExportCommandActions? {
        // Menu dispatch bypasses the lock overlay's hitTest gate, so the
        // published value itself must vanish while App Lock is engaged or the
        // stores are the in-memory placeholder — nil grays every export item.
        guard model.isCommandSurfaceAvailable else { return nil }
        // The visible period wins: with a month or year open (or a trip pushed
        // from one), the ⌘-menu exports that period, not the default month.
        switch ExportScopeResolution.exportPeriodScope(in: effectiveRoutes) {
        case let .month(monthStart):
            return DriveExportCommandActions(
                canExportDefaultMonth: true,
                defaultExportMonthTitle: monthStart.formatted(.dateTime.month(.wide).year()),
                exportDefaultMonthCSV: { exportMonth(monthStart, format: .csv, vehicleFilter: model.vehicleFilter) },
                exportDefaultMonthPDF: { exportMonth(monthStart, format: .pdf, vehicleFilter: model.vehicleFilter) },
                exportDefaultMonthQuickBooksCSV: { exportMonth(monthStart, format: .quickBooksCSV, vehicleFilter: model.vehicleFilter) }
            )
        case let .year(yearStart):
            return DriveExportCommandActions(
                canExportDefaultMonth: true,
                defaultExportMonthTitle: yearStart.formatted(.dateTime.year()),
                exportDefaultMonthCSV: { exportYear(yearStart, format: .csv, vehicleFilter: model.vehicleFilter) },
                exportDefaultMonthPDF: { exportYear(yearStart, format: .pdf, vehicleFilter: model.vehicleFilter) },
                exportDefaultMonthQuickBooksCSV: { exportYear(yearStart, format: .quickBooksCSV, vehicleFilter: model.vehicleFilter) }
            )
        default:
            let defaultMonth = directory.defaultExportMonthStart
            return DriveExportCommandActions(
                canExportDefaultMonth: defaultMonth != nil,
                defaultExportMonthTitle: defaultMonth?.formatted(.dateTime.month(.wide).year())
                    ?? String(localized: "Current Month"),
                exportDefaultMonthCSV: { exportDefaultMonth(defaultMonth, format: .csv) },
                exportDefaultMonthPDF: { exportDefaultMonth(defaultMonth, format: .pdf) },
                exportDefaultMonthQuickBooksCSV: { exportDefaultMonth(defaultMonth, format: .quickBooksCSV) }
            )
        }
    }

    private func sceneCommandActions() -> DriveSceneCommandActions? {
        // Same lock/protected-data gate as exportCommandActions — ⌘N and ⌘,
        // must not run behind the lock screen either.
        guard model.isCommandSurfaceAvailable else { return nil }
        return DriveSceneCommandActions(
            canGoBack: !path.isEmpty,
            openNeedsReview: { open(scope: .needsReview) },
            openAllTrips: { open(scope: .allTrips) },
            openCurrentMonth: {
                open(scope: .month(DriveMonthSummary.monthInterval(containing: Date()).start))
            },
            goBack: {
                if let openTripID {
                    closeTrip(openTripID)
                } else if !path.isEmpty {
                    path.removeLast()
                    selectedTripIDs = []
                }
            },
            addTrip: {
                manualTripDefaultDate = ExportScopeResolution.defaultNewTripDate(in: effectiveRoutes)
                activeSheet = .manualTripEditor
            },
            openSettings: { activeSheet = .settings }
        )
    }

    // MARK: - Export

    /// The filter is an explicit parameter, not a `model.vehicleFilter` read:
    /// the sidebar's context-menu exports pass `.all` (its rows are always
    /// visible beside a possibly-filtered list, with no filter indication of
    /// their own), while the list toolbar and ⌘-menu pass the visible filter.
    private func exportYear(
        _ yearStart: Date,
        format: MileageReportExportFormat,
        vehicleFilter: TripVehicleFilter
    ) {
        // Recheck after awaiting: the app may lock during the rate check.
        guard model.isCommandSurfaceAvailable, !isPreparingReportExport else { return }
        isPreparingReportExport = true
        Task { @MainActor in
            defer { isPreparingReportExport = false }
            do {
                let report = try await model.prepareAnnualReportExport(
                    forYearContaining: yearStart,
                    vehicleFilter: vehicleFilter,
                    format: format
                )
                guard model.isCommandSurfaceAvailable else {
                    try? FileManager.default.removeItem(at: report.csvURL)
                    try? FileManager.default.removeItem(at: report.pdfURL)
                    return
                }
                activeShare = ActivityShareItem(
                    url: format.url(from: report),
                    cleanupURLs: [report.csvURL, report.pdfURL],
                    notice: report.rateFreshnessMessage
                )
            } catch {
                model.present(error, .export)
            }
        }
    }

    private func exportMonth(
        _ monthStart: Date,
        format: MileageReportExportFormat,
        vehicleFilter: TripVehicleFilter
    ) {
        guard model.isCommandSurfaceAvailable, !isPreparingReportExport else { return }
        isPreparingReportExport = true
        Task { @MainActor in
            defer { isPreparingReportExport = false }
            do {
                let report = try await model.prepareMonthlyReportExport(
                    forMonthContaining: monthStart,
                    vehicleFilter: vehicleFilter,
                    format: format
                )
                guard model.isCommandSurfaceAvailable else {
                    try? FileManager.default.removeItem(at: report.csvURL)
                    try? FileManager.default.removeItem(at: report.pdfURL)
                    return
                }
                activeShare = ActivityShareItem(
                    url: format.url(from: report),
                    cleanupURLs: [report.csvURL, report.pdfURL],
                    notice: report.rateFreshnessMessage
                )
            } catch {
                model.present(error, .export)
            }
        }
    }

    private func exportDefaultMonth(_ monthStart: Date?, format: MileageReportExportFormat) {
        guard let monthStart else {
            model.present(String(localized: "There are no trips to export."), .export)
            return
        }
        exportMonth(monthStart, format: format, vehicleFilter: model.vehicleFilter)
    }

    private func exportTripPDF(_ trip: TripSummary) async {
        guard model.isCommandSurfaceAvailable else { return }
        guard let url = await model.exportTripPDF(trip) else { return }
        activeShare = ActivityShareItem(url: url, notice: model.irsRateExportStatusMessage)
    }

    // MARK: - Deletion

    private func deletePendingSelection() {
        let trips = bulkTripsPendingDeletion
        guard !trips.isEmpty else { return }
        let tripIDs = Set(trips.map(\.id))
        selectedTripIDs.subtract(tripIDs)
        path.removeAll { route in
            if case let .trip(id) = route { return tripIDs.contains(id) }
            return false
        }
        model.delete(tripIDs: Array(tripIDs))
        bulkTripsPendingDeletion = []
    }

    private func deleteConfirmationMessage(for trip: TripSummary) -> String {
        let date = trip.startDate.formatted(date: .abbreviated, time: .shortened)
        return String(
            localized: "This permanently deletes your \(date) trip. This can't be undone."
        )
    }

    private var bulkDeleteConfirmationTitle: String {
        if bulkTripsPendingDeletion.count == 1 {
            return String(localized: "Delete selected trip?")
        }
        return String(localized: "Delete selected trips?")
    }

    private var bulkDeleteButtonTitle: String {
        if bulkTripsPendingDeletion.count == 1 {
            return String(localized: "Delete Trip")
        }
        return String(localized: "Delete \(bulkTripsPendingDeletion.count) Trips")
    }

    private var bulkDeleteConfirmationMessage: String {
        let count = bulkTripsPendingDeletion.count
        if count == 1 {
            return String(
                localized: "This permanently deletes the selected trip. This can't be undone."
            )
        }
        return String(
            localized: "This permanently deletes \(count) selected trips. This can't be undone."
        )
    }

    // MARK: - Vehicle scope

    /// Clears a vehicle filter that no longer applies — the vehicle was deleted,
    /// or the fleet dropped below the two-vehicle threshold that shows filters.
    private func resetVehicleFilterIfNeeded() {
        guard model.vehicleFilter.isActive else { return }
        if !model.multiVehicleUIActive {
            model.vehicleFilter = .all
            return
        }
        if case let .vehicle(id) = model.vehicleFilter,
           !model.vehicles.contains(where: { $0.id == id }) {
            model.vehicleFilter = .all
        }
    }

    // MARK: - Live drive deep links

    /// The Live Activity's main link reveals the controls even when the user
    /// minimized them or is reading an older trip. The shared presenter below
    /// holds the request while locked or while another editor is open.
    private func presentRequestedCurrentDriveIfPossible() {
        guard let requestedTripID = model.currentDrivePresentationRequestID,
              let currentDrive = model.currentDrive else { return }
        model.clearCurrentDrivePresentationRequest()
        guard currentDrive.pendingTripID == requestedTripID else { return }
        currentDriveBarIsMinimized = false
        closeScope()
    }

    /// Presents the fee sheet for a deep-link / Live Activity fee request, but only
    /// once the app is unlocked and the request matches the active drive.
    private func presentRequestedFeeIfPossible() {
        guard model.appLock.lockState == .unlocked,
              let request = model.currentDriveFeeRequest,
              let currentDrive = model.currentDrive else {
            return
        }
        guard currentDrive.pendingTripID == request.tripID else {
            model.clearCurrentDriveFeeRequest()
            return
        }
        guard !hasBlockingPresentation else { return }
        driveFeeEntryRequest = .draft(category: request.category)
        model.clearCurrentDriveFeeRequest()
    }

    /// Presents the vehicle picker requested by the Live Activity only after
    /// the app is unlocked and the link still targets the active drive.
    private func presentRequestedCurrentDriveVehicleIfPossible() {
        guard model.appLock.lockState == .unlocked,
              let requestedTripID = model.currentDriveVehicleRequestID,
              let currentDrive = model.currentDrive else {
            return
        }
        guard currentDrive.pendingTripID == requestedTripID else {
            model.clearCurrentDriveVehicleRequest()
            return
        }
        guard !hasBlockingPresentation else { return }
        showingCurrentDriveVehiclePicker = true
        model.clearCurrentDriveVehicleRequest()
    }

    /// Performs the Live Activity's "New Leg" request. Unlike its two siblings
    /// this presents nothing — it is an action — but it takes the same gates:
    ///
    /// * `appLock == .unlocked`, which is the whole reason New Leg is a deep
    ///   link and not a `Button(intent:)`. App Intents run without consulting
    ///   App Lock at all, so an intent would split a drive on a locked phone.
    /// * a matching `pendingTripID`, so a link left over from a drive that has
    ///   since ended or already split can never split the wrong drive.
    /// * `!hasBlockingPresentation`, even though nothing is presented: a split
    ///   changes which trip subsequent edits land on, so firing it under an open
    ///   fee sheet would silently attribute an in-flight fee to the new leg. It
    ///   also matches the bar, whose own New Leg button a sheet covers.
    private func performRequestedCurrentDriveNewLegIfPossible() {
        guard model.appLock.lockState == .unlocked,
              let requestedTripID = model.currentDriveNewLegRequestID,
              let currentDrive = model.currentDrive else {
            return
        }
        guard currentDrive.pendingTripID == requestedTripID else {
            model.clearCurrentDriveNewLegRequest()
            return
        }
        guard !hasBlockingPresentation else { return }
        // Cleared BEFORE the action, unlike the sheet presenters which clear
        // after: `startNewLegNow` publishes a new snapshot synchronously, which
        // re-enters this presenter. A still-set request could not match the new
        // `pendingTripID`, but clearing first makes a second split structurally
        // impossible rather than merely unreachable.
        model.clearCurrentDriveNewLegRequest()
        model.startNewLegNow()
    }

    /// Replays deferred Live Activity requests through one serialized presenter.
    ///
    /// The request stays on the model while onboarding, another sheet, a dialog,
    /// or an alert is active. When the blocking presentation clears,
    /// `hasBlockingPresentation` changes and this method runs again. Fee entry has
    /// priority only because it is a sheet; the vehicle request remains queued and
    /// is replayed after that sheet dismisses.
    private func presentDeferredCurrentDriveRequestIfPossible() {
        guard model.appLock.lockState == .unlocked,
              model.currentDrive != nil,
              !hasBlockingPresentation else {
            return
        }
        presentRequestedCurrentDriveIfPossible()
        presentRequestedFeeIfPossible()
        guard driveFeeEntryRequest == nil else { return }
        presentRequestedCurrentDriveVehicleIfPossible()
        // New Leg runs LAST, and the vehicle guard exists only because
        // something now follows that presenter. Two queued requests can only
        // coexist if both were tapped on the same activity, so both carry the
        // same pre-split `pendingTripID`. Splitting first would drop a queued
        // toll via the identity guard — silently losing the user's input —
        // while splitting last lets that toll land on the leg that was
        // recording when they tapped it. A fee tapped after a split already
        // carries the new ID and cannot be misattributed.
        guard !showingCurrentDriveVehiclePicker else { return }
        performRequestedCurrentDriveNewLegIfPossible()
    }

    private var rememberCurrentConnectionTitle: String {
        let vehicleName = model.vehicle(for: model.currentDrive?.vehicleID)?.name
            ?? String(localized: "this vehicle")
        if model.currentDriveConnectionRememberCandidates.count > 1 {
            return String(localized: "Which connection should recognize \(vehicleName)?")
        }
        guard let hint = model.currentDriveConnectionRememberCandidates.first,
              let connectionName = trimmedVehicleConnectionName(hint) else {
            return String(localized: "Use this car connection for \(vehicleName)?")
        }
        return String(localized: "Use “\(connectionName)” for \(vehicleName)?")
    }

    private var rememberCurrentConnectionMessage: String {
        let vehicleName = model.vehicle(for: model.currentDrive?.vehicleID)?.name
            ?? String(localized: "this vehicle")
        let candidates = model.currentDriveConnectionRememberCandidates
        if candidates.count == 1, let hint = candidates.first {
            if hint.identityQuality == .stablePortIdentifier {
                return String(localized: "Future drives with this connection can use \(vehicleName) automatically.")
            }
            return String(localized: "Mileager will suggest \(vehicleName) next time, but still ask you to confirm.")
        }
        return String(localized: "Choose the connection Mileager should associate with \(vehicleName). Less reliable connections will still ask you to confirm.")
    }

    private var pendingVehicleConnectionDecisionItemBinding: Binding<PendingVehicleConnectionDecision?> {
        Binding(
            get: {
                guard model.appLock.lockState == .unlocked,
                      canSafelyPresentVehicleConnectionDecision else {
                    return nil
                }
                return model.pendingVehicleConnectionDecision
            },
            set: { presentedDecision in
                // Swiping the sheet away is the sole "not now" action. Explicit
                // vehicle and ignore choices clear the pending decision first.
                if presentedDecision == nil,
                   model.pendingVehicleConnectionDecision != nil {
                    model.deferPendingVehicleConnection()
                }
            }
        )
    }

    /// A hand-written enumeration of every other presentation this root owns.
    /// Anything added to `body` must be added here too, or the connection sheet
    /// can appear on top of it.
    private var hasBlockingPresentation: Bool {
        activeSheet != nil
            || showingOnboarding
            || quickEntryRequest != nil
            || feeEntryRequest != nil
            || driveFeeEntryRequest != nil
            || activeShare != nil
            || tripPendingDeletion != nil
            || !bulkTripsPendingDeletion.isEmpty
            || showingSampleDataConfirmation
            || showingCurrentDriveVehiclePicker
            || showingRememberCurrentConnectionPicker
            || currentDriveBarIsPresentingPurposeEditor
            || tripDetailIsPresentingModal
            || model.errorAlert != nil
    }

    private var canSafelyPresentVehicleConnectionDecision: Bool {
        model.currentDrive == nil && !hasBlockingPresentation
    }

    private func vehicleConnectionLabel(for hint: BluetoothDriveHint) -> String {
        let kind = vehicleConnectionKindLabel(hint.connectionKind)
        let name = trimmedVehicleConnectionName(hint)
        guard let name, !name.isEmpty else {
            return String(localized: "\(kind) connection")
        }
        return "\(name) · \(kind)"
    }

    private func trimmedVehicleConnectionName(_ hint: BluetoothDriveHint) -> String? {
        guard let name = hint.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return name
    }

    private func vehicleConnectionKindLabel(_ kind: VehicleConnectionKind) -> String {
        switch kind {
        case .carPlay:
            String(localized: "CarPlay")
        case .bluetooth:
            String(localized: "Bluetooth")
        case .unknown:
            String(localized: "Car connection")
        }
    }
}

/// A comfortable form-sheet size at regular width (the sheet otherwise hugs
/// the Form's ~285pt ideal into a cramped card); compact sheets are untouched.
/// One column's width-persistence contract: the defaults key, the fresh-install
/// fallback, and the single min/max range shared by the layout modifier and
/// the persistence clamp — they express one contract and must not drift.
struct SplitColumnWidthSpec {
    let key: String
    let fallback: Double
    let range: ClosedRange<Double>

    static let sidebar = SplitColumnWidthSpec(
        key: "SplitViewSidebarWidth", fallback: 230, range: 180...400
    )
    static let content = SplitColumnWidthSpec(
        key: "SplitViewContentWidth", fallback: 420, range: 320...700
    )

    func storedWidth() -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }
}

/// The root modal surfaces, split from `ContentView.body` so the navigation
/// shell stays readable. Attach order and behavior are unchanged.
private struct HomeSheetsModifier: ViewModifier {
    @Environment(MileageAppModel.self) private var model
    @Binding var showingOnboarding: Bool
    @Binding var activeSheet: ContentView.HomeSheet?
    @Binding var quickEntryRequest: QuickTripEntryRequest?
    @Binding var feeEntryRequest: FeeEntryRequest?
    @Binding var driveFeeEntryRequest: FeeEntryRequest?
    @Binding var activeShare: ActivityShareItem?
    var manualTripDefaultDate: Date?
    var onBulkPurpose: (String) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingOnboarding) {
                OnboardingView {
                    model.completeOnboarding()
                    showingOnboarding = false
                }
                .environment(model)
                .interactiveDismissDisabled(!model.hasCompletedOnboarding)
                // The first thing a Mac user ever sees — without the frame it
                // hugs the Form's ~285pt ideal into a cramped card.
                .macSheetFrame()
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .settings:
                    SettingsView()
                        .environment(model)
                        // Settings is a workspace on the Mac rather than a
                        // compact confirmation form.
                        .macSheetFrame(.workspace)
                case .manualTripEditor:
                    ManualTripEditorView(now: manualTripDefaultDate ?? Date())
                        .environment(model)
                        .macSheetFrame(.workspace)
                case .bulkCustomPurpose:
                    BusinessPurposeCustomEntryView(initialPurpose: "") { purpose in
                        onBulkPurpose(purpose)
                    }
                    .environment(model)
                }
            }
            .sheet(item: $quickEntryRequest) { request in
                if let trip = model.trip(id: request.trip.id) {
                    QuickTripFieldEntryView(trip: trip, field: request.field)
                        .environment(model)
                } else {
                    ContentUnavailableView("Trip Not Found", systemImage: "exclamationmark.triangle")
                }
            }
            .sheet(item: $feeEntryRequest) { request in
                FeeEntryView(request: request)
                    .environment(model)
            }
            .sheet(item: $driveFeeEntryRequest) { request in
                FeeEntryView(request: request) { fee in
                    model.addCurrentDriveFee(fee)
                }
                .environment(model)
            }
            .exportShare(item: $activeShare)
    }
}
