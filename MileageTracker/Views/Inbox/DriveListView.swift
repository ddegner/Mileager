import AppCore
import AppIntents
import SwiftUI

/// Something a drive list needs the root to do, because the root owns every
/// modal surface and every file export.
///
/// One enum and one closure rather than a struct of ten closures: the list only
/// ever *asks*, so the shape of the request is the interesting part and the
/// plumbing is not. It also keeps `canSafelyPresentVehicleConnectionDecision`
/// honest — every presentation still originates from one switch in `ContentView`.
enum DriveListRequest {
    case editPurpose(TripSummary)
    case editNotes(TripSummary)
    case addFee(TripSummary, TripFeeCategory)
    case exportTrip(TripSummary)
    case exportMonth(Date, MileageReportExportFormat)
    case exportYear(Date, MileageReportExportFormat)
    /// The custom-purpose sheet, applied to these trips when it is confirmed.
    case bulkPurpose([UUID])
    case confirmDelete(TripSummary)
    case confirmBulkDelete([TripSummary])
    /// Present on every drive list, not just the root: you notice a drive the
    /// engine missed while reviewing the others, which is when the list is in
    /// front of you.
    ///
    /// The date seeds the editor. Adding a trip while looking at June and having
    /// it default to today files it into the wrong month, which is a silent
    /// accounting error rather than a typo.
    case addManualTrip(defaultDate: Date?)
    case currentDriveFee(TripFeeCategory)
    case currentDriveVehicle
}

/// The list's filtered and ordered rows, derived once for each body pass.
///
/// Header scopes are grouped and sorted once, then flattened in the exact order
/// SwiftUI renders them. A month has no headers, so it only needs the one row
/// sort. Keeping the rendered order here also gives navigation, selection
/// cleanup, and the adjacent-row actions one source of truth.
struct DriveListDerivation {
    var trips: [TripSummary]
    var monthGroups: [DriveMonthGroup]
    var unresolvedCount: Int
    /// Shared by the floating controls and context menu, after all filters and
    /// section-local sorting. Headers do not interrupt the displayed trip order.
    var nextTripByID: [UUID: TripSummary]

    var visibleOrder: [UUID] {
        trips.map(\.id)
    }

    init(
        trips sourceTrips: [TripSummary],
        scope: DriveListScope,
        sortOption: DriveSortOption,
        tripFilter: TripClassificationFilter,
        vehicleFilter: TripVehicleFilter,
        primaryVehicleID: UUID?,
        searchText: String = ""
    ) {
        // Resolved once, not once per trip: `scope.matches()` hoists the
        // period's `DateInterval` out of the loop.
        let matchesScope = scope.matches()
        let query = TripSearchQuery(searchText)
        let scoped = sourceTrips.filter {
            matchesScope($0)
                && vehicleFilter.matches($0, primaryVehicleID: primaryVehicleID)
        }
        unresolvedCount = scoped.filter(\.isUnresolved).count
        let filtered = scoped.filter { tripFilter.matches($0) && query.matches($0) }
        if scope.showsMonthHeaders {
            monthGroups = DriveMonthSummary.groups(for: filtered, sort: sortOption)
            trips = monthGroups.flatMap(\.trips)
        } else {
            monthGroups = []
            trips = sortOption.sorted(filtered)
        }
        nextTripByID = zip(trips, trips.dropFirst()).reduce(into: [:]) { result, pair in
            result[pair.0.id] = pair.1
        }
    }
}

/// Keeps the browse-only accessibility activation out of explicit Select mode.
/// Merely making the action a no-op is not enough: its presence would still
/// replace the native List action exposed to assistive technologies.
private struct DriveRowBrowseAccessibilityModifier: ViewModifier {
    var isEnabled: Bool
    var action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        } else {
            content
        }
    }
}

/// One list, four scopes. The scope supplies the predicate, the title, the
/// empty-state copy, and report context.
struct DriveListView: View {
    var scope: DriveListScope
    /// The system-owned list selection. The root owns it because the expanded
    /// reading pane is another presentation of this same state on the Mac.
    @Binding var selection: Set<UUID>
    /// A direct route to the same root-owned Set while Edit mode is active.
    /// Compact Mac browsing has a tiny primary-action settle policy in its
    /// normal binding; native Select-mode writes must bypass that policy so
    /// deselecting the last row and Done clear synchronously.
    var editModeSelection: Binding<Set<UUID>>? = nil
    /// The trip currently rendered in the reading pane. On touch platforms
    /// this is deliberately separate from Select-mode checkmarks; on the Mac
    /// it mirrors the one-row selection and keeps external opens in sync.
    var presentedTripID: UUID?
    /// Whether this list is a column standing beside the reading pane, rather
    /// than a screen pushed on top of the mailboxes. Gates the selection chip,
    /// which means nothing when the list is not on screen next to what it
    /// selects.
    ///
    /// Supplied by the root, like `MailboxesList(showsSettingsRow:)`: a split
    /// view column reports `.compact` to its own content whatever the window
    /// is doing, so reading the environment here answers the wrong question.
    var showsSelection: Bool = false
    @Binding var currentDriveBarIsPresentingPurposeEditor: Bool
    @Binding var currentDriveBarIsMinimized: Bool
    var perform: (DriveListRequest) -> Void
    /// The platform's primary action: a tap on iOS/iPadOS and the compact-Mac
    /// fallback. The expanded Mac list is selection-driven instead, so its
    /// item context menu deliberately has no primary action.
    var onPrimaryAction: (TripSummary) -> Void
    /// Publishes the current mailbox and layout for root-owned map warming.
    var onMapMailboxChange: (DriveMapMailboxContext) -> Void = { _ in }
    var onMapCompactLayoutChange: (Bool) -> Void = { _ in }
    /// Reports the order the rows are actually rendered in, so Trip Detail's
    /// ↑/↓ chevrons walk the list the user is looking at rather than a
    /// separately-derived one that ignores this screen's sort and filters.
    var onVisibleOrderChange: ([UUID]) -> Void = { _ in }

