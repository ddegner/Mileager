import AppCore
import Foundation

// MARK: - Vehicles
// Vehicle CRUD, attribution, and car-connection linking. Store wiring
// (reloadVehicles, createDefaultVehicleIfNeeded) stays in MileageAppModel.swift
// with the rest of the lifecycle code.

@MainActor
extension MileageAppModel {
    /// True when at least one vehicle exists. The app backfills a default
    /// vehicle at onboarding/launch, so this is effectively always true; it
    /// still guards the transient zero-vehicle states (locked-launch in-memory
    /// fallback, the instant before backfill, a remote CloudKit deletion).
    var vehiclesConfigured: Bool { !vehicles.isEmpty }

    /// True once there are two or more vehicles. Unlocks list/report filters,
    /// card labels, and the per-vehicle odometer surfaces. With 0–1 vehicles
    /// filtering is noise, so it stays hidden.
    var multiVehicleUIActive: Bool { vehicles.count >= 2 }

    func vehicle(for id: UUID?) -> Vehicle? {
        guard let id else { return nil }
        return vehicles.first { $0.id == id }
    }

    /// Display name for a trip's `vehicleID`. A `nil` id resolves to the primary
    /// vehicle's name (the implicit default) when vehicles exist.
    func vehicleName(for id: UUID?) -> String? {
        if let id { return vehicle(for: id)?.name }
        guard let primaryVehicleID else { return nil }
        return vehicle(for: primaryVehicleID)?.name
    }

    /// Builds a Siri/Spotlight projection of a trip with its resolved vehicle
    /// name folded in.
    func entity(for trip: TripSummary) -> TripAppEntity {
        TripAppEntity(trip, vehicleName: vehicleName(for: trip.vehicleID))
    }

    /// Learned Bluetooth devices offered for vehicle assignment, hiding
    /// blocked (rejected) devices which never contribute drive signals.
    var learnedBluetoothDevices: [BluetoothDriveHint] {
        ((try? bluetoothHintStore.fetchHints()) ?? []).filter { !$0.blocked }
    }

    /// Connections hidden by "Not one of my vehicles". Settings exposes these
    /// separately so an accidental ignore is always reversible without waiting
    /// for the route to be connected again.
    var ignoredVehicleConnections: [BluetoothDriveHint] {
        ((try? bluetoothHintStore.fetchHints()) ?? [])
            .filter { $0.mappingDisposition == .ignored }
            .sorted(by: Self.vehicleConnectionHintOrder)
    }

    /// Connected routes that can be explicitly associated after a user makes
    /// a manual mid-drive vehicle correction. Merely reading this list never
    /// changes an existing mapping.
    var currentDriveConnectionRememberCandidates: [BluetoothDriveHint] {
        guard let currentDrive,
              currentDrive.vehicleAssignmentSource == .manual,
              let vehicleID = currentDrive.vehicleID else {
            return []
        }
        var seen = Set<String>()
        return (bluetoothSignalService?.connectedHints ?? [])
            .filter { hint in
                hint.vehicleID != vehicleID && seen.insert(hint.identifierHash).inserted
            }
            .sorted(by: Self.vehicleConnectionHintOrder)
    }

    func connectionAliases(for vehicleID: UUID) -> [VehicleConnectionAlias] {
        (try? bluetoothHintStore.fetchConnectionAliases(vehicleID: vehicleID)) ?? []
    }

    func vehicleConnectionCount(for vehicleID: UUID) -> Int {
        let aliases = connectionAliases(for: vehicleID)
        let aliasIDs = Set(aliases.map(\.id))
        let localOnlyCount = learnedBluetoothDevices.count {
            $0.vehicleID == vehicleID
                && $0.connectionAliasID.map(aliasIDs.contains) != true
        }
        return aliases.count + localOnlyCount
    }

    @discardableResult
    func createVehicle(name: String, colorHex: String? = nil, symbolName: String? = nil) -> Vehicle? {
        do {
            let vehicle = try vehicleStore.createVehicle(name: name, colorHex: colorHex, symbolName: symbolName)
            reloadVehicles()
            // A first vehicle becomes primary, changing the projected vehicle
            // name of every nil-vehicle trip in the Spotlight index.
            invalidateSpotlightIndex()
            return vehicle
        } catch {
            present(error, .saveChanges)
            return nil
        }
    }

    func renameVehicle(id: UUID, name: String) {
        do {
            _ = try vehicleStore.renameVehicle(id: id, name: name)
            reloadVehicles()
            // Donated snippets embed the vehicle name; no trip row changes on a
            // rename, so updatedAt diffing alone would never heal the index.
            invalidateSpotlightIndex()
        } catch {
            present(error, .saveChanges)
        }
    }

