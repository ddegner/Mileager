import AppCore
import AppIntents
import SwiftUI
import UIKit

private enum TripDetailField: Hashable {
    case distance
    case origin
    case destination
    case notes
}

/// The user-editable values whose SwiftUI state survives updates to the
/// `TripDetailView` value. Keeping the rebase rule in a value type makes the
/// external-refresh boundary testable: a field follows a refreshed trip only
/// while the user has not changed it from the prior baseline.
struct TripDetailDraftRefreshState: Equatable {
    var purpose: String
    var notes: String
    var classification: TripClassification?
    var vehicleID: UUID?
    var correctedDistanceText: String
    var startDate: Date
    var endDate: Date
    var origin: String
    var destination: String

    mutating func rebaseUntouchedFields(
        from baseline: TripSummary,
        to refreshed: TripSummary,
        refreshedDistanceText: String,
        distanceWasEdited: Bool,
        clearManualDistanceOverride: Bool,
        vehicleManuallyChanged: Bool
    ) {
        if classification == baseline.classification {
            classification = refreshed.classification
        }
        if purpose == (baseline.businessPurpose ?? "") {
            purpose = refreshed.businessPurpose ?? ""
        }
        if notes == (baseline.notes ?? "") {
            notes = refreshed.notes ?? ""
        }
        if startDate == baseline.startDate {
            startDate = refreshed.startDate
        }
        if endDate == baseline.endDate {
            endDate = refreshed.endDate
        }
        if origin == (baseline.startAddress ?? "") {
            origin = refreshed.startAddress ?? ""
        }
        if destination == (baseline.endAddress ?? "") {
            destination = refreshed.endAddress ?? ""
        }
        if !distanceWasEdited, !clearManualDistanceOverride {
            correctedDistanceText = refreshedDistanceText
        }
        if !vehicleManuallyChanged, vehicleID == baseline.vehicleID {
            vehicleID = refreshed.vehicleID
        }
    }

    func hasPersistedFieldEdits(comparedTo baseline: TripSummary) -> Bool {
        classification != baseline.classification
            || purpose != (baseline.businessPurpose ?? "")
            || notes != (baseline.notes ?? "")
            || origin != (baseline.startAddress ?? "")
            || destination != (baseline.endAddress ?? "")
            || startDate != baseline.startDate
            || endDate != baseline.endDate
    }
}

enum TripDetailDistancePresentation {
    static func text(for trip: TripSummary, unit: DistanceUnit) -> String {
        DistanceFormatting.valueText(meters: trip.reportableDistanceMeters, unit: unit)
    }
}

enum TripDetailStructuralAction {
    /// The save-then-close-then-mutate contract for structural trip changes
    /// (unmerge, duplicate, add return trip), and the single implementation
    /// production runs. The draft saves first because the mutation reads the
    /// persisted trip; the screen closes BEFORE the mutation because a
    /// mutation that removes the trip makes the live-resolving detail
    /// destination replace the screen mid-dismissal and strand it on Trip Not
    /// Found; the mutation itself runs through `scheduling` (a yielded
    /// MainActor task in production, synchronous in tests). A failed save
    /// stops everything with the screen still open; a failed mutation
    /// surfaces through the model's root-level error alert, which outlives
    /// the already-closed screen.
    @discardableResult
    static func perform(
        saveDraft: () -> Bool,
        close: () -> Void,
        mutation: @escaping () -> Bool,
        scheduling: (@escaping () -> Void) -> Void
    ) -> Bool {
        guard saveDraft() else { return false }
        close()
        scheduling { _ = mutation() }
        return true
    }
}

struct TripDetailView: View {
    static let viewingTripActivityType = "com.daviddegner.MileageTracker.viewingTrip"
    @Environment(MileageAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.distanceUnit) private var distanceUnit

    /// Nil while composing a new manual trip. Creation stays entirely local
    /// until the bottom Add Trip button commits the draft.
    var trip: TripSummary?
    /// The run of drives the ↑/↓ chevrons walk, snapshotted by the root when
    /// this screen was pushed. Snapshotted rather than live so resolving the
    /// drive you are reading does not dissolve the "next" target under you.
    var reviewQueue: [UUID] = []
    var onNavigate: ((UUID) -> Void)?
    /// Root-owned close for the pushed-detail flows. `@Environment(\.dismiss)`
    /// is a silent no-op inside the split view's detail-column stack, so
    /// programmatic dismissal (unmerge, duplicate, delete) must pop the path
    /// at the root. The environment dismiss remains the fallback for the
    /// new-trip sheet, where it works.
    ///
    /// REQUIRED by `init(trip:)` — no default. It reads as an optional because
    /// `init(creatingAt:)` presents this screen as a sheet and legitimately
    /// has no root path to pop, but a pushed call site that omitted it would
    /// silently fall through to `dismiss()`: correct on iPhone, correct on
    /// iPad, and a dead button on the Mac. Making the pushed initializer
    /// demand it turns that into a compile error instead of a bug report.
    var onClose: (() -> Void)?
    @Binding private var isPresentingModal: Bool

    @State private var editBaseline: TripSummary?
    @State private var purpose: String
    @State private var notes: String
    @State private var classification: TripClassification?
    @State private var vehicleID: UUID?
    @State private var vehicleManuallyChanged = false
    @State private var correctedMilesText: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var origin: String
    @State private var destination: String
    @State private var routeLookup = ManualRouteLookupController()
    @State private var distanceWasEdited = false
    @State private var clearManualDistanceOverride = false
    @State private var activeShare: ActivityShareItem?
    @State private var showingDeleteConfirmation = false
    @State private var showingExpandedMap = false
    @State private var shouldAutosaveOnDisappear = true
    @State private var fees: [TripFee] = []
    @State private var feeEntryRequest: FeeEntryRequest?
    @State private var showingCustomPurpose = false
    @State private var pendingBusinessPurposePresets: [String] = []
    @State private var originSearchResult: TripEndpointSearchResult?
    @State private var destinationSearchResult: TripEndpointSearchResult?
    @State private var autocompleteTarget: TripEndpointSearchTarget?
    @State private var endpointAutocomplete = TripEndpointAutocompleteModel()
    @FocusState private var focusedField: TripDetailField?

