import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

@MainActor
final class PreferenceDuplicateResolverTests: XCTestCase {
    func testReconcileMergesPurposeListsUsingNewestOrderAndStableUUIDTieBreak() async throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        let key = BusinessPurposePresetStore.preferenceKey
        let newestDate = Date(timeIntervalSince1970: 1_800_200_000)

        try insertPreference(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            key: key,
            purposes: ["Old"],
            updatedAt: newestDate.addingTimeInterval(-60),
            in: context
        )
        try insertPreference(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            key: key,
            purposes: ["Tie loser"],
            updatedAt: newestDate,
            in: context
        )
        try insertPreference(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            key: key,
            purposes: ["Client meeting", "Site visit"],
            updatedAt: newestDate,
            in: context
        )
        try context.save()

        let deleted = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()

        XCTAssertEqual(deleted, 2)
        XCTAssertEqual(
            try BusinessPurposePresetStore(context: context).fetchPurposes(),
            ["Client meeting", "Site visit", "Tie loser", "Old"]
        )
        let request = NSFetchRequest<NSManagedObject>(entityName: "PreferenceEntity")
        request.predicate = NSPredicate(format: "key == %@", key)
        XCTAssertEqual(try context.count(for: request), 1)
    }

    func testReconcileMergesFeePresetListsAndKeepsNewerDuplicateValue() async throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        let key = TripFeePresetStore.preferenceKey
        let now = Date(timeIntervalSince1970: 1_800_250_000)
        let parkingID = UUID()
        let newerTollID = UUID()

        try insertPreference(
            id: UUID(),
            key: key,
            value: [
                TripFeePreset(
                    id: UUID(),
                    category: .toll,
                    label: "Bridge",
                    amount: 4,
                    sortOrder: 0
                ),
                TripFeePreset(
                    id: parkingID,
                    category: .parking,
                    label: "Garage",
                    amount: 12,
                    sortOrder: 1
                )
            ],
            updatedAt: now.addingTimeInterval(-60),
            in: context
        )
        try insertPreference(
            id: UUID(),
            key: key,
            value: [
                TripFeePreset(
                    id: newerTollID,
                    category: .toll,
                    label: "Bridge",
                    amount: 5,
                    sortOrder: 0
                )
            ],
            updatedAt: now,
            in: context
        )
        try context.save()

        let deleted = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()
        XCTAssertEqual(deleted, 1)
        let presets = try TripFeePresetStore(context: context).fetchPresets()
        XCTAssertEqual(presets.map(\.label), ["Bridge", "Garage"])
        XCTAssertEqual(presets.map(\.amount), [5, 12])
        XCTAssertEqual(presets.map(\.id), [newerTollID, parkingID])
    }

    func testPurposeDeletionIsNotResurrectedByAnOlderDuplicateList() async throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        let store = BusinessPurposePresetStore(context: context)
        _ = try store.savePurposes(["Client meeting", "Site visit"])
        _ = try store.savePurposes(["Client meeting"])
        try insertPreference(
            id: UUID(),
            key: BusinessPurposePresetStore.preferenceKey,
            purposes: ["Site visit", "Vendor pickup"],
            updatedAt: .distantPast,
            in: context
        )
        try context.save()

        _ = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()

        XCTAssertEqual(try store.fetchPurposes(), ["Client meeting", "Vendor pickup"])
    }

    func testNewerLegacyPurposeListCanExplicitlyReAddADeletedChoice() async throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        let store = BusinessPurposePresetStore(context: context)
        _ = try store.savePurposes(["Client meeting", "Site visit"])
        _ = try store.savePurposes(["Client meeting"])
        try insertPreference(
            id: UUID(),
            key: BusinessPurposePresetStore.preferenceKey,
            purposes: ["Site visit"],
            updatedAt: Date().addingTimeInterval(3_600),
            in: context
        )
        try context.save()

        _ = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()
        _ = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()

        XCTAssertEqual(try store.fetchPurposes(), ["Site visit", "Client meeting"])
    }

    func testFeePresetDeletionSuppressesAnOlderSameLabelWithDifferentIdentity() async throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        let store = TripFeePresetStore(context: context)
        let bridge = TripFeePreset(
            category: .toll,
            label: "Bridge",
            amount: 7.50,
            sortOrder: 0
        )
        let garage = TripFeePreset(
            category: .parking,
            label: "Garage",
            amount: 12,
            sortOrder: 1
        )
        _ = try store.savePresets([bridge, garage])
        _ = try store.savePresets([garage])
        try insertPreference(
            id: UUID(),
            key: TripFeePresetStore.preferenceKey,
            value: [
                TripFeePreset(
                    id: UUID(),
                    category: .toll,
                    label: "Bridge",
                    amount: 6,
                    sortOrder: 0
                ),
                TripFeePreset(
                    category: .parking,
                    label: "Lot",
                    amount: 4,
                    sortOrder: 1
                )
            ],
            updatedAt: .distantPast,
            in: context
        )
        try context.save()

        _ = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()

        let presets = try store.fetchPresets()
        XCTAssertEqual(presets.map(\.label), ["Garage", "Lot"])
        XCTAssertEqual(presets.map(\.sortOrder), [0, 1])
    }

    func testSinglePurposeRowStillAppliesANewerDeletionState() async throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        let now = Date(timeIntervalSince1970: 1_800_275_000)
        try insertPreference(
            id: UUID(),
            key: BusinessPurposePresetStore.preferenceKey,
            purposes: ["Site visit"],
            updatedAt: now,
            in: context
        )
        try insertPreference(
            id: UUID(),
            key: BusinessPurposePresetStore.itemStatePreferenceKey,
            value: [
                BusinessPurposePresetStore.itemKey("Site visit"): SyncedListItemState(
                    isDeleted: true,
                    updatedAt: now.addingTimeInterval(60)
                )
            ],
            updatedAt: now.addingTimeInterval(60),
            in: context
        )
        try context.save()

        _ = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()

        XCTAssertTrue(try BusinessPurposePresetStore(context: context).fetchPurposes().isEmpty)
    }

    func testDuplicateItemStateRowsMergePerItemRevision() async throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        let now = Date(timeIntervalSince1970: 1_800_280_000)
        let firstKey = "client meeting"
        let secondKey = "site visit"
        try insertPreference(
            id: UUID(),
            key: BusinessPurposePresetStore.itemStatePreferenceKey,
            value: [
                firstKey: SyncedListItemState(isDeleted: true, updatedAt: now),
                secondKey: SyncedListItemState(
                    isDeleted: false,
                    updatedAt: now.addingTimeInterval(120)
                )
            ],
            updatedAt: now.addingTimeInterval(120),
            in: context
        )
        try insertPreference(
            id: UUID(),
            key: BusinessPurposePresetStore.itemStatePreferenceKey,
            value: [
                firstKey: SyncedListItemState(
                    isDeleted: false,
                    updatedAt: now.addingTimeInterval(60)
                ),
                secondKey: SyncedListItemState(isDeleted: true, updatedAt: now)
            ],
            updatedAt: now.addingTimeInterval(60),
            in: context
        )
        try context.save()

        let deleted = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()
        XCTAssertEqual(deleted, 1)
        let stored: [String: SyncedListItemState]? = try PreferenceStore(
            context: context,
            key: BusinessPurposePresetStore.itemStatePreferenceKey
        ).read()

        XCTAssertEqual(stored?[firstKey]?.isDeleted, false)
        XCTAssertEqual(stored?[secondKey]?.isDeleted, false)
        XCTAssertEqual(stored?[secondKey]?.updatedAt, now.addingTimeInterval(120))
    }

    func testConcurrentMileageSchedulesMergeRulesAndRespectTombstones() async throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        let now = Date(timeIntervalSince1970: 1_800_290_000)
        let deletedID = UUID()
        let retainedID = UUID()
        try insertPreference(
            id: UUID(),
            key: MileageRateScheduleStore.preferenceKey,
            value: MileageRateSchedule(
                baseRate: MileageRate(amountPerUnit: 0.50, unit: .miles),
                rules: [
                    MileageRateRule(
                        id: deletedID,
                        effectiveFrom: MileageRateEffectiveDate(year: 2025, month: 1, day: 1),
                        rate: MileageRate(amountPerUnit: 0.60, unit: .miles),
                        updatedAt: now
                    )
                ],
                deletedRuleIDs: [deletedID: now.addingTimeInterval(120)]
            ),
            updatedAt: now.addingTimeInterval(120),
            in: context
        )
        try insertPreference(
            id: UUID(),
            key: MileageRateScheduleStore.preferenceKey,
            value: MileageRateSchedule(
                baseRate: MileageRate(amountPerUnit: 0.55, unit: .miles),
                rules: [
                    MileageRateRule(
                        id: retainedID,
                        effectiveFrom: MileageRateEffectiveDate(year: 2026, month: 1, day: 1),
                        rate: MileageRate(amountPerUnit: 0.70, unit: .miles),
                        updatedAt: now.addingTimeInterval(60)
                    )
                ]
            ),
            updatedAt: now.addingTimeInterval(60),
            in: context
        )
        try context.save()

        _ = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()

        let schedule = try MileageRateScheduleStore(context: context).fetchSchedule()
        XCTAssertEqual(schedule.baseRate.amountPerUnit, 0.50)
        XCTAssertEqual(schedule.normalizedRules.map(\.id), [retainedID])
        XCTAssertNotNil(schedule.deletedRuleIDs[deletedID])
    }

    func testMileageSourceSelectionUsesItsOwnTimestampWhenNewerRuleEditsArrive() async throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        let now = Date(timeIntervalSince1970: 1_800_290_000)
        let from = MileageRateEffectiveDate(year: 2026, month: 1, day: 1)
        let following = MileageRateSchedule(baseRate: .default, irsFollowingFrom: from,
                                             sourceSelectionUpdatedAt: now)
        let stopped = IRSBusinessRateScheduleUpdater.stopFollowing(following, now: now.addingTimeInterval(60))
        try insertPreference(id: UUID(), key: MileageRateScheduleStore.preferenceKey,
                             value: following, updatedAt: now.addingTimeInterval(120), in: context)
        try insertPreference(id: UUID(), key: MileageRateScheduleStore.preferenceKey,
                             value: stopped, updatedAt: now.addingTimeInterval(60), in: context)
        try context.save()
        _ = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()
        let merged = try MileageRateScheduleStore(context: context).fetchSchedule()
        XCTAssertNil(merged.irsFollowingFrom)
        XCTAssertEqual(merged.sourceSelectionUpdatedAt, now.addingTimeInterval(60))
    }

    func testAutomaticIRSDefaultYieldsEntirelyToOlderLegacyCustomSchedule() async throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        let now = Date(timeIntervalSince1970: 1_800_295_000)
        let savedAt = now.addingTimeInterval(-60)
        let customRate = MileageRate(amountPerUnit: 0.50, unit: .miles)
        let savedID = UUID()
        let automatic = automaticIRSDefault(updatedAt: now)
        try insertPreference(id: UUID(), key: MileageRateScheduleStore.preferenceKey,
                             value: automatic, updatedAt: now, in: context)
        // Older encodings have neither a choice timestamp nor the new marker.
        try insertPreference(id: savedID, key: MileageRateScheduleStore.preferenceKey,
                             value: LegacyCustomSchedule(baseRate: customRate),
                             updatedAt: savedAt, in: context)
        try context.save()

        let deleted = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()

        XCTAssertEqual(deleted, 1)
        let merged = try MileageRateScheduleStore(context: context).fetchSchedule()
        XCTAssertFalse(merged.isAutomaticIRSDefault)
        XCTAssertNil(merged.irsFollowingFrom)
        XCTAssertNil(merged.sourceSelectionUpdatedAt)
        XCTAssertEqual(merged.baseRate, customRate)
        XCTAssertTrue(merged.rules.isEmpty)
        XCTAssertTrue(merged.deletedRuleIDs.isEmpty)
        XCTAssertEqual(merged.rate(on: Date(timeIntervalSince1970: 1_800_000_000)), customRate)
        let rows = try context.fetch(PreferenceEntity.fetchRequest())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, savedID)
        XCTAssertEqual(rows.first?.updatedAt, savedAt)
        let repeatedDeleted = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()
        XCTAssertEqual(repeatedDeleted, 0)
    }

    func testAutomaticIRSDefaultYieldsToSavedIRSHistoryAndChoice() async throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        let now = Date(timeIntervalSince1970: 1_800_296_000)
        let savedAt = now.addingTimeInterval(-60)
        let firstPeriod = IRSBusinessRatePeriod(
            effectiveFrom: MileageRateEffectiveDate(year: 2026, month: 1, day: 1),
            effectiveThrough: MileageRateEffectiveDate(year: 2026, month: 6, day: 30),
            amountPerMile: 0.725,
            sourceURL: "https://www.irs.gov/tax-professionals/standard-mileage-rates",
            rateEvidence: "72.5",
            periodEvidence: "2026 (Jan. 1 – June 30)"
        )
        var saved = automaticIRSDefault(updatedAt: savedAt)
        saved.isAutomaticIRSDefault = false
        saved.baseRate = MileageRate(amountPerUnit: 0.45, unit: .miles)
        saved.irsFollowingFrom = firstPeriod.effectiveFrom
        saved.sourceSelectionUpdatedAt = savedAt
        saved.rules.insert(
            MileageRateRule(effectiveFrom: firstPeriod.effectiveFrom, rate: firstPeriod.rate,
                            updatedAt: savedAt, irsSource: firstPeriod), at: 0
        )
        let automatic = automaticIRSDefault(updatedAt: now)
        try insertPreference(id: UUID(), key: MileageRateScheduleStore.preferenceKey,
                             value: automatic, updatedAt: now, in: context)
        try insertPreference(id: UUID(), key: MileageRateScheduleStore.preferenceKey,
                             value: saved, updatedAt: savedAt, in: context)
        try context.save()

        let deleted = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()

        XCTAssertEqual(deleted, 1)
        let merged = try MileageRateScheduleStore(context: context).fetchSchedule()
        XCTAssertEqual(merged, saved)
        XCTAssertFalse(merged.rules.contains { $0.id == automatic.rules[0].id })
        XCTAssertEqual(try context.fetch(PreferenceEntity.fetchRequest()).first?.updatedAt, savedAt)
    }

    func testConcurrentAutomaticIRSDefaultsDeduplicateWithoutBecomingUserChoice() async throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        let now = Date(timeIntervalSince1970: 1_800_297_000)
        let older = automaticIRSDefault(updatedAt: now.addingTimeInterval(-60))
        let newer = automaticIRSDefault(updatedAt: now)
        try insertPreference(id: UUID(), key: MileageRateScheduleStore.preferenceKey,
                             value: older, updatedAt: now.addingTimeInterval(-60), in: context)
        try insertPreference(id: UUID(), key: MileageRateScheduleStore.preferenceKey,
                             value: newer, updatedAt: now, in: context)
        try context.save()

        let deleted = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()

        XCTAssertEqual(deleted, 1)
        let merged = try MileageRateScheduleStore(context: context).fetchSchedule()
        XCTAssertTrue(merged.isAutomaticIRSDefault)
        XCTAssertNil(merged.sourceSelectionUpdatedAt)
        XCTAssertEqual(merged.irsFollowingFrom, newer.irsFollowingFrom)
        XCTAssertEqual(merged.baseRate, newer.baseRate)
        XCTAssertEqual(merged.normalizedRules, newer.rules)
        XCTAssertEqual(merged.deletedRuleIDs[older.rules[0].id], now)
        XCTAssertEqual(try context.fetch(PreferenceEntity.fetchRequest()).count, 1)
        let repeatedDeleted = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()
        XCTAssertEqual(repeatedDeleted, 0)
    }

    func testAutomaticIRSDefaultDoesNotReplaceUndecodableSavedSchedule() async throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        let now = Date(timeIntervalSince1970: 1_800_298_000)
        let savedAt = now.addingTimeInterval(-60)
        let savedData = Data("{invalid saved schedule}".utf8)
        let saved = PreferenceEntity.insert(into: context)
        saved.id = UUID()
        saved.key = MileageRateScheduleStore.preferenceKey
        saved.valueData = savedData
        saved.updatedAt = savedAt
        try insertPreference(id: UUID(), key: MileageRateScheduleStore.preferenceKey,
                             value: automaticIRSDefault(updatedAt: now), updatedAt: now, in: context)
        try context.save()

        let deleted = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()

        XCTAssertEqual(deleted, 1)
        let rows = try context.fetch(PreferenceEntity.fetchRequest())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.valueData, savedData)
        XCTAssertEqual(rows.first?.updatedAt, savedAt)
        let decoded: MileageRateSchedule? = try PreferenceStore(
            context: context, key: MileageRateScheduleStore.preferenceKey
        ).read()
        XCTAssertNil(decoded)
    }

    func testReconcileDeletesLosingConcurrentCanonicalReport() async throws {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        let start = Date(timeIntervalSince1970: 1_800_300_000)
        let end = start.addingTimeInterval(2_592_000)
        let key = "\(ReportArtifactCleanupStore.legacyMetadataKeyPrefix).month.2027-01"
        let losingReportID = UUID()
        let winningReportID = UUID()
        insertReport(id: losingReportID, start: start, end: end, in: context)
        insertReport(
            id: losingReportID,
            start: start.addingTimeInterval(1),
            end: end.addingTimeInterval(1),
            in: context
        )
        insertReport(id: winningReportID, start: start, end: end, in: context)
        try insertReportMetadata(
            id: UUID(),
            key: key,
            reportID: losingReportID,
            updatedAt: start,
            in: context
        )
        try insertReportMetadata(
            id: UUID(),
            key: key,
            reportID: winningReportID,
            updatedAt: start.addingTimeInterval(60),
            in: context
        )
        try context.save()

        let deleted = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()
        XCTAssertEqual(deleted, 1)

        let reports = try context.fetch(ReportSnapshotEntity.fetchRequest())
        XCTAssertEqual(reports.compactMap(\.id), [winningReportID])
    }

    private struct LegacyCustomSchedule: Encodable {
        var baseRate: MileageRate
    }

    private func automaticIRSDefault(updatedAt: Date) -> MileageRateSchedule {
        let period = IRSBusinessRatePeriod(
            effectiveFrom: MileageRateEffectiveDate(year: 2026, month: 7, day: 1),
            effectiveThrough: MileageRateEffectiveDate(year: 2026, month: 12, day: 31),
            amountPerMile: 0.76,
            sourceURL: "https://www.irs.gov/tax-professionals/standard-mileage-rates",
            rateEvidence: "76",
            periodEvidence: "2026 (July 1 – Dec. 31)"
        )
        var schedule = MileageRateSchedule(
            baseRate: period.rate,
            rules: [MileageRateRule(effectiveFrom: period.effectiveFrom, rate: period.rate,
                                    updatedAt: updatedAt, irsSource: period)],
            irsFollowingFrom: period.effectiveFrom
        )
        schedule.isAutomaticIRSDefault = true
        return schedule
    }

    private func insertPreference(
        id: UUID,
        key: String,
        purposes: [String],
        updatedAt: Date,
        in context: NSManagedObjectContext
    ) throws {
        let row = PreferenceEntity.insert(into: context)
        row.id = id
        row.key = key
        row.valueData = try JSONEncoder().encode(purposes)
        row.updatedAt = updatedAt
    }

    private func insertPreference<Value: Encodable>(
        id: UUID,
        key: String,
        value: Value,
        updatedAt: Date,
        in context: NSManagedObjectContext
    ) throws {
        let row = PreferenceEntity.insert(into: context)
        row.id = id
        row.key = key
        row.valueData = try JSONEncoder().encode(value)
        row.updatedAt = updatedAt
    }

    private func insertReport(
        id: UUID,
        start: Date,
        end: Date,
        in context: NSManagedObjectContext
    ) {
        let report = ReportSnapshotEntity.insert(into: context)
        report.id = id
        report.createdAt = start
        report.startDate = start
        report.endDate = end
        report.title = "Report"
        report.csvText = ""
        report.pdfData = Data([1])
    }

    // Real legacy rows carry a full generation fingerprint alongside the
    // report identity; the resolver must tolerate the extra fields.
    private func insertReportMetadata(
        id: UUID,
        key: String,
        reportID: UUID,
        updatedAt: Date,
        in context: NSManagedObjectContext
    ) throws {
        let row = PreferenceEntity.insert(into: context)
        row.id = id
        row.key = key
        row.valueData = try JSONEncoder().encode([
            "reportID": reportID.uuidString,
            "legacyFingerprintField": "ignored"
        ])
        row.updatedAt = updatedAt
    }
}
