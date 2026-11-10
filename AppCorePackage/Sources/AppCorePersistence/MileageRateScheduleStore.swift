import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

public final class MileageRateScheduleStore {
    public static let preferenceKey = "mileageRateSchedule.v1"

    private let context: NSManagedObjectContext
    private let preferences: PreferenceStore
    private let legacyPreferences: PreferenceStore
    // Populated older stores used this implicit value before the new default.
    private static let previousImplicitRate = MileageRate(amountPerUnit: 0.725, unit: .miles)

    public init(context: NSManagedObjectContext) {
        self.context = context
        preferences = PreferenceStore(context: context, key: Self.preferenceKey)
        legacyPreferences = PreferenceStore(context: context, key: MileageRateStore.preferenceKey)
    }

    public func fetchSchedule() throws -> MileageRateSchedule {
        if let schedule: MileageRateSchedule = try preferences.read() {
            if schedule.isAutomaticIRSDefault || schedule.requiresCustomRate, try containsLegacyRatePreference() {
                guard let rate = try MileageRateStore(context: context).fetchPersistedRate() else {
                    // Keep malformed imported bytes intact and stop automatic
                    // selection rather than treating them as a fresh install.
                    return MileageRateSchedule(baseRate: Self.previousImplicitRate)
                }
                // This is an inferred legacy choice, not a new edit. Leave the
                // bootstrap row marked on disk so an arriving modern schedule
                // replaces it wholly, retaining that schedule's original dates.
                return MileageRateSchedule(baseRate: rate)
            }
            return try Self.validated(schedule)
        }
        if let legacy = try MileageRateStore(context: context).fetchPersistedRate() {
            return MileageRateSchedule(baseRate: legacy)
        }
        return MileageRateSchedule(baseRate: try containsRatePreference() ? Self.previousImplicitRate : .default)
    }

    /// Only a genuinely empty store receives an implicit IRS source. Existing
    /// rows, including unreadable rate rows, never become a new user choice.
    public func initializeDefaultScheduleIfNeeded(currencyCode: String, now: Date = Date()) throws -> MileageRateSchedule {
        guard try !containsRatePreference() else { return try fetchSchedule() }
        let schedule = try containsAnyData()
            ? MileageRateSchedule(baseRate: Self.previousImplicitRate)
            : IRSBusinessRateScheduleUpdater.initialSchedule(currencyCode: currencyCode, now: now)
        return try saveSchedule(schedule, now: now)
    }

