import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

/// Reconciles logical preference keys after CloudKit imports. Core Data's
/// CloudKit integration cannot use a uniqueness constraint here, so two devices
/// may create separate rows for the same key before either sees the other.
public final class PreferenceDuplicateResolver: @unchecked Sendable {
    private let persistence: PersistenceController
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    @discardableResult
    public func reconcile() async throws -> Int {
        try await persistence.performBackgroundTask(name: "PreferenceDuplicateResolver") { context in
            let request = PreferenceEntity.fetchRequest()
            let rows = try context.fetch(request)
            let keyedRows = Dictionary(grouping: rows) { $0.key ?? "" }
            let purposeItemStates = self.mergedItemStates(
                from: keyedRows[BusinessPurposePresetStore.itemStatePreferenceKey] ?? []
            )
            let feePresetItemStates = self.mergedItemStates(
                from: keyedRows[TripFeePresetStore.itemStatePreferenceKey] ?? []
            )
            var deletedCount = 0

            for (key, duplicates) in keyedRows {
                let hasApplicableItemState =
                    (key == BusinessPurposePresetStore.preferenceKey && !purposeItemStates.isEmpty)
                    || (key == TripFeePresetStore.preferenceKey && !feePresetItemStates.isEmpty)
                guard duplicates.count > 1 || hasApplicableItemState else { continue }
                var ordered = duplicates.sorted(by: Self.preferredOrder)
                if key == MileageRateScheduleStore.preferenceKey,
                   let savedIndex = ordered.firstIndex(where: { row in
                       let schedule = row.valueData.flatMap {
                           try? self.decoder.decode(MileageRateSchedule.self, from: $0)
                       }
                       return schedule?.isAutomaticIRSDefault != true && schedule?.requiresCustomRate != true
                   }), savedIndex > 0 {
                    // Preserve the saved row's identity as well as its value.
                    let saved = ordered.remove(at: savedIndex)
                    ordered.insert(saved, at: 0)
                }
                if let winner = ordered.first {
                    try self.mergeMileageRateSchedulesIfNeeded(
                        key: key,
                        orderedRows: ordered,
                        into: winner
                    )
                    try self.mergeListPreferenceIfNeeded(
                        key: key,
                        orderedRows: ordered,
                        into: winner,
                        purposeItemStates: purposeItemStates,
                        feePresetItemStates: feePresetItemStates
                    )
                    try self.mergeItemStatePreferenceIfNeeded(
                        key: key,
                        orderedRows: ordered,
                        into: winner
                    )
                }
                if key.hasPrefix(ReportArtifactCleanupStore.legacyMetadataKeyPrefix + "."),
                   let winner = ordered.first,
                   let winnerMetadata = self.reportMetadata(from: winner) {
                    for duplicate in ordered.dropFirst() {
                        guard let metadata = self.reportMetadata(from: duplicate),
                              metadata.reportID != winnerMetadata.reportID else { continue }
                        let request = ReportSnapshotEntity.fetchRequest()
                        request.predicate = NSPredicate(
                            format: "id == %@",
                            metadata.reportID as CVarArg
                        )
                        for report in try context.fetch(request) {
                            context.delete(report)
                        }
                    }
                }
                for duplicate in ordered.dropFirst() {
                    context.delete(duplicate)
                    deletedCount += 1
                }
            }
            return deletedCount
        }
    }

    private func mergeMileageRateSchedulesIfNeeded(
        key: String,
        orderedRows: [PreferenceEntity],
        into winner: PreferenceEntity
    ) throws {
        guard key == MileageRateScheduleStore.preferenceKey else { return }
        let candidates = orderedRows.map { row in
            (
                row: row,
                schedule: row.valueData.flatMap {
                    try? decoder.decode(MileageRateSchedule.self, from: $0)
                }
            )
        }
        // An automatic first-launch default must yield entirely when saved
        // preferences arrive. Keeping its dated rules would still change a
        // Custom base rate even if the saved source selection won.
        let savedCandidates = candidates.filter { $0.schedule?.isAutomaticIRSDefault != true && $0.schedule?.requiresCustomRate != true }
        let eligible = savedCandidates.isEmpty ? candidates : savedCandidates
        let schedules = eligible.compactMap(\.schedule)
        guard let newest = schedules.first else {
            // An undecodable saved value is still saved data, not permission
            // to replace it with a first-launch default.
            if let saved = eligible.first?.row {
                winner.valueData = saved.valueData
                winner.updatedAt = saved.updatedAt
            }
            return
        }
        // A newer unrelated rule edit must not resurrect a source selection
        // that the user stopped following on another device.
        let selection = schedules.dropFirst().reduce(newest) { selected, candidate in
            (candidate.sourceSelectionUpdatedAt ?? .distantPast)
                > (selected.sourceSelectionUpdatedAt ?? .distantPast) ? candidate : selected
        }

        var rulesByID: [UUID: MileageRateRule] = [:]
        var tombstones: [UUID: Date] = [:]
        for schedule in schedules {
            for (id, date) in schedule.deletedRuleIDs {
                tombstones[id] = max(tombstones[id] ?? .distantPast, date)
            }
            for rule in schedule.rules {
                guard let current = rulesByID[rule.id] else {
                    rulesByID[rule.id] = rule
                    continue
                }
                if rule.updatedAt > current.updatedAt {
                    rulesByID[rule.id] = rule
                }
            }
        }

        let active = rulesByID.values.filter {
            $0.updatedAt > (tombstones[$0.id] ?? .distantPast)
        }
        let byDate = Dictionary(grouping: active, by: \.effectiveFrom)
        var mergedRules: [MileageRateRule] = []
        for candidates in byDate.values {
            let ordered = candidates.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            guard let selected = ordered.first else { continue }
            mergedRules.append(selected)
            for duplicate in ordered.dropFirst() {
                tombstones[duplicate.id] = max(
                    tombstones[duplicate.id] ?? .distantPast,
                    selected.updatedAt
                )
            }
        }

        let merged = try MileageRateScheduleStore.validated(MileageRateSchedule(
            baseRate: newest.baseRate,
            rules: mergedRules,
            deletedRuleIDs: tombstones,
            irsFollowingFrom: selection.irsFollowingFrom,
            sourceSelectionUpdatedAt: selection.sourceSelectionUpdatedAt,
            isAutomaticIRSDefault: selection.isAutomaticIRSDefault,
            requiresCustomRate: selection.requiresCustomRate
        ))
        let current = winner.valueData.flatMap {
            try? decoder.decode(MileageRateSchedule.self, from: $0)
        }
        guard current != merged else { return }
        winner.valueData = try encoder.encode(merged)
        // The discarded default's creation time must not make this saved
        // value outrank a later import of another actual user preference.
        winner.updatedAt = eligible.compactMap { $0.row.updatedAt }.max()
    }