    func updateVehicleAppearance(id: UUID, colorHex: String?, symbolName: String?) {
        do {
            _ = try vehicleStore.updateAppearance(id: id, colorHex: colorHex, symbolName: symbolName)
            reloadVehicles()
        } catch {
            present(error, .saveChanges)
        }
    }

    func setVehicleOrder(_ ids: [UUID]) {
        do {
            try vehicleStore.setSortOrder(ids: ids)
            reloadVehicles()
        } catch {
            present(error, .saveChanges)
        }
    }

    /// Atomically deletes a vehicle, moves its trips to the default vehicle,
    /// removes its physical odometer readings, and unlinks Bluetooth mappings.
    func deleteVehicle(id: UUID) {
        do {
            // Rewrites vehicleID across an unbounded set of trips and returns no
            // IDs, so there is nothing to scope an undo entry to.
            undoCoordinator.invalidate()
            _ = try vehicleStore.deleteVehicleAndAssociatedData(id: id)
            reloadVehicles()
            refresh()
            // Primary may have handed off, changing the projected vehicle name
            // of nil-vehicle trips in the Spotlight index.
            invalidateSpotlightIndex()
        } catch {
            present(error, .saveChanges)
        }
    }

    /// Applies a user's vehicle choice to a trip. `nil` clears the assignment
    /// back to the default vehicle.
    func assignVehicle(_ trip: TripSummary, vehicleID: UUID?) {
        do {
            _ = try tripStore.assignVehicle(tripID: trip.id, vehicleID: vehicleID)
            refresh()
        } catch {
            present(error, .saveChanges)
        }
    }

    /// Links or unlinks a learned Bluetooth device to a vehicle.
    func setVehicle(for hint: BluetoothDriveHint, vehicleID: UUID?) {
        do {
            _ = try bluetoothHintStore.assignVehicle(identifierHash: hint.identifierHash, vehicleID: vehicleID)
            refreshVehicleConnectionSignals()
        } catch {
            present(error, .saveChanges)
        }
    }

    /// Explicit second step after a manual current-drive correction. The trip
    /// choice remains manual; this only teaches future automatic attribution.
    func rememberCurrentConnection(_ hint: BluetoothDriveHint, for vehicleID: UUID) {
        do {
            _ = try bluetoothHintStore.assignVehicle(
                identifierHash: hint.identifierHash,
                vehicleID: vehicleID
            )
            refreshVehicleConnectionSignals()
        } catch {
            present(error, .saveChanges)
        }
    }

    func clearVehicleConnection(for hint: BluetoothDriveHint) {
        do {
            _ = try bluetoothHintStore.clearVehicleAssignment(identifierHash: hint.identifierHash)
            refreshVehicleConnectionSignals()
        } catch {
            present(error, .saveChanges)
        }
    }

    func restoreIgnoredVehicleConnection(_ hint: BluetoothDriveHint) {
        clearVehicleConnection(for: hint)
    }

    func reassignConnectionAlias(_ alias: VehicleConnectionAlias, to vehicleID: UUID) {
        do {
            _ = try bluetoothHintStore.assignConnectionAlias(id: alias.id, vehicleID: vehicleID)
            refreshVehicleConnectionSignals()
        } catch {
            present(error, .saveChanges)
        }
    }

    func removeConnectionAlias(_ alias: VehicleConnectionAlias) {
        do {
            _ = try bluetoothHintStore.deleteConnectionAlias(id: alias.id)
            refreshVehicleConnectionSignals()
        } catch {
            present(error, .saveChanges)
        }
    }

    /// Number of past trips that would be re-attributed if `hint` were linked to
    /// a vehicle (non-manual, non-shortcut trips whose start hashes contain it).
    func unattributedPastTripCount(matching hint: BluetoothDriveHint) -> Int {
        ((try? tripStore.vehicleReattributionCandidates(startHintHash: hint.identifierHash)) ?? []).count
    }

    /// Re-attributes past trips matching `hint` to `vehicleID`.
    @discardableResult
    func assignPastTrips(matching hint: BluetoothDriveHint, to vehicleID: UUID?) -> Int {
        do {
            // Bulk re-attribution returns only a count, so the affected trips
            // cannot be tracked for a scoped undo.
            undoCoordinator.invalidate()
            let count = try tripStore.reattributeTrips(startHintHash: hint.identifierHash, to: vehicleID)
            refresh()
            return count
        } catch {
            present(error, .saveChanges)
            return 0
        }
    }