    init(
        trip: TripSummary,
        reviewQueue: [UUID] = [],
        isPresentingModal: Binding<Bool> = .constant(false),
        onNavigate: ((UUID) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.trip = trip
        self.reviewQueue = reviewQueue
        self.onNavigate = onNavigate
        self.onClose = onClose
        _isPresentingModal = isPresentingModal
        _editBaseline = State(initialValue: trip)
        _purpose = State(initialValue: trip.businessPurpose ?? "")
        _notes = State(initialValue: trip.notes ?? "")
        _classification = State(initialValue: trip.classification)
        _vehicleID = State(initialValue: trip.vehicleID)
        _correctedMilesText = State(initialValue: NumericTextInput.fixedTwoDecimals(trip.miles))
        _startDate = State(initialValue: trip.startDate)
        _endDate = State(initialValue: trip.endDate)
        _origin = State(initialValue: trip.startAddress ?? "")
        _destination = State(initialValue: trip.endAddress ?? "")
    }

    init(
        creatingAt now: Date = Date(),
        isPresentingModal: Binding<Bool> = .constant(false)
    ) {
        let end = now
        trip = nil
        reviewQueue = []
        onNavigate = nil
        _isPresentingModal = isPresentingModal
        _editBaseline = State(initialValue: nil)
        _purpose = State(initialValue: "")
        _notes = State(initialValue: "")
        _classification = State(initialValue: .business)
        _vehicleID = State(initialValue: nil)
        _correctedMilesText = State(initialValue: "")
        _startDate = State(initialValue: end.addingTimeInterval(-25 * 60))
        _endDate = State(initialValue: end)
        _origin = State(initialValue: "")
        _destination = State(initialValue: "")
        _shouldAutosaveOnDisappear = State(initialValue: false)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            editorForm
                .task(id: endpointAutocompleteScrollID) {
                    guard endpointAutocompleteScrollID != nil else { return }
                    // Debounce result changes and let the Form/keyboard finish
                    // laying out before moving the active field into position.
                    do {
                        try await Task.sleep(for: .milliseconds(200))
                    } catch {
                        return
                    }
                    scrollToEndpointSearch(using: scrollProxy)
                }
                .onChange(of: hasTripStatus) { _, _ in
                    scrollToEndpointSearch(using: scrollProxy)
                }
        }
    }