    /// Local-only devices can each create their own row before first sync.
    /// Ordered choice lists are additive data, so retaining only the newest
    /// entire row would silently discard valid choices from the other library.
    /// Newer rows keep ordering and values; choices found only in older rows
    /// are appended before the duplicate rows are removed.
    private func mergeListPreferenceIfNeeded(
        key: String,
        orderedRows: [PreferenceEntity],
        into winner: PreferenceEntity,
        purposeItemStates: [String: SyncedListItemState],
        feePresetItemStates: [String: SyncedListItemState]
    ) throws {
        if key == BusinessPurposePresetStore.preferenceKey {
            var seen = Set<String>()
            var merged: [String] = []
            for row in orderedRows {
                let list = row.valueData.flatMap {
                    try? decoder.decode([String].self, from: $0)
                } ?? []
                for purpose in BusinessPurposePresetStore.normalized(list) {
                    let itemKey = BusinessPurposePresetStore.itemKey(purpose)
                    guard SyncedListItemStateMerge.includes(
                        key: itemKey,
                        listUpdatedAt: row.updatedAt ?? .distantPast,
                        states: purposeItemStates
                    ), seen.insert(itemKey).inserted else {
                        continue
                    }
                    merged.append(purpose)
                }
            }
            let current = winner.valueData.flatMap { try? decoder.decode([String].self, from: $0) }
            guard current != merged else { return }
            winner.valueData = try encoder.encode(merged)
            winner.updatedAt = Date()
            return
        }

        if key == TripFeePresetStore.preferenceKey {
            var seen = Set<String>()
            var merged: [TripFeePreset] = []
            for row in orderedRows {
                let list = row.valueData.flatMap {
                    try? decoder.decode([TripFeePreset].self, from: $0)
                } ?? []
                for preset in TripFeePresetStore.normalized(list) {
                    let itemKey = TripFeePresetStore.itemKey(preset)
                    guard SyncedListItemStateMerge.includes(
                        key: itemKey,
                        listUpdatedAt: row.updatedAt ?? .distantPast,
                        states: feePresetItemStates
                    ), seen.insert(itemKey).inserted else {
                        continue
                    }
                    var orderedPreset = preset
                    orderedPreset.sortOrder = merged.count
                    merged.append(orderedPreset)
                }
            }
            let current = winner.valueData.flatMap { try? decoder.decode([TripFeePreset].self, from: $0) }
            guard current != merged else { return }
            winner.valueData = try encoder.encode(merged)
            winner.updatedAt = Date()
        }
    }

    private func mergeItemStatePreferenceIfNeeded(
        key: String,
        orderedRows: [PreferenceEntity],
        into winner: PreferenceEntity
    ) throws {
        guard key == BusinessPurposePresetStore.itemStatePreferenceKey
            || key == TripFeePresetStore.itemStatePreferenceKey else {
            return
        }
        let merged = mergedItemStates(from: orderedRows)
        let current = winner.valueData.flatMap {
            try? decoder.decode([String: SyncedListItemState].self, from: $0)
        }
        guard current != merged else { return }
        winner.valueData = try encoder.encode(merged)
        winner.updatedAt = Date()
    }

    private func mergedItemStates(
        from rows: [PreferenceEntity]
    ) -> [String: SyncedListItemState] {
        SyncedListItemStateMerge.merged(rows.compactMap { row in
            row.valueData.flatMap {
                try? decoder.decode([String: SyncedListItemState].self, from: $0)
            }
        })
    }

    private static func preferredOrder(_ lhs: PreferenceEntity, _ rhs: PreferenceEntity) -> Bool {
        let lhsDate = lhs.updatedAt ?? .distantPast
        let rhsDate = rhs.updatedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
    }

    /// Legacy canonical-report metadata rows carry a full generation
    /// fingerprint, but duplicate resolution only needs the report identity;
    /// unknown payload fields are ignored.
    private struct LegacyReportMetadata: Decodable {
        var reportID: UUID
    }

    private func reportMetadata(from row: PreferenceEntity) -> LegacyReportMetadata? {
        row.valueData.flatMap { try? decoder.decode(LegacyReportMetadata.self, from: $0) }
    }
}
