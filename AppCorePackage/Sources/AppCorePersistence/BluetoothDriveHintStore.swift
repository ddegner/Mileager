import AppCoreModels
import DriveCaptureEngine
import CoreData
import CryptoKit
import Foundation

public enum BluetoothDriveHintStoreError: Error, LocalizedError {
    case hintNotFound
    case aliasNotFound
    case vehicleNotFound
    case aliasDoesNotMatchHint

    public var errorDescription: String? {
        switch self {
        case .hintNotFound:
            String(localized: "Bluetooth device not found.", bundle: .appCoreStrings)
        case .aliasNotFound:
            String(localized: "Car connection not found.", bundle: .appCoreStrings)
        case .vehicleNotFound:
            String(localized: "Vehicle not found.", bundle: .appCoreStrings)
        case .aliasDoesNotMatchHint:
            String(
                localized: "The suggested car connection no longer matches this device.",
                bundle: .appCoreStrings
            )
        }
    }
}

public final class BluetoothDriveHintStore {
    public static let defaultObservationWindow: TimeInterval = 10 * 60
    /// Forward tolerance when associating observations with a drive start:
    /// the car's route observation often lands seconds AFTER the backdated
    /// trip start. Matches `ParkedStartInference.maximumLeadTime`.
    public static let defaultStartLookahead: TimeInterval = 5 * 60
    public static let defaultObservationRetention: TimeInterval = 7 * 24 * 60 * 60

    private let context: NSManagedObjectContext

    public init(context: NSManagedObjectContext) {
        self.context = context
    }

    @discardableResult
    public func recordObservation(
        identifier: String,
        displayName: String?,
        source: BluetoothSignalSource,
        connectionKind: VehicleConnectionKind = .unknown,
        identityQuality: VehicleConnectionIdentityQuality = .unknown,
        observedAt: Date = Date()
    ) throws -> BluetoothDriveObservation {
        let identifierHash = try Self.hashIdentifier("\(source.rawValue):\(identifier)", salt: salt())
        return try recordHashedObservation(
            identifierHash: identifierHash,
            displayName: displayName,
            source: source,
            connectionKind: connectionKind,
            identityQuality: identityQuality,
            observedAt: observedAt
        )
    }

    @discardableResult
    public func recordHashedObservation(
        identifierHash: String,
        displayName: String?,
        source: BluetoothSignalSource,
        connectionKind: VehicleConnectionKind = .unknown,
        identityQuality: VehicleConnectionIdentityQuality = .unknown,
        observedAt: Date = Date()
    ) throws -> BluetoothDriveObservation {
        try context.saveTransaction {
            _ = try deleteExpiredObservations(now: observedAt)

            let resolvedKind: VehicleConnectionKind = if connectionKind == .unknown,
                                                          source == .blePeripheral {
                .bluetooth
            } else {
                connectionKind
            }

            let hintEntity = try upsertHintEntity(
                identifierHash: identifierHash,
                displayName: displayName,
                source: source,
                connectionKind: resolvedKind,
                identityQuality: identityQuality,
                observedAt: observedAt
            )
            try createAliasForPreviouslyAssignedHintIfPossible(hintEntity, now: observedAt)
            let hint = hintEntity.asHint

            let observation = BluetoothDriveObservation(
                identifierHash: hint.identifierHash,
                displayName: hint.displayName,
                source: hint.source,
                connectionKind: hint.connectionKind,
                identityQuality: hint.identityQuality,
                observedAt: observedAt
            )

            let entity = BluetoothObservationEntity.insert(into: context)
            entity.id = observation.id
            entity.identifierHash = observation.identifierHash
            entity.displayName = observation.displayName
            entity.sourceRaw = observation.source.rawValue
            entity.connectionKindRaw = observation.connectionKind.rawValue
            entity.identityQualityRaw = observation.identityQuality.rawValue
            entity.observedAt = observation.observedAt
            entity.expiresAt = observedAt.addingTimeInterval(Self.defaultObservationRetention)
            return observation
        }
    }