    private var classificationSection: some View {
        Section {
            TripClassificationButtonGroup(
                selection: classification,
                presentation: .compact,
                accessibilityPrefix: accessibilityIdentifier("Classification"),
                onSelect: setClassification
            )

            if classification == .business {
                TripDetailPurposeChips(
                    purposes: purposeChipOptions,
                    selection: purpose,
                    accessibilityPrefix: accessibilityPrefix,
                    onSelect: { purpose = $0 },
                    onNew: {
                        focusedField = nil
                        showingCustomPurpose = true
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var tripStatusSection: some View {
        if hasTripStatus {
            Section {
                tripStatusRows
            } header: {
                TripDetailSectionHeader("Status")
            }
        }
    }

    private var tripFieldsSection: some View {
        Section {
            TripEndpointField(
                title: String(localized: "Origin"),
                text: $origin,
                focus: $focusedField,
                field: .origin,
                submitLabel: .next,
                identifier: accessibilityIdentifier("Origin"),
                searchIdentifier: accessibilityIdentifier("OriginSearch"),
                onSubmit: { focusedField = .destination },
                onSearch: { beginEndpointSearch(for: .origin) },
                onChange: {
                    endpointTextChanged(target: .origin)
                },
                usesSystemLabelLayout: true,
                displayText: displayAddress(origin)
            )
            .id("endpointField-origin")

            endpointAutocompleteRows(for: .origin)

            TripEndpointField(
                title: String(localized: "Destination"),
                text: $destination,
                focus: $focusedField,
                field: .destination,
                submitLabel: .next,
                identifier: accessibilityIdentifier("Destination"),
                searchIdentifier: accessibilityIdentifier("DestinationSearch"),
                onSubmit: { focusedField = .distance },
                onSearch: { beginEndpointSearch(for: .destination) },
                onChange: {
                    endpointTextChanged(target: .destination)
                },
                usesSystemLabelLayout: true,
                displayText: displayAddress(destination)
            )
            .id("endpointField-destination")

            endpointAutocompleteRows(for: .destination)

            DatePicker("Start", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                .accessibilityIdentifier(accessibilityIdentifier("Start"))
            DatePicker("End", selection: $endDate, displayedComponents: [.date, .hourAndMinute])
                .accessibilityIdentifier(accessibilityIdentifier("End"))

            TripDistanceField(
                text: distanceTextBinding,
                focus: $focusedField,
                field: .distance,
                identifier: accessibilityIdentifier("Distance"),
                usesSystemLabelLayout: true
            )

            if trip?.manualDistanceOverrideMeters != nil {
                LabeledContent {
                    Button {
                        useRecordedDistance()
                    } label: {
                        Label("Use Recorded Distance", systemImage: "arrow.uturn.backward")
                    }
                    .font(.subheadline)
                    .accessibilityIdentifier("tripDetailUseRecordedDistance")
                } label: {
                    Color.clear.frame(width: 1, height: 1)
                }
            }

            if let saveValidationMessage {
                Text(saveValidationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(accessibilityIdentifier("Validation"))
            }
        } header: {
            TripDetailSectionHeader("Trip")
        }
    }

    private var editorForm: some View {
        return Form {
            if !isCreatingNewTrip || heroMapContent != nil {
                Section {
                    TripDetailHero(
                        mapContent: heroMapContent,
                        origin: heroOrigin,
                        destination: heroDestination,
                        dateLine: heroDateLine,
                        preview: heroPreview,
                        distance: heroDistanceText,
                        distanceUnit: heroDistanceUnit,
                        onExpandMap: { showingExpandedMap = true }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .listSectionMargins(.horizontal, 0)
            }

            if !isCreatingNewTrip {
                classificationSection
                tripStatusSection
            }

            tripFieldsSection

            if isCreatingNewTrip {
                classificationSection
                tripStatusSection
            }

            Section {
                TripFeeSection(
                    fees: fees,
                    total: feeTotal,
                    addAccessibilityIdentifier: accessibilityIdentifier("AddFee"),
                    totalAccessibilityIdentifier: accessibilityIdentifier("FeeTotal"),
                    rowAccessibilityIdentifier: isCreatingNewTrip
                        ? { "manualTripDraftFee-\($0.id.uuidString)" }
                        : nil,
                    onAddFee: {
                        focusedField = nil
                        if let trip {
                            feeEntryRequest = .trip(trip, category: .toll)
                        } else {
                            feeEntryRequest = .draft(category: .toll)
                        }
                    },
                    onSelectFee: { fee in
                        if let trip {
                            feeEntryRequest = .trip(trip, category: fee.category, fee: fee)
                        } else {
                            feeEntryRequest = .draft(fee: fee)
                        }
                    },
                    onDeleteFee: { fee in
                        if isCreatingNewTrip {
                            deleteDraftFee(fee)
                        } else {
                            model.deleteFee(fee)
                            loadFees()
                        }
                    }
                )
            } header: {
                TripDetailSectionHeader("Fees")
            }

            if let trip, trip.effectiveLegs.count > 1 || !trip.stops.isEmpty || trip.canUnmerge {
                Section {
                    TripDetailLegsView(trip: trip)
                        .listRowInsets(EdgeInsets())
                        .accessibilityIdentifier("tripDetailStops")

                    if trip.canUnmerge {
                        Button {
                            performStructuralAction {
                                model.unmerge(trip)
                            }
                        } label: {
                            Label("Un-Merge Trip", systemImage: "link.badge.minus")
                                .labelStyle(.titleAndIcon)
                        }
                        .disabled(!canSave)
                        .accessibilityIdentifier("tripDetailUnmerge")
                    }
                } header: {
                    TripDetailSectionHeader("Legs", detail: legSectionSummary(for: trip))
                }
            }

            Section {
                if model.vehiclesConfigured {
                    VehiclePicker(
                        selection: $vehicleID,
                        accessibilityIdentifier: accessibilityIdentifier("Vehicle")
                    ) { newValue in
                        vehicleManuallyChanged = true
                        if let trip {
                            model.assignVehicle(trip, vehicleID: newValue)
                        }
                    }
                    if let provenance = vehicleProvenance {
                        Label(provenance.message, systemImage: provenance.icon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(provenance.message)
                            .accessibilityIdentifier("tripDetailVehicleSource")
                    }
                }
                TripNotesField(
                    text: $notes,
                    focus: $focusedField,
                    field: .notes,
                    identifier: accessibilityIdentifier("Notes"),
                    usesSystemLabelLayout: true
                )
            } header: {
                TripDetailSectionHeader("Details")
            }

            if let trip {
                Section {
                    Button("Add Return Trip") {
                        performStructuralAction {
                            model.addReturnTrip(trip)
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("tripDetailAddReturnTrip")
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        HStack {
                            Text("Delete Trip")
                            Spacer(minLength: 12)
                            Text("Can't be undone")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("tripDetailDelete")
                }
            }

        }
        .accessibilityIdentifier(accessibilityIdentifier("Form"))
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectHidden(heroMapContent != nil, for: .top)
        .contentMargins(.top, heroMapContent == nil ? nil : 0, for: .scrollContent)
        .listSectionSpacing(20)
        .ignoresSafeArea(.container, edges: heroMapContent == nil ? [] : .top)
        .coordinateSpace(name: TripHeroMapLayout.scrollCoordinateSpace)
        .navigationTitle(isCreatingNewTrip ? "Add Trip" : "Trip Detail")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: isCreatingNewTrip ? nil : .title)
        .mileageGroupedBackground()
        // Onscreen awareness: while this screen is visible (and the user has
        // opted into Siri & Search), Siri can resolve "this trip" to the
        // entity being viewed.
        .appEntityIdentifier(
            model.siriIndexingEnabled
                ? trip.map { EntityIdentifier(for: TripAppEntity.self, identifier: $0.id) }
                : nil
        )
        .userActivity(
            Self.viewingTripActivityType,
            isActive: model.siriIndexingEnabled && trip != nil
        ) { activity in
            guard let trip else { return }
            activity.title = DriveRouteLabelFormatter.label(for: trip)
            activity.targetContentIdentifier = trip.id.uuidString
            activity.appEntityIdentifier = EntityIdentifier(
                for: TripAppEntity.self,
                identifier: trip.id
            )
        }
        .alert("Delete this trip?", isPresented: $showingDeleteConfirmation) {
            Button("Delete Trip", role: .destructive) {
                guard let trip else { return }
                shouldAutosaveOnDisappear = false
                let tripToDelete = trip
                close()
                Task { @MainActor in
                    await Task.yield()
                    model.delete(tripToDelete)
                }
            }
            .accessibilityIdentifier("confirmTripDelete")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes this trip and its mileage. This can't be undone.")
        }
        .exportShare(item: $activeShare)
        .sheet(item: $feeEntryRequest, onDismiss: {
            if !isCreatingNewTrip {
                loadFees()
            }
        }) { request in
            if isCreatingNewTrip {
                FeeEntryView(request: request) { fee in
                    upsertDraftFee(fee)
                }
                .environment(model)
            } else {
                FeeEntryView(request: request)
                    .environment(model)
            }
        }
        .sheet(isPresented: $showingCustomPurpose) {
            BusinessPurposeCustomEntryView(
                initialPurpose: purpose,
                onAddToPresets: handleBusinessPurposePreset
            ) { selected in
                purpose = selected
            }
            .environment(model)
        }
        .fullScreenCover(isPresented: $showingExpandedMap) {
            if let mapContent = heroMapContent {
                ExpandedRouteMapView(content: mapContent)
            }
        }
        .onChange(of: hasBlockingPresentation) { _, isPresented in
            isPresentingModal = isPresented
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button(action: moveToPreviousField) {
                    Image(systemName: "chevron.up")
                }
                .disabled(previousField == nil)
                .accessibilityLabel("Previous Field")
                .accessibilityIdentifier("keyboardPreviousField")

                Button(action: moveToNextField) {
                    Image(systemName: "chevron.down")
                }
                .disabled(nextField == nil)
                .accessibilityLabel("Next Field")
                .accessibilityIdentifier("keyboardNextField")

                Spacer()

                Button("Done") {
                    focusedField = nil
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier("keyboardDismissDone")
            }

            if isCreatingNewTrip {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }

            if isCreatingNewTrip {
                ToolbarItem(placement: .confirmationAction) {
                    CheckmarkConfirmationButton(
                        action: saveNewTrip,
                        isDisabled: !canSave,
                        accessibilityLabel: String(localized: "Add Trip"),
                        accessibilityIdentifier: "manualTripSave"
                    )
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await exportPDF() }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(!canSave)
                    .accessibilityLabel("Export PDF")
                    .accessibilityIdentifier("tripDetailExportPDF")
                }

                if adjacentTripID(by: -1) != nil || adjacentTripID(by: 1) != nil {
                    ToolbarSpacer(.flexible, placement: .bottomBar)

                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            navigate(by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(adjacentTripID(by: -1) == nil || !canSave)
                        .accessibilityLabel("Previous Trip")
                        .accessibilityIdentifier("tripDetailPreviousTrip")

                        Button {
                            navigate(by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(adjacentTripID(by: 1) == nil || !canSave)
                        .accessibilityLabel("Next Trip")
                        .accessibilityIdentifier("tripDetailNextTrip")
                    }
                }
            }
        }
        // The ⌘-menu's focused-trip verbs; nil while creating so the commands
        // disable. Every closure goes through the same dirty-tracking paths
        // as the toolbar (navigate commits edits, exportPDF saves first,
        // delete fronts the confirmation alert).
        .focusedSceneValue(\.tripDetailCommandActions, detailCommandActions)
        .onAppear {
            isPresentingModal = hasBlockingPresentation
            // The field was seeded in miles at init (the environment isn't
            // available there); re-seed for other display units before edits.
            if let trip, distanceUnit != .miles, !distanceWasEdited {
                correctedMilesText = TripDetailDistancePresentation.text(
                    for: trip,
                    unit: distanceUnit
                )
            }
            if isCreatingNewTrip {
                applyDefaultPurposeIfNeeded()
            }
            // Existing trips get a default only after an explicit Business
            // tap; merely viewing one must not stamp a purpose. A new trip is
            // intentionally seeded with the configured default above.
        }
        .task {
            if !isCreatingNewTrip {
                loadFees()
            }
        }
        .onChange(of: trip) { _, refreshedTrip in
            if let refreshedTrip {
                rebaseUntouchedDraftFields(to: refreshedTrip)
            }
        }
        .onChange(of: focusedField) { _, newValue in
            updateAutocompleteTarget(for: newValue)
        }
        .onDisappear {
            isPresentingModal = false
            // Autosave only a real edit. A pure view-and-leave must not persist,
            // or model.update would stamp the default purpose onto an untouched
            // business trip. Vehicle/fees commit on their own, not via saveEdits.
            if shouldAutosaveOnDisappear, hasUserEdits {
                _ = saveEdits()
            }
            routeLookup.cancel()
            endpointAutocomplete.clear()
        }
    }

    private var hasBlockingPresentation: Bool {
        activeShare != nil
            || showingDeleteConfirmation
            || showingExpandedMap
            || feeEntryRequest != nil
            || showingCustomPurpose
    }

    private var isCreatingNewTrip: Bool {
        trip == nil
    }

    private var accessibilityPrefix: String {
        isCreatingNewTrip ? "manualTrip" : "tripDetail"
    }

    private func accessibilityIdentifier(_ suffix: String) -> String {
        "\(accessibilityPrefix)\(suffix)"
    }

    private var hasTripStatus: Bool {
        routePresentation.statusMessage != nil
            || !(trip?.attentionReasons ?? []).isEmpty
            || (classification == .notADrive && trip?.classificationSource != nil)
    }

    @ViewBuilder
    private var tripStatusRows: some View {
        if let routeStatusMessage = routePresentation.statusMessage {
            Label {
                Text(routeStatusMessage.text)
                    .foregroundStyle(routeStatusMessage.color)
            } icon: {
                Image(systemName: "map.fill")
                    .foregroundStyle(routeStatusMessage.color)
            }
            .font(.subheadline)
            .accessibilityIdentifier(accessibilityIdentifier("RouteStatus"))
        }

        // The engine's notes describe how the drive was recorded. They remain
        // read-only and do not gate review or export.
        ForEach(trip?.attentionReasons ?? [], id: \.self) { reason in
            Label {
                Text(AttentionReasonText.display(reason))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MileageTheme.attentionAccent)
            }
            .font(.subheadline)
        }

        if classification == .notADrive, let classificationSource = trip?.classificationSource {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(
                    automaticNotADriveMessage(for: classificationSource),
                    systemImage: automaticNotADriveIcon(for: classificationSource)
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button("Undo") {
                    setClassification(nil)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    private var purposeChipOptions: [String] {
        BusinessPurposePresetStore.normalized([purpose] + model.businessPurposePresets)
    }

    // Display-only, so the hero gets the deduplicated readable form — raw
    // geocodes in the store can carry doubled/tripled components, which the
    // editable Origin/Destination fields must preserve but a title must not.
    private var heroOrigin: String {
        displayAddress(origin) ?? String(localized: "Origin")
    }

    private var heroDestination: String {
        displayAddress(destination) ?? String(localized: "Destination")
    }

    /// The single display boundary for stored address strings on this screen:
    /// geocoded values repeat their components ("22 Example St, 22 Example St,
    /// Cambridge, MA"), so nothing renders one straight from the draft — the
    /// hero title and the unfocused Origin/Destination fields both route
    /// through it. Nil when there is nothing to show, so callers supply their
    /// own placeholder.
    private func displayAddress(_ address: String) -> String? {
        TripEndpointField<TripDetailField>.displayText(for: address)
    }

    private var heroDateLine: String {
        TripHierarchyPresentation.timelineLabel(
            startDate: startDate,
            endDate: endDate
        )
    }

    private var heroPreview: DriveRowPreviewLine? {
        if var presentationTrip = trip {
            presentationTrip.classification = classification
            presentationTrip.businessPurpose = classification == .business
                ? TripReviewPolicy.normalizedBusinessPurpose(purpose)
                : nil
            presentationTrip.notes = notes
            presentationTrip.vehicleID = vehicleID
            let suggestion = classification == nil
                ? model.tripSuggestions[presentationTrip.id]
                : nil
            return DriveRowPreviewLine.make(
                trip: presentationTrip,
                suggestion: suggestion,
                includesGenericReviewStatus: false
            )
        }

        return DriveRowPreviewLine.make(
            classification: classification,
            businessPurpose: purpose,
            notes: notes,
            suggestion: nil
        )
    }

    private var heroDistanceMeters: Double {
        guard let correctedDistanceMiles else { return trip?.reportableDistanceMeters ?? 0 }
        return DistanceConversion.meters(value: correctedDistanceMiles, in: .miles)
    }

    private var heroDistanceText: String {
        guard correctedDistanceMiles != nil else { return "—" }
        return DistanceFormatting.valueText(meters: heroDistanceMeters, unit: distanceUnit)
    }

    private var heroDistanceUnit: String {
        DistanceFormatting.unitSymbol(distanceUnit)
    }

    private func legSectionSummary(for trip: TripSummary) -> String {
        let legCount = trip.effectiveLegs.count
        let stopCount = trip.stops.count
        let legWord = legCount == 1 ? String(localized: "leg") : String(localized: "legs")
        let stopWord = stopCount == 1 ? String(localized: "stop") : String(localized: "stops")
        let distance = DistanceFormatting.label(
            meters: trip.reportableDistanceMeters,
            unit: distanceUnit,
            fractionDigits: 2
        )
        return "\(legCount) \(legWord) · \(stopCount) \(stopWord) · \(distance)"
    }

    private func saveNewTrip() {
        if focusedField != nil {
            focusedField = nil
        }
        guard let distanceMiles = correctedDistanceMiles else { return }
        let storedPurpose = classification == .business ? purpose : ""
        guard model.createManualTrip(
            startDate: startDate,
            endDate: endDate,
            distanceMiles: distanceMiles,
            distanceWasEdited: distanceWasEdited,
            origin: origin,
            destination: destination,
            resolvedRoute: routeLookup.resolvedRoute,
            classification: classification,
            purpose: storedPurpose,
            notes: notes,
            tolls: 0,
            parking: 0,
            vehicleID: vehicleID,
            fees: fees
        ) != nil else {
            return
        }
        if !pendingBusinessPurposePresets.isEmpty {
            model.saveBusinessPurposePresets(
                model.businessPurposePresets + pendingBusinessPurposePresets
            )
        }
        shouldAutosaveOnDisappear = false
        dismiss()
    }

    private func automaticNotADriveMessage(for source: TripClassificationSource) -> String {
        switch source {
        case .autoTransit:
            String(localized: "Marked automatically - this looked like a subway or train ride.")
        case .autoShortTrip:
            String(localized: "Marked automatically - this trip was shorter than 0.2 mi.")
        case .autoWater:
            String(localized: "Marked automatically - this route was mostly over water.")
        case .autoAircraft:
            String(localized: "Marked automatically - this looked like a flight.")
        case .autoCycling:
            String(localized: "Marked automatically - this looked like a bike ride.")
        }
    }

    private func automaticNotADriveIcon(for source: TripClassificationSource) -> String {
        switch source {
        case .autoTransit:
            "tram.fill"
        case .autoShortTrip:
            "ruler.fill"
        case .autoWater:
            "ferry.fill"
        case .autoAircraft:
            "airplane"
        case .autoCycling:
            "bicycle"
        }
    }

    /// Shown when the vehicle was assigned automatically and the user hasn't
    /// overridden it in this session — a manual pick clears the note.
    private var vehicleProvenance: (message: String, icon: String)? {
        guard !vehicleManuallyChanged, let trip else { return nil }
        switch trip.vehicleAssignmentSource {
        case .vehicleConnection:
            return (String(localized: "Assigned automatically from your car connection"), "car.side.fill")
        case .bluetooth:
            return (String(localized: "Assigned automatically from your car's Bluetooth"), "wave.3.right.circle.fill")
        case .shortcut:
            return (String(localized: "Assigned automatically from your Shortcuts automation"), "bolt.circle.fill")
        case .manual, .none:
            return nil
        }
    }

    /// The distance field is edited in the display unit; the save path stays
    /// miles-based, so convert at this boundary.
    private var correctedDistanceMiles: Double? {
        guard let entered = NumericTextInput.nonnegativeDouble(correctedMilesText) else { return nil }
        return DistanceConversion.miles(fromMeters: DistanceConversion.meters(value: entered, in: distanceUnit))
    }

    private var feeTotal: Double {
        fees.reduce(0) { $0 + $1.amount }
    }

    private var distanceTextBinding: Binding<String> {
        Binding(
            get: { correctedMilesText },
            set: { newValue in
                correctedMilesText = newValue
                distanceWasEdited = true
                clearManualDistanceOverride = false
            }
        )
    }

    private var currentRouteKey: ManualRouteLookupKey? {
        TripRouteEditing.routeKey(origin: origin, destination: destination)
    }

    private var tripRouteKey: ManualRouteLookupKey? {
        guard let trip else { return nil }
        return TripRouteEditing.routeKey(
            origin: trip.startAddress ?? "",
            destination: trip.endAddress ?? ""
        )
    }

    private var shouldClearRouteOnSave: Bool {
        routePresentation.shouldClearRouteOnSave
    }

    private var heroMapContent: RouteMapContent? {
        return routePresentation.mapContent ?? TripRouteEditing.endpointMapContent(
            origin: origin,
            destination: destination,
            originResult: originSearchResult,
            destinationResult: destinationSearchResult,
            storedTrip: trip
        )
    }

    private var routePresentation: ManualRouteLookupPresentation {
        ManualRouteLookupPresentation(
            lookup: routeLookup,
            currentKey: currentRouteKey,
            storedKey: tripRouteKey,
            storedTrip: trip
        )
    }

    private var saveValidationMessage: String? {
        guard endDate > startDate else {
            return String(localized: "End time must be after start time.")
        }
        if isCreatingNewTrip,
           correctedMilesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        guard correctedDistanceMiles != nil else {
            return String(localized: "Enter a valid distance.")
        }
        return nil
    }

    private var canSave: Bool {
        endDate > startDate && correctedDistanceMiles != nil
    }

    private func endpointTextChanged(target: TripEndpointSearchTarget? = nil) {
        if let target {
            clearStaleEndpointSearchResult(for: target)
            refreshAutocomplete(for: target)
        }

        routeLookup.scheduleAndApply(
            currentKey: currentRouteKey,
            currentKeyProvider: { currentRouteKey },
            resolve: { key in
                try await model.resolveManualRoute(
                    origin: manualRouteEndpoint(for: .origin, text: key.origin),
                    destination: manualRouteEndpoint(for: .destination, text: key.destination)
                )
            },
            onApplied: { route in
                applyResolvedRoute(route)
            }
        )
    }

    private func applyResolvedRoute(_ route: ResolvedManualRoute) {
        if let distanceMeters = route.distanceMeters, !distanceWasEdited {
            correctedMilesText = formatDistance(distanceMeters)
        }
    }

    private func useRecordedDistance() {
        guard let trip else { return }
        correctedMilesText = formatDistance(trip.distanceMeters)
        distanceWasEdited = false
        clearManualDistanceOverride = true
    }

    private func formatDistance(_ distanceMeters: Double) -> String {
        DistanceFormatting.valueText(meters: distanceMeters, unit: distanceUnit)
    }


    private func adjacentTripID(by offset: Int) -> UUID? {
        guard let trip else { return nil }
        guard let index = reviewQueue.firstIndex(of: trip.id) else { return nil }
        let target = index + offset
        guard reviewQueue.indices.contains(target) else { return nil }
        return reviewQueue[target]
    }

    private var detailCommandActions: TripDetailCommandActions? {
        // isCommandSurfaceAvailable: menu dispatch bypasses the lock
        // overlay's hitTest gate, so the value vanishes while locked or on
        // the in-memory placeholder store.
        guard model.isCommandSurfaceAvailable, !isCreatingNewTrip, let trip else { return nil }
        return TripDetailCommandActions(
            tripID: trip.id,
            canNavigatePrevious: adjacentTripID(by: -1) != nil && canSave,
            canNavigateNext: adjacentTripID(by: 1) != nil && canSave,
            canExport: canSave,
            navigatePrevious: { navigate(by: -1) },
            navigateNext: { navigate(by: 1) },
            exportPDF: { Task { await exportPDF() } },
            classify: { setClassification($0) },
            confirmDelete: { showingDeleteConfirmation = true }
        )
    }

    /// Commits the open edits before moving, because the chevrons replace the
    /// top path element rather than popping — `onDisappear` autosave would
    /// otherwise race the rebuild.
    private func navigate(by offset: Int) {
        guard let next = adjacentTripID(by: offset) else { return }
        guard canSave else { return }
        if hasUserEdits, !saveEdits() { return }
        shouldAutosaveOnDisappear = false
        onNavigate?(next)
    }

    /// Saves the open draft before changing the trip's structure. Both steps
    /// must succeed before dismissal: duplication reads the persisted trip, and
    /// unmerge copies the persisted merged fields into its restored legs.
    private func performStructuralAction(_ action: @escaping () -> Bool) {
        guard canSave else { return }
        // The ordering contract lives in TripDetailStructuralAction.perform —
        // one implementation, exercised by both production and its tests.
        TripDetailStructuralAction.perform(
            saveDraft: saveEdits,
            close: {
                shouldAutosaveOnDisappear = false
                close()
            },
            mutation: action,
            scheduling: { work in
                Task { @MainActor in
                    await Task.yield()
                    work()
                }
            }
        )
    }

    /// See `onClose` — the root pops pushed details; the environment dismiss
    /// covers the new-trip sheet. The `else` is reachable only from
    /// `init(creatingAt:)`, which is a sheet: `init(trip:)` requires `onClose`.
    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func setClassification(_ nextClassification: TripClassification?) {
        classification = nextClassification
        if nextClassification == .notADrive {
            purpose = ""
        } else {
            applyDefaultPurposeIfNeeded(for: nextClassification)
        }
        if let trip {
            model.classify(trip, as: nextClassification)
        }
    }

    private func applyDefaultPurposeIfNeeded(for nextClassification: TripClassification? = nil) {
        let targetClassification = nextClassification ?? classification
        purpose = model.defaultBusinessPurposeIfNeeded(
            currentPurpose: purpose,
            classification: targetClassification
        )
    }

    private func handleBusinessPurposePreset(_ preset: String) {
        if isCreatingNewTrip {
            pendingBusinessPurposePresets = BusinessPurposePresetStore.normalized(
                pendingBusinessPurposePresets + [preset]
            )
        } else {
            model.addBusinessPurposePreset(preset)
        }
    }

    private func loadFees() {
        guard let trip else { return }
        fees = model.fees(for: trip)
    }

    private func upsertDraftFee(_ fee: TripFee) {
        if let index = fees.firstIndex(where: { $0.id == fee.id }) {
            fees[index] = fee
        } else {
            fees.append(fee)
        }
    }

    private func deleteDraftFee(_ fee: TripFee) {
        fees.removeAll { $0.id == fee.id }
    }

    /// True when the user changed a field that `saveEdits` actually persists.
    /// Gates the autosave-on-disappear so opening a trip and leaving without
    /// editing never rewrites it. Vehicle assignment and fees commit on their
    /// own paths, so they are intentionally excluded here.
    private var hasUserEdits: Bool {
        guard let editBaseline else { return false }
        return draftRefreshState.hasPersistedFieldEdits(comparedTo: editBaseline)
            || distanceWasEdited
            || clearManualDistanceOverride
            || routeLookup.resolvedRoute != nil
    }

    private func saveEdits() -> Bool {
        guard let trip, editBaseline != nil else { return false }
        // `trip` can refresh while this screen remains alive (for example when
        // foreground enrichment repairs an offline trip). Rebase synchronously
        // at the write boundary as well as in onChange so an onDisappear save
        // can never mistake untouched stale state for a manual edit.
        rebaseUntouchedDraftFields(to: trip)
        guard hasUserEdits else { return true }

        // Coerce invalid numeric/date fields to safe fallbacks (the trip's existing values)
        // so one unparseable field can never silently discard the rest of the user's edits
        // when autosaving on disappear.
        let hasValidDistance = correctedDistanceMiles != nil
        let resolvedDistance = correctedDistanceMiles ?? trip.miles
        let datesValid = endDate > startDate
        return model.update(
            trip,
            classification: classification,
            purpose: purpose,
            notes: notes,
            correctedDistanceMiles: resolvedDistance,
            distanceWasEdited: distanceWasEdited && hasValidDistance,
            clearManualDistanceOverride: clearManualDistanceOverride,
            startDate: datesValid ? startDate : trip.startDate,
            endDate: datesValid ? endDate : trip.endDate,
            origin: origin,
            destination: destination,
            resolvedRoute: routeLookup.resolvedRoute,
            clearRouteMap: shouldClearRouteOnSave
        )
    }

    private var draftRefreshState: TripDetailDraftRefreshState {
        TripDetailDraftRefreshState(
            purpose: purpose,
            notes: notes,
            classification: classification,
            vehicleID: vehicleID,
            correctedDistanceText: correctedMilesText,
            startDate: startDate,
            endDate: endDate,
            origin: origin,
            destination: destination
        )
    }

    private func rebaseUntouchedDraftFields(to refreshedTrip: TripSummary) {
        guard let baseline = editBaseline else { return }
        guard refreshedTrip.id == baseline.id else { return }
        let previousOrigin = origin
        let previousDestination = destination
        var refreshedDraft = draftRefreshState
        refreshedDraft.rebaseUntouchedFields(
            from: baseline,
            to: refreshedTrip,
            refreshedDistanceText: TripDetailDistancePresentation.text(
                for: refreshedTrip,
                unit: distanceUnit
            ),
            distanceWasEdited: distanceWasEdited,
            clearManualDistanceOverride: clearManualDistanceOverride,
            vehicleManuallyChanged: vehicleManuallyChanged
        )

        purpose = refreshedDraft.purpose
        notes = refreshedDraft.notes
        classification = refreshedDraft.classification
        vehicleID = refreshedDraft.vehicleID
        correctedMilesText = refreshedDraft.correctedDistanceText
        startDate = refreshedDraft.startDate
        endDate = refreshedDraft.endDate
        origin = refreshedDraft.origin
        destination = refreshedDraft.destination
        if origin != previousOrigin {
            originSearchResult = nil
        }
        if destination != previousDestination {
            destinationSearchResult = nil
        }
        editBaseline = refreshedTrip
    }

    private func exportPDF() async {
        guard let trip, canSave, saveEdits() else { return }
        guard let refreshedTrip = model.trip(id: trip.id),
              let url = await model.exportTripPDF(refreshedTrip) else {
            return
        }
        activeShare = ActivityShareItem(url: url, notice: model.irsRateExportStatusMessage)
    }

    private var fieldOrder: [TripDetailField] {
        [.origin, .destination, .distance, .notes]
    }

    private var previousField: TripDetailField? {
        adjacentField(offset: -1)
    }

    private var nextField: TripDetailField? {
        adjacentField(offset: 1)
    }

    private func adjacentField(offset: Int) -> TripDetailField? {
        adjacentFormField(in: fieldOrder, from: focusedField, offset: offset)
    }

    private func moveToPreviousField() {
        focusedField = previousField
    }

    private func moveToNextField() {
        guard let nextField else {
            focusedField = nil
            return
        }

        focusedField = nextField
    }

    private func endpointText(for target: TripEndpointSearchTarget) -> String {
        TripRouteEditing.endpointText(for: target, origin: origin, destination: destination)
    }

    private func scrollToEndpointSearch(using scrollProxy: ScrollViewProxy) {
        guard endpointAutocompleteScrollID != nil, let target = autocompleteTarget else { return }
        // The field already exists in the lazy Form when new result rows arrive.
        // Keep it near the top, leaving room for several suggestions above
        // the keyboard without tucking the field behind the navigation bar.
        withAnimation(.easeInOut(duration: 0.2)) {
            scrollProxy.scrollTo("endpointField-\(target.id)", anchor: UnitPoint(x: 0.5, y: 0.2))
        }
    }

    private var endpointAutocompleteScrollID: String? {
        guard let target = autocompleteTarget else { return nil }
        if let completion = endpointAutocomplete.completions.prefix(4).last {
            return "endpointAutocomplete-\(target.id)-\(completion.id)"
        }
        return endpointAutocomplete.statusMessage == nil ? nil : "endpointAutocomplete-\(target.id)-status"
    }

    @ViewBuilder
    private func endpointAutocompleteRows(for target: TripEndpointSearchTarget) -> some View {
        if autocompleteTarget == target {
            if endpointAutocomplete.isSearching || endpointAutocomplete.isResolving {
                ProgressView("Searching")
                    .accessibilityIdentifier(accessibilityIdentifier("\(target.rawValue.capitalized)AutocompleteSearching"))
            }

            ForEach(Array(endpointAutocomplete.completions.prefix(4))) { completion in
                Button {
                    Task { await applyEndpointCompletion(completion, to: target) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(completion.title)
                            .foregroundStyle(.primary)
                        if !completion.subtitle.isEmpty {
                            Text(completion.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(endpointAutocomplete.isResolving)
                .accessibilityIdentifier(completion.accessibilityIdentifier)
                .id("endpointAutocomplete-\(target.id)-\(completion.id)")
            }

            if let statusMessage = endpointAutocomplete.statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
                    .id("endpointAutocomplete-\(target.id)-status")
            }
        }
    }

    private func applyEndpointSearchResult(_ result: TripEndpointSearchResult, to target: TripEndpointSearchTarget) {
        switch target {
        case .origin:
            originSearchResult = result
            origin = result.endpointText
        case .destination:
            destinationSearchResult = result
            destination = result.endpointText
        }
        endpointAutocomplete.clear()
        autocompleteTarget = nil
        focusedField = nil
        endpointTextChanged()
    }

    private func clearStaleEndpointSearchResult(for target: TripEndpointSearchTarget) {
        switch target {
        case .origin:
            if TripRouteEditing.isStaleResult(originSearchResult, currentText: origin) {
                originSearchResult = nil
            }
        case .destination:
            if TripRouteEditing.isStaleResult(destinationSearchResult, currentText: destination) {
                destinationSearchResult = nil
            }
        }
    }

    private func manualRouteEndpoint(for target: TripEndpointSearchTarget, text: String) -> ManualRouteEndpoint {
        TripRouteEditing.manualRouteEndpoint(
            for: target,
            text: text,
            originResult: originSearchResult,
            destinationResult: destinationSearchResult,
            storedTrip: trip
        )
    }

    private func beginEndpointSearch(for target: TripEndpointSearchTarget) {
        endpointAutocomplete.clear()
        focusedField = target == .origin ? .origin : .destination
        updateAutocompleteTarget(for: focusedField)
    }

    private func updateAutocompleteTarget(for field: TripDetailField?) {
        let target: TripEndpointSearchTarget? = switch field {
        case .origin: .origin
        case .destination: .destination
        default: nil
        }
        if autocompleteTarget != target {
            endpointAutocomplete.clear()
        }
        autocompleteTarget = target
        if let target {
            refreshAutocomplete(for: target)
        } else {
            endpointAutocomplete.clear()
        }
    }

    private func refreshAutocomplete(for target: TripEndpointSearchTarget) {
        guard autocompleteTarget == target else { return }
        endpointAutocomplete.updateQuery(endpointText(for: target))
    }

    private func applyEndpointCompletion(
        _ completion: TripEndpointSearchCompletion,
        to target: TripEndpointSearchTarget
    ) async {
        let query = endpointText(for: target)
        guard let result = await endpointAutocomplete.result(for: completion),
              autocompleteTarget == target,
              endpointText(for: target) == query else { return }
        applyEndpointSearchResult(result, to: target)
    }

}

private struct TripDetailSectionHeader: View {
    var title: LocalizedStringKey
    var detail: String?

    init(_ title: LocalizedStringKey, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)

            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
        .textCase(nil)
    }
}

/// The noninteractive map layer shared by reading and composition. Its size
/// stays fixed while scrolling, so a blur/fade never starts a new snapshot.
private struct TripDetailMap: View {
    var content: RouteMapContent

    var body: some View {
        Group {
            if content.segments.isEmpty {
                // Unresolved endpoint editing retains live pins until there is
                // a route. No cached route may stand in for an edited endpoint.
                RouteMapPreviewView(
                    content: content, isFullBleed: true, allowsInteraction: false,
                    height: TripHeroMapLayout.imageHeight,
                    showsControls: false,
                    viewportPadding: TripHeroMapLayout.viewportPadding
                )
            } else {
                DriveCardMapThumbnail(
                    content: content,
                    identityToken: TripHeroMapLayout.identityToken,
                    routeColor: MileageTheme.routeUIColor,
                    minimumPointSize: CGSize(width: 1, height: TripHeroMapLayout.imageHeight),
                    presentation: .hero
                )
                .frame(height: TripHeroMapLayout.imageHeight)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tripDetailMainMap")
    }
}

private struct TripDetailHero: View {
    var mapContent: RouteMapContent?
    var origin: String
    var destination: String
    var dateLine: String
    var preview: DriveRowPreviewLine?
    var distance: String
    var distanceUnit: String
    var onExpandMap: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if mapContent != nil {
                Color.clear.frame(height: TripHeroMapLayout.clearHeight)
                    .accessibilityHidden(true)
            }
            summary.padding(.horizontal, 20).padding(.vertical, 16)
        }
        .background(alignment: .top) {
            if let mapContent {
                TripDetailMap(content: mapContent)
                    .visualEffect { [reduceTransparency] content, geometry in
                        let y = geometry.frame(in: .named(TripHeroMapLayout.scrollCoordinateSpace)).minY
                        let scroll = y.isFinite ? min(max(0, -y), TripHeroMapLayout.imageHeight) : 0
                        let blur = min(scroll / 140, 1) * 20
                        return content
                            .blur(radius: reduceTransparency ? 0 : blur)
                            .opacity(TripHeroMapLayout.opacity(at: y))
                            // Cancel the Form's movement so the map stays
                            // anchored while the summary scrolls over it.
                            .offset(y: scroll)
                    }
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.56),
                                .init(color: .black.opacity(reduceTransparency ? 0 : 0.16), location: 0.68),
                                .init(color: .clear, location: 0.9)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            if mapContent != nil {
                RouteMapExpandButton(action: onExpandMap)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .padding(.trailing, 10)
                    .padding(.top, TripHeroMapLayout.clearHeight - 52)
                    .visualEffect { content, geometry in
                        content.opacity(TripHeroMapLayout.opacity(
                            at: geometry.frame(in: .named(TripHeroMapLayout.scrollCoordinateSpace)).minY
                        ))
                    }
            }
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tripDetailHero")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(origin)
                .font(.title3.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Label {
                Text(destination)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .accessibilityIdentifier("tripDetailRouteDestination")
            } icon: {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.title3.weight(.semibold))

            if let preview {
                if preview.kind == .suggestion {
                    TripSuggestionBand(
                        preview: preview,
                        accessibilityIdentifier: "tripDetailPreview"
                    )
                } else {
                    Text(verbatim: preview.text)
                        .font(.footnote)
                        .foregroundStyle(preview.kind == .note ? .secondary : MileageTheme.attentionAccent)
                        .accessibilityLabel(preview.accessibilityText)
                        .accessibilityIdentifier("tripDetailPreview")
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    timeline.fixedSize()
                    Spacer(minLength: 0)
                    mileage
                }
                VStack(alignment: .leading, spacing: 4) {
                    timeline
                    mileage.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .font(.footnote)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tripDetailTimelineMileageRow")
        }
    }

    private var timeline: some View {
        Text(dateLine)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("tripDetailTimeline")
    }

    private var mileage: some View {
        Text(verbatim: "\(distance) \(distanceUnit)")
            .monospacedDigit()
            .fontWeight(.bold)
            .foregroundStyle(.primary)
            .fixedSize()
            .accessibilityIdentifier("tripDetailDistanceSummary")
    }
}

private struct TripDetailPurposeChips: View {
    var purposes: [String]
    var selection: String
    var accessibilityPrefix: String
    var onSelect: (String) -> Void
    var onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            TripDetailFlowLayout(spacing: 7) {
                ForEach(purposes, id: \.self) { purpose in
                    Button {
                        onSelect(purpose)
                    } label: {
                        Text(purpose)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 240)
                            .foregroundStyle(
                                isSelected(purpose) ? MileageTheme.businessAccent : .primary
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                isSelected(purpose)
                                    ? MileageTheme.businessAccent.opacity(0.14)
                                    : Color(.quaternarySystemFill),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected(purpose) ? .isSelected : [])
                }

                Button(action: onNew) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(MileageTheme.appTint)
                        .frame(width: 44, height: 35)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("+ New")
                .accessibilityIdentifier("\(accessibilityPrefix)NewPurpose")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Purpose")
        .contextMenu {
            ForEach(purposes, id: \.self) { purpose in
                Button {
                    onSelect(purpose)
                } label: {
                    if isSelected(purpose) {
                        Label(purpose, systemImage: "checkmark")
                    } else {
                        Text(purpose)
                    }
                }
            }

            Divider()

            Button(action: onNew) {
                Label("Custom...", systemImage: "square.and.pencil")
            }
        }
    }

    private func isSelected(_ purpose: String) -> Bool {
        purpose.caseInsensitiveCompare(
            selection.trimmingCharacters(in: .whitespacesAndNewlines)
        ) == .orderedSame
    }
}

private struct TripDetailFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextX = x == 0 ? size.width : x + spacing + size.width
            if x > 0, nextX > maxWidth {
                measuredWidth = max(measuredWidth, x)
                x = size.width
                y += rowHeight + spacing
                rowHeight = size.height
            } else {
                x = nextX
                rowHeight = max(rowHeight, size.height)
            }
        }

        measuredWidth = max(measuredWidth, x)
        return CGSize(
            width: proposal.width ?? measuredWidth,
            height: subviews.isEmpty ? 0 : y + rowHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct TripDetailLegsView: View {
    var trip: TripSummary
    @State private var rowWidth: CGFloat = .infinity

    var body: some View {
        let legs = trip.effectiveLegs
        let stops = trip.stops
        VStack(spacing: 0) {
            ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                TripDetailLegRow(
                    tripID: trip.id,
                    leg: leg,
                    usesCompactLayout: rowWidth < 360,
                    showsDivider: legs.indices.contains(index + 1)
                )

                if legs.indices.contains(index + 1) {
                    if stops.indices.contains(index) {
                        TripDetailStopRow(stop: stops[index])
                        Divider().padding(.leading, TripDetailLegLayout.stopLeading)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .accessibilityElement(children: .contain)
    }
}

private enum TripDetailLegLayout {
    // A stop has no thumbnail, so use the card's normal inset rather than
    // leaving its time/address stranded in the leg text column.
    static let stopLeading: CGFloat = 20
    static let contentTrailing: CGFloat = 20
}

private struct TripDetailLegRow: View {
    var tripID: UUID
    var leg: TripDisplayLeg
    var usesCompactLayout: Bool
    var showsDivider: Bool

    @Environment(\.distanceUnit) private var distanceUnit
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var regularThumbnailSize: CGFloat = 70
    @ScaledMetric(relativeTo: .subheadline) private var compactThumbnailSize: CGFloat = 48

    private var thumbnailSize: CGFloat {
        usesCompactLayout ? compactThumbnailSize : regularThumbnailSize
    }

    private var mapContent: RouteMapContent? {
        dynamicTypeSize < .accessibility3 ? RouteMapContent(leg: leg) : nil
    }

    private var stacksDetailsVertically: Bool {
        dynamicTypeSize >= .accessibility1
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: stacksDetailsVertically ? 8 : 7) {
                if let mapContent {
                    thumbnail(content: mapContent)
                }
                summary
            }
            .padding(.vertical, 9)

            if showsDivider {
                Divider().padding(.leading, mapContent == nil ? 0 : thumbnailSize + (stacksDetailsVertically ? 8 : 7))
            }
        }
        .padding(.leading, TripDetailLegLayout.stopLeading)
        .padding(.trailing, TripDetailLegLayout.contentTrailing)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tripDetailLeg-\(leg.id.uuidString)")
    }

    private var summary: some View {
        let endpoints = DriveRouteLabelFormatter.compactEndpoints(for: leg)
        return VStack(alignment: .leading, spacing: 0) {
            Text(endpoints.origin)
                .lineLimit(stacksDetailsVertically ? 2 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(endpointText(address: leg.startAddress, coordinate: leg.startCoordinate))

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(endpoints.destination)
                    .lineLimit(stacksDetailsVertically ? 2 : 1)
                    .minimumScaleFactor(stacksDetailsVertically ? 1 : 0.88)
                    .accessibilityLabel(endpointText(address: leg.endAddress, coordinate: leg.endCoordinate))
            }

            Spacer(minLength: stacksDetailsVertically ? 2 : 0)
            detailsRow
        }
        .font(.body)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: thumbnailSize, alignment: .topLeading)
        .layoutPriority(1)
    }

    @ViewBuilder
    private var detailsRow: some View {
        Group {
            if stacksDetailsVertically {
                VStack(alignment: .leading, spacing: 2) {
                    timelineText
                    distanceText
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    timelineText
                        .layoutPriority(1)

                    Spacer(minLength: 8)

                    distanceText
                }
            }
        }
        .font(.footnote)
    }

    private var timelineText: some View {
        Group {
            if stacksDetailsVertically {
                Text(timeLine).lineLimit(2)
            } else {
                ViewThatFits(in: .horizontal) {
                    Text(timeLine).fixedSize()
                    Text(leg.startDate.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        .fixedSize()
                    Text(leg.startDate.formatted(.dateTime.month(.abbreviated).day()))
                        .lineLimit(1)
                }
            }
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(timeLine)
    }

    private var distanceText: some View {
        Text(DistanceFormatting.label(
            meters: leg.distanceMeters,
            unit: distanceUnit
        ))
        .monospacedDigit()
        .fontWeight(.bold)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func thumbnail(content: RouteMapContent) -> some View {
        DriveCardMapThumbnail(
            content: content,
            identityToken: "trip=\(tripID.uuidString)|leg=\(leg.id.uuidString)",
            routeColor: MileageTheme.routeUIColor,
            minimumPointSize: CGSize(width: thumbnailSize, height: thumbnailSize),
            usesProposedSize: false
        )
        .frame(width: thumbnailSize, height: thumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }

    private var timeLine: String {
        TripHierarchyPresentation.timelineLabel(
            startDate: leg.startDate,
            endDate: leg.endDate
        )
    }

    private func endpointText(address: String?, coordinate: Coordinate?) -> String {
        AddressDisplayFormatter.endpointText(address: address, coordinate: coordinate)
    }
}

private struct TripDetailStopRow: View {
    var stop: TripStop
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 2)
                .frame(width: 7, height: 7)

            Text(verbatim: stopText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
        }
        .padding(.leading, TripDetailLegLayout.stopLeading)
        .padding(.trailing, TripDetailLegLayout.contentTrailing)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var stopText: String {
        let duration = Duration.seconds(stop.durationSeconds).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2)
        )
        let address = AddressDisplayFormatter.endpointText(
            address: stop.address,
            coordinate: stop.coordinate
        )
        return "\(String(localized: "Stopped")) \(duration) · \(address)"
    }
}

/// Maps stored (engineer-facing) attention reasons to plain copy for the one
/// place they appear: Trip Detail's "Needs Attention" section. The raw strings
/// stay unchanged at rest — they double as logic keys in AppCore — and unknown
/// reasons pass through verbatim.
enum AttentionReasonText {
    static func display(_ reason: String) -> String {
        switch reason {
        case DriveCaptureReducer.shortTripInferredAttentionReason:
            String(localized: "This was a short trip with limited GPS data — double-check the distance.")
        case TransitTripClassifier.impossibleJumpReason:
            String(localized: "The GPS location jumped unexpectedly — check the distance and route.")
        case DriveCompletionCoordinator.ambiguousVehicleAttentionReason:
            String(localized: "More than one of your cars was nearby at the start — check which vehicle this trip belongs to.")
        default:
            reason
        }
    }
}