    @Environment(MileageAppModel.self) private var model
    @Environment(\.distanceUnit) private var distanceUnit
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Read once here, not per row: the touch reading-pane highlight follows
    /// the active-window emphasis without making every DriveRow observe it.
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sidebarUnderlap) private var sidebarUnderlap

    @State private var editMode: EditMode = .inactive
    /// The rendered row order, kept because the ⌘-menu's closures cannot see
    /// the per-pass derivation that produces it.
    @State private var visibleOrder: [UUID] = []
    @State private var sortOption: DriveSortOption = .newestFirst
    @State private var tripFilter: TripClassificationFilter = .all
    @State private var searchText = ""
    @State private var searchScope: DriveSearchScope = .currentMailbox
    @State private var pullCaptionToolbarBottom: CGFloat?
    @State private var pullCaptionSearchScopeBottom: CGFloat?
    @State private var listWidth: CGFloat = .infinity
    /// The row a plain click made the singleton selection — what ⇧⌘↑/⇧⌘↓
    /// extend from and shrink back toward when the keyboard moves that the
    /// Designed-for-iPad List cannot receive natively arrive as menu commands.
    @State private var selectionAnchor: UUID?

    private var vehicleFilter: TripVehicleFilter { model.vehicleFilter }

    /// Whether the list is holding a selection the bulk verbs can act on.
    ///
    /// Select mode is only one way rows get selected. Select All, keyboard
    /// range commands, and other programmatic changes fill `List(selection:)`
    /// without touching `editMode`, so every bulk surface follows the actual
    /// selection rather than asking only whether Edit mode is active.
    private var isSelecting: Bool { editMode.isEditing || !selection.isEmpty }

    /// Whether the explicit Select/Done presentation is active.
    ///
    /// On the Mac, an ordinary browse click always leaves one row selected,
    /// so selection presence cannot answer this question. Touch shells also
    /// treat a pointer-made selection outside Edit mode as a transient mode
    /// that Done can clear.
    private var selectionModeIsActive: Bool {
        editMode.isEditing || (!isMacList && !selection.isEmpty)
    }

    /// Still a plain SwiftUI List binding. The only distinction is whether
    /// compact Mac's browse-only primary-action coalescing participates.
    private var activeSelectionBinding: Binding<Set<UUID>> {
        if editMode.isEditing, let editModeSelection {
            return editModeSelection
        }
        return $selection
    }

    /// Whether this list should behave like a Mac list rather than an iOS one.
    ///
    /// A Mac keeps a live browse selection whose verbs only enable and disable.
    /// It can also enter the same explicit SwiftUI Select mode as iPhone and
    /// iPad when plain-click multi-selection is needed. Pointer modifiers
    /// outside that mode follow SwiftUI's host behavior.
    ///
    /// Read off the model rather than shell width. A Designed-for-iPad app is
    /// still a Mac app when its window narrows, including when it explicitly
    /// enters Select mode.
    /// The injected platform also keeps this path reachable in simulator UI
    /// tests through `--mac-mode=on`.
    private var isMacList: Bool { model.platform.isMac }

    private var interactionPolicy: DriveListInteractionPolicy {
        .resolve(isMac: isMacList, showsSelection: showsSelection)
    }

    /// Classification is itself the work in Need Review, so category filters
    /// are mostly impossible there (Personal and Not a Drive can never match).
    /// A vehicle filter remains useful when the account has multiple vehicles.
    private var allowsClassificationFilter: Bool {
        if case .needsReview = scope { return false }
        return true
    }

    private var effectiveTripFilter: TripClassificationFilter {
        allowsClassificationFilter ? tripFilter : .all
    }

    private var showsFilterMenu: Bool {
        allowsClassificationFilter || model.multiVehicleUIActive
    }

    private var anyFilterActive: Bool {
        effectiveTripFilter.isActive || vehicleFilter.isActive
    }

    private var searchQuery: TripSearchQuery { TripSearchQuery(searchText) }

    private var effectiveScope: DriveListScope {
        searchScope.listScope(mailbox: scope, query: searchQuery)
    }

    private var usesCompactRows: Bool {
        // Select mode gives its checkmarks space by narrowing the summary;
        // keep the map size tied to the column width so it does not shrink.
        listWidth - sidebarUnderlap < 360
    }

    private var mapMailboxContext: DriveMapMailboxContext {
        .init(scope: effectiveScope, sort: sortOption, filter: effectiveTripFilter,
              vehicleFilter: vehicleFilter, primaryVehicleID: model.primaryVehicleID, searchText: searchText)
    }

    var body: some View {
        let derivation = DriveListDerivation(
            trips: model.trips,
            scope: effectiveScope,
            sortOption: sortOption,
            tripFilter: effectiveTripFilter,
            vehicleFilter: vehicleFilter,
            primaryVehicleID: model.primaryVehicleID,
            searchText: searchText
        )

        // SwiftUI does not scroll a list when an external open or detail
        // chevron changes its selection programmatically.
        ScrollViewReader { proxy in
            listBody(derivation: derivation, proxy: proxy)
        }
        .onChange(of: mapMailboxContext, initial: true) { _, context in onMapMailboxChange(context) }
        .modifier(DriveListSearchModifier(text: $searchText))
        .onChange(of: model.requestedTripSearch, initial: true) { _, _ in
            consumeRequestedSearch()
        }
        .onChange(of: scope) { _, _ in consumeRequestedSearch() }
        .onChange(of: searchText) { _, text in
            if TripSearchQuery(text).isEmpty {
                searchScope = .currentMailbox
            }
        }
    }

    private func consumeRequestedSearch() {
        guard scope == .allTrips, model.isCommandSurfaceAvailable,
              let requested = model.requestedTripSearch else { return }
        tripFilter = .all
        model.vehicleFilter = .all
        searchText = requested.text
        searchScope = .currentMailbox
        model.requestedTripSearch = nil
    }

    /// Split out of `body` so the reader's closure does not add another layer
    /// to an expression the type-checker already needed help with.
    private func listBody(
        derivation: DriveListDerivation,
        proxy: ScrollViewProxy
    ) -> some View {
        // Projected once per pass and handed to both the toolbar and the
        // ⌘-menu, so what enables a verb is exactly what the verb acts on.
        let orderedSelection = DriveListSelectionProjection.ordered(
            selection, visibleOrder: derivation.visibleOrder
        )
        return selectionContextMenuHost(
            // The rows carry swipe actions, and a swipe action inside a column
            // the floating sidebar overlaps needs that overlap expressed as a
            // scroll-content margin rather than a safe area. Keep this on the
            // List itself: applying it outside would also drop the safe area
            // from non-scrolling overlays such as the empty state.
            selectionList(derivation: derivation)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.width - geometry.safeAreaInsets.trailing
                } action: { listWidth = $0 }
                .sidebarUnderlapConsumed(),
            nextTripByID: derivation.nextTripByID
        )
        // MUST precede .toolbar — EditButton mutates whatever editMode binding
        // it inherits, and applying the environment afterwards leaves the
        // toolbar toggling a different binding than the List reads, so
        // selection silently never engages.
        .environment(\.editMode, $editMode)
        .navigationTitle(scope.title)
        .navigationBarTitleDisplayMode(.large)
        .navigationSubtitle(subtitle(for: derivation))
        // Keep adjacent-merge controls in the scrolling list's layer. The live
        // drive bar is added immediately afterwards, so its Liquid Glass stays
        // visually above a merge control when the last row scrolls beneath it.
        .overlayPreferenceValue(AdjacentMergeBoundaryPreferenceKey.self) { boundaries in
            GeometryReader { proxy in
                ForEach(boundaries) { boundary in
                    let frame = proxy[boundary.anchor]
                    AdjacentMergeGlassButton(
                        pairID: boundary.id,
                        firstRouteLabel: boundary.firstRouteLabel,
                        secondRouteLabel: boundary.secondRouteLabel
                    ) {
                        // The only animated transaction these buttons ever see:
                        // merge synchronously collapses the pair, so the
                        // transition below fades this button out with the rows.
                        withAnimation(reduceMotion ? nil : .snappy) {
                            model.merge(tripIDs: [boundary.firstTripID, boundary.secondTripID])
                        }
                    }
                    // Sits in the reserved trailing lane, on the boundary —
                    // the least information-dense strip on the row. Moving it
                    // further inboard covers the distance instead, and a number
                    // is worth more than a chevron. Anchored to the row bounds
                    // rather than the container edge so column resizing can't
                    // strand it outside the rows.
                    .position(x: frame.maxX - 10, y: frame.maxY)
                    // Geometry changes land instantly as one unit: without
                    // this, late anchor resolution after the list settles let
                    // inherited animations fly the control across the screen
                    // into position.
                    .geometryGroup()
                    // No ambient .animation on this overlay: the lazy List
                    // realizes rows during scroll and resolves anchors after
                    // first layout, so animating on boundary membership made
                    // every button zoom into place instead of just being
                    // there. This transition therefore only plays inside an
                    // animated transaction — the merge action above — where
                    // the button fades out with the collapsing pair.
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.6).combined(with: .opacity)
                    )
                }
            }
            // The overlay is decoration over a scrolling list; only the button
            // itself takes touches, so the rows underneath stay swipeable.
            .allowsHitTesting(true)
        }
        // The inset keeps the list's structural identity while the panel is
        // minimized. Native toolbar items remain owned by this screen.
        .currentDriveBar(
            suppressed: isSelecting,
            isMinimized: $currentDriveBarIsMinimized,
            isPresentingPurposeEditor: $currentDriveBarIsPresentingPurposeEditor,
            onAddFee: { perform(.currentDriveFee($0)) },
            onChooseVehicle: { perform(.currentDriveVehicle) }
        )
        .toolbar { toolbarContent(selectedTripIDs: orderedSelection) }
        .onAppear {
            visibleOrder = derivation.visibleOrder
            onVisibleOrderChange(derivation.visibleOrder)
            onMapCompactLayoutChange(usesCompactRows)
            pruneSelection(to: derivation.visibleOrder)
            synchronizePresentedTrip(presentedTripID, proxy: proxy)
            registerSelectAll()
        }
        .onDisappear {
            SelectAllCommandRelay.handler = nil
        }
        .onChange(of: model.isCommandSurfaceAvailable) { _, _ in
            registerSelectAll()
        }
        .onChange(of: usesCompactRows) { _, compact in onMapCompactLayoutChange(compact) }
        .onChange(of: derivation.visibleOrder) { _, order in
            visibleOrder = order
            onVisibleOrderChange(order)
            pruneSelection(to: order)
        }
        // Sort, Select, Merge, and the selection-wide verbs live here, so this
        // is what answers for them.
        .focusedSceneValue(
            \.driveCommandActions,
            commandActions(selectedTripIDs: orderedSelection, proxy: proxy)
        )
        .overlay { emptyState(isEmpty: derivation.trips.isEmpty) }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !searchQuery.isEmpty, scope != .allTrips {
                DriveSearchScopePicker(selection: $searchScope, mailbox: scope)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                        pullCaptionSearchScopeBottom = $0
                    }
            }
        }
        .onChange(of: editMode) { oldValue, newValue in
            if oldValue.isEditing, !newValue.isEditing {
                (editModeSelection ?? $selection).wrappedValue = []
            }
        }
        // A singleton — a plain click, a ⌘-arrow step — is the anchor every
        // Mac list keeps; a removal, a range, or a prune keeps it as long as
        // its row is still selected, and drops it otherwise.
        .onChange(of: selection) { _, newSelection in
            if newSelection.count == 1 {
                selectionAnchor = newSelection.first
            } else if let anchor = selectionAnchor, !newSelection.contains(anchor) {
                selectionAnchor = nil
            }
        }
        // Keeps the selected row on screen when the pane moves from outside
        // this list — a detail chevron, Spotlight open, or deep link. SwiftUI
        // does not scroll a list to a programmatic change on its own, and
        // `anchor: nil` scrolls the minimum distance, so a row selected by
        // clicking it (already visible) does not get re-centered under the
        // pointer.
        .onChange(of: presentedTripID) { _, id in
            synchronizePresentedTrip(id, proxy: proxy)
        }
    }

    /// SwiftUI owns click selection through the direct binding. On the tested
    /// Designed-for-iPad Mac host, modified clicks follow the host's default
    /// singleton-replacement behavior; Mileager does not reinterpret them.
    /// The explicit policy branches keep navigation and context-menu behavior
    /// separate even though both lists use the same selection binding.
    @ViewBuilder
    private func selectionList(derivation: DriveListDerivation) -> some View {
        switch interactionPolicy {
        case .selectionDriven:
            List(selection: activeSelectionBinding) {
                listContents(derivation: derivation)
            }
            .listStyle(.plain)
            .accessibilityIdentifier("tripList")
            .modifier(TripPullCaption(
                rollup: rollupDisplay(trips: derivation.trips),
                currencyCode: model.currencyCode,
                distanceUnit: distanceUnit,
                toolbarBottom: pullCaptionToolbarBottom,
                controlsBottom: !searchQuery.isEmpty && scope != .allTrips ? pullCaptionSearchScopeBottom : nil,
                isEnabled: scope != .needsReview && !model.platform.isMac
            ))
            .tint(Color(uiColor: .systemBlue))
        case .primaryActionDriven:
            List(selection: activeSelectionBinding) {
                listContents(derivation: derivation)
            }
            .listStyle(.plain)
            .accessibilityIdentifier("tripList")
            .modifier(TripPullCaption(
                rollup: rollupDisplay(trips: derivation.trips),
                currencyCode: model.currencyCode,
                distanceUnit: distanceUnit,
                toolbarBottom: pullCaptionToolbarBottom,
                controlsBottom: !searchQuery.isEmpty && scope != .allTrips ? pullCaptionSearchScopeBottom : nil,
                isEnabled: scope != .needsReview && !model.platform.isMac
            ))
            .tint(isMacList ? Color(uiColor: .systemBlue) : nil)
        }
    }

    @ViewBuilder
    private func listContents(derivation: DriveListDerivation) -> some View {
        if effectiveScope.showsMonthHeaders {
            ForEach(derivation.monthGroups) { group in
                Section {
                    rows(group.trips, nextTripByID: derivation.nextTripByID)
                } header: {
                    // Just the month. The root's month rows already carry
                    // distance and money; repeating them here is the kind of
                    // duplicated furniture Mail never shows.
                    Text(group.monthStart.formatted(.dateTime.month(.wide).year()))
                }
            }
        } else {
            Section {
                rows(derivation.trips, nextTripByID: derivation.nextTripByID)
            } header: {
                if !derivation.trips.isEmpty {
                    // "%lld trips" carries a plural variation in the catalog.
                    Text("\(derivation.trips.count) trips")
                }
            }
        }
    }

    /// The same item-aware menu is available on every list. Only the touch
    /// and compact-Mac policies attach a primary action; on expanded Mac the
    /// `List(selection:)` binding is the interaction and drives the adjacent
    /// reading pane directly.
    @ViewBuilder
    private func selectionContextMenuHost<Content: View>(
        _ content: Content,
        nextTripByID: [UUID: TripSummary]
    ) -> some View {
        if interactionPolicy == .primaryActionDriven {
            content.contextMenu(forSelectionType: UUID.self) { itemIDs in
                selectionContextMenu(for: itemIDs, nextTripByID: nextTripByID)
            } primaryAction: { itemIDs in
                performPrimaryAction(for: itemIDs)
            }
        } else {
            content.contextMenu(forSelectionType: UUID.self) { itemIDs in
                selectionContextMenu(for: itemIDs, nextTripByID: nextTripByID)
            }
        }
    }

    /// Edit ▸ Select All reaches the Mac list through the responder chain;
    /// the same lock gate as the ⌘-menu decides whether it is offered.
    private func registerSelectAll() {
        guard isMacList, model.isCommandSurfaceAvailable else {
            SelectAllCommandRelay.handler = nil
            return
        }
        SelectAllCommandRelay.handler = {
            activeSelectionBinding.wrappedValue = Set(visibleOrder)
        }
    }

    /// Nil while App Lock is engaged or the stores are the in-memory
    /// placeholder — menu dispatch bypasses the lock overlay's hitTest gate,
    /// so withholding the value is what grays the ⌘-menu out.
    ///
    /// `orderedSelection` is the per-pass projection the toolbar also renders
    /// from; the closures re-project at call time because they run later.
    private func commandActions(
        selectedTripIDs orderedSelection: [UUID],
        proxy: ScrollViewProxy
    ) -> DriveCommandActions? {
        guard model.isCommandSurfaceAvailable else { return nil }
        return DriveCommandActions(
            sortOption: sortOption,
            selectionModeActive: selectionModeIsActive,
            canMergeSelection: orderedSelection.count >= 2,
            selectedTripIDs: orderedSelection,
            businessPurposePresets: model.businessPurposePresets,
            supportsKeyboardSelection: isMacList,
            setSortOption: { sortOption = $0 },
            cycleSortOption: { sortOption = sortOption.next },
            toggleSelectionMode: {
                // A normal Mac click is a live singleton selection, not an
                // explicit mode to finish. Only Edit mode changes the Mac
                // command from Select Trips to Finish Selecting Trips.
                if selectionModeIsActive {
                    endSelection()
                } else {
                    withAnimation(.snappy) { editMode = .active }
                }
            },
            deselectAll: { activeSelectionBinding.wrappedValue = [] },
            // SwiftUI does not scroll a list to a programmatic selection, so
            // each keyboard move brings the row it landed on into view.
            stepSelection: { offset in
                guard let id = DriveListSelectionProjection.stepped(
                    selection, by: offset, visibleOrder: visibleOrder
                ) else { return }
                activeSelectionBinding.wrappedValue = [id]
                proxy.scrollTo(id, anchor: nil)
            },
            extendSelection: { offset in
                let move = DriveListSelectionProjection.extended(
                    selection, anchor: selectionAnchor, by: offset, visibleOrder: visibleOrder
                )
                guard let focus = move.focus else { return }
                activeSelectionBinding.wrappedValue = move.selection
                proxy.scrollTo(focus, anchor: nil)
            },
            mergeSelected: {
                let ids = selectedTripIDs
                guard ids.count >= 2 else { return }
                model.merge(tripIDs: ids)
                finishBulkAction()
            },
            classifySelection: { classification, purpose in
                guard !selectedTripIDs.isEmpty else { return }
                model.classify(
                    tripIDs: selectedTripIDs, as: classification, purpose: purpose
                )
                finishBulkAction()
            },
            deleteSelection: {
                guard !selectedTripIDs.isEmpty else { return }
                // The confirmation dialog always fronts the destructive verb.
                perform(.confirmBulkDelete(selectedTrips))
            },
            vehicles: model.multiVehicleUIActive
                ? model.vehicles.map { DriveCommandVehicle(id: $0.id, name: $0.name) }
                : [],
            customPurpose: {
                let ids = selectedTripIDs
                guard !ids.isEmpty else { return }
                perform(.bulkPurpose(ids))
                finishBulkAction()
            },
            clearPurpose: {
                let ids = selectedTripIDs
                guard !ids.isEmpty else { return }
                model.updatePurpose(tripIDs: ids, purpose: "")
                finishBulkAction()
            },
            assignVehicle: { vehicleID in
                let ids = selectedTripIDs
                guard !ids.isEmpty else { return }
                model.assignVehicle(tripIDs: ids, vehicleID: vehicleID)
                finishBulkAction()
            }
        )
    }

    // MARK: - Rows

    @ViewBuilder
    private func rows(_ trips: [TripSummary], nextTripByID: [UUID: TripSummary]) -> some View {
        ForEach(trips) { trip in
            let next = nextTripByID[trip.id]
            let showsMergeAfter = next.map { canMergeAdjacent(trip, $0) } ?? false

            // A selection has its own vocabulary — checkmarks in Select
            // mode, the system's filled row for a pointer selection — and two
            // selection languages at once would be unreadable, so the browse
            // chip yields whenever rows are selected.
            let isOpenInReadingPane = showsSelection
                && !isMacList
                && !isSelecting
                && trip.id == presentedTripID
            // Derived ONCE and passed to both the chip and the row text, so
            // the blue-vs-gray rule cannot drift between them: blue while the
            // window is active, gray when it is not — Mail's two states.
            let isEmphasized = isOpenInReadingPane && scenePhase == .active
            // Mail's selection on the Mac list (David's call, 2026-09-02): a
            // blue chip with white text while browsing. Explicit Select mode
            // yields to SwiftUI's native checkmarks instead.
            let isFilledByMacSelection = isMacList
                && !editMode.isEditing
                && selection.contains(trip.id)
            DriveRow(
                trip: trip,
                suggestion: !editMode.isEditing && trip.classification == nil
                    ? model.tripSuggestions[trip.id]
                    : nil,
                includesGenericReviewStatus: effectiveScope != .needsReview,
                usesCompactLayout: usesCompactRows,
                isEmphasizedSelection: isEmphasized || isFilledByMacSelection
            )
            // Reserve the lane the adjacent-merge control straddles.
            .padding(.trailing, 20)
            .driveRowSelection(isSelected: isOpenInReadingPane, isEmphasized: isEmphasized)
            .contentShape(Rectangle())
            // Announced as a button with an explicit activate action while
            // browsing, without being a Button VIEW: a row-level Button
            // consumed the modifier click before List(selection:) saw it,
            // whereas a trait and an accessibility action are AX-only and
            // never enter the gesture path. Explicit Select mode removes this
            // browse action too, leaving VoiceOver and Switch Control on the
            // List's native selection semantics.
            .modifier(
                DriveRowBrowseAccessibilityModifier(isEnabled: !editMode.isEditing) {
                    onPrimaryAction(trip)
                }
            )
            .appEntityIdentifier(
                model.siriIndexingEnabled
                    ? EntityIdentifier(for: TripAppEntity.self, identifier: trip.id)
                    : nil
            )
            .accessibilityIdentifier("driveCard")
            .anchorPreference(key: AdjacentMergeBoundaryPreferenceKey.self, value: .bounds) { anchor in
                guard showsMergeAfter, let next else { return [] }
                return [
                    AdjacentMergeBoundary(
                        firstTripID: trip.id,
                        secondTripID: next.id,
                        firstRouteLabel: DriveRouteLabelFormatter.label(for: trip),
                        secondRouteLabel: DriveRouteLabelFormatter.label(for: next),
                        anchor: anchor
                    )
                ]
            }
            // This tag connects the passive row to both List(selection:) and
            // the list-level context-menu primary action.
            .tag(trip.id)
            // Tighter than the system default so the map claims the width back:
            // the thumbnail is the most legible thing in the row and the
            // margin around it was doing no work.
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .listRowBackground(macRowBackground(isSelected: isFilledByMacSelection))
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                leadingSwipeButtons(for: trip)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                trailingSwipeButtons(for: trip)
            }
        }
    }

    /// The Mac list's browse-mode row background: Mail's blue chip when the
    /// row is selected, clear otherwise. `nil` — no custom background at all —
    /// on touch shells and while explicit Select mode is showing SwiftUI's
    /// native checkmarks. The platform's selection treatment depends on the
    /// default cell background; a custom one suppresses it.
    /// Same geometry as `driveRowSelection`'s chip, so the reading-pane chip
    /// and the selection chip are the same shape on every shell.
    private func macRowBackground(isSelected: Bool) -> AnyView? {
        guard isMacList, !editMode.isEditing else { return nil }
        return AnyView(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color(uiColor: .systemBlue) : Color.clear)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
        )
    }

    /// Leading carries *purposes*, not a bare "Business": a Business trip with
    /// no purpose stays unresolved, so a bare-Business swipe would only move the
    /// row between unread reasons rather than finishing it.
    @ViewBuilder
    private func leadingSwipeButtons(for trip: TripSummary) -> some View {
        let purposes = Array(model.businessPurposePresets.prefix(3))
        if purposes.isEmpty {
            Button {
                model.classify(trip, as: .business)
            } label: {
                Label("Business", systemImage: "briefcase.fill")
            }
            .tint(MileageTheme.businessAccent)
            .accessibilityIdentifier("swipeBusinessPrimary")
        } else {
            ForEach(Array(purposes.enumerated()), id: \.element) { index, purpose in
                Button {
                    model.classify(trip, as: .business, purpose: purpose)
                } label: {
                    Label(purpose, systemImage: index == 0 ? "briefcase.fill" : "briefcase")
                }
                .tint(index == 0 ? MileageTheme.businessAccent : MileageTheme.businessSecondaryAccent)
                .accessibilityIdentifier([
                    "swipeBusinessPrimary",
                    "swipeBusinessSecondary",
                    "swipeBusinessTertiary"
                ][index])
            }
        }
    }

    /// Declared outermost-first. The rail carries classification only — an
    /// engine note is not work, so there is nothing here to clear.
    @ViewBuilder
    private func trailingSwipeButtons(for trip: TripSummary) -> some View {
        Button {
            model.classify(trip, as: .personal)
        } label: {
            Label("Personal", systemImage: "person.fill")
        }
        .tint(MileageTheme.personalAccent)
        .accessibilityIdentifier("swipePersonal")

        Button {
            model.classify(trip, as: .notADrive)
        } label: {
            Label("Not a Drive", systemImage: "nosign")
        }
        .tint(Color(.systemGray))
        .accessibilityIdentifier("swipeNotADrive")
    }

    /// The menu receives SwiftUI's item set, not a row-local guess. A
    /// right-click on one selected row therefore speaks for the whole native
    /// selection, while a right-click outside it receives that one item.
    @ViewBuilder
    private func selectionContextMenu(
        for itemIDs: Set<UUID>,
        nextTripByID: [UUID: TripSummary]
    ) -> some View {
        let orderedIDs = DriveListSelectionProjection.ordered(
            itemIDs, visibleOrder: visibleOrder
        )
        if orderedIDs.count > 1 {
            bulkContextMenu(for: orderedIDs)
        } else if let id = orderedIDs.first, let trip = model.trip(id: id) {
            contextMenu(for: trip, next: nextTripByID[id])
        }
    }

    private func performPrimaryAction(for itemIDs: Set<UUID>) {
        guard !editMode.isEditing,
              itemIDs.count == 1,
              let id = itemIDs.first,
              let trip = model.trip(id: id)
        else { return }
        switch interactionPolicy {
        case .primaryActionDriven where !isMacList:
            // iOS may transiently report the tapped item through the List
            // binding before delivering primaryAction. Browsing is not
            // selection mode, so do not let that implementation detail raise
            // the bulk-action bar.
            activeSelectionBinding.wrappedValue = []
            onPrimaryAction(trip)
        case .primaryActionDriven:
            // A compact Mac has no adjacent pane for a selection to open. Its
            // primary action identifies and opens the clicked row. Modifier
            // clicks are left entirely to SwiftUI's List selection behavior.
            onPrimaryAction(trip)
        case .selectionDriven:
            // This policy never attaches a primary action. Keep the case
            // explicit so a future policy change cannot silently reopen the
            // selection/activation race.
            assertionFailure("Expanded Mac selection must not deliver a primary action")
        }
    }

    @ViewBuilder
    private func contextMenu(for trip: TripSummary, next: TripSummary?) -> some View {
        // Classification leads, mirroring the swipe rails, so pointer users
        // (trackpad, Mac) have a first-class path to the app's primary work.
        // Business is a submenu holding its purposes — the presets, Custom…,
        // the bare Business for a purpose to be filled in later, and Clear
        // Purpose — the same shape as the bar's Classify menu (David's call,
        // 2026-09-02, retiring the separate Purpose submenu). A typed or
        // preset purpose classifies the trip Business by itself.
        Menu {
            ForEach(model.businessPurposePresets, id: \.self) { purpose in
                Button(purpose) {
                    model.classify(trip, as: .business, purpose: purpose)
                }
            }
            Button {
                perform(.editPurpose(trip))
            } label: {
                Label("Custom...", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("tripContextQuickPurpose")
            Divider()
            Button {
                model.classify(trip, as: .business)
            } label: {
                Label("Business", systemImage: "briefcase.fill")
            }
            if TripReviewPolicy.normalizedBusinessPurpose(trip.businessPurpose) != nil {
                Button(role: .destructive) {
                    model.updatePurpose(tripIDs: [trip.id], purpose: "")
                } label: {
                    Label("Clear Purpose", systemImage: "xmark.circle.fill")
                }
            }
        } label: {
            Label("Business", systemImage: "briefcase.fill")
        }
        .menuOrder(.fixed)
        .accessibilityIdentifier("tripContextBusiness")

        Button {
            model.classify(trip, as: .personal)
        } label: {
            Label("Personal", systemImage: "person.fill")
        }
        .accessibilityIdentifier("tripContextPersonal")

        Button {
            model.classify(trip, as: .notADrive)
        } label: {
            Label("Not a Drive", systemImage: "nosign")
        }
        .accessibilityIdentifier("tripContextNotADrive")

        Divider()

        Button { perform(.editNotes(trip)) } label: {
            Label("Notes", systemImage: QuickTripField.notes.systemImage)
        }
        .accessibilityIdentifier("tripContextQuickNotes")

        Button { perform(.addFee(trip, .toll)) } label: {
            Label("Toll", systemImage: "dollarsign.circle.fill")
        }
        .accessibilityIdentifier("tripContextQuickTolls")

        Button { perform(.addFee(trip, .parking)) } label: {
            Label("Parking", systemImage: "parkingsign.circle.fill")
        }
        .accessibilityIdentifier("tripContextQuickParking")

        Button { perform(.exportTrip(trip)) } label: {
            Label("Export PDF", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("tripContextExportPDF")

        if trip.classification != nil {
            Button {
                model.classify(tripIDs: [trip.id], as: nil)
            } label: {
                Label("Unclassify", systemImage: "arrow.uturn.backward.circle")
            }
            .accessibilityIdentifier("tripContextUnclassify")
        }

        // The same displayed successor as the floating boundary control.
        if let next, model.canMergeAdjacentTrips(trip, next) {
            Button {
                model.merge(tripIDs: [trip.id, next.id])
            } label: {
                Label("Merge with Next Trip", systemImage: "link")
            }
            .accessibilityIdentifier("tripContextMergeAdjacent")
        }

        if trip.canUnmerge {
            Button {
                model.unmerge(trip)
            } label: {
                Label("Unmerge Trip", systemImage: "link.badge.minus")
            }
            .accessibilityIdentifier("tripContextUnmerge")
        }

        Divider()

        Button(role: .destructive) {
            perform(.confirmDelete(trip))
        } label: {
            Label("Delete Trip", systemImage: "trash.fill")
        }
    }

    // MARK: - Period roll-up

    /// Compute the pull summary from exactly the scoped, filtered rows.
    /// A separate store query could disagree with search or vehicle selection.
    private func rollupDisplay(trips: [TripSummary]) -> ReportRollupDisplay? {
        guard !trips.isEmpty else { return nil }

        let drives = trips.filter { $0.classification?.countsAsDrive ?? true }
        let businessTrips = drives.filter(\.isExportableBusiness)
        return ReportRollupDisplay(
            businessDriveCount: businessTrips.count,
            businessMiles: businessTrips.reduce(0) { $0 + $1.miles },
            businessParkingAndTolls: businessTrips.reduce(0) { $0 + $1.tollsAmount + $1.parkingAmount },
            unclassifiedCount: trips.filter { $0.classification == nil }.count,
            // Anchored to the period, which is the only date this figure can
            // honestly describe. `rate` is just the fallback for an empty
            // business set; reading it off whichever trip the store happened
            // to publish first was neither the period's rate nor any trip's.
            rate: model.mileageRateSchedule.rate(on: scope.periodInterval()?.start ?? Date()),
            businessTrips: businessTrips,
            rateSchedule: model.mileageRateSchedule,
            currencyCode: model.currencyCode,
            distanceUnit: distanceUnit
        )
    }

    // MARK: - Chrome

    /// Status, never totals. Totals live on the month rows, where they foot to
    /// something an accountant can check.
    private func subtitle(for derivation: DriveListDerivation) -> String {
        if !searchQuery.isEmpty {
            return String(localized: "\(derivation.trips.count) results")
        }
        switch scope {
        case .needsReview:
            return String(localized: "\(derivation.trips.count) need review")
        case .allTrips:
            return String(localized: "\(derivation.trips.count) trips")
        case .month, .year:
            return derivation.unresolvedCount == 0
                ? String(localized: "Ready to Export")
                : String(localized: "\(derivation.unresolvedCount) need review")
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(selectedTripIDs ids: [UUID]) -> some ToolbarContent {
        if !isSelecting, currentDriveBarIsMinimized, let summary = model.currentDrive {
            ToolbarItem(placement: .bottomBar) {
                CurrentDriveMinimizedButton(summary: summary) {
                    currentDriveBarIsMinimized = false
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        if UIDevice.current.userInterfaceIdiom != .phone {
            DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
        }
        if isMacList {
            // The Mac toolbar never changes shape when Select mode starts.
            // Select and Done occupy one visible trailing slot, while the
            // entire bottom bar stays put; only the rows' selection treatment
            // and the bulk verbs' enabled state change.
            //
            // They sit in the BOTTOM bar, not beside List Options, because a
            // navigation bar in this column folds a trailing group larger than
            // about four items into a system "More" overflow — measured on an
            // iPad Pro 13": six items left Classify, Purpose, Merge and
            // "More", with Delete and List Options hidden inside it, which is
            // precisely the "can't see what's actionable" this arrangement
            // exists to avoid. The bottom bar has no such cap; it already
            // carries five in Select mode on an iPhone SE.
            ToolbarItemGroup(placement: .topBarTrailing) {
                listOptionsMenu
                if case let .month(monthStart) = scope, searchQuery.isEmpty {
                    exportMenu { perform(.exportMonth(monthStart, $0)) }
                }
                if case let .year(yearStart) = scope, searchQuery.isEmpty {
                    exportMenu { perform(.exportYear(yearStart, $0)) }
                }
                macSelectionModeButton
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if showsFilterMenu {
                    filterMenu
                }
                Spacer()
                classifyMenu(for: ids)
                if model.multiVehicleUIActive {
                    vehicleMenu(for: ids)
                }
                mergeButton(for: ids)
                deleteButton(for: ids)
                Spacer()
                Button { perform(.addManualTrip(defaultDate: scope.defaultNewTripDate)) } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add missed trip")
                .accessibilityIdentifier("listAddTripButton")
            }
        } else if isSelecting {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { endSelection() }
                    .accessibilityIdentifier("selectionDoneButton")
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                        pullCaptionToolbarBottom = $0
                    }
            }
            // Every bulk verb is on the bar; nothing hides behind an overflow.
            // Only the two menus that open a list of choices carry titles —
            // Merge and Delete are single actions with unambiguous glyphs, so
            // they shrink to icons and the row still fits an iPhone SE.
            ToolbarItemGroup(placement: .bottomBar) {
                classifyMenu(for: ids)
                if model.multiVehicleUIActive {
                    vehicleMenu(for: ids)
                }
                mergeButton(for: ids)
                Spacer()
                deleteButton(for: ids)
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                listOptionsMenu
                if case let .month(monthStart) = scope, searchQuery.isEmpty {
                    exportMenu { perform(.exportMonth(monthStart, $0)) }
                }
                if case let .year(yearStart) = scope, searchQuery.isEmpty {
                    exportMenu { perform(.exportYear(yearStart, $0)) }
                }
            }
            browseBottomBar
        }
    }

    /// A first-class Mac control rather than a command hidden inside List
    /// Options. The paired labels keep the entry and exit affordance in the
    /// same trailing toolbar slot.
    @ViewBuilder
    private var macSelectionModeButton: some View {
        if editMode.isEditing {
            Button("Done") { endSelection() }
                .accessibilityIdentifier("selectionDoneButton")
        } else {
            Button("Select") {
                withAnimation(.snappy) { editMode = .active }
            }
            .accessibilityIdentifier("selectTripsButton")
        }
    }

    /// Filter and Add, which belong to browsing rather than to a deliberate
    /// Select-mode session. A normal Mac row selection keeps them in place;
    /// explicit Select mode uses the shared bulk bar above.
    ///
    /// iPhone gives system search an explicit slot beside Filter and Add.
    /// iPad and Mac keep search in the top toolbar, its native placement there.
    @ToolbarContentBuilder
    private var browseBottomBar: some ToolbarContent {
        if UIDevice.current.userInterfaceIdiom == .phone {
            ToolbarItem(placement: .bottomBar) {
                if showsFilterMenu { filterMenu }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { addTripButton }
        } else {
            ToolbarItemGroup(placement: .bottomBar) {
                if showsFilterMenu {
                    filterMenu
                }
                Spacer()
                addTripButton
            }
        }
    }

    private var addTripButton: some View {
        Button { perform(.addManualTrip(defaultDate: scope.defaultNewTripDate)) } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add missed trip")
        .accessibilityIdentifier("listAddTripButton")
    }

    /// Bottom-leading, Mail's filter slot. Fills in when a filter narrows the
    /// list, so an unexpectedly short list explains itself.
    private var filterMenu: some View {
        Menu {
            if allowsClassificationFilter {
                Picker("Filter Trips", selection: $tripFilter) {
                    ForEach(TripClassificationFilter.allCases) { option in
                        Label(option.title, systemImage: option.systemImage).tag(option)
                    }
                }
            }
            if model.multiVehicleUIActive {
                @Bindable var model = model
                Picker("Vehicle", selection: $model.vehicleFilter) {
                    Text("All Vehicles").tag(TripVehicleFilter.all)
                    ForEach(model.vehicles) { vehicle in
                        Text(vehicle.name).tag(TripVehicleFilter.vehicle(vehicle.id))
                    }
                }
                .accessibilityIdentifier("vehicleScopeMenu")
            }
        } label: {
            Image(systemName: anyFilterActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter Trips")
        .accessibilityValue(
            Text(verbatim: "\(effectiveTripFilter.title), \(vehicleFilter.title(vehicles: model.vehicles))")
        )
        .accessibilityIdentifier("filterDrivesMenu")
    }

    private var listOptionsMenu: some View {
        Menu {
            // Touch platforms keep Select in List Options. The Mac has a
            // persistent, directly-visible Select/Done button in the bar.
            if !isMacList {
                Button {
                    withAnimation(.snappy) { editMode = .active }
                } label: {
                    Label("Select", systemImage: "checklist")
                }
                .accessibilityIdentifier("selectTripsButton")

                Divider()
            }

            Picker("Sort Trips", selection: $sortOption) {
                ForEach(DriveSortOption.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            .accessibilityIdentifier("sortDrivesMenu")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("List Options")
        .accessibilityIdentifier("listOptionsMenu")
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
            pullCaptionToolbarBottom = $0
        }
    }

    private func exportMenu(onExport: @escaping (MileageReportExportFormat) -> Void) -> some View {
        Menu {
            Button("Export PDF") { onExport(.pdf) }
                .accessibilityIdentifier("periodExportPDF")
            Button("Export CSV") { onExport(.csv) }
                .accessibilityIdentifier("periodExportCSV")
            Button("Export QuickBooks CSV") { onExport(.quickBooksCSV) }
                .accessibilityIdentifier("periodExportQuickBooksCSV")
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        // The toolbar's default label style — the glyph alone, like every
        // other item in the bar (David's call, 2026-09-02).
        .menuOrder(.fixed)
        .accessibilityIdentifier("periodExportMenu")
    }

    // MARK: - Bulk verbs

    private var selectedTripIDs: [UUID] {
        DriveListSelectionProjection.ordered(selection, visibleOrder: visibleOrder)
    }

    private var selectedTrips: [TripSummary] {
        trips(for: selectedTripIDs)
    }

    private func trips(for ids: [UUID]) -> [TripSummary] {
        ids.compactMap { model.trip(id: $0) }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Right-click / long-press on a selected row while multiple rows are
    /// selected: the same verbs as the edit-mode bottom bar, acting on the
    /// full selection.
    @ViewBuilder
    private func bulkContextMenu(for ids: [UUID]) -> some View {
        bulkClassifyButtons(for: ids)

        Divider()

        if model.multiVehicleUIActive {
            Menu {
                ForEach(model.vehicles) { vehicle in
                    Button(vehicle.name) {
                        model.assignVehicle(tripIDs: ids, vehicleID: vehicle.id)
                        finishBulkAction()
                    }
                }
            } label: {
                Label("Assign Vehicle", systemImage: "car")
            }
        }

        Button {
            model.merge(tripIDs: ids)
            finishBulkAction()
        } label: {
            Label("Merge", systemImage: "link")
        }

        Divider()

        Button(role: .destructive) {
            perform(.confirmBulkDelete(trips(for: ids)))
        } label: {
            Label("Delete Permanently", systemImage: "trash")
        }
    }

    /// The four classification verbs in the same order the swipe rail uses.
    /// The classification verbs acting on the whole selection — one builder
    /// shared by the bar's Classify menu and the multi-select context menu,
    /// so the verb list cannot drift between them.
    ///
    /// Business opens as a submenu, because a purpose is Business's own
    /// detail rather than a separate verb (David's call, 2026-09-02, retiring
    /// the standalone Purpose menu): the presets classify Business and set
    /// the purpose in one hit, Custom… asks for one, the bare Business stays
    /// for a purpose to be filled in later, and Clear Purpose lives with the
    /// purposes it clears. Same shape as the single-row context menu.
    @ViewBuilder
    private func bulkClassifyButtons(for ids: [UUID]) -> some View {
        Menu {
            ForEach(model.businessPurposePresets, id: \.self) { purpose in
                Button(purpose) {
                    model.classify(tripIDs: ids, as: .business, purpose: purpose)
                    finishBulkAction()
                }
            }
            Button {
                perform(.bulkPurpose(ids))
                finishBulkAction()
            } label: {
                Label("Custom...", systemImage: "square.and.pencil")
            }
            Divider()
            Button {
                model.classify(tripIDs: ids, as: .business)
                finishBulkAction()
            } label: {
                Label("Business", systemImage: "briefcase.fill")
            }
            Button(role: .destructive) {
                model.updatePurpose(tripIDs: ids, purpose: "")
                finishBulkAction()
            } label: {
                Label("Clear Purpose", systemImage: "xmark.circle.fill")
            }
        } label: {
            Label("Business", systemImage: "briefcase.fill")
        }
        .menuOrder(.fixed)
        .accessibilityIdentifier("bulkBusinessMenu")
        Button {
            model.classify(tripIDs: ids, as: .personal)
            finishBulkAction()
        } label: {
            Label("Personal", systemImage: "person.fill")
        }
        Button {
            model.classify(tripIDs: ids, as: .notADrive)
            finishBulkAction()
        } label: {
            Label("Not a Drive", systemImage: "nosign")
        }
        Divider()
        Button {
            model.classify(tripIDs: ids, as: nil)
            finishBulkAction()
        } label: {
            Label("Unclassify", systemImage: "arrow.uturn.backward.circle")
        }
    }

    /// Every bar verb takes the same projected `ids` it is enabled on. The
    /// raw `selection` can hold rows this scope never rendered (a Siri open
    /// of a classified trip while Need Review is showing), and a verb enabled
    /// on that set but acting on the projection was a tappable no-op — or,
    /// for Merge, a store call with one id and an error alert.
    private func classifyMenu(for ids: [UUID]) -> some View {
        Menu {
            bulkClassifyButtons(for: ids)
        } label: {
            // A checkmark, not the tag Purpose already wears: classifying is
            // how a trip leaves Need Review, and the Caught Up state uses the
            // same glyph for the same idea. An icon like its neighbours
            // (David's call, 2026-09-02); the label still reads "Classify"
            // to VoiceOver.
            Label("Classify", systemImage: "checkmark.circle")
        }
        // The bar sits at the bottom, so the menu always opens upward and
        // `.priority` would flip these into Unclassify-first. Keep declaration
        // order on screen: Business is the common case and belongs on top.
        .menuOrder(.fixed)
        .labelStyle(.iconOnly)
        .disabled(ids.isEmpty)
        .accessibilityLabel("Classify")
        .accessibilityIdentifier("bulkClassifyButton")
    }

    /// Icon-only: the car glyph carries it, and this slot only exists for the
    /// minority of users running more than one vehicle. Spelling it out would
    /// be the thing that pushes the bar back into an overflow menu.
    private func vehicleMenu(for ids: [UUID]) -> some View {
        Menu {
            ForEach(model.vehicles) { vehicle in
                Button(vehicle.name) {
                    model.assignVehicle(tripIDs: ids, vehicleID: vehicle.id)
                    finishBulkAction()
                }
            }
        } label: {
            Label("Assign Vehicle", systemImage: "car")
        }
        .labelStyle(.iconOnly)
        .menuOrder(.fixed)
        .disabled(ids.isEmpty)
        .accessibilityLabel("Assign Vehicle")
        .accessibilityIdentifier("bulkVehicleButton")
    }

    private func mergeButton(for ids: [UUID]) -> some View {
        Button {
            // Same guard as ⇧⌘M: `TripStore.mergeTrips` throws on fewer than
            // two ids, and a button the app enabled must not produce an alert.
            guard ids.count >= 2 else { return }
            model.merge(tripIDs: ids)
            finishBulkAction()
        } label: {
            Label("Merge", systemImage: "link")
        }
        .labelStyle(.iconOnly)
        .disabled(ids.count < 2)
        .accessibilityLabel("Merge")
        .accessibilityIdentifier("mergeTripsButton")
    }

    /// Trailing edge, past the spacer — the one verb here that destroys a tax
    /// record does not sit thumb-adjacent to Merge. `.confirmBulkDelete` still
    /// puts a confirmation dialog in front of it.
    private func deleteButton(for ids: [UUID]) -> some View {
        Button(role: .destructive) {
            perform(.confirmBulkDelete(trips(for: ids)))
        } label: {
            Label("Delete Permanently", systemImage: "trash")
        }
        .labelStyle(.iconOnly)
        .disabled(ids.isEmpty)
        .accessibilityLabel("Delete Permanently")
        .accessibilityIdentifier("deleteSelectedTripsButton")
    }

    /// Whether the floating merge control should straddle this pair's boundary.
    /// Every scope this list serves qualifies; see `AdjacentMergeOverlayVisibility`.
    private func canMergeAdjacent(_ first: TripSummary, _ second: TripSummary) -> Bool {
        AdjacentMergeOverlayVisibility.canShow(
            // Not `isSelecting`: on the Mac a plain click always selects, so
            // asking that would retire this control permanently. It yields to
            // Select mode and to a real multi-selection, nothing else.
            isEditing: editMode.isEditing || selection.count > 1,
            canMerge: model.canMergeAdjacentTrips(first, second)
        )
    }

    private func synchronizePresentedTrip(_ id: UUID?, proxy: ScrollViewProxy) {
        guard let id else { return }
        proxy.scrollTo(id, anchor: nil)
        guard isMacList, visibleOrder.contains(id), selection != [id] else { return }
        activeSelectionBinding.wrappedValue = [id]
    }

    private func endSelection() {
        // A pointer-made iPad selection has no edit mode to leave, so clearing
        // the binding is still the visible part of finishing selection.
        withAnimation(.snappy) {
            // Clear through the Edit-mode binding before changing the mode;
            // compact Mac's browse binding deliberately defers singleton
            // empties while waiting for a primary action.
            activeSelectionBinding.wrappedValue = []
            editMode = .inactive
        }
    }

    /// A normal Mac browse selection survives non-destructive commands. An
    /// explicit Select-mode session follows the touch lifecycle and returns to
    /// browsing after the command completes.
    private func finishBulkAction() {
        guard !isMacList || editMode.isEditing else { return }
        endSelection()
    }

    /// Keeps the selection tied to rows that still exist in this exact scope,
    /// and leaves Select mode when nothing survived.
    private func pruneSelection(to visibleOrder: [UUID]) {
        let pruned = DriveListSelectionProjection.pruned(selection, visibleOrder: visibleOrder)
        if pruned != selection { activeSelectionBinding.wrappedValue = pruned }
        if pruned.isEmpty, editMode.isEditing { endSelection() }
    }

    // MARK: - Empty states

    @ViewBuilder
    /// A filter is checked *before* the scope, because a filter can empty any
    /// list — including the inbox. Claiming "Caught Up" when the user has simply
    /// filtered to Personal is a lie about their tax record, and it is the one
    /// message on this screen they might act on by not reviewing anything.
    ///
    /// The vehicle scope wins over the classification filter when both are on,
    /// so the copy names the narrower reason; that also keeps
    /// `TripVehicleFilter`'s own empty-state strings reachable.
    private func emptyState(isEmpty: Bool) -> some View {
        if isEmpty {
            if !searchQuery.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Trips", systemImage: "magnifyingglass")
                } description: {
                    Text("Try another place, purpose, or note, or change your filters.")
                } actions: {
                    if effectiveScope != .allTrips {
                        Button("Search All Trips") { searchScope = .allTrips }
                            .accessibilityIdentifier("searchAllTripsButton")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("tripSearchEmptyState")
            } else if vehicleFilter.isActive {
                EmbossedEmptyState(
                    title: Text(vehicleFilter.emptyStateMessage(vehicles: model.vehicles)),
                    systemImage: vehicleFilter.systemImage,
                    description: Text(vehicleFilter.emptyStateHint)
                )
                .accessibilityIdentifier("filteredEmptyState")
            } else if effectiveTripFilter.isActive {
                EmbossedEmptyState(
                    title: Text(effectiveTripFilter.emptyStateMessage),
                    systemImage: effectiveTripFilter.systemImage,
                    description: Text(effectiveTripFilter.emptyStateHint)
                )
                .accessibilityIdentifier("filteredEmptyState")
            } else if case .needsReview = scope {
                // Deliberately quieter than ContentUnavailableView: an empty
                // inbox is the goal state, not a problem to headline.
                EmbossedEmptyState(
                    title: Text("Caught Up"),
                    systemImage: "checkmark.circle"
                )
                .accessibilityIdentifier("inboxCaughtUpState")
            } else {
                EmbossedEmptyState(
                    title: Text("No trips"),
                    systemImage: "car.fill",
                    description: Text("Drives you take show up here automatically.")
                )
                .accessibilityIdentifier("emptyScopeState")
            }
        }
    }
}