    public func fetchHints() throws -> [BluetoothDriveHint] {
        let request = BluetoothHintEntity.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "trusted", ascending: false),
            NSSortDescriptor(key: "lastSeenAt", ascending: false)
        ]
        return try context.fetch(request).map(\.asHint)
    }

    public func fetchHints(matching identifierHashes: Set<String>) throws -> [BluetoothDriveHint] {
        guard !identifierHashes.isEmpty else { return [] }
        let request = BluetoothHintEntity.fetchRequest()
        request.predicate = NSPredicate(format: "identifierHash IN %@", Array(identifierHashes))
        request.sortDescriptors = [
            NSSortDescriptor(key: "trusted", ascending: false),
            NSSortDescriptor(key: "lastSeenAt", ascending: false)
        ]
        return try context.fetch(request).map(\.asHint)
    }

    /// Connections that still need a user decision. Ignored and repeatedly
    /// rejected (blocked) devices are excluded. Supplying trip-start hashes
    /// narrows this to candidates relevant to a just-saved trip.
    public func fetchReviewCandidates(
        startHintHashes: [String]? = nil
    ) throws -> [BluetoothDriveHint] {
        let hints: [BluetoothDriveHint]
        if let startHintHashes {
            guard !startHintHashes.isEmpty else { return [] }
            hints = try fetchHints(matching: Set(startHintHashes))
        } else {
            hints = try fetchHints()
        }
        return hints
            .filter { Self.needsReview($0) }
            .sorted(by: Self.reviewCandidateOrder)
    }

    /// Links a learned device to a vehicle and, when the connection has a known
    /// kind and display name, creates or updates its Cloud semantic alias.
    /// Passing nil clears the local decision back to unreviewed.
    @discardableResult
    public func assignVehicle(
        identifierHash: String,
        vehicleID: UUID?,
        now: Date = Date()
    ) throws -> BluetoothDriveHint {
        try context.saveTransaction {
            guard let hint = try fetchHintEntity(identifierHash: identifierHash) else {
                throw BluetoothDriveHintStoreError.hintNotFound
            }
            if let vehicleID {
                hint.vehicleID = vehicleID
                hint.mappingDispositionRaw = VehicleConnectionMappingDisposition.assigned.rawValue
                hint.mappingUpdatedAt = now
                // Preserve the historical device-local API's tolerance for a
                // stale synced vehicle ID. Only a currently existing vehicle
                // may produce a new Cloud alias.
                if try vehicleExists(vehicleID) {
                    hint.connectionAliasID = try upsertAlias(
                        for: hint,
                        vehicleID: vehicleID,
                        now: now
                    )?.id
                } else {
                    hint.connectionAliasID = nil
                }
            } else {
                clearMapping(on: hint, disposition: .unreviewed, now: now)
            }
            return hint.asHint
        }
    }

    /// Device-local "Not one of my vehicles" decision. It intentionally does
    /// not create, modify, or delete any Cloud alias.
    @discardableResult
    public func markIgnored(
        identifierHash: String,
        now: Date = Date()
    ) throws -> BluetoothDriveHint {
        try context.saveTransaction {
            guard let hint = try fetchHintEntity(identifierHash: identifierHash) else {
                throw BluetoothDriveHintStoreError.hintNotFound
            }
            clearMapping(on: hint, disposition: .ignored, now: now)
            return hint.asHint
        }
    }

    /// Durable "Ask me later" decision. It is suppressed until this connection
    /// is observed again (normally on a later trip).
    @discardableResult
    public func deferReview(
        identifierHash: String,
        now: Date = Date()
    ) throws -> BluetoothDriveHint {
        try context.saveTransaction {
            guard let hint = try fetchHintEntity(identifierHash: identifierHash) else {
                throw BluetoothDriveHintStoreError.hintNotFound
            }
            // Deferral controls prompting only. Preserve an established
            // fallback-quality mapping and its Cloud alias so "Ask me later"
            // can never silently unlink a vehicle the user already chose.
            hint.mappingDispositionRaw = VehicleConnectionMappingDisposition.deferred.rawValue
            hint.mappingUpdatedAt = max(now, hint.lastSeenAt)
            return hint.asHint
        }
    }

    /// Removes either an assignment or ignore decision so the connection may
    /// be asked about again.
    @discardableResult
    public func clearVehicleAssignment(
        identifierHash: String,
        now: Date = Date()
    ) throws -> BluetoothDriveHint {
        try assignVehicle(identifierHash: identifierHash, vehicleID: nil, now: now)
    }

    /// Cloud aliases, optionally filtered to one vehicle. Duplicate Cloud rows
    /// are collapsed by logical ID so callers see the newest copy.
    public func fetchConnectionAliases(vehicleID: UUID? = nil) throws -> [VehicleConnectionAlias] {
        let request = VehicleConnectionAliasEntity.fetchRequest()
        return preferredAliases(from: try context.fetch(request))
            .compactMap(\.asConnectionAlias)
            .filter { vehicleID == nil || $0.vehicleID == vehicleID }
            .sorted(by: Self.aliasDisplayOrder)
    }

    /// Reassigns a synced alias even when this phone has not yet bound a local
    /// connection to it. Local bindings on this phone follow the reassignment.
    @discardableResult
    public func assignConnectionAlias(
        id: UUID,
        vehicleID: UUID,
        now: Date = Date()
    ) throws -> VehicleConnectionAlias {
        try context.saveTransaction {
            guard try vehicleExists(vehicleID) else {
                throw BluetoothDriveHintStoreError.vehicleNotFound
            }
            let aliases = try fetchAliasEntities(id: id)
            guard let alias = aliases.first else {
                throw BluetoothDriveHintStoreError.aliasNotFound
            }
            guard let source = alias.asConnectionAlias else {
                throw BluetoothDriveHintStoreError.aliasNotFound
            }

            let allEntities = try context.fetch(VehicleConnectionAliasEntity.fetchRequest())
            let normalizedName = Self.normalizedConnectionName(source.displayName)
            let semanticTargetAliases = preferredAliases(from: allEntities).filter {
                $0.id != id
                    && $0.vehicleID == vehicleID
                    && VehicleConnectionKind(rawValue: $0.connectionKindRaw) == source.connectionKind
                    && Self.normalizedConnectionName($0.displayName) == normalizedName
            }
            let semanticIDs = Set([id] + semanticTargetAliases.compactMap(\.id))
            let canonicalID = semanticIDs.min { $0.uuidString < $1.uuidString } ?? id
            guard let canonical = allEntities
                .filter({ $0.id == canonicalID })
                .sorted(by: Self.prefersAlias)
                .first else {
                throw BluetoothDriveHintStoreError.aliasNotFound
            }

            for entity in allEntities
            where entity.id.map(semanticIDs.contains) == true && entity.objectID != canonical.objectID {
                context.delete(entity)
            }
            canonical.vehicleID = vehicleID
            canonical.displayName = source.displayName
            canonical.connectionKindRaw = source.connectionKind.rawValue
            canonical.createdAt = ([source.createdAt, canonical.createdAt].compactMap { $0 }).min() ?? now
            canonical.updatedAt = now
            _ = try rebindLocalHints(
                aliasIDs: semanticIDs,
                to: canonicalID,
                vehicleID: vehicleID,
                disposition: .assigned,
                now: now
            )
            guard let result = canonical.asConnectionAlias else {
                throw BluetoothDriveHintStoreError.aliasNotFound
            }
            return result
        }
    }

    /// Finds a portable semantic match by normalized display name and kind.
    /// Conflicting aliases for different vehicles intentionally produce no
    /// suggestion. This method never changes the local mapping.
    public func suggestedAlias(for identifierHash: String) throws -> VehicleConnectionSuggestion? {
        guard let hint = try fetchHintEntity(identifierHash: identifierHash) else {
            throw BluetoothDriveHintStoreError.hintNotFound
        }
        let domainHint = hint.asHint
        guard Self.needsReview(domainHint),
              domainHint.connectionKind.isKnown,
              let normalizedName = Self.normalizedConnectionName(domainHint.displayName) else {
            return nil
        }

        let existingVehicleIDs = Set(try context.fetch(VehicleEntity.fetchRequest()).compactMap(\.id))
        let matching = preferredAliases(from: try context.fetch(VehicleConnectionAliasEntity.fetchRequest()))
            .compactMap(\.asConnectionAlias)
            .filter {
                $0.connectionKind == domainHint.connectionKind
                    && Self.normalizedConnectionName($0.displayName) == normalizedName
            }
            .filter { existingVehicleIDs.contains($0.vehicleID) }

        let vehicleIDs = Set(matching.map(\.vehicleID))
        guard vehicleIDs.count == 1,
              let alias = matching.max(by: Self.olderAlias) else {
            return nil
        }
        return VehicleConnectionSuggestion(alias: alias)
    }

    /// Binds a synced suggestion only after explicit user confirmation.
    @discardableResult
    public func confirmSuggestion(
        identifierHash: String,
        aliasID: UUID,
        now: Date = Date()
    ) throws -> BluetoothDriveHint {
        try context.saveTransaction {
            guard let hint = try fetchHintEntity(identifierHash: identifierHash) else {
                throw BluetoothDriveHintStoreError.hintNotFound
            }
            guard let aliasEntity = try preferredAliasEntity(id: aliasID),
                  let alias = aliasEntity.asConnectionAlias else {
                throw BluetoothDriveHintStoreError.aliasNotFound
            }
            guard Self.needsReview(hint.asHint),
                  hint.asHint.connectionKind == alias.connectionKind,
                  Self.normalizedConnectionName(hint.displayName)
                    == Self.normalizedConnectionName(alias.displayName) else {
                throw BluetoothDriveHintStoreError.aliasDoesNotMatchHint
            }
            guard try vehicleExists(alias.vehicleID) else {
                throw BluetoothDriveHintStoreError.vehicleNotFound
            }

            hint.vehicleID = alias.vehicleID
            hint.connectionAliasID = alias.id
            hint.mappingDispositionRaw = VehicleConnectionMappingDisposition.assigned.rawValue
            hint.mappingUpdatedAt = now
            return hint.asHint
        }
    }

    @discardableResult
    public func resolveVehicleChoice<T>(
        identifierHash: String,
        vehicleID: UUID,
        suggestedAliasID: UUID? = nil,
        now: Date = Date(),
        additionalMutation: () throws -> T
    ) throws -> (hint: BluetoothDriveHint, result: T) {
        try context.saveTransaction {
            guard let hint = try fetchHintEntity(identifierHash: identifierHash) else {
                throw BluetoothDriveHintStoreError.hintNotFound
            }
            guard try vehicleExists(vehicleID) else {
                throw BluetoothDriveHintStoreError.vehicleNotFound
            }

            var usedSuggestedAlias = false
            if let suggestedAliasID,
               let aliasEntity = try preferredAliasEntity(id: suggestedAliasID),
               let alias = aliasEntity.asConnectionAlias,
               alias.vehicleID == vehicleID,
               hint.asHint.connectionKind == alias.connectionKind,
               Self.normalizedConnectionName(hint.displayName)
                    == Self.normalizedConnectionName(alias.displayName) {
                hint.vehicleID = alias.vehicleID
                hint.connectionAliasID = alias.id
                hint.mappingDispositionRaw = VehicleConnectionMappingDisposition.assigned.rawValue
                hint.mappingUpdatedAt = now
                usedSuggestedAlias = true
            }

            if !usedSuggestedAlias {
                hint.vehicleID = vehicleID
                hint.mappingDispositionRaw = VehicleConnectionMappingDisposition.assigned.rawValue
                hint.mappingUpdatedAt = now
                hint.connectionAliasID = try upsertAlias(
                    for: hint,
                    vehicleID: vehicleID,
                    now: now
                )?.id
            }

            let result = try additionalMutation()
            return (hint.asHint, result)
        }
    }

    /// Reconciles this device's private identifier bindings with the latest
    /// Cloud aliases after a remote-store merge. Alias reassignment follows the
    /// synced vehicle choice; an alias or vehicle deleted elsewhere returns the
    /// local connection to unreviewed instead of allowing a stale UUID to latch
    /// onto a future drive. Legacy mappings without an alias remain valid while
    /// their vehicle still exists.
    @discardableResult
    public func reconcileLocalBindingsWithAliases(now: Date = Date()) throws -> Int {
        guard PersistenceController.hasLoadedStore(
            configurationName: PersistenceController.localConfigurationName,
            in: context
        ) else {
            return 0
        }

        return try context.saveTransaction {
            let vehicleIDs = Set(try context.fetch(VehicleEntity.fetchRequest()).compactMap(\.id))
            var changed = try collapseSemanticAliasDuplicates(now: now)
            let aliasesByID = Dictionary(
                uniqueKeysWithValues: preferredAliases(
                    from: try context.fetch(VehicleConnectionAliasEntity.fetchRequest())
                ).compactMap { entity -> (UUID, VehicleConnectionAlias)? in
                    guard let alias = entity.asConnectionAlias else { return nil }
                    return (alias.id, alias)
                }
            )

            for hint in try context.fetch(BluetoothHintEntity.fetchRequest())
            where hint.asHint.mappingDisposition == .assigned
                || hint.asHint.mappingDisposition == .deferred {
                if let aliasID = hint.connectionAliasID {
                    if let alias = aliasesByID[aliasID],
                       vehicleIDs.contains(alias.vehicleID) {
                        if hint.vehicleID != alias.vehicleID {
                            hint.vehicleID = alias.vehicleID
                            hint.mappingUpdatedAt = now
                            changed += 1
                        }
                        continue
                    }
                    if let replacement = uniqueSemanticAlias(for: hint, among: Array(aliasesByID.values)) {
                        hint.connectionAliasID = replacement.id
                        hint.vehicleID = replacement.vehicleID
                        hint.mappingUpdatedAt = now
                        changed += 1
                    } else {
                        clearMapping(on: hint, disposition: .unreviewed, now: now)
                        changed += 1
                    }
                } else if let vehicleID = hint.vehicleID,
                          !vehicleIDs.contains(vehicleID) {
                    clearMapping(on: hint, disposition: .unreviewed, now: now)
                    changed += 1
                }
            }
            return changed
        }
    }

    /// Deletes a Cloud alias and returns every local binding to unreviewed. A
    /// Cloud-only context (the Mac app) simply performs the alias deletion.
    @discardableResult
    public func deleteConnectionAlias(id: UUID, now: Date = Date()) throws -> Int {
        try context.saveTransaction {
            let aliases = try fetchAliasEntities(id: id)
            guard !aliases.isEmpty else { throw BluetoothDriveHintStoreError.aliasNotFound }
            aliases.forEach(context.delete)

            var unlinkedCount = 0
            if PersistenceController.hasLoadedStore(
                configurationName: PersistenceController.localConfigurationName,
                in: context
            ) {
                let request = BluetoothHintEntity.fetchRequest()
                request.predicate = NSPredicate(format: "connectionAliasID == %@", id as CVarArg)
                let hints = try context.fetch(request)
                for hint in hints {
                    clearMapping(on: hint, disposition: .unreviewed, now: now)
                }
                unlinkedCount = Set(hints.map(\.identifierHash)).count
            }
            return unlinkedCount
        }
    }

    public func trustedVehicleHint(now: Date = Date(), within interval: TimeInterval = defaultObservationWindow) throws -> Bool {
        let trustedHashes = Set(try fetchHints()
            .filter { $0.trusted && $0.contributesDriveDetection }
            .map(\.identifierHash))
        guard !trustedHashes.isEmpty else { return false }

        let request = BluetoothObservationEntity.fetchRequest()
        request.predicate = NSPredicate(
            format: "observedAt >= %@ AND observedAt <= %@",
            now.addingTimeInterval(-interval) as NSDate,
            now as NSDate
        )
        return try context.fetch(request).contains { trustedHashes.contains($0.identifierHash) }
    }

    /// Observations recorded within `window` before `date` or `lookahead`
    /// after it, deduplicated by device. Used to associate a finished drive
    /// with the devices present at its start; the lookahead covers routes
    /// observed just after a backdated start.
    public func observations(
        near date: Date,
        window: TimeInterval = defaultObservationWindow,
        lookahead: TimeInterval = defaultStartLookahead
    ) throws -> [BluetoothDriveObservation] {
        let request = BluetoothObservationEntity.fetchRequest()
        request.predicate = NSPredicate(
            format: "observedAt >= %@ AND observedAt <= %@",
            date.addingTimeInterval(-window) as NSDate,
            date.addingTimeInterval(lookahead) as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "observedAt", ascending: true)]

        var seenHashes: Set<String> = []
        return try context.fetch(request).compactMap { observation in
            guard seenHashes.insert(observation.identifierHash).inserted else { return nil }
            return BluetoothDriveObservation(
                id: observation.id,
                identifierHash: observation.identifierHash,
                displayName: observation.displayName,
                source: BluetoothSignalSource(rawValue: observation.sourceRaw) ?? .audioRoute,
                connectionKind: VehicleConnectionKind(rawValue: observation.connectionKindRaw) ?? .unknown,
                identityQuality: VehicleConnectionIdentityQuality(rawValue: observation.identityQualityRaw) ?? .unknown,
                observedAt: observation.observedAt
            )
        }
    }

    /// Applies a review decision to the hints behind `identifierHashes`,
    /// adjusting positive/negative evidence and recomputing trust. Hashes with
    /// no matching hint (forgotten, or stamped on another device) are skipped.
    @discardableResult
    public func applyReviewOutcome(
        identifierHashes: [String],
        outcome: VehicleReviewOutcome,
        policy: VehicleTrustPolicy = VehicleTrustPolicy()
    ) throws -> [BluetoothDriveHint] {
        guard !identifierHashes.isEmpty else { return [] }

        return try context.saveTransaction {
            var updated: [BluetoothDriveHint] = []
            for identifierHash in Set(identifierHashes) {
                guard let hint = try fetchHintEntity(identifierHash: identifierHash) else { continue }
                switch outcome {
                case .confirmedDrive:
                    hint.correlationCount += 1
                case .notADrive:
                    hint.notADriveCount += 1
                case .undoConfirmedDrive:
                    hint.correlationCount = max(0, hint.correlationCount - 1)
                case .undoNotADrive:
                    hint.notADriveCount = max(0, hint.notADriveCount - 1)
                }
                hint.trusted = policy.isTrusted(
                    confirmed: Int(hint.correlationCount),
                    notADrive: Int(hint.notADriveCount),
                    displayName: hint.displayName
                )
                updated.append(hint.asHint)
            }
            return updated
        }
    }

    /// One-time conversion of manual trust overrides from the removed Trusted
    /// Vehicles settings UI into counter seeds the learned policy understands,
    /// followed by a trust recompute for every hint under the new policy.
    public func migrateManualTrustOverridesIfNeeded(policy: VehicleTrustPolicy = VehicleTrustPolicy()) throws {
        let migrationKey = "trustMigrationV1"
        guard try BluetoothMetadataEntity.fetchOne(
            in: context,
            where: NSPredicate(format: "key == %@", migrationKey)
        ) == nil else { return }

        try context.saveTransaction {
            for hint in try context.fetch(BluetoothHintEntity.fetchRequest()) {
                if let override = hint.manualTrustOverride?.boolValue {
                    if override {
                        let threshold = Int64(VehicleTrustPolicy.trustThreshold(displayName: hint.displayName))
                        hint.correlationCount = max(hint.correlationCount, threshold)
                    } else {
                        hint.notADriveCount = max(2, hint.correlationCount)
                    }
                    hint.manualTrustOverride = nil
                }
                hint.trusted = policy.isTrusted(
                    confirmed: Int(hint.correlationCount),
                    notADrive: Int(hint.notADriveCount),
                    displayName: hint.displayName
                )
            }

            let marker = BluetoothMetadataEntity.insert(into: context)
            marker.key = migrationKey
            marker.value = "done"
        }
    }

    @discardableResult
    public func purgeExpiredObservations(now: Date = Date()) throws -> Int {
        try context.saveTransaction {
            try deleteExpiredObservations(now: now)
        }
    }

    @discardableResult
    private func deleteExpiredObservations(now: Date = Date()) throws -> Int {
        let request = BluetoothObservationEntity.fetchRequest()
        request.predicate = NSPredicate(format: "expiresAt < %@", now as NSDate)
        let expired = try context.fetch(request)
        expired.forEach(context.delete)
        return expired.count
    }

    public static func hashIdentifier(_ identifier: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data("\(salt):\(identifier)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private

    private func salt() throws -> String {
        if let existing = try BluetoothMetadataEntity.fetchOne(
            in: context,
            where: NSPredicate(format: "key == %@", "salt")
        ) {
            return existing.value
        }
        let value = UUID().uuidString
        let entity = BluetoothMetadataEntity.insert(into: context)
        entity.key = "salt"
        entity.value = value
        return value
    }

    private func upsertHintEntity(
        identifierHash: String,
        displayName: String?,
        source: BluetoothSignalSource,
        connectionKind: VehicleConnectionKind,
        identityQuality: VehicleConnectionIdentityQuality,
        observedAt: Date
    ) throws -> BluetoothHintEntity {
        let hint = try fetchHintEntity(identifierHash: identifierHash) ?? insertHintEntity(
            identifierHash: identifierHash,
            displayName: displayName,
            source: source,
            connectionKind: connectionKind,
            identityQuality: identityQuality,
            observedAt: observedAt
        )
        if let displayName, !displayName.isEmpty {
            hint.displayName = displayName
        }
        hint.sourceRaw = source.rawValue
        if connectionKind.isKnown {
            hint.connectionKindRaw = connectionKind.rawValue
        }
        if identityQuality != .unknown {
            hint.identityQualityRaw = identityQuality.rawValue
        }
        hint.lastSeenAt = observedAt
        // A vehicleID predating the connection schema is already an explicit
        // user decision. Preserve it as assigned during lightweight migration.
        if hint.vehicleID != nil,
           hint.mappingDispositionRaw == VehicleConnectionMappingDisposition.unreviewed.rawValue {
            hint.mappingDispositionRaw = VehicleConnectionMappingDisposition.assigned.rawValue
        }
        return hint
    }

    private func insertHintEntity(
        identifierHash: String,
        displayName: String?,
        source: BluetoothSignalSource,
        connectionKind: VehicleConnectionKind,
        identityQuality: VehicleConnectionIdentityQuality,
        observedAt: Date
    ) -> BluetoothHintEntity {
        let hint = BluetoothHintEntity.insert(into: context)
        hint.id = UUID()
        hint.identifierHash = identifierHash
        hint.displayName = displayName
        hint.sourceRaw = source.rawValue
        hint.firstSeenAt = observedAt
        hint.lastSeenAt = observedAt
        hint.correlationCount = 0
        hint.notADriveCount = 0
        hint.trusted = false
        hint.manualTrustOverride = nil
        hint.vehicleID = nil
        hint.connectionAliasID = nil
        hint.connectionKindRaw = connectionKind.rawValue
        hint.mappingDispositionRaw = VehicleConnectionMappingDisposition.unreviewed.rawValue
        hint.mappingUpdatedAt = nil
        hint.identityQualityRaw = identityQuality.rawValue
        return hint
    }

    private func fetchHintEntity(identifierHash: String) throws -> BluetoothHintEntity? {
        try BluetoothHintEntity.fetchOne(
            in: context,
            where: NSPredicate(format: "identifierHash == %@", identifierHash)
        )
    }

    private func createAliasForPreviouslyAssignedHintIfPossible(
        _ hint: BluetoothHintEntity,
        now: Date
    ) throws {
        guard hint.connectionAliasID == nil,
              let vehicleID = hint.vehicleID,
              hint.asHint.connectionKind.isKnown,
              try vehicleExists(vehicleID) else {
            return
        }
        hint.connectionAliasID = try upsertAlias(for: hint, vehicleID: vehicleID, now: now)?.id
    }

    private func upsertAlias(
        for hint: BluetoothHintEntity,
        vehicleID: UUID,
        now: Date
    ) throws -> VehicleConnectionAlias? {
        let kind = hint.asHint.connectionKind
        guard kind.isKnown,
              let displayName = Self.trimmedConnectionName(hint.displayName) else {
            return nil
        }

        let aliasEntity: VehicleConnectionAliasEntity
        if let aliasID = hint.connectionAliasID,
           let existing = try preferredAliasEntity(id: aliasID) {
            aliasEntity = existing
        } else {
            let normalizedName = Self.normalizedConnectionName(displayName)
            let matching = preferredAliases(
                from: try context.fetch(VehicleConnectionAliasEntity.fetchRequest())
            ).first {
                $0.vehicleID == vehicleID
                    && VehicleConnectionKind(rawValue: $0.connectionKindRaw) == kind
                    && Self.normalizedConnectionName($0.displayName) == normalizedName
            }
            if let matching {
                aliasEntity = matching
            } else {
                aliasEntity = VehicleConnectionAliasEntity.insert(into: context)
                aliasEntity.id = UUID()
                aliasEntity.createdAt = now
            }
        }

        aliasEntity.vehicleID = vehicleID
        aliasEntity.displayName = displayName
        aliasEntity.connectionKindRaw = kind.rawValue
        aliasEntity.updatedAt = now
        if aliasEntity.createdAt == nil { aliasEntity.createdAt = now }
        return aliasEntity.asConnectionAlias
    }

    private func clearMapping(
        on hint: BluetoothHintEntity,
        disposition: VehicleConnectionMappingDisposition,
        now: Date
    ) {
        hint.vehicleID = nil
        hint.connectionAliasID = nil
        hint.mappingDispositionRaw = disposition.rawValue
        // A route observation can occasionally arrive with a clock value just
        // ahead of `Date()` (or a test/import can carry a future timestamp).
        // Anchor the decision at least as late as that observation so
        // "Ask me later" stays suppressed until the connection is genuinely
        // seen again.
        hint.mappingUpdatedAt = max(now, hint.lastSeenAt)
    }

    private func vehicleExists(_ id: UUID) throws -> Bool {
        try VehicleEntity.fetchOne(
            in: context,
            where: NSPredicate(format: "id == %@", id as CVarArg)
        ) != nil
    }

    private func fetchAliasEntities(id: UUID) throws -> [VehicleConnectionAliasEntity] {
        let request = VehicleConnectionAliasEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request).sorted { Self.prefersAlias($0, over: $1) }
    }

    private func preferredAliasEntity(id: UUID) throws -> VehicleConnectionAliasEntity? {
        try fetchAliasEntities(id: id).first
    }

    private func preferredAliases(
        from entities: [VehicleConnectionAliasEntity]
    ) -> [VehicleConnectionAliasEntity] {
        var result: [UUID: VehicleConnectionAliasEntity] = [:]
        for entity in entities {
            guard let id = entity.id else { continue }
            if let current = result[id] {
                if Self.prefersAlias(entity, over: current) { result[id] = entity }
            } else {
                result[id] = entity
            }
        }
        return Array(result.values)
    }

    /// Converges distinct Cloud rows that represent the same approved semantic
    /// connection on one vehicle. The lowest UUID is the deterministic survivor
    /// on every device; local private bindings follow it before loser rows are
    /// deleted from CloudKit.
    private func collapseSemanticAliasDuplicates(now: Date) throws -> Int {
        let allEntities = try context.fetch(VehicleConnectionAliasEntity.fetchRequest())
        let logicalAliases = preferredAliases(from: allEntities)
        var groups: [AliasSemanticKey: [VehicleConnectionAliasEntity]] = [:]
        for alias in logicalAliases {
            guard let vehicleID = alias.vehicleID,
                  let normalizedName = Self.normalizedConnectionName(alias.displayName) else {
                continue
            }
            let key = AliasSemanticKey(
                vehicleID: vehicleID,
                connectionKindRaw: alias.connectionKindRaw,
                normalizedName: normalizedName
            )
            groups[key, default: []].append(alias)
        }

        var changed = 0
        for (key, logicalGroup) in groups where logicalGroup.count > 1 {
            let ids = Set(logicalGroup.compactMap(\.id))
            guard let canonicalID = ids.min(by: { $0.uuidString < $1.uuidString }),
                  let canonical = allEntities
                    .filter({ $0.id == canonicalID })
                    .sorted(by: Self.prefersAlias)
                    .first else {
                continue
            }
            let groupEntities = allEntities.filter { entity in
                guard let id = entity.id else { return false }
                return ids.contains(id)
            }
            let earliestCreatedAt = groupEntities.compactMap(\.createdAt).min()
            let latestUpdatedAt = groupEntities.compactMap(\.updatedAt).max()
            for entity in groupEntities where entity.objectID != canonical.objectID {
                context.delete(entity)
                changed += 1
            }
            canonical.vehicleID = key.vehicleID
            canonical.connectionKindRaw = key.connectionKindRaw
            canonical.createdAt = earliestCreatedAt ?? canonical.createdAt ?? now
            canonical.updatedAt = latestUpdatedAt ?? canonical.updatedAt ?? now
            changed += try rebindLocalHints(
                aliasIDs: ids,
                to: canonicalID,
                vehicleID: key.vehicleID,
                disposition: nil,
                now: now
            )
        }
        return changed
    }

    private func rebindLocalHints(
        aliasIDs: Set<UUID>,
        to canonicalID: UUID,
        vehicleID: UUID,
        disposition: VehicleConnectionMappingDisposition?,
        now: Date
    ) throws -> Int {
        guard !aliasIDs.isEmpty,
              PersistenceController.hasLoadedStore(
                configurationName: PersistenceController.localConfigurationName,
                in: context
              ) else {
            return 0
        }
        let request = BluetoothHintEntity.fetchRequest()
        request.predicate = NSPredicate(format: "connectionAliasID IN %@", Array(aliasIDs))
        var changed = 0
        for hint in try context.fetch(request) {
            let nextDisposition = disposition?.rawValue ?? hint.mappingDispositionRaw
            guard hint.connectionAliasID != canonicalID
                    || hint.vehicleID != vehicleID
                    || hint.mappingDispositionRaw != nextDisposition else {
                continue
            }
            hint.connectionAliasID = canonicalID
            hint.vehicleID = vehicleID
            hint.mappingDispositionRaw = nextDisposition
            hint.mappingUpdatedAt = now
            changed += 1
        }
        return changed
    }

    private func uniqueSemanticAlias(
        for hint: BluetoothHintEntity,
        among aliases: [VehicleConnectionAlias]
    ) -> VehicleConnectionAlias? {
        let domainHint = hint.asHint
        guard domainHint.connectionKind.isKnown,
              let normalizedName = Self.normalizedConnectionName(domainHint.displayName) else {
            return nil
        }
        let matches = aliases.filter {
            $0.connectionKind == domainHint.connectionKind
                && Self.normalizedConnectionName($0.displayName) == normalizedName
        }
        guard Set(matches.map(\.vehicleID)).count == 1 else { return nil }
        return matches.sorted { $0.id.uuidString < $1.id.uuidString }.first
    }

    private struct AliasSemanticKey: Hashable {
        var vehicleID: UUID
        var connectionKindRaw: String
        var normalizedName: String
    }

    private static func prefersAlias(
        _ lhs: VehicleConnectionAliasEntity,
        over rhs: VehicleConnectionAliasEntity
    ) -> Bool {
        let lhsDate = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
        let rhsDate = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.objectID.uriRepresentation().absoluteString
            < rhs.objectID.uriRepresentation().absoluteString
    }

    private static func olderAlias(_ lhs: VehicleConnectionAlias, _ rhs: VehicleConnectionAlias) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    private static func aliasDisplayOrder(_ lhs: VehicleConnectionAlias, _ rhs: VehicleConnectionAlias) -> Bool {
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        if lhs.connectionKind != rhs.connectionKind {
            return lhs.connectionKind.rawValue < rhs.connectionKind.rawValue
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func reviewCandidateOrder(_ lhs: BluetoothDriveHint, _ rhs: BluetoothDriveHint) -> Bool {
        if lhs.connectionKind.isKnown != rhs.connectionKind.isKnown {
            return lhs.connectionKind.isKnown
        }
        if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
        return lhs.identifierHash < rhs.identifierHash
    }

    private static func needsReview(_ hint: BluetoothDriveHint) -> Bool {
        guard !hint.blocked else { return false }
        switch hint.mappingDisposition {
        case .unreviewed:
            return true
        case .deferred:
            guard let deferredAt = hint.mappingUpdatedAt else { return true }
            return hint.lastSeenAt > deferredAt
        case .assigned:
            return !hint.canIdentifyVehicleSilently
        case .ignored:
            return false
        }
    }

    private static func trimmedConnectionName(_ name: String?) -> String? {
        guard let value = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static func normalizedConnectionName(_ name: String?) -> String? {
        guard let trimmed = trimmedConnectionName(name) else { return nil }
        return trimmed
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

extension BluetoothHintEntity {
    var asHint: BluetoothDriveHint {
        BluetoothDriveHint(
            id: id,
            identifierHash: identifierHash,
            displayName: displayName,
            source: BluetoothSignalSource(rawValue: sourceRaw) ?? .audioRoute,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            correlationCount: Int(correlationCount),
            notADriveCount: Int(notADriveCount),
            trusted: trusted,
            manualTrustOverride: manualTrustOverride?.boolValue,
            vehicleID: vehicleID,
            connectionAliasID: connectionAliasID,
            connectionKind: VehicleConnectionKind(rawValue: connectionKindRaw) ?? .unknown,
            identityQuality: VehicleConnectionIdentityQuality(rawValue: identityQualityRaw) ?? .unknown,
            mappingDisposition: VehicleConnectionMappingDisposition(rawValue: mappingDispositionRaw) ?? .unreviewed,
            mappingUpdatedAt: mappingUpdatedAt
        )
    }
}

extension VehicleConnectionAliasEntity {
    var asConnectionAlias: VehicleConnectionAlias? {
        guard let id,
              let vehicleID,
              let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty,
              let kind = VehicleConnectionKind(rawValue: connectionKindRaw),
              kind.isKnown else {
            return nil
        }
        let fallbackDate = updatedAt ?? createdAt ?? .distantPast
        return VehicleConnectionAlias(
            id: id,
            vehicleID: vehicleID,
            displayName: displayName,
            connectionKind: kind,
            createdAt: createdAt ?? fallbackDate,
            updatedAt: updatedAt ?? fallbackDate
        )
    }
}
