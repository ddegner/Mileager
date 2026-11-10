import AppCore
import CoreData
import Foundation

/// Drives the system undo conventions (shake, three-finger swipe, ⌘Z) on top of
/// Core Data's built-in context undo.
///
/// Why the built-in path rather than hand-rolled snapshots: Core Data undoes at
/// the object-graph level, so a committed merge or delete reverts *exactly* —
/// including `createdAt`, `captureSource`, cascade-deleted fees, and Local-store
/// raw GPS samples, none of which a domain-level snapshot could restore.
/// Measured, not assumed: see `TripUndoTests`.
///
/// ## Registration is off by default
///
/// Every writer in the app shares one `TripStore` on one context — the UI, the
/// background capture runtime, automatic enrichment, App Intents, fixture
/// seeding, and CloudKit import. Rather than bracketing each non-interactive
/// writer (which would mean editing the capture path, where raw GPS samples are
/// written on every fix and undo snapshots would pile up mid-drive), undo
/// registration is **suspended at all times** and enabled only inside
/// `perform(_:tripIDs:body:)`.
///
/// That makes the exclusion structural: a writer that forgets to opt out simply
/// never registers. The only way onto the undo stack is an explicit user command.
///
/// ## Two `UndoManager` mechanics that shape this class
///
/// 1. `groupsByEvent = false` means a registration outside an open group raises
///    `NSInternalInconsistencyException`, so commands must go through `perform`.
///    The payoff is that undo becomes synchronous and deterministic rather than
///    waiting on a run-loop observer, which keeps tests free of timing hacks.
/// 2. Undo reverts the *context* and leaves it dirty; nothing is persisted until
///    `save()`. It also bypasses `TripStore.transaction`, so no `TripChangeSet`
///    is emitted and neither Spotlight nor the published trip list would update
///    on their own. Hence `undoRedoDidChange`.
///
/// The manager is reached by the system through `UndoResponderBridge`, which is
/// the only reason shake works at all — see that file for the measurement.
@MainActor
final class TripUndoCoordinator {
    /// Bounded because each level retains Core Data snapshots of every changed
    /// object. Ten commands is far more than a shake-driven interaction needs.
    private static let undoLevels = 10

    let undoManager: UndoManager

    /// Set from `wireStores`. Weak to avoid a cycle; the model owns this.
    weak var model: MileageAppModel?

    private weak var context: NSManagedObjectContext?
    private var observers: [NSObjectProtocol] = []
    /// Mirrors `UndoManager`'s registration flag so the enable/disable pairs stay
    /// balanced — an unbalanced `enableUndoRegistration()` raises
    /// `NSInternalInconsistencyException`.
    ///
    /// Deliberately a boolean rather than a nesting counter: `removeAllActions()`
    /// silently **re-enables** registration, so any depth we tracked would drift
    /// out of sync with the manager on every `invalidate()`. A single flag can be
    /// re-asserted after that reset instead.
    private var registrationSuspended = false

    init(undoManager: UndoManager = UndoManager()) {
        self.undoManager = undoManager
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = Self.undoLevels
        setRegistrationSuspended(true)
        observeUndoRedo()
    }

    // No deinit teardown: the observers capture `self` weakly and are keyed to
    // this instance's `undoManager`, so they go inert once the coordinator dies.
    // Reaching into main-actor state from a nonisolated deinit is not allowed
    // under Swift 6 concurrency checking.

    /// True only while a user command or an undo/redo is in flight.
    var isRegistrationEnabled: Bool { !registrationSuspended }

    // MARK: - Installation

    /// Attaches the manager to a freshly wired context. Called from
    /// `wireStores`, so a protected-data store swap re-installs onto the real
    /// context and abandons any stack built against the placeholder.
    func install(on context: NSManagedObjectContext) {
        if let existing = self.context, existing !== context {
            existing.undoManager = nil
        }
        invalidate()
        self.context = context
        context.undoManager = undoManager
    }

    // MARK: - Recording

    /// Runs one user command as a single named undo group.
    ///
    /// `actionName` is user-visible — it appears in the system's "Undo <name>"
    /// alert — so it must be localized and placeholder-free.
    ///
    /// Only UI-facing model methods call this. In particular `classify` is
    /// wrapped and the shared `applyClassification` core is not, which is what
    /// keeps App Intent invocations off the stack.
    @discardableResult
    func perform<T>(_ actionName: String, body: () -> T) -> T {
        // Re-entrancy would unbalance the enable/disable pairing, and a command
        // running inside an undo has no business registering a third state.
        guard !undoManager.isUndoing, !undoManager.isRedoing, registrationSuspended else {
            return body()
        }
        setRegistrationSuspended(false)
        undoManager.beginUndoGrouping()
        let result = body()
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
        setRegistrationSuspended(true)
        return result
    }

    private func setRegistrationSuspended(_ suspended: Bool) {
        guard suspended != registrationSuspended else { return }
        if suspended {
            undoManager.disableUndoRegistration()
        } else {
            undoManager.enableUndoRegistration()
        }
        registrationSuspended = suspended
    }

    // MARK: - Invalidation

    /// Drops the whole stack. Idempotent, which matters because
    /// `PersistentHistoryMonitor` can replay one logical import across its
    /// `[1s, 3s, 10s]` retries.
    func invalidate() {
        guard !undoManager.isUndoing, !undoManager.isRedoing else { return }
        clearStackPreservingRegistrationState()
    }

    /// `removeAllActions()` also re-enables registration as a side effect, which
    /// would leave every subsequent write — capture, enrichment, CloudKit
    /// import — landing on the stack. Re-assert the previous state afterwards.
    private func clearStackPreservingRegistrationState() {
        let wasSuspended = registrationSuspended
        undoManager.removeAllActions()
        registrationSuspended = false
        setRegistrationSuspended(wasSuspended)
    }

    // MARK: - Undo/redo lifecycle

    /// Registration must be *enabled* while undoing, because that is how the
    /// redo entries get created — Core Data registers the inverse as it reverts.
    /// The Will/Did pair brackets exactly that window.
    private func observeUndoRedo() {
        let willNames: [Notification.Name] = [
            .NSUndoManagerWillUndoChange, .NSUndoManagerWillRedoChange
        ]
        let didNames: [Notification.Name] = [
            .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange
        ]
        for name in willNames {
            observers.append(observe(name) { $0.setRegistrationSuspended(false) })
        }
        for name in didNames {
            observers.append(observe(name) { coordinator in
                coordinator.setRegistrationSuspended(true)
                coordinator.undoRedoDidChange()
            })
        }
    }

    private func observe(
        _ name: Notification.Name,
        _ handler: @escaping @MainActor (TripUndoCoordinator) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: name,
            object: undoManager,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
    }

    /// Persist the reverted context and rebuild published state. Suggestion
    /// staleness needs no special handling here: `refresh()` runs the
    /// suggestion engine's fingerprint sweep, which drops any suggestion whose
    /// trip was reverted out from under it.
    private func undoRedoDidChange() {
        guard let context else { return }
        do {
            if context.hasChanges { try context.save() }
        } catch {
            // A failed save leaves the context dirty and the stack untrustworthy;
            // better to lose undo history than to leave half-reverted rows.
            context.rollback()
            clearStackPreservingRegistrationState()
            model?.present(error, .saveChanges)
        }
        model?.refreshAfterUndo()
    }
}