    // MARK: - Live and post-trip connection decisions

    /// Called for every route refresh. Mapped hints are applied in a stable,
    /// user-meaningful order (CarPlay before Bluetooth); reducer policy owns the
    /// first-wins latch and conflict behavior.
    func handleConnectedVehicleHints(_ hints: [BluetoothDriveHint]) {
        var seenVehicleIDs = Set<UUID>()
        let mappedVehicleIDs = hints
            .filter {
                $0.canIdentifyVehicleSilently
            }
            .sorted(by: Self.vehicleConnectionHintOrder)
            .compactMap(\.vehicleID)
            .filter { vehicle(for: $0) != nil }
            .filter { seenVehicleIDs.insert($0).inserted }

        for vehicleID in mappedVehicleIDs {
            observeMappedVehicleConnection(vehicleID)
        }
    }

    func queueVehicleConnectionDecision(
        for trip: TripSummary,
        conflictingVehicleIDs: [UUID] = []
    ) {
        // A split leg completes while another active leg is already recording;
        // setup prompts belong after the full drive, never on top of that drive.
        guard currentDrive == nil,
              !hasHandledVehicleConnectionDecision(for: trip.id) else {
            return
        }

        if let conflict = makeVehicleConflictDecision(
            trip: trip,
            conflictingVehicleIDs: conflictingVehicleIDs
        ) {
            persistDeferredVehicleConflict(conflict)
            enqueueVehicleConnectionDecision(conflict)
            return
        }

        // A manual, Shortcut, or already-confirmed connection attribution is
        // authoritative. Unknown routes may still be remembered explicitly
        // from the current-drive picker, but a post-trip prompt must not rewrite
        // that trip or silently teach a different mapping.
        guard trip.vehicleID == nil, trip.vehicleAssignmentSource == nil else {
            markVehicleConnectionDecisionHandled(tripID: trip.id)
            return
        }

        let candidates = (try? bluetoothHintStore.fetchReviewCandidates(
            startHintHashes: trip.startBluetoothHintHashes
        )) ?? []
        guard let hint = candidates.sorted(by: Self.vehicleConnectionHintOrder).first else {
            return
        }
        let suggestion = try? bluetoothHintStore.suggestedAlias(for: hint.identifierHash)
        enqueueVehicleConnectionDecision(PendingVehicleConnectionDecision(
            tripID: trip.id,
            kind: .unknownConnection(hint: hint, suggestion: suggestion)
        ))
    }

    /// Recovers a background-completed prompt after process termination. Local
    /// observations expire quickly, so a bounded lookback avoids surfacing
    /// ancient setup questions after an update.
    func recoverRecentVehicleConnectionDecisionIfNeeded(now: Date = Date()) {
        guard currentDrive == nil,
              pendingVehicleConnectionDecision == nil,
              queuedVehicleConnectionDecisions.isEmpty else {
            return
        }
        if recoverDeferredVehicleConflictIfNeeded() {
            return
        }
        let cutoff = now.addingTimeInterval(-48 * 60 * 60)
        let handledTripIDs = Set(preferences.handledVehicleConnectionTripIDs)
        for trip in trips
            .filter({ $0.captureSource == "automatic" && $0.endDate >= cutoff })
            .sorted(by: { $0.endDate > $1.endDate })
        where !handledTripIDs.contains(trip.id) {
            guard trip.vehicleID == nil, trip.vehicleAssignmentSource == nil else {
                markVehicleConnectionDecisionHandled(tripID: trip.id)
                continue
            }
            let candidates = (try? bluetoothHintStore.fetchReviewCandidates(
                startHintHashes: trip.startBluetoothHintHashes
            )) ?? []
            guard let hint = candidates.sorted(by: Self.vehicleConnectionHintOrder).first else { continue }
            let suggestion = try? bluetoothHintStore.suggestedAlias(for: hint.identifierHash)
            enqueueVehicleConnectionDecision(PendingVehicleConnectionDecision(
                tripID: trip.id,
                kind: .unknownConnection(hint: hint, suggestion: suggestion)
            ))
            return
        }
    }

    func presentQueuedVehicleConnectionDecisionIfPossible() {
        guard sceneIsActive,
              currentDrive == nil,
              pendingVehicleConnectionDecision == nil,
              !queuedVehicleConnectionDecisions.isEmpty else {
            return
        }
        pendingVehicleConnectionDecision = queuedVehicleConnectionDecisions.removeFirst()
    }

