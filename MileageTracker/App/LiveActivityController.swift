import AppCore
import Foundation

#if canImport(ActivityKit)
@preconcurrency import ActivityKit
#endif

@MainActor
final class LiveActivityController {
    private static let minimumUpdateInterval: TimeInterval = 10
    private static let staleInterval: TimeInterval = 2 * 60
    private static let finalStateLingerInterval: TimeInterval = 2

    #if canImport(ActivityKit)
    private struct ReconcileRequest {
        var currentDrive: CurrentDriveSummary?
        var sceneIsActive: Bool
        var enabled: Bool
        var distanceUnit: DistanceUnit
    }

    private var activity: Activity<MileageDriveActivityAttributes>?
    private var lastContentState: MileageDriveActivityAttributes.ContentState?
    private var lastUpdateAt: Date?
    private var pendingRequest: ReconcileRequest?
    private var isReconciling = false
    #endif

    func reconcile(
        currentDrive: CurrentDriveSummary?,
        sceneIsActive: Bool,
        enabled: Bool,
        distanceUnit: DistanceUnit = .miles
    ) {
        #if canImport(ActivityKit)
        // Coalesce overlapping calls onto a single serial worker. Reconcile fires
        // rapidly at drive start (scene-active snapshot, the runtime callback, and
        // the 15s timer can all land within milliseconds); without serialization two
        // tasks could both observe `activity == nil` across the `Activity.request`
        // await and start duplicate Live Activities for the same drive.
        pendingRequest = ReconcileRequest(
            currentDrive: currentDrive,
            sceneIsActive: sceneIsActive,
            enabled: enabled,
            distanceUnit: distanceUnit
        )
        guard !isReconciling else { return }
        isReconciling = true
        Task { @MainActor in
            defer { isReconciling = false }
            while let next = pendingRequest {
                pendingRequest = nil
                await reconcileActivity(
                    currentDrive: next.currentDrive,
                    sceneIsActive: next.sceneIsActive,
                    enabled: next.enabled,
                    distanceUnit: next.distanceUnit
                )
            }
        }
        #endif
    }

    #if canImport(ActivityKit)
    private func reconcileActivity(
        currentDrive: CurrentDriveSummary?,
        sceneIsActive: Bool,
        enabled: Bool,
        distanceUnit: DistanceUnit
    ) async {
        guard enabled else {
            // After a relaunch `activity` is nil even though ActivityKit can
            // still own a visible activity. End the system collection first;
            // relying on the cached reference leaves that activity alive.
            await endAllActivities()
            return
        }

        guard let currentDrive else {
            await endAllActivities()
            return
        }

        await endOrphanedActivities(keeping: currentDrive.pendingTripID)

        if activity?.attributes.pendingTripID != currentDrive.pendingTripID {
            activity = Activity<MileageDriveActivityAttributes>.activities.first {
                $0.attributes.pendingTripID == currentDrive.pendingTripID
            }
            lastContentState = nil
            lastUpdateAt = nil
        }

        if activity == nil {
            guard sceneIsActive,
                  currentDrive.phase != .paused,
                  ActivityAuthorizationInfo().areActivitiesEnabled else {
                return
            }
            do {
                let attributes = MileageDriveActivityAttributes(pendingTripID: currentDrive.pendingTripID)
                let state = MileageDriveActivityAttributes.ContentState(summary: currentDrive, distanceUnit: distanceUnit)
                activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(
                        state: state,
                        staleDate: Date().addingTimeInterval(Self.staleInterval)
                    ),
                    pushType: nil
                )
                lastContentState = state
                lastUpdateAt = Date()
            } catch {
                activity = nil
            }
            return
        }

        await updateActivityIfNeeded(with: currentDrive, distanceUnit: distanceUnit)
    }

    private func updateActivityIfNeeded(with currentDrive: CurrentDriveSummary, distanceUnit: DistanceUnit) async {
        guard let activity else { return }
        let state = MileageDriveActivityAttributes.ContentState(summary: currentDrive, distanceUnit: distanceUnit)
        guard shouldUpdate(to: state) else { return }
        await activity.update(ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(Self.staleInterval)
        ))
        lastContentState = state
        lastUpdateAt = Date()
    }

    private func shouldUpdate(to state: MileageDriveActivityAttributes.ContentState) -> Bool {
        guard let lastContentState else { return true }
        // Discrete, user-meaningful changes always warrant a prompt update.
        if state.isPaused != lastContentState.isPaused
            || state.phaseRaw != lastContentState.phaseRaw
            || state.vehicle != lastContentState.vehicle
            || state.classification != lastContentState.classification
            || state.businessPurpose != lastContentState.businessPurpose
            || state.feeCount != lastContentState.feeCount
            || state.distanceUnitRaw != lastContentState.distanceUnitRaw {
            return true
        }
        if state.phase == .confirmingTripEnd,
           state.lastMovingAt != lastContentState.lastMovingAt {
            return true
        }
        // Otherwise only distance moved: require a meaningful delta AND a minimum
        // spacing between pushes, so we neither spam updates on fast roads nor push
        // unchanged content on a periodic tick.
        guard abs(state.distanceMeters - lastContentState.distanceMeters) >= 100 else {
            return false
        }
        guard let lastUpdateAt else { return true }
        return Date().timeIntervalSince(lastUpdateAt) >= Self.minimumUpdateInterval
    }

    private func endOrphanedActivities(keeping pendingTripID: UUID?) async {
        for existing in Activity<MileageDriveActivityAttributes>.activities
        where Self.shouldEndActivity(
            pendingTripID: existing.attributes.pendingTripID,
            keeping: pendingTripID,
            enabled: true
        ) {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func endAllActivities() async {
        for existing in Activity<MileageDriveActivityAttributes>.activities
        where Self.shouldEndActivity(
            pendingTripID: existing.attributes.pendingTripID,
            keeping: nil,
            enabled: false
        ) {
            // The drive just finished (or Live Activities got turned off) — let
            // the final distance linger briefly instead of snapping straight to
            // nothing. `existing.content.state` is ActivityKit's own last-pushed
            // content, so this holds even right after a relaunch when `activity`
            // (our cached reference) is nil and `lastContentState` was never set
            // this launch.
            await existing.end(
                ActivityContent(state: existing.content.state, staleDate: Date()),
                dismissalPolicy: .after(Date().addingTimeInterval(Self.finalStateLingerInterval))
            )
        }
        resetCachedActivityState()
    }

    private func resetCachedActivityState() {
        activity = nil
        lastContentState = nil
        lastUpdateAt = nil
    }

    /// Kept internal for a focused regression test of the relaunch/disable
    /// selection rule without needing to create a real system Live Activity.
    static func shouldEndActivity(
        pendingTripID: UUID,
        keeping currentTripID: UUID?,
        enabled: Bool
    ) -> Bool {
        !enabled || pendingTripID != currentTripID
    }
    #endif
}
