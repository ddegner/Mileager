import AppCore
import SwiftUI

/// Export commands. Owned by the root, which is the only thing that knows the
/// export period (the visible scope, else the default month) and owns the
/// share presentation.
struct DriveExportCommandActions: Equatable {
    var canExportDefaultMonth: Bool
    var defaultExportMonthTitle: String
    var exportDefaultMonthCSV: () -> Void
    var exportDefaultMonthPDF: () -> Void
    var exportDefaultMonthQuickBooksCSV: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canExportDefaultMonth == rhs.canExportDefaultMonth
            && lhs.defaultExportMonthTitle == rhs.defaultExportMonthTitle
    }
}

/// Sort, select, merge, and selection-wide verbs. Published only by a
/// `DriveListView`, because that is where the sort option and visible-order
/// projection for the root-owned selection live.
///
/// Split out of a single focused value: the root cannot answer any of these
/// once the list owns them, and publishing hardcoded stand-ins made the ⌘-menu
/// claim a sort it was not using and enable a Merge that could never fire.
struct DriveCommandActions: Equatable {
    var sortOption: DriveSortOption
    var selectionModeActive: Bool
    var canMergeSelection: Bool
    /// The selection projected through the list's visible row order — the
    /// same value every bulk verb acts on, so a menu item can never be enabled
    /// for rows its action would then drop.
    var selectedTripIDs: [UUID]
    var businessPurposePresets: [String]
    /// Whether this list keeps a live selection a keyboard can walk — the Mac
    /// list does at every window width; a touch shell's Select mode does not,
    /// and filling its selection from a chord would leave rows checked with
    /// the mode closed.
    var supportsKeyboardSelection: Bool
    var setSortOption: (DriveSortOption) -> Void
    var cycleSortOption: () -> Void
    var toggleSelectionMode: () -> Void
    var deselectAll: () -> Void
    /// Moves the selection by one row; negative is up.
    var stepSelection: (Int) -> Void
    /// Extends the selection by one row from its anchor; negative is up.
    var extendSelection: (Int) -> Void
    var mergeSelected: () -> Void
    /// `nil` classification = unclassify; a purpose rides along for presets.
    var classifySelection: (TripClassification?, String?) -> Void
    var deleteSelection: () -> Void
    /// The vehicles the Assign Vehicle submenu offers; empty hides it (a
    /// single-vehicle account has nothing to assign).
    var vehicles: [DriveCommandVehicle]
    var customPurpose: () -> Void
    var clearPurpose: () -> Void
    var assignVehicle: (UUID) -> Void

    /// Compared on the values that decide how the ⌘-menu *renders*; the closures
    /// are deliberately excluded — this now includes `selectedTripIDs` and
    /// `businessPurposePresets`, which gate and label menu items.
    ///
    /// Without this, every `body` pass built a fresh instance whose closures
    /// could never compare equal, so the focused value changed on every render
    /// and SwiftUI logged "FocusedValue update tried to update multiple times
    /// per frame" — a feedback loop, not just noise.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sortOption == rhs.sortOption
            && lhs.selectionModeActive == rhs.selectionModeActive
            && lhs.canMergeSelection == rhs.canMergeSelection
            && lhs.selectedTripIDs == rhs.selectedTripIDs
            && lhs.businessPurposePresets == rhs.businessPurposePresets
            && lhs.supportsKeyboardSelection == rhs.supportsKeyboardSelection
            && lhs.vehicles == rhs.vehicles
    }
}

/// A vehicle as the ⌘-menu renders it: identity and name, nothing that would
/// make the focused value change on every render.
struct DriveCommandVehicle: Equatable, Identifiable {
    var id: UUID
    var name: String
}