    func chooseVehicleForPendingConnection(_ vehicleID: UUID) {
        guard let decision = pendingVehicleConnectionDecision else { return }
        do {
            switch decision.kind {
            case let .unknownConnection(hint, suggestion):
                _ = try bluetoothHintStore.resolveVehicleChoice(
                    identifierHash: hint.identifierHash,
                    vehicleID: vehicleID,
                    suggestedAliasID: suggestion?.vehicleID == vehicleID
                        ? suggestion?.alias.id
                        : nil
                ) {
                    let trip = try tripStore.fetchTrip(id: decision.tripID)
                    if trip.vehicleID == nil,
                       trip.vehicleAssignmentSource == nil {
                        _ = try tripStore.assignVehicle(
                            tripID: decision.tripID,
                            vehicleID: vehicleID,
                            source: .vehicleConnection
                        )
                    }
                }
            case .conflictingVehicles:
                // A person resolved conflicting machine evidence, so protect
                // this trip from any later automatic re-attribution.
                _ = try tripStore.assignVehicle(
                    tripID: decision.tripID,
                    vehicleID: vehicleID,
                    source: .manual
                )
            }
            markVehicleConnectionDecisionHandled(tripID: decision.tripID)
            completePendingVehicleConnectionDecision()
        } catch TripStoreError.tripNotFound {
            // The trip can disappear while the dialog is visible or during the
            // tap itself. The mapping transaction has rolled back, so consume
            // the stale prompt without manufacturing an error loop.
            markVehicleConnectionDecisionHandled(tripID: decision.tripID)
            completePendingVehicleConnectionDecision()
        } catch {
            present(error, .saveChanges)
        }
    }

    func ignorePendingVehicleConnection() {
        guard let decision = pendingVehicleConnectionDecision else { return }
        do {
            if case let .unknownConnection(hint, _) = decision.kind {
                _ = try bluetoothHintStore.markIgnored(identifierHash: hint.identifierHash)
            }
            markVehicleConnectionDecisionHandled(tripID: decision.tripID)
            completePendingVehicleConnectionDecision()
        } catch {
            present(error, .saveChanges)
        }
    }

    func deferPendingVehicleConnection() {
        guard let decision = pendingVehicleConnectionDecision else { return }
        do {
            if case let .unknownConnection(hint, _) = decision.kind {
                _ = try bluetoothHintStore.deferReview(identifierHash: hint.identifierHash)
                // Ask again only after a later trip observes this connection,
                // never for another refresh of the trip just dismissed.
                markVehicleConnectionDecisionHandled(tripID: decision.tripID)
            }
            // Conflicts deliberately remain in the durable deferred list so
            // "Review later" resurfaces on a future foreground.
            completePendingVehicleConnectionDecision()
        } catch {
            present(error, .saveChanges)
        }
    }

    private func makeVehicleConflictDecision(
        trip: TripSummary,
        conflictingVehicleIDs: [UUID]
    ) -> PendingVehicleConnectionDecision? {
        var seen = Set<UUID>()
        let activeVehicleIDs = ([trip.vehicleID].compactMap { $0 } + conflictingVehicleIDs)
            .filter { seen.insert($0).inserted && vehicle(for: $0) != nil }
        guard activeVehicleIDs.count > 1 else { return nil }
        return PendingVehicleConnectionDecision(
            tripID: trip.id,
            kind: .conflictingVehicles(
                vehicleIDs: activeVehicleIDs,
                latchedVehicleID: trip.vehicleID
            )
        )
    }

    private func enqueueVehicleConnectionDecision(_ decision: PendingVehicleConnectionDecision) {
        guard pendingVehicleConnectionDecision?.tripID != decision.tripID,
              !queuedVehicleConnectionDecisions.contains(where: { $0.tripID == decision.tripID }) else {
            return
        }
        if sceneIsActive, pendingVehicleConnectionDecision == nil {
            pendingVehicleConnectionDecision = decision
        } else {
            queuedVehicleConnectionDecisions.append(decision)
        }
    }