    @discardableResult
    public func saveSchedule(
        _ schedule: MileageRateSchedule,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> MileageRateSchedule {
        try saveSchedule(schedule, now: now, calendar: calendar, additionalChanges: {})
    }

    /// A single Custom editor save commits the amount, currency, and display
    /// unit together, so a failed write cannot leave a relabeled old amount.
    @discardableResult
    public func saveSchedule(
        _ schedule: MileageRateSchedule,
        currencyCode: String,
        distanceUnitPreference: DistanceUnitPreference,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> MileageRateSchedule {
        try saveSchedule(schedule, currencyCode: currencyCode, distanceUnitPreference: distanceUnitPreference,
                         now: now, calendar: calendar, beforeSave: {})
    }

    @discardableResult
    func saveSchedule(
        _ schedule: MileageRateSchedule,
        currencyCode: String,
        distanceUnitPreference: DistanceUnitPreference,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        beforeSave: () throws -> Void
    ) throws -> MileageRateSchedule {
        guard Locale.commonISOCurrencyCodes.contains(currencyCode),
              currencyCode == "USD" || schedule.irsFollowingFrom == nil else {
            throw MileageRateScheduleError.invalidCurrency
        }
        return try saveSchedule(schedule, now: now, calendar: calendar) {
            try PreferenceStore(context: self.context, key: UnitsCurrencyStore.currencyKey)
                .writeWithoutSaving(currencyCode, updatedAt: now)
            try PreferenceStore(context: self.context, key: UnitsCurrencyStore.distanceUnitKey)
                .writeWithoutSaving(distanceUnitPreference, updatedAt: now)
            try beforeSave()
        }
    }

    private func saveSchedule(
        _ schedule: MileageRateSchedule,
        now: Date,
        calendar: Calendar,
        additionalChanges: () throws -> Void
    ) throws -> MileageRateSchedule {
        let previous = try fetchSchedule()
        var candidate = schedule
        if candidate.isAutomaticIRSDefault || candidate.requiresCustomRate,
           !previous.isAutomaticIRSDefault && !previous.requiresCustomRate,
           try containsRatePreference() {
            return previous
        }
        let removedIDs = Set(previous.normalizedRules.map(\.id))
            .subtracting(candidate.rules.map(\.id))
        for id in removedIDs {
            candidate.deletedRuleIDs[id] = max(candidate.deletedRuleIDs[id] ?? .distantPast, now)
        }
        let validated = try Self.validated(candidate)
        let currentRate = validated.rate(on: now, calendar: calendar)
        try context.saveTransaction {
            try preferences.writeWithoutSaving(validated, updatedAt: now)
            // Older builds continue to see the rate effective today.
            if !validated.isAutomaticIRSDefault && !validated.requiresCustomRate {
                try legacyPreferences.writeWithoutSaving(currentRate, updatedAt: now)
            }
            try additionalChanges()
        }
        return validated
    }

    @discardableResult
    public func saveBaseRate(_ rate: MileageRate) throws -> MileageRateSchedule {
        var schedule = try fetchSchedule()
        schedule = IRSBusinessRateScheduleUpdater.stopFollowing(schedule)
        schedule.isAutomaticIRSDefault = false
        schedule.requiresCustomRate = false
        schedule.baseRate = rate
        return try saveSchedule(schedule)
    }

    public static func validated(_ schedule: MileageRateSchedule) throws -> MileageRateSchedule {
        let baseRate = try MileageRateStore.validated(schedule.baseRate)
        if let followingFrom = schedule.irsFollowingFrom,
           followingFrom.date(calendar: Calendar(identifier: .gregorian)) == nil {
            throw MileageRateScheduleError.invalidEffectiveDate
        }
        var dates = Set<MileageRateEffectiveDate>()
        var rules: [MileageRateRule] = []
        for rule in schedule.rules where
            rule.updatedAt > (schedule.deletedRuleIDs[rule.id] ?? .distantPast) {
            guard rule.effectiveFrom.date(calendar: Calendar(identifier: .gregorian)) != nil else {
                throw MileageRateScheduleError.invalidEffectiveDate
            }
            guard dates.insert(rule.effectiveFrom).inserted else {
                throw MileageRateScheduleError.duplicateEffectiveDate
            }
            var validatedRule = rule
            validatedRule.rate = try MileageRateStore.validated(rule.rate)
            if let source = rule.irsSource {
                _ = try IRSBusinessRateScheduleUpdater.validatedPeriods([source])
                guard rule.effectiveFrom >= source.effectiveFrom,
                      rule.effectiveFrom <= source.effectiveThrough else {
                    throw IRSBusinessRateScheduleError.invalidPeriod
                }
                guard abs(validatedRule.rate.amountPerMeter - source.rate.amountPerMeter) < 0.000_000_000_001 else {
                    throw IRSBusinessRateScheduleError.invalidAmount
                }
            }
            rules.append(validatedRule)
        }
        return MileageRateSchedule(
            baseRate: baseRate,
            rules: rules.sorted {
            if $0.effectiveFrom != $1.effectiveFrom {
                return $0.effectiveFrom < $1.effectiveFrom
            }
            return $0.id.uuidString < $1.id.uuidString
            },
            deletedRuleIDs: schedule.deletedRuleIDs,
            irsFollowingFrom: schedule.irsFollowingFrom,
            sourceSelectionUpdatedAt: schedule.sourceSelectionUpdatedAt,
            isAutomaticIRSDefault: schedule.isAutomaticIRSDefault,
            requiresCustomRate: schedule.requiresCustomRate
        )
    }

    private func containsLegacyRatePreference() throws -> Bool {
        try containsPreference(keys: [MileageRateStore.preferenceKey, MileageRateStore.legacyPreferenceKey])
    }

    private func containsRatePreference() throws -> Bool {
        try containsPreference(keys: [Self.preferenceKey, MileageRateStore.preferenceKey, MileageRateStore.legacyPreferenceKey])
    }

    private func containsPreference(keys: [String]) throws -> Bool {
        let request = PreferenceEntity.fetchRequest()
        request.predicate = NSPredicate(format: "key IN %@", keys)
        return try context.count(for: request) > 0
    }

    private func containsAnyData() throws -> Bool {
        guard let coordinator = context.persistentStoreCoordinator else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreOperationError)
        }
        let model = coordinator.managedObjectModel
        let entities = coordinator.persistentStores.flatMap {
            model.entities(forConfigurationName: $0.configurationName) ?? []
        }
        for name in Set(entities.filter { !$0.isAbstract }.compactMap(\.name)) {
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            if try context.count(for: request) > 0 { return true }
        }
        return false
    }
}