/// The focused trip's verbs. Published by `TripDetailView`; every closure
/// routes through the detail screen's existing dirty-tracking paths so a
/// menu command can never bypass the draft-save discipline.
struct TripDetailCommandActions: Equatable {
    var tripID: UUID
    var canNavigatePrevious: Bool
    var canNavigateNext: Bool
    var canExport: Bool
    var navigatePrevious: () -> Void
    var navigateNext: () -> Void
    var exportPDF: () -> Void
    var classify: (TripClassification?) -> Void
    var confirmDelete: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tripID == rhs.tripID
            && lhs.canNavigatePrevious == rhs.canNavigatePrevious
            && lhs.canNavigateNext == rhs.canNavigateNext
            && lhs.canExport == rhs.canExport
    }
}

/// Navigation and creation verbs owned by the root (it owns the path and the
/// manual-trip sheet). Always published, so these commands stay alive at the
/// Mailboxes root where the list- and detail-scoped values are absent.
struct DriveSceneCommandActions: Equatable {
    var canGoBack: Bool
    var openNeedsReview: () -> Void
    var openAllTrips: () -> Void
    var openCurrentMonth: () -> Void
    var goBack: () -> Void
    var addTrip: () -> Void
    var openSettings: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canGoBack == rhs.canGoBack
    }
}

struct DriveCommands: Commands {
    @FocusedValue(\.driveCommandActions) private var actions
    @FocusedValue(\.driveExportCommandActions) private var exportActions
    @FocusedValue(\.tripDetailCommandActions) private var tripDetail
    @FocusedValue(\.driveSceneCommandActions) private var sceneActions

    var body: some Commands {
        // The standard Settings… slot in the app menu (⌘,) — on the Mac the
        // sidebar's toolbar gear sits in the titlebar strip, which does not
        // deliver clicks, so the menu is the reliable path.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                sceneActions?.openSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])
            .disabled(sceneActions == nil)
        }