    private func completePendingVehicleConnectionDecision() {
        pendingVehicleConnectionDecision = nil
        refreshVehicleConnectionSignals()
        refresh()
        // Let SwiftUI finish dismissing the current confirmation dialog before
        // installing the next payload into the same presentation host.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.presentQueuedVehicleConnectionDecisionIfPossible()
        }
    }

    /// Applies Cloud alias reassignments/deletions to this iPhone's private
    /// identifier bindings. Called after remote merges and before route hints
    /// are used, so a deleted vehicle UUID can never latch onto a new drive.
    func reconcileVehicleConnectionMappings() {
        do {
            let changed = try bluetoothHintStore.reconcileLocalBindingsWithAliases()
            guard changed > 0 else { return }
            refreshVehicleConnectionSignals()
        } catch {
            present(error, .saveChanges)
        }
    }

    private func refreshVehicleConnectionSignals() {
        bluetoothSignalService?.refreshHints()
        bluetoothSignalService?.refreshConnectedHints()
    }

    private func hasHandledVehicleConnectionDecision(for tripID: UUID) -> Bool {
        preferences.handledVehicleConnectionTripIDs.contains(tripID)
    }

    private func markVehicleConnectionDecisionHandled(tripID: UUID) {
        var handled = preferences.handledVehicleConnectionTripIDs.filter { $0 != tripID }
        handled.append(tripID)
        preferences.handledVehicleConnectionTripIDs = Array(handled.suffix(256))
        var conflicts = preferences.deferredVehicleConnectionConflicts
        conflicts.removeAll { $0.tripID == tripID }
        preferences.deferredVehicleConnectionConflicts = conflicts
    }

    private func persistDeferredVehicleConflict(_ decision: PendingVehicleConnectionDecision) {
        guard case let .conflictingVehicles(vehicleIDs, latchedVehicleID) = decision.kind else {
            return
        }
        var conflicts = preferences.deferredVehicleConnectionConflicts
            .filter { $0.tripID != decision.tripID }
        conflicts.append(DeferredVehicleConnectionConflict(
            tripID: decision.tripID,
            vehicleIDs: vehicleIDs,
            latchedVehicleID: latchedVehicleID,
            createdAt: Date()
        ))
        preferences.deferredVehicleConnectionConflicts = Array(
            conflicts.sorted { $0.createdAt < $1.createdAt }.suffix(50)
        )
    }

    @discardableResult
    private func recoverDeferredVehicleConflictIfNeeded() -> Bool {
        let handled = Set(preferences.handledVehicleConnectionTripIDs)
        for conflict in preferences.deferredVehicleConnectionConflicts
            .sorted(by: { $0.createdAt < $1.createdAt }) {
            guard !handled.contains(conflict.tripID) else {
                var conflicts = preferences.deferredVehicleConnectionConflicts
                conflicts.removeAll { $0.tripID == conflict.tripID }
                preferences.deferredVehicleConnectionConflicts = conflicts
                continue
            }
            guard let trip = try? tripStore.fetchTrip(id: conflict.tripID) else {
                markVehicleConnectionDecisionHandled(tripID: conflict.tripID)
                continue
            }
            // A later explicit edit resolves the old machine conflict.
            guard trip.vehicleAssignmentSource != .manual else {
                markVehicleConnectionDecisionHandled(tripID: conflict.tripID)
                continue
            }
            var seen = Set<UUID>()
            let validVehicleIDs = conflict.vehicleIDs
                .filter { vehicle(for: $0) != nil && seen.insert($0).inserted }
            guard validVehicleIDs.count > 1 else {
                markVehicleConnectionDecisionHandled(tripID: conflict.tripID)
                continue
            }
            enqueueVehicleConnectionDecision(PendingVehicleConnectionDecision(
                tripID: conflict.tripID,
                kind: .conflictingVehicles(
                    vehicleIDs: validVehicleIDs,
                    latchedVehicleID: conflict.latchedVehicleID.flatMap {
                        validVehicleIDs.contains($0) ? $0 : nil
                    } ?? trip.vehicleID
                )
            ))
            return true
        }
        return false
    }

    private static func vehicleConnectionHintOrder(
        _ lhs: BluetoothDriveHint,
        _ rhs: BluetoothDriveHint
    ) -> Bool {
        let lhsKey = (
            connectionKindPriority(lhs.connectionKind),
            identityQualityPriority(lhs.identityQuality),
            lhs.identifierHash
        )
        let rhsKey = (
            connectionKindPriority(rhs.connectionKind),
            identityQualityPriority(rhs.identityQuality),
            rhs.identifierHash
        )
        return lhsKey < rhsKey
    }

    private static func connectionKindPriority(_ kind: VehicleConnectionKind) -> Int {
        switch kind {
        case .carPlay: 0
        case .bluetooth: 1
        case .unknown: 2
        }
    }

    private static func identityQualityPriority(_ quality: VehicleConnectionIdentityQuality) -> Int {
        switch quality {
        case .stablePortIdentifier: 0
        case .fallbackPortName: 1
        case .unknown: 2
        }
    }
}