        // Add Trip takes the File menu's New slot — the Mac convention for
        // "create the thing this app is about".
        CommandGroup(replacing: .newItem) {
            Button("Add Trip") {
                sceneActions?.addTrip()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(sceneActions == nil)
        }

        CommandMenu("Trips") {
            // Plain ⌘1-3 view switching (the Mail/Finder convention);
            // the sort shortcuts below keep their historical ⌥⌘ numbers.
            Button("Need Review") {
                sceneActions?.openNeedsReview()
            }
            .keyboardShortcut("1", modifiers: [.command])
            .disabled(sceneActions == nil)

            Button("All Trips") {
                sceneActions?.openAllTrips()
            }
            .keyboardShortcut("2", modifiers: [.command])
            .disabled(sceneActions == nil)

            Button("Current Month") {
                sceneActions?.openCurrentMonth()
            }
            .keyboardShortcut("3", modifiers: [.command])
            .disabled(sceneActions == nil)

            // The Mac-conventional Back chord; pops one level of the path.
            Button("Back") {
                sceneActions?.goBack()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(sceneActions?.canGoBack != true)

            Divider()

            Button("Cycle Sort") {
                actions?.cycleSortOption()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(actions == nil)

            ForEach(DriveSortOption.allCases) { option in
                Button(sortTitle(for: option)) {
                    actions?.setSortOption(option)
                }
                .keyboardShortcut(option.keyEquivalent, modifiers: [.command, .option])
                .disabled(actions == nil)
            }

            Divider()

            Button(actions?.selectionModeActive == true
                ? String(localized: "Finish Selecting Trips")
                : String(localized: "Select Trips")) {
                actions?.toggleSelectionMode()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Button("Merge Selected Trips") {
                actions?.mergeSelected()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(actions?.canMergeSelection != true)

            // Every bottom-bar verb has a menu-bar home on the Mac (David's
            // call, 2026-09-02): the Classify menu (purposes included, under
            // Business), Merge above, Delete below, and Assign Vehicle here.
            // Vehicles are a moving list, so they get no chords.
            if let vehicles = actions?.vehicles, !vehicles.isEmpty {
                Menu("Assign Vehicle") {
                    ForEach(vehicles) { vehicle in
                        Button(vehicle.name) {
                            actions?.assignVehicle(vehicle.id)
                        }
                    }
                }
                .disabled(actions?.selectedTripIDs.isEmpty != false)
            }

            Divider()

            // No "Select All" here, and never ⌘A on any item in this menu: a
            // custom key command that duplicates the system Edit ▸ Select All
            // makes UIKit drop this ENTIRE menu on the Mac (measured
            // 2026-09-02 — builds carrying a ⌘A item had no Trips menu at
            // all). Select All is the Edit menu's own item, answered through
            // the responder chain by `SelectAllCommandRelay`. Deselect takes
            // Finder's ⌥⌘A.
            Button("Deselect All") {
                actions?.deselectAll()
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(actions?.supportsKeyboardSelection != true)

            Divider()

            // ⌘ arrows, not ⌥⌘ (David's call, 08-31), and safe with text
            // fields even so: the text input system receives hardware keys
            // first, so with a field focused ⌘↑/⌘↓ move the caret to the
            // start/end of its text and this menu item never fires. Bare
            // arrows remain unclaimable — focus never reliably lands on a
            // Designed-for-iPad list (FB13644182), which is why keyboard trip
            // stepping lives here in the menu rather than on the list.
            //
            // On the Mac the arrows move the SELECTION and the reading pane
            // follows, because there the two are the same fact — which is also
            // what keeps them alive with nothing or several rows selected. In
            // a touch shell there is no live selection to walk, so they step
            // the open trip through TripDetailView's own save-first path.
            Button("Previous Trip") {
                step(-1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(!canStep(canNavigate: tripDetail?.canNavigatePrevious))

            Button("Next Trip") {
                step(1)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .disabled(!canStep(canNavigate: tripDetail?.canNavigateNext))

            Button("Extend Selection Up") {
                actions?.extendSelection(-1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
            .disabled(actions?.supportsKeyboardSelection != true)

            Button("Extend Selection Down") {
                actions?.extendSelection(1)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
            .disabled(actions?.supportsKeyboardSelection != true)

            Divider()

            Button("Export \(exportActions?.defaultExportMonthTitle ?? String(localized: "Current Month")) as CSV") {
                exportActions?.exportDefaultMonthCSV()
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(exportActions?.canExportDefaultMonth != true)

            Button("Export \(exportActions?.defaultExportMonthTitle ?? String(localized: "Current Month")) as PDF") {
                exportActions?.exportDefaultMonthPDF()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(exportActions?.canExportDefaultMonth != true)

            Button("Export \(exportActions?.defaultExportMonthTitle ?? String(localized: "Current Month")) for QuickBooks") {
                exportActions?.exportDefaultMonthQuickBooksCSV()
            }
            .disabled(exportActions?.canExportDefaultMonth != true)

            Button("Export Trip as PDF") {
                tripDetail?.exportPDF()
            }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(tripDetail?.canExport != true)

            Divider()

            // A non-empty Select-mode selection wins over the reading-pane
            // trip (David's call, 08-31); both routes end at a confirmation,
            // never a direct delete.
            if actions?.selectedTripIDs.isEmpty == false {
                // Counted, because on the Mac a single click IS a selection,
                // so the ordinary one-row case took this branch and read
                // "Delete Trips" over an alert that said "Delete Trip". The
                // app's one irreversible verb does not get to disagree with
                // itself about how many records it is about to destroy.
                Button(
                    actions?.selectedTripIDs.count == 1
                        ? String(localized: "Delete Trip")
                        : String(localized: "Delete Trips"),
                    role: .destructive
                ) {
                    actions?.deleteSelection()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
            } else {
                Button("Delete Trip", role: .destructive) {
                    tripDetail?.confirmDelete()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(tripDetail == nil)
            }
        }

        CommandMenu("Classify") {
            // Business is a submenu because a purpose is its detail, not a
            // separate verb (David's call, 2026-09-02): the presets classify
            // Business and set the purpose in one hit — the common case — and
            // act on the list selection (the detail screen has its own inline
            // purpose editing); the bare Business keeps ⇧⌘B and the
            // selection-or-detail target. Custom Purpose… is ⌥⌘P, because
            // ⇧⌘P is Personal and ⌘P is the system's Print; presets are a
            // moving list and get no chords.
            Menu("Business") {
                if let presets = actions?.businessPurposePresets, !presets.isEmpty {
                    ForEach(presets, id: \.self) { purpose in
                        Button(purpose) {
                            actions?.classifySelection(.business, purpose)
                        }
                        .disabled(actions?.selectedTripIDs.isEmpty != false)
                    }
                }
                Button("Custom Purpose…") {
                    actions?.customPurpose()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(actions?.selectedTripIDs.isEmpty != false)

                Divider()

                Button("Business") {
                    classifyTarget(.business)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!canClassify)

                Button("Clear Purpose") {
                    actions?.clearPurpose()
                }
                .disabled(actions?.selectedTripIDs.isEmpty != false)
            }

            Button("Personal") {
                classifyTarget(.personal)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!canClassify)

            Button("Not a Drive") {
                classifyTarget(.notADrive)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!canClassify)

            Divider()

            Button("Unclassify") {
                classifyTarget(nil)
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!canClassify)
        }
    }

    /// A non-empty list selection wins over the reading-pane trip: checking
    /// rows is the more deliberate targeting gesture, while a touch reading
    /// pane can legitimately remain on an unrelated trip during Select mode.
    private var resolvedTarget: DriveCommandTarget {
        DriveCommandTargetResolution.classifyTarget(
            selectedTripIDs: actions?.selectedTripIDs ?? [],
            hasDetail: tripDetail != nil
        )
    }

    private var canClassify: Bool {
        resolvedTarget != .none
    }

    private func step(_ offset: Int) {
        if actions?.supportsKeyboardSelection == true {
            actions?.stepSelection(offset)
        } else if offset < 0 {
            tripDetail?.navigatePrevious()
        } else {
            tripDetail?.navigateNext()
        }
    }

    private func canStep(canNavigate: Bool?) -> Bool {
        actions?.supportsKeyboardSelection == true || canNavigate == true
    }

    private func classifyTarget(_ classification: TripClassification?) {
        switch resolvedTarget {
        case .selection:
            actions?.classifySelection(classification, nil)
        case .detail:
            tripDetail?.classify(classification)
        case .none:
            break
        }
    }

    private func sortTitle(for option: DriveSortOption) -> String {
        guard actions?.sortOption == option else { return option.title }
        return String(localized: "\(option.title) - Selected")
    }
}

private struct DriveCommandActionsKey: FocusedValueKey {
    typealias Value = DriveCommandActions
}

private struct DriveExportCommandActionsKey: FocusedValueKey {
    typealias Value = DriveExportCommandActions
}

private struct TripDetailCommandActionsKey: FocusedValueKey {
    typealias Value = TripDetailCommandActions
}

private struct DriveSceneCommandActionsKey: FocusedValueKey {
    typealias Value = DriveSceneCommandActions
}

extension FocusedValues {
    var driveCommandActions: DriveCommandActions? {
        get { self[DriveCommandActionsKey.self] }
        set { self[DriveCommandActionsKey.self] = newValue }
    }

    var driveExportCommandActions: DriveExportCommandActions? {
        get { self[DriveExportCommandActionsKey.self] }
        set { self[DriveExportCommandActionsKey.self] = newValue }
    }

    var tripDetailCommandActions: TripDetailCommandActions? {
        get { self[TripDetailCommandActionsKey.self] }
        set { self[TripDetailCommandActionsKey.self] = newValue }
    }

    var driveSceneCommandActions: DriveSceneCommandActions? {
        get { self[DriveSceneCommandActionsKey.self] }
        set { self[DriveSceneCommandActionsKey.self] = newValue }
    }
}
