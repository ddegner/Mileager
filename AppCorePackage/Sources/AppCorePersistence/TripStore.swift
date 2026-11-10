import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

public enum TripStoreError: Error, LocalizedError {
    case tripNotFound
    case invalidDateRange
    case invalidDistance
    case invalidAmount
    case invalidCoordinate
    case invalidOdometer
    case invalidRoute
    case feeNotFound
    case odometerCheckpointNotFound
    case notMergedTrip
    case mergeSourcesUnavailable
    case rawSampleStoreUnavailable
    case enrichmentAttemptStoreUnavailable
    case invalidBulkRequest
    case invalidBusinessPurpose
    case invalidFeeEdit

    public var errorDescription: String? {
        switch self {
        case .tripNotFound:
            String(localized: "Trip not found.", bundle: .appCoreStrings)
        case .invalidDateRange:
            String(
                localized: "The trip end time must be after the start time.",
                bundle: .appCoreStrings
            )
        case .invalidDistance:
            String(
                localized: "Mileage must be a finite number greater than or equal to zero.",
                bundle: .appCoreStrings
            )
        case .invalidAmount:
            String(
                localized: "Amounts must be finite numbers greater than or equal to zero.",
                bundle: .appCoreStrings
            )
        case .invalidCoordinate:
            String(
                localized: "Coordinates must be finite latitude and longitude values.",
                bundle: .appCoreStrings
            )
        case .invalidOdometer:
            String(
                localized: "Odometer readings must be finite numbers greater than or equal to zero.",
                bundle: .appCoreStrings
            )
        case .invalidRoute:
            String(localized: "The route data is malformed.", bundle: .appCoreStrings)
        case .feeNotFound:
            String(localized: "Fee not found.", bundle: .appCoreStrings)
        case .odometerCheckpointNotFound:
            String(localized: "Odometer reading not found.", bundle: .appCoreStrings)
        case .notMergedTrip:
            String(localized: "Only merged trips can be un-merged.", bundle: .appCoreStrings)
        case .mergeSourcesUnavailable:
            String(
                localized: "The original trips for this merged trip are unavailable.",
                bundle: .appCoreStrings
            )
        case .rawSampleStoreUnavailable:
            String(
                localized: "Raw location samples require the local capture store.",
                bundle: .appCoreStrings
            )
        case .enrichmentAttemptStoreUnavailable:
            String(
                localized: "Enrichment retry metadata requires the local capture store.",
                bundle: .appCoreStrings
            )
        case .invalidBulkRequest:
            String(
                localized: "The bulk trip request contains duplicate trip identifiers.",
                bundle: .appCoreStrings
            )
        case .invalidBusinessPurpose:
            String(
                localized: "A business purpose can only be assigned to a Business trip.",
                bundle: .appCoreStrings
            )
        case .invalidFeeEdit:
            String(
                localized: "The fee draft is stale or contains a fee that belongs to another trip.",
                bundle: .appCoreStrings
            )
        }
    }
}

public final class TripStore {
    private let context: NSManagedObjectContext
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Notified after each successful save; see `TripStoreChangeObserver`.
    public weak var changeObserver: (any TripStoreChangeObserver)?
    private static let mergeConnectorMaximumDistanceMeters = 800.0
    private enum MergeConnectorPolicy {
        case createNearbyConnectors
        case preserveExistingOnly
    }

    public init(context: NSManagedObjectContext) {
        self.context = context
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Trip writes

    @discardableResult
    public func saveCompletedTrip(_ draft: TripDraft) throws -> TripSummary {
        try saveCompletedTrip(draft, configuration: .automatic)
    }

    @discardableResult
    public func saveCompletedTrip(
        _ draft: TripDraft,
        configuration: DriveCaptureConfiguration
    ) throws -> TripSummary {
        try transaction {
            try Validator.validate(draft)
            let sortedSamples = draft.samples.sorted { $0.timestamp < $1.timestamp }
            let routePolyline = RouteSimplifier.simplifiedPolyline(
                samples: sortedSamples,
                toleranceMeters: configuration.routeSimplificationToleranceMeters
            )
            try Validator.validateRoutePolyline(routePolyline)

            let existingTrip = try fetchTripEntity(id: draft.id)
            let trip = existingTrip ?? TripEntity.insert(into: context)
            let isNewTrip = existingTrip == nil
            let priorStartState = trip.startAddressEnrichmentState
            let priorEndState = trip.endAddressEnrichmentState
            let priorRouteState = trip.routeEnrichmentState
            let priorStartCoordinate = trip.startCoordinate
            let priorEndCoordinate = trip.endCoordinate
            let priorStartAddress = trip.startAddress
            let priorEndAddress = trip.endAddress
            let priorStartComponents = trip.startAddressComponents(decoder: decoder)
            let priorEndComponents = trip.endAddressComponents(decoder: decoder)
            let priorRoutePolyline = trip.routePolyline
            let priorDistanceMeters = trip.distanceMeters
            let now = Date()
            trip.id = draft.id
            trip.createdAt = trip.createdAt ?? now
            trip.updatedAt = now
            trip.captureSource = "automatic"
            trip.startDate = draft.startDate
            trip.endDate = draft.endDate
            let recordedStart = sortedSamples.first.map {
                Coordinate(latitude: $0.latitude, longitude: $0.longitude)
            }
            let recordedEnd = sortedSamples.last.map {
                Coordinate(latitude: $0.latitude, longitude: $0.longitude)
            }
            let startIsPending = isNewTrip || priorStartState == .pending
            let endIsPending = isNewTrip || priorEndState == .pending
            let routeIsPending = isNewTrip || priorRouteState == .pending
            trip.startCoordinate = startIsPending ? recordedStart : priorStartCoordinate
            trip.endCoordinate = endIsPending ? recordedEnd : priorEndCoordinate
            trip.startAddress = startIsPending ? nil : priorStartAddress
            trip.endAddress = endIsPending ? nil : priorEndAddress
            trip.setStartAddressComponents(
                startIsPending ? nil : priorStartComponents,
                encoder: encoder
            )
            trip.setEndAddressComponents(
                endIsPending ? nil : priorEndComponents,
                encoder: encoder
            )
            trip.distanceMeters = routeIsPending ? draft.distanceMeters : priorDistanceMeters
            trip.durationSeconds = draft.endDate.timeIntervalSince(draft.startDate)
            trip.routePolyline = routeIsPending ? routePolyline : priorRoutePolyline
            if isNewTrip {
                trip.startAddressEnrichmentState = recordedStart == nil ? .unavailable : .pending
                trip.endAddressEnrichmentState = recordedEnd == nil ? .unavailable : .pending
                trip.routeEnrichmentState = sortedSamples.count >= 2 ? .pending : .unavailable
            }
            try applyLegs([
                TripLeg(
                    id: draft.id,
                    sourceTripID: draft.id,
                    captureSource: "automatic",
                    startDate: draft.startDate,
                    endDate: draft.endDate,
                    startCoordinate: trip.startCoordinate,
                    endCoordinate: trip.endCoordinate,
                    startAddress: trip.startAddress,
                    endAddress: trip.endAddress,
                    distanceMeters: trip.distanceMeters,
                    routePolyline: trip.routePolyline
                )
            ], to: trip)
            let attentionReasons = TripReviewPolicy.actionableAttentionReasons(
                from: draft.attentionReasons
            )
            trip.setAttentionReasons(attentionReasons, encoder: encoder)
            if let classification = draft.classification {
                if trip.classification != classification {
                    trip.classificationSource = nil
                }
                trip.classification = classification
            }
            if draft.classification == .notADrive {
                trip.businessPurpose = nil
            } else if let businessPurpose = draft.businessPurpose {
                trip.businessPurpose = emptyToNil(businessPurpose)
            }
            if let notes = draft.notes {
                trip.notes = emptyToNil(notes)
            }
            // Stamp the vehicle carried by the arming Shortcut, but never
            // downgrade an existing manual assignment on a re-save of the capture.
            // A stale automation (or unlinked hint) can carry a deleted vehicle's
            // ID; writing it would strand the trip outside every vehicle filter.
            if let draftVehicleID = draft.vehicleID,
               trip.vehicleAssignmentSource != .manual,
               try vehicleExists(draftVehicleID) {
                trip.vehicleID = draftVehicleID
                trip.vehicleAssignmentSource = draft.vehicleAssignmentSource ?? .shortcut
            }

            try replaceRawSamples(tripID: draft.id, with: sortedSamples, retentionDays: configuration.rawSampleRetentionDays)
            try upsertDraftFees(draft.fees, tripID: draft.id)
            // applyLegs above replaced the legs with a single zero-fee leg;
            // re-distribute any fees already linked to this trip (re-save of an
            // existing capture) and let review state honor an existing
            // classification instead of resetting it.
            try recomputeFeeTotals(forTripID: draft.id, marksEdited: false)
            normalizeReviewState(for: trip)
            return trip.toSummary(decoder: decoder)
        }
    }

    @discardableResult
    public func createManualTrip(_ input: ManualTripInput, id: UUID = UUID()) throws -> TripSummary {
        try transaction {
            try insertManualTrip(input, id: id).toSummary(decoder: decoder)
        }
    }

    /// Creates a manual trip and all of its draft fees in one save. This is the
    /// Mac New Trip boundary: validation failure cannot leave a fee-less trip
    /// behind, and observers receive one change set for the completed draft.
    @discardableResult
    public func createManualTrip(
        _ input: ManualTripInput,
        fees: [TripFee],
        id: UUID = UUID()
    ) throws -> TripSummary {
        try createManualTripWithSnapshot(input, fees: fees, id: id).trip
    }

    /// Returns the complete created trip and exact redo state from the same
    /// transaction. Snapshot failure therefore rolls back creation.
    public func createManualTripWithSnapshot(
        _ input: ManualTripInput,
        fees: [TripFee],
        id: UUID = UUID()
    ) throws -> TripCreationSnapshotResult {
        try transaction {
            try validateManualTripCreation(input, fees: fees, id: id)
            let trip = try insertManualTrip(input, id: id)
            try upsertDraftFees(fees, tripID: id)
            try recomputeFeeTotals(forTripID: id, marksEdited: false)
            let summary = trip.toSummary(decoder: decoder)
            return TripCreationSnapshotResult(
                trip: summary,
                snapshot: TripEditableSnapshot(
                    trip: summary,
                    fees: try fetchFees(tripID: id)
                )
            )
        }
    }

    // MARK: - Trip reads

    public func fetchTrips(from startDate: Date? = nil, to endDate: Date? = nil) throws -> [TripSummary] {
        try fetchPreferredTripEntities(
            from: startDate,
            to: endDate,
            vehicle: .any
        ).map { $0.toSummary(decoder: decoder) }
    }

    public func fetchTrips(
        from startDate: Date? = nil,
        to endDate: Date? = nil,
        vehicle: VehicleFilter
    ) throws -> [TripSummary] {
        try fetchPreferredTripEntities(
            from: startDate,
            to: endDate,
            vehicle: vehicle
        ).map { $0.toSummary(decoder: decoder) }
    }

    public func fetchTripRows(
        from startDate: Date? = nil,
        to endDate: Date? = nil,
        vehicle: VehicleFilter = .any
    ) throws -> [TripRowProjection] {
        let request = NSFetchRequest<NSDictionary>(entityName: TripEntity.entityName)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = [
            "id",
            "createdAt",
            "startDate",
            "endDate",
            "startAddress",
            "endAddress",
            "distanceMeters",
            "durationSeconds",
            "manualDistanceOverrideMeters",
            "classificationRaw",
            "classificationSourceRaw",
            "reviewStatusRaw",
            "businessPurpose",
            "notes",
            "tollsAmount",
            "parkingAmount",
            "needsAttention",
            "vehicleID",
            "captureSource",
            "updatedAt"
        ]
        let projections = try context.fetch(request).compactMap(Self.tripRowProjection)
        return Self.preferredTripRows(projections)
            .filter { projection in
                (startDate.map { projection.endDate >= $0 } ?? true)
                    && (endDate.map { projection.startDate <= $0 } ?? true)
                    && Self.vehicleMatches(projection.vehicleID, filter: vehicle)
            }
            .sorted(by: Self.tripRowOrder)
    }

    static let tripIndexProjectionPropertyNames = [
        "id",
        "createdAt",
        "updatedAt",
        "startDate",
        "endDate",
        "startAddress",
        "endAddress",
        "distanceMeters",
        "durationSeconds",
        "manualDistanceOverrideMeters",
        "classificationRaw",
        "classificationSourceRaw",
        "reviewStatusRaw",
        "businessPurpose",
        "notes",
        "tollsAmount",
        "parkingAmount",
        "needsAttention",
        "attentionReasonsData",
        "vehicleID",
        "captureSource"
    ]

    public func fetchTripIndexProjections(
        ids: [UUID]? = nil,
        from startDate: Date? = nil,
        to endDate: Date? = nil,
        vehicle: VehicleFilter = .any
    ) throws -> [TripIndexProjection] {
        if let ids, ids.isEmpty { return [] }
        let request = NSFetchRequest<NSDictionary>(entityName: TripEntity.entityName)
        var predicates: [NSPredicate] = []
        if let ids {
            predicates.append(NSPredicate(format: "id IN %@", ids as NSArray))
        }
        if !predicates.isEmpty {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = Self.tripIndexProjectionPropertyNames
        let projections = Self.preferredTripIndexProjections(
            try context.fetch(request).compactMap(Self.tripIndexProjection)
        ).filter { projection in
            (startDate.map { projection.endDate >= $0 } ?? true)
                && (endDate.map { projection.startDate <= $0 } ?? true)
                && Self.vehicleMatches(projection.vehicleID, filter: vehicle)
        }
        guard let ids else {
            return projections.sorted(by: Self.tripIndexProjectionOrder)
        }
        let projectionsByID = Dictionary(
            projections.map { ($0.id, $0) },
            uniquingKeysWith: Self.preferredTripIndexProjection
        )
        var emittedIDs = Set<UUID>()
        return ids.compactMap { id in
            guard emittedIDs.insert(id).inserted else { return nil }
            return projectionsByID[id]
        }
    }

    private static func preferredTripRows(_ projections: [TripRowProjection]) -> [TripRowProjection] {
        Array(Dictionary(
            projections.map { ($0.id, $0) },
            uniquingKeysWith: preferredTripRow
        ).values)
    }

    private static func preferredTripIndexProjections(
        _ projections: [TripIndexProjection]
    ) -> [TripIndexProjection] {
        Array(Dictionary(
            projections.map { ($0.id, $0) },
            uniquingKeysWith: preferredTripIndexProjection
        ).values)
    }

    private static func preferredTripRow(
        _ lhs: TripRowProjection,
        _ rhs: TripRowProjection
    ) -> TripRowProjection {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt ? lhs : rhs }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt ? lhs : rhs }
        if lhs.startDate != rhs.startDate { return lhs.startDate > rhs.startDate ? lhs : rhs }
        if lhs.endDate != rhs.endDate { return lhs.endDate > rhs.endDate ? lhs : rhs }
        return (lhs.startAddress ?? "") >= (rhs.startAddress ?? "") ? lhs : rhs
    }

    private static func preferredTripIndexProjection(
        _ lhs: TripIndexProjection,
        _ rhs: TripIndexProjection
    ) -> TripIndexProjection {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt ? lhs : rhs }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt ? lhs : rhs }
        if lhs.startDate != rhs.startDate { return lhs.startDate > rhs.startDate ? lhs : rhs }
        if lhs.endDate != rhs.endDate { return lhs.endDate > rhs.endDate ? lhs : rhs }
        return (lhs.startAddress ?? "") >= (rhs.startAddress ?? "") ? lhs : rhs
    }

    private static func tripRowOrder(_ lhs: TripRowProjection, _ rhs: TripRowProjection) -> Bool {
        if lhs.startDate != rhs.startDate { return lhs.startDate > rhs.startDate }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func tripIndexProjectionOrder(
        _ lhs: TripIndexProjection,
        _ rhs: TripIndexProjection
    ) -> Bool {
        if lhs.startDate != rhs.startDate { return lhs.startDate > rhs.startDate }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func vehicleMatches(_ vehicleID: UUID?, filter: VehicleFilter) -> Bool {
        switch filter {
        case .any:
            true
        case .unassigned:
            vehicleID == nil
        case let .vehicle(id, includesUnassigned):
            vehicleID == id || (includesUnassigned && vehicleID == nil)
        }
    }

    private static func tripRowProjection(_ values: NSDictionary) -> TripRowProjection? {
        guard let id = uuid(values["id"]),
              let startDate = values["startDate"] as? Date,
              let endDate = values["endDate"] as? Date else {
            return nil
        }
        let storedDistance = number(values["distanceMeters"])
        let manualDistance = optionalNumber(values["manualDistanceOverrideMeters"])
        let notes = values["notes"] as? String
        return TripRowProjection(
            id: id,
            createdAt: values["createdAt"] as? Date ?? startDate,
            startDate: startDate,
            endDate: endDate,
            startAddress: values["startAddress"] as? String,
            endAddress: values["endAddress"] as? String,
            distanceMeters: manualDistance ?? storedDistance,
            durationSeconds: number(values["durationSeconds"]),
            classification: (values["classificationRaw"] as? String).flatMap(TripClassification.init(rawValue:)),
            classificationSource: (values["classificationSourceRaw"] as? String)
                .flatMap(TripClassificationSource.init(rawValue:)),
            reviewStatus: (values["reviewStatusRaw"] as? String)
                .flatMap(ReviewStatus.init(rawValue:)) ?? .needsReview,
            businessPurpose: values["businessPurpose"] as? String,
            notes: notes,
            hasNotes: !(notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            tollsAmount: number(values["tollsAmount"]),
            parkingAmount: number(values["parkingAmount"]),
            needsAttention: bool(values["needsAttention"]),
            vehicleID: uuid(values["vehicleID"]),
            captureSource: values["captureSource"] as? String ?? "automatic",
            updatedAt: values["updatedAt"] as? Date ?? startDate
        )
    }

    private static func tripIndexProjection(_ values: NSDictionary) -> TripIndexProjection? {
        guard let id = uuid(values["id"]),
              let startDate = values["startDate"] as? Date,
              let endDate = values["endDate"] as? Date else {
            return nil
        }
        let storedDistance = number(values["distanceMeters"])
        let manualDistance = optionalNumber(values["manualDistanceOverrideMeters"])
        let attentionReasons: [String]
        if let data = values["attentionReasonsData"] as? Data {
            attentionReasons = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            attentionReasons = []
        }
        return TripIndexProjection(
            id: id,
            createdAt: values["createdAt"] as? Date ?? startDate,
            updatedAt: values["updatedAt"] as? Date ?? startDate,
            startDate: startDate,
            endDate: endDate,
            startAddress: values["startAddress"] as? String,
            endAddress: values["endAddress"] as? String,
            distanceMeters: manualDistance ?? storedDistance,
            durationSeconds: number(values["durationSeconds"]),
            classification: (values["classificationRaw"] as? String)
                .flatMap(TripClassification.init(rawValue:)),
            classificationSource: (values["classificationSourceRaw"] as? String)
                .flatMap(TripClassificationSource.init(rawValue:)),
            reviewStatus: (values["reviewStatusRaw"] as? String)
                .flatMap(ReviewStatus.init(rawValue:)) ?? .needsReview,
            businessPurpose: values["businessPurpose"] as? String,
            notes: values["notes"] as? String,
            tollsAmount: number(values["tollsAmount"]),
            parkingAmount: number(values["parkingAmount"]),
            needsAttention: bool(values["needsAttention"]),
            attentionReasons: attentionReasons,
            vehicleID: uuid(values["vehicleID"]),
            captureSource: values["captureSource"] as? String ?? "automatic"
        )
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? (value as? Double) ?? 0
    }

    private static func optionalNumber(_ value: Any?) -> Double? {
        if value == nil || value is NSNull { return nil }
        return (value as? NSNumber)?.doubleValue ?? value as? Double
    }

    private static func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? (value as? Bool) ?? false
    }

    private static func uuid(_ value: Any?) -> UUID? {
        if let value = value as? UUID { return value }
        if let value = value as? NSUUID { return value as UUID }
        return nil
    }

    static func vehiclePredicate(for filter: VehicleFilter) -> NSPredicate? {
        switch filter {
        case .any:
            return nil
        case .unassigned:
            return NSPredicate(format: "vehicleID == nil")
        case let .vehicle(id, includesUnassigned):
            if includesUnassigned {
                return NSPredicate(format: "vehicleID == %@ OR vehicleID == nil", id as CVarArg)
            }
            return NSPredicate(format: "vehicleID == %@", id as CVarArg)
        }
    }

    public func fetchTrip(id: UUID) throws -> TripSummary {
        guard let trip = try fetchTripEntity(id: id) else {
            throw TripStoreError.tripNotFound
        }
        return trip.toSummary(decoder: decoder)
    }

        /// No production caller: this was the native Mac editor's path into the
    /// store, and iOS reaches the same states through other facade methods.
    /// Kept at `package` access — in-package tests use it to construct and
    /// verify those states, and the narrower access keeps the app from
    /// growing a second way to do the same thing.
package func editableSnapshot(tripID: UUID) throws -> TripEditableSnapshot {
        let trip = try fetchTrip(id: tripID)
        return TripEditableSnapshot(trip: trip, fees: try fetchFees(tripID: tripID))
    }

        /// No production caller: this was the native Mac editor's path into the
    /// store, and iOS reaches the same states through other facade methods.
    /// Kept at `package` access — in-package tests use it to construct and
    /// verify those states, and the narrower access keeps the app from
    /// growing a second way to do the same thing.
package func editableSnapshots(tripIDs: [UUID]) throws -> [TripEditableSnapshot] {
        try validateUniqueTripIDs(tripIDs)
        // Fetch every row before returning any result so a missing ID cannot
        // produce a partial before-state for an undoable command.
        let trips = try tripIDs.map { id -> TripSummary in
            guard let trip = try fetchTripIfExists(id: id) else {
                throw TripStoreError.tripNotFound
            }
            return trip
        }
        return try trips.map { trip in
            TripEditableSnapshot(trip: trip, fees: try fetchFees(tripID: trip.id))
        }
    }

    public func fetchTripIfExists(id: UUID) throws -> TripSummary? {
        guard let trip = try fetchTripEntity(id: id) else {
            return nil
        }
        return trip.toSummary(decoder: decoder)
    }

    // MARK: - Fees

    public func fetchFees(tripID: UUID) throws -> [TripFee] {
        try logicalFeeEntities(fetchFeeEntities(tripID: tripID)).map(\.asFee)
    }

    public func fetchFees(includeUnlinked: Bool = false) throws -> [TripFee] {
        let request = TripFeeEntity.fetchRequest()
        if !includeUnlinked {
            request.predicate = NSPredicate(format: "tripID != nil")
        }
        request.sortDescriptors = [
            NSSortDescriptor(key: "occurredAt", ascending: true),
            NSSortDescriptor(key: "amount", ascending: true)
        ]
        return try logicalFeeEntities(context.fetch(request)).map(\.asFee)
    }

    @discardableResult
    public func addFee(_ fee: TripFee) throws -> TripFee {
        try transaction {
            try Validator.validate(fee)
            if let tripID = fee.tripID, try fetchTripEntity(id: tripID) == nil {
                throw TripStoreError.tripNotFound
            }
            guard try fetchFeeEntities(id: fee.id).isEmpty else {
                throw TripStoreError.invalidFeeEdit
            }
            let entity = TripFeeEntity.insert(into: context)
            write(fee: fee, to: entity)
            if let tripID = fee.tripID {
                try recomputeFeeTotals(forTripID: tripID)
            }
            return entity.asFee
        }
    }

    @discardableResult
    public func addFee(
        tripID: UUID,
        category: TripFeeCategory,
        amount: Double,
        occurredAt: Date = Date(),
        label: String? = nil,
        source: TripFeeSource = .manual,
        presetID: UUID? = nil
    ) throws -> TripFee {
        try addFee(TripFee(
            tripID: tripID,
            category: category,
            amount: amount,
            occurredAt: occurredAt,
            label: label,
            source: source,
            presetID: presetID
        ))
    }

    @discardableResult
    public func updateFee(_ fee: TripFee) throws -> TripFee {
        try transaction {
            try Validator.validate(fee)
            let copies = try fetchFeeEntities(id: fee.id)
            guard !copies.isEmpty else {
                throw TripStoreError.feeNotFound
            }
            let entity = try convergeFeeCopies(copies)
            let previousTripID = entity.tripID
            if let tripID = fee.tripID, try fetchTripEntity(id: tripID) == nil {
                throw TripStoreError.tripNotFound
            }
            write(fee: fee, to: entity)
            var affectedTripIDs = Set<UUID>()
            if let previousTripID { affectedTripIDs.insert(previousTripID) }
            if let tripID = fee.tripID { affectedTripIDs.insert(tripID) }
            for tripID in affectedTripIDs {
                try recomputeFeeTotals(forTripID: tripID)
            }
            return entity.asFee
        }
    }

    public func deleteFee(id: UUID) throws {
        try transaction {
            let entities = try fetchFeeEntities(id: id)
            guard !entities.isEmpty else {
                throw TripStoreError.feeNotFound
            }
            let affectedTripIDs = Set(entities.compactMap(\.tripID))
            entities.forEach(context.delete)
            for tripID in affectedTripIDs {
                try recomputeFeeTotals(forTripID: tripID)
            }
        }
    }

    @discardableResult
    public func recomputeTripFeeTotals(tripID: UUID) throws -> TripSummary {
        try transaction {
            try recomputeFeeTotals(forTripID: tripID)
            guard let trip = try fetchTripEntity(id: tripID) else {
                throw TripStoreError.tripNotFound
            }
            return trip.toSummary(decoder: decoder)
        }
    }

    // MARK: - Updates

    @discardableResult
    public func updateReview(tripID: UUID, update: ReviewUpdate) throws -> TripSummary {
        try transaction {
            guard let trip = try fetchTripEntity(id: tripID) else {
                throw TripStoreError.tripNotFound
            }

            let proposedStartDate = update.startDate ?? trip.startDate ?? Date()
            let proposedEndDate = update.endDate ?? trip.endDate ?? Date()
            try Validator.validateDateRange(start: proposedStartDate, end: proposedEndDate)
            try Validator.validateAmount(update.tollsAmount)
            try Validator.validateAmount(update.parkingAmount)
            try Validator.validateDistance(update.manualDistanceOverrideMeters)
            let priorManualDistanceOverride = trip.manualDistanceOverride

            if update.startDate != nil { trip.startDate = proposedStartDate }
            if update.endDate != nil { trip.endDate = proposedEndDate }
            trip.durationSeconds = proposedEndDate.timeIntervalSince(proposedStartDate)
            if update.startDate != nil || update.endDate != nil {
                try updateLegDates(for: trip, startDate: proposedStartDate, endDate: proposedEndDate)
            }

            if update.clearClassification {
                // Any change of classification (set, change, or clear) is a
                // user decision and erases the auto-mark indicator; re-saving
                // the same value preserves it.
                if trip.classification != nil {
                    trip.classificationSource = nil
                }
                trip.classification = nil
            } else if let classification = update.classification {
                if trip.classification != classification {
                    trip.classificationSource = nil
                }
                trip.classification = classification
            } else if let reviewStatus = update.reviewStatus {
                trip.reviewStatus = reviewStatus
            }
            if let businessPurpose = update.businessPurpose {
                trip.businessPurpose = emptyToNil(businessPurpose)
            }
            if let notes = update.notes {
                trip.notes = emptyToNil(notes)
            }
            if let tollsAmount = update.tollsAmount {
                try replaceLegacyTotalFee(trip: trip, category: .toll, totalAmount: tollsAmount)
            }
            if let parkingAmount = update.parkingAmount {
                try replaceLegacyTotalFee(trip: trip, category: .parking, totalAmount: parkingAmount)
            }
            if update.clearManualDistanceOverride {
                trip.manualDistanceOverride = nil
            } else if let manualOverride = update.manualDistanceOverrideMeters {
                trip.manualDistanceOverride = manualOverride
            }
            if trip.manualDistanceOverride != priorManualDistanceOverride {
                trip.routeEnrichmentState = .userManaged
                try deleteEnrichmentAttempts(
                    tripID: tripID,
                    components: [.route]
                )
            }
            if update.clearVehicleAssignment {
                trip.vehicleID = nil
                trip.vehicleAssignmentSource = nil
            } else if let vehicleID = update.vehicleID {
                trip.vehicleID = vehicleID
                trip.vehicleAssignmentSource = .manual
            }
            normalizeReviewState(for: trip, requestedStatus: update.reviewStatus)
            markEdited(trip)

            return trip.toSummary(decoder: decoder)
        }
    }

    /// Commits a complete Mac-style editor draft as one Core Data transaction.
    /// All references and values are validated before mutation. Imported tolls
    /// are immutable here and remain the responsibility of toll reconciliation.
    @discardableResult
        /// No production caller: this was the native Mac editor's path into the
    /// store, and iOS reaches the same states through other facade methods.
    /// Kept at `package` access — in-package tests use it to construct and
    /// verify those states, and the narrower access keeps the app from
    /// growing a second way to do the same thing.
package func updateTrip(
        id tripID: UUID,
        update: TripEditorUpdate
    ) throws -> TripSummary {
        try updateTripWithSnapshots(id: tripID, update: update).trip
    }

    /// Returns the before and after undo states from the editor transaction.
    /// Callers never need a fallible post-commit snapshot fetch.
    public func updateTripWithSnapshots(
        id tripID: UUID,
        update: TripEditorUpdate
    ) throws -> TripEditSnapshotResult {
        try transaction {
            guard let trip = try fetchTripEntity(id: tripID) else {
                throw TripStoreError.tripNotFound
            }
            let currentSummary = trip.toSummary(decoder: decoder)
            let currentFees = try fetchFees(tripID: tripID)
            let before = TripEditableSnapshot(trip: currentSummary, fees: currentFees)
            var normalizedUpdate = update
            normalizedUpdate.fees = normalizedUpdate.fees.sorted(by: TripEditorUpdate.feeOrder)
            if normalizedUpdate == TripEditorUpdate(trip: currentSummary, fees: currentFees) {
                return TripEditSnapshotResult(
                    trip: currentSummary,
                    before: before,
                    after: before
                )
            }

            try validateEditorUpdate(normalizedUpdate, tripID: tripID, currentFees: currentFees)

            let datesChanged = normalizedUpdate.startDate != currentSummary.startDate
                || normalizedUpdate.endDate != currentSummary.endDate
            let normalizedStartComponents = normalizedUpdate.startAddressComponents?.hasDisplayableComponent == true
                ? normalizedUpdate.startAddressComponents
                : nil
            let normalizedEndComponents = normalizedUpdate.endAddressComponents?.hasDisplayableComponent == true
                ? normalizedUpdate.endAddressComponents
                : nil
            let startLegEndpointChanged = normalizedUpdate.startCoordinate != currentSummary.startCoordinate
                || emptyToNil(normalizedUpdate.startAddress) != emptyToNil(currentSummary.startAddress)
            let endLegEndpointChanged = normalizedUpdate.endCoordinate != currentSummary.endCoordinate
                || emptyToNil(normalizedUpdate.endAddress) != emptyToNil(currentSummary.endAddress)
            let startEndpointChanged = startLegEndpointChanged
                || normalizedStartComponents != currentSummary.startAddressComponents
            let endEndpointChanged = endLegEndpointChanged
                || normalizedEndComponents != currentSummary.endAddressComponents
            let routeChanged = normalizedUpdate.startCoordinate != currentSummary.startCoordinate
                || normalizedUpdate.endCoordinate != currentSummary.endCoordinate
                || normalizedUpdate.routePolyline != currentSummary.routePolyline
                || normalizedUpdate.distanceMeters != currentSummary.distanceMeters
                || normalizedUpdate.manualDistanceOverrideMeters
                    != currentSummary.manualDistanceOverrideMeters

            trip.startDate = normalizedUpdate.startDate
            trip.endDate = normalizedUpdate.endDate
            trip.durationSeconds = normalizedUpdate.endDate.timeIntervalSince(normalizedUpdate.startDate)
            if datesChanged {
                try updateLegDates(
                    for: trip,
                    startDate: normalizedUpdate.startDate,
                    endDate: normalizedUpdate.endDate
                )
            }

            trip.startCoordinate = normalizedUpdate.startCoordinate
            trip.endCoordinate = normalizedUpdate.endCoordinate
            trip.startAddress = emptyToNil(normalizedUpdate.startAddress)
            trip.endAddress = emptyToNil(normalizedUpdate.endAddress)
            trip.setStartAddressComponents(normalizedUpdate.startAddressComponents, encoder: encoder)
            trip.setEndAddressComponents(normalizedUpdate.endAddressComponents, encoder: encoder)
            if startLegEndpointChanged || endLegEndpointChanged {
                try updateLegEndpoints(
                    for: trip,
                    startCoordinate: normalizedUpdate.startCoordinate,
                    endCoordinate: normalizedUpdate.endCoordinate,
                    startAddress: normalizedUpdate.startAddress,
                    endAddress: normalizedUpdate.endAddress
                )
            }

            trip.routePolyline = normalizedUpdate.routePolyline
            trip.distanceMeters = normalizedUpdate.distanceMeters
            if routeChanged
                || ((startLegEndpointChanged || endLegEndpointChanged)
                    && normalizedUpdate.routePolyline == nil) {
                try updateLegRoute(
                    for: trip,
                    startCoordinate: normalizedUpdate.startCoordinate,
                    endCoordinate: normalizedUpdate.endCoordinate,
                    routePolyline: normalizedUpdate.routePolyline,
                    distanceMeters: normalizedUpdate.routePolyline == nil
                        && normalizedUpdate.manualDistanceOverrideMeters != nil
                        ? nil
                        : normalizedUpdate.distanceMeters,
                    invalidateStartLegRoute: startLegEndpointChanged,
                    invalidateEndLegRoute: endLegEndpointChanged,
                    clearAllLegRoutes: normalizedUpdate.routePolyline == nil
                        && currentSummary.routePolyline != nil
                        && !startLegEndpointChanged
                        && !endLegEndpointChanged
                )
                trip.distanceMeters = normalizedUpdate.distanceMeters
            }
            trip.manualDistanceOverride = normalizedUpdate.manualDistanceOverrideMeters
            var userManagedComponents = Set<TripEnrichmentComponent>()
            if startEndpointChanged {
                trip.startAddressEnrichmentState = .userManaged
                userManagedComponents.insert(.startAddress)
            }
            if endEndpointChanged {
                trip.endAddressEnrichmentState = .userManaged
                userManagedComponents.insert(.endAddress)
            }
            if routeChanged {
                trip.routeEnrichmentState = .userManaged
                userManagedComponents.insert(.route)
            }
            try deleteEnrichmentAttempts(
                tripID: tripID,
                components: userManagedComponents
            )

            if trip.classification != normalizedUpdate.classification {
                trip.classificationSource = nil
                trip.classification = normalizedUpdate.classification
            }
            // Reclassification preserves the stored purpose, matching the
            // iPhone updateTrip path. Not a Drive clears it when review state
            // is normalized below.
            if normalizedUpdate.classification == .business {
                trip.businessPurpose = emptyToNil(normalizedUpdate.businessPurpose)
            }
            trip.notes = emptyToNil(normalizedUpdate.notes)

            if trip.vehicleID != normalizedUpdate.vehicleID {
                trip.vehicleID = normalizedUpdate.vehicleID
                trip.vehicleAssignmentSource = normalizedUpdate.vehicleID == nil ? nil : .manual
            }

            try replaceEditorFees(
                normalizedUpdate.fees,
                tripID: tripID,
                currentFees: currentFees
            )
            normalizeReviewState(for: trip)
            markEdited(trip)
            let summary = trip.toSummary(decoder: decoder)
            return TripEditSnapshotResult(
                trip: summary,
                before: before,
                after: TripEditableSnapshot(
                    trip: summary,
                    fees: try fetchFees(tripID: tripID)
                )
            )
        }
    }

    /// Applies one validated mutation to every requested trip and saves once.
    /// IDs and results preserve caller order; no trip is touched unless every
    /// ID, vehicle reference, and proposed purpose/classification is valid.
    @discardableResult
    public func updateTrips(
        tripIDs: [UUID],
        update: TripBulkUpdate
    ) throws -> [TripSummary] {
        try transaction {
            try validateUniqueTripIDs(tripIDs)
            let trips = try tripIDs.map { id -> TripEntity in
                guard let trip = try fetchTripEntity(id: id) else {
                    throw TripStoreError.tripNotFound
                }
                return trip
            }
            if case let .set(vehicleID) = update.vehicle,
               try !activeVehicleExists(vehicleID) {
                throw VehicleStoreError.vehicleNotFound
            }

            for trip in trips {
                let proposedClassification: TripClassification? = switch update.classification {
                case .unchanged: trip.classification
                case .clear: nil
                case let .set(value): value
                }
                if let purpose = update.businessPurpose,
                   emptyToNil(purpose) != nil,
                   proposedClassification != .business {
                    throw TripStoreError.invalidBusinessPurpose
                }
            }

            return trips.map { trip in
                switch update.classification {
                case .unchanged:
                    break
                case .clear:
                    trip.classification = nil
                    trip.classificationSource = nil
                case let .set(classification):
                    trip.classification = classification
                    trip.classificationSource = nil
                }
                // Reclassification itself never erases purpose. Not a Drive
                // clears it in normalizeReviewState below.
                if let purpose = update.businessPurpose {
                    trip.businessPurpose = emptyToNil(purpose)
                }
                if let notes = update.notes {
                    trip.notes = emptyToNil(notes)
                }
                switch update.vehicle {
                case .unchanged:
                    break
                case .clear:
                    trip.vehicleID = nil
                    trip.vehicleAssignmentSource = nil
                case let .set(vehicleID):
                    trip.vehicleID = vehicleID
                    trip.vehicleAssignmentSource = .manual
                }
                if update.resolveAttention {
                    trip.setAttentionReasons([], encoder: encoder)
                    trip.needsAttention = false
                }
                normalizeReviewState(for: trip)
                markEdited(trip)
                return trip.toSummary(decoder: decoder)
            }
        }
    }

    /// Restores every user-editable cloud field in one transaction. Capture
    /// provenance, Bluetooth hints, identity, and creation metadata are left
    /// untouched. Remote imports clear undo before this API can be invoked, so
    /// fee rows cannot be pulled back across a foreign edit accidentally.
    @discardableResult
    public func restoreEditableSnapshot(_ snapshot: TripEditableSnapshot) throws -> TripSummary {
        try transaction {
            try validateEditableSnapshot(snapshot)
            guard let trip = try fetchTripEntity(id: snapshot.tripID) else {
                throw TripStoreError.tripNotFound
            }
            return try restoreEditableSnapshot(snapshot, to: trip)
        }
    }

    @discardableResult
        /// No production caller: this was the native Mac editor's path into the
    /// store, and iOS reaches the same states through other facade methods.
    /// Kept at `package` access — in-package tests use it to construct and
    /// verify those states, and the narrower access keeps the app from
    /// growing a second way to do the same thing.
package func restoreEditableSnapshots(
        _ snapshots: [TripEditableSnapshot]
    ) throws -> [TripSummary] {
        try transaction {
            try validateUniqueTripIDs(snapshots.map(\.tripID))
            for snapshot in snapshots {
                try validateEditableSnapshot(snapshot)
            }
            let trips = try snapshots.map { snapshot -> TripEntity in
                guard let trip = try fetchTripEntity(id: snapshot.tripID) else {
                    throw TripStoreError.tripNotFound
                }
                return trip
            }
            return try zip(snapshots, trips).map { snapshot, trip in
                try restoreEditableSnapshot(snapshot, to: trip)
            }
        }
    }

    /// Applies a machine-made classification to a still-unreviewed trip.
    /// Unlike `updateReview` this is not a user edit: it refuses to touch a
    /// trip the user has already classified and does not mark the trip edited.
    @discardableResult
    public func applyAutomaticClassification(
        tripID: UUID,
        classification: TripClassification,
        source: TripClassificationSource
    ) throws -> TripSummary {
        try transaction {
            guard let trip = try fetchTripEntity(id: tripID) else {
                throw TripStoreError.tripNotFound
            }
            guard trip.classification == nil else {
                return trip.toSummary(decoder: decoder)
            }
            trip.classification = classification
            trip.classificationSource = source
            normalizeReviewState(for: trip)
            trip.updatedAt = Date()
            return trip.toSummary(decoder: decoder)
        }
    }

    /// Applies a machine-made classification only when the persisted trip is
    /// still the untouched automatic capture represented by `basis`. Returning
    /// `nil` is an intentional abstention: enrichment must never race a user
    /// edit or classify a trip carrying user-entered details or fees.
    @discardableResult
    public func applyAutomaticClassificationIfUnchanged(
        basis: TripAutomaticEnrichmentBasis,
        rawSamples: [LocationSample],
        classification: TripClassification,
        source: TripClassificationSource
    ) throws -> TripSummary? {
        try transaction {
            guard let trip = try fetchTripEntity(id: basis.tripID) else {
                throw TripStoreError.tripNotFound
            }
            // Sibling automatic address/route enrichment may advance
            // `updatedAt`; the path and user-edit guards below are the
            // meaningful concurrency boundary for this classifier.
            guard trip.captureSource == "automatic",
                  trip.startDate == basis.startDate,
                  trip.endDate == basis.endDate,
                  trip.startCoordinate == basis.startCoordinate,
                  trip.endCoordinate == basis.endCoordinate,
                  trip.distanceMeters == basis.distanceMeters,
                  try fetchRawSamples(tripID: basis.tripID) == rawSamples,
                  trip.classification == basis.classification,
                  basis.classification == nil,
                  trip.classification == nil,
                  trip.classificationSource == nil,
                  trip.lastEditedAt == nil,
                  basis.manualDistanceOverrideMeters == nil,
                  trip.manualDistanceOverride == nil,
                  trip.vehicleAssignmentSource != .manual,
                  trip.startAddressEnrichmentState != .userManaged,
                  trip.endAddressEnrichmentState != .userManaged,
                  trip.routeEnrichmentState != .userManaged,
                  trip.businessPurpose == nil,
                  trip.notes == nil,
                  trip.tollsAmount == 0,
                  trip.parkingAmount == 0,
                  try fetchFeeEntities(tripID: basis.tripID).isEmpty else {
                return nil
            }

            trip.classification = classification
            trip.classificationSource = source
            normalizeReviewState(for: trip)
            trip.updatedAt = Date()
            return trip.toSummary(decoder: decoder)
        }
    }

    @discardableResult
    public func setStartBluetoothHints(tripID: UUID, identifierHashes: [String]) throws -> TripSummary {
        try transaction {
            guard let trip = try fetchTripEntity(id: tripID) else {
                throw TripStoreError.tripNotFound
            }
            trip.setStartBluetoothHintHashes(identifierHashes, encoder: encoder)
            trip.updatedAt = Date()
            return trip.toSummary(decoder: decoder)
        }
    }

    // MARK: - Vehicle attribution

    /// User-driven vehicle assignment. Passing `vehicleID: nil` clears the
    /// assignment back to the default (primary) vehicle. Records the source as
    /// `.manual` (or nil on clear) and marks the trip edited.
    @discardableResult
    public func assignVehicle(
        tripID: UUID,
        vehicleID: UUID?,
        source: VehicleAssignmentSource? = .manual
    ) throws -> TripSummary {
        try transaction {
            guard let trip = try fetchTripEntity(id: tripID) else {
                throw TripStoreError.tripNotFound
            }
            trip.vehicleID = vehicleID
            trip.vehicleAssignmentSource = vehicleID == nil ? nil : source
            markEdited(trip)
            return trip.toSummary(decoder: decoder)
        }
    }

    /// Machine-made vehicle assignment. Like `applyAutomaticClassification`, it
    /// refuses to touch a trip the user has manually assigned and does not mark
    /// the trip edited.
    @discardableResult
    public func applyAutomaticVehicleAssignment(
        tripID: UUID,
        vehicleID: UUID,
        source: VehicleAssignmentSource
    ) throws -> TripSummary {
        try transaction {
            guard let trip = try fetchTripEntity(id: tripID) else {
                throw TripStoreError.tripNotFound
            }
            guard trip.vehicleAssignmentSource != .manual,
                  try vehicleExists(vehicleID) else {
                return trip.toSummary(decoder: decoder)
            }
            trip.vehicleID = vehicleID
            trip.vehicleAssignmentSource = source
            trip.updatedAt = Date()
            return trip.toSummary(decoder: decoder)
        }
    }

    /// Whether a vehicle profile with this ID currently exists. Automatic
    /// attribution paths check this so a stale Shortcut or Bluetooth mapping
    /// can't tag trips with a deleted vehicle's ID.
    private func vehicleExists(_ id: UUID) throws -> Bool {
        try VehicleEntity.fetchOne(
            in: context,
            where: NSPredicate(format: "id == %@", id as CVarArg)
        ) != nil
    }

    /// A past trip eligible for retroactive re-attribution when a Bluetooth
    /// device is linked to a vehicle.
    public struct VehicleReattributionCandidate: Equatable, Sendable {
        public var tripID: UUID
        public var startDate: Date
        public var currentVehicleID: UUID?
    }

    /// Trips whose recorded start-Bluetooth hashes contain `hash`
    /// and whose vehicle was not manually assigned (nil or `.bluetooth` source).
    /// The hash list is a JSON blob, so it can't be queried by predicate — it is
    /// decoded and matched in memory.
    public func vehicleReattributionCandidates(startHintHash hash: String) throws -> [VehicleReattributionCandidate] {
        try fetchPreferredTripEntities(
            from: nil,
            to: nil,
            vehicle: .any
        ).compactMap { trip in
            guard let tripID = trip.id,
                  trip.vehicleAssignmentSource != .manual,
                  trip.vehicleAssignmentSource != .shortcut,
                  trip.startBluetoothHintHashes(decoder: decoder).contains(hash) else {
                return nil
            }
            return VehicleReattributionCandidate(
                tripID: tripID,
                startDate: trip.startDate ?? Date(),
                currentVehicleID: trip.vehicleID
            )
        }
    }

    /// Re-attributes every candidate for `hash` to `vehicleID` with source
    /// `.bluetooth`. Returns the number of trips changed.
    @discardableResult
    public func reattributeTrips(startHintHash hash: String, to vehicleID: UUID?) throws -> Int {
        try transaction {
            var changed = 0
            for trip in try fetchPreferredTripEntities(
                from: nil,
                to: nil,
                vehicle: .any
            ) {
                guard trip.vehicleAssignmentSource != .manual,
                      trip.vehicleAssignmentSource != .shortcut,
                      trip.startBluetoothHintHashes(decoder: decoder).contains(hash) else {
                    continue
                }
                trip.vehicleID = vehicleID
                trip.vehicleAssignmentSource = vehicleID == nil ? nil : .bluetooth
                trip.updatedAt = Date()
                changed += 1
            }
            return changed
        }
    }

    /// Moves every trip on `vehicleID` to `newVehicleID` (nil = default). Used
    /// when a vehicle is deleted. Returns the number of trips moved.
    @discardableResult
    public func reassignTrips(from vehicleID: UUID, to newVehicleID: UUID?) throws -> Int {
        try transaction {
            let request = TripEntity.fetchRequest()
            request.predicate = NSPredicate(format: "vehicleID == %@", vehicleID as CVarArg)
            let trips = try context.fetch(request)
            let now = Date()
            for trip in trips {
                trip.vehicleID = newVehicleID
                if newVehicleID == nil { trip.vehicleAssignmentSource = nil }
                trip.updatedAt = now
            }
            return Set(trips.compactMap(\.id)).count
        }
    }

    /// Appends a machine-generated attention reason without marking the trip
    /// edited. Generalizes `appendAutomaticRouteAttentionReason` for non-route
    /// reasons (e.g. ambiguous vehicle attribution).
    @discardableResult
    public func appendAttentionReason(tripID: UUID, reason: String) throws -> TripSummary {
        try transaction {
            guard let trip = try fetchTripEntity(id: tripID) else {
                throw TripStoreError.tripNotFound
            }
            if let reason = emptyToNil(reason) {
                appendAttentionReason(reason, to: trip)
                trip.updatedAt = Date()
            }
            return trip.toSummary(decoder: decoder)
        }
    }

    @discardableResult
    public func updateAddresses(
        tripID: UUID,
        startAddress: String?,
        endAddress: String?,
        startAddressComponents: TripEndpointAddressComponents? = nil,
        endAddressComponents: TripEndpointAddressComponents? = nil
    ) throws -> TripSummary {
        try transaction {
            guard let trip = try fetchTripEntity(id: tripID) else {
                throw TripStoreError.tripNotFound
            }
            var changedComponents = Set<TripEnrichmentComponent>()
            if let startAddress {
                let normalizedAddress = emptyToNil(startAddress)
                let addressChanged = trip.startAddress != normalizedAddress
                let normalizedComponents: TripEndpointAddressComponents? = if let startAddressComponents {
                    startAddressComponents.hasDisplayableComponent
                        ? startAddressComponents
                        : nil
                } else if addressChanged {
                    nil
                } else {
                    trip.startAddressComponents(decoder: decoder)
                }
                if trip.startAddress != normalizedAddress
                    || trip.startAddressComponents(decoder: decoder) != normalizedComponents {
                    trip.startAddress = normalizedAddress
                    trip.setStartAddressComponents(normalizedComponents, encoder: encoder)
                    trip.startAddressEnrichmentState = .userManaged
                    changedComponents.insert(.startAddress)
                }
            }
            if let endAddress {
                let normalizedAddress = emptyToNil(endAddress)
                let addressChanged = trip.endAddress != normalizedAddress
                let normalizedComponents: TripEndpointAddressComponents? = if let endAddressComponents {
                    endAddressComponents.hasDisplayableComponent
                        ? endAddressComponents
                        : nil
                } else if addressChanged {
                    nil
                } else {
                    trip.endAddressComponents(decoder: decoder)
                }
                if trip.endAddress != normalizedAddress
                    || trip.endAddressComponents(decoder: decoder) != normalizedComponents {
                    trip.endAddress = normalizedAddress
                    trip.setEndAddressComponents(normalizedComponents, encoder: encoder)
                    trip.endAddressEnrichmentState = .userManaged
                    changedComponents.insert(.endAddress)
                }
            }
            guard !changedComponents.isEmpty else {
                return trip.toSummary(decoder: decoder)
            }
            try updateLegEndpoints(
                for: trip,
                startCoordinate: trip.startCoordinate,
                endCoordinate: trip.endCoordinate,
                startAddress: trip.startAddress,
                endAddress: trip.endAddress
            )
            try deleteEnrichmentAttempts(
                tripID: tripID,
                components: changedComponents
            )
            trip.updatedAt = Date()
            return trip.toSummary(decoder: decoder)
        }
    }

    @discardableResult
    public func updateAutomaticEndpointIfUnchanged(
        basis: TripAutomaticEnrichmentBasis,
        component: TripEnrichmentComponent,
        address: String,
        components: TripEndpointAddressComponents? = nil
    ) throws -> TripSummary? {
        try transaction {
            guard let resolvedAddress = emptyToNil(address),
                  let trip = try fetchTripEntity(id: basis.tripID) else {
                if emptyToNil(address) == nil { return nil }
                throw TripStoreError.tripNotFound
            }
            let normalizedComponents = components?.hasDisplayableComponent == true
                ? components
                : nil

            switch component {
            case .startAddress:
                guard automaticEndpointEnrichmentBasisMatches(
                    basis,
                    component: component,
                    trip: trip
                ) else { return nil }
                trip.startAddress = resolvedAddress
                trip.setStartAddressComponents(normalizedComponents, encoder: encoder)
                trip.startAddressEnrichmentState = .complete
            case .endAddress:
                guard automaticEndpointEnrichmentBasisMatches(
                    basis,
                    component: component,
                    trip: trip
                ) else { return nil }
                trip.endAddress = resolvedAddress
                trip.setEndAddressComponents(normalizedComponents, encoder: encoder)
                trip.endAddressEnrichmentState = .complete
            case .route:
                return nil
            }

            try updateLegEndpoints(
                for: trip,
                startCoordinate: trip.startCoordinate,
                endCoordinate: trip.endCoordinate,
                startAddress: trip.startAddress,
                endAddress: trip.endAddress
            )
            try deleteEnrichmentAttempts(
                tripID: basis.tripID,
                components: [component]
            )
            trip.updatedAt = Date()
            return trip.toSummary(decoder: decoder)
        }
    }

    @discardableResult
    public func updateAutomaticAddressesIfUnchanged(
        basis: TripAutomaticEnrichmentBasis,
        startAddress: String?,
        endAddress: String?,
        startAddressComponents: TripEndpointAddressComponents? = nil,
        endAddressComponents: TripEndpointAddressComponents? = nil
    ) throws -> TripSummary? {
        var result: TripSummary?
        if let startAddress {
            result = try updateAutomaticEndpointIfUnchanged(
                basis: basis,
                component: .startAddress,
                address: startAddress,
                components: startAddressComponents
            ) ?? result
        }
        if let endAddress {
            result = try updateAutomaticEndpointIfUnchanged(
                basis: basis,
                component: .endAddress,
                address: endAddress,
                components: endAddressComponents
            ) ?? result
        }
        if startAddress == nil, endAddress == nil {
            return try fetchTrip(id: basis.tripID)
        }
        return result
    }

    @discardableResult
    public func updateRoute(
        tripID: UUID,
        startCoordinate: Coordinate,
        endCoordinate: Coordinate,
        routePolyline: String?,
        distanceMeters: Double?
    ) throws -> TripSummary {
        try transaction {
            try Validator.validate(startCoordinate)
            try Validator.validate(endCoordinate)
            try Validator.validateRoutePolyline(routePolyline)
            try Validator.validateDistance(distanceMeters)
            guard let trip = try fetchTripEntity(id: tripID) else {
                throw TripStoreError.tripNotFound
            }
            let currentSummary = trip.toSummary(decoder: decoder)
            let startEndpointChanged = startCoordinate != currentSummary.startCoordinate
            let endEndpointChanged = endCoordinate != currentSummary.endCoordinate

            trip.startCoordinate = startCoordinate
            trip.endCoordinate = endCoordinate
            trip.routePolyline = routePolyline
            if let distanceMeters {
                trip.distanceMeters = distanceMeters
                trip.manualDistanceOverride = nil
            }
            try updateLegRoute(
                for: trip,
                startCoordinate: startCoordinate,
                endCoordinate: endCoordinate,
                routePolyline: routePolyline,
                distanceMeters: distanceMeters,
                invalidateStartLegRoute: startEndpointChanged,
                invalidateEndLegRoute: endEndpointChanged,
                clearAllLegRoutes: routePolyline == nil
                    && currentSummary.routePolyline != nil
                    && !startEndpointChanged
                    && !endEndpointChanged
            )
            var userManagedComponents = Set<TripEnrichmentComponent>()
            if startEndpointChanged {
                trip.startAddressEnrichmentState = .userManaged
                userManagedComponents.insert(.startAddress)
            }
            if endEndpointChanged {
                trip.endAddressEnrichmentState = .userManaged
                userManagedComponents.insert(.endAddress)
            }
            trip.routeEnrichmentState = .userManaged
            userManagedComponents.insert(.route)
            try deleteEnrichmentAttempts(
                tripID: tripID,
                components: userManagedComponents
            )
            markEdited(trip)
            return trip.toSummary(decoder: decoder)
        }
    }

    @discardableResult
    public func updateAutomaticRoute(
        tripID: UUID,
        routePolyline: String,
        distanceMeters: Double?,
        attentionReason: String? = nil
    ) throws -> TripSummary {
        try transaction {
            try Validator.validateRoutePolyline(routePolyline)
            try Validator.validateDistance(distanceMeters)
            guard let trip = try fetchTripEntity(id: tripID) else {
                throw TripStoreError.tripNotFound
            }
            guard trip.routeEnrichmentState == .pending else {
                return trip.toSummary(decoder: decoder)
            }

            trip.routePolyline = routePolyline
            if let distanceMeters {
                trip.distanceMeters = distanceMeters
            }
            try updateLegRoute(
                for: trip,
                startCoordinate: trip.startCoordinate,
                endCoordinate: trip.endCoordinate,
                routePolyline: routePolyline,
                distanceMeters: distanceMeters
            )
            if let attentionReason = emptyToNil(attentionReason) {
                appendAttentionReason(attentionReason, to: trip)
            }
            trip.routeEnrichmentState = .complete
            try deleteEnrichmentAttempts(
                tripID: tripID,
                components: [.route]
            )
            trip.updatedAt = Date()
            return trip.toSummary(decoder: decoder)
        }
    }

    @discardableResult
    public func updateAutomaticRouteIfUnchanged(
        basis: TripAutomaticEnrichmentBasis,
        routePolyline: String,
        distanceMeters: Double?,
        attentionReason: String? = nil
    ) throws -> TripSummary? {
        try transaction {
            try Validator.validateRoutePolyline(routePolyline)
            try Validator.validateDistance(distanceMeters)
            guard let trip = try fetchTripEntity(id: basis.tripID) else {
                throw TripStoreError.tripNotFound
            }
            guard automaticRouteEnrichmentBasisMatches(basis, trip: trip) else {
                return nil
            }

            trip.routePolyline = routePolyline
            if let distanceMeters {
                trip.distanceMeters = distanceMeters
            }
            try updateLegRoute(
                for: trip,
                startCoordinate: trip.startCoordinate,
                endCoordinate: trip.endCoordinate,
                routePolyline: routePolyline,
                distanceMeters: distanceMeters
            )
            if let attentionReason = emptyToNil(attentionReason) {
                appendAttentionReason(attentionReason, to: trip)
            }
            trip.routeEnrichmentState = .complete
            try deleteEnrichmentAttempts(
                tripID: basis.tripID,
                components: [.route]
            )
            trip.updatedAt = Date()
            return trip.toSummary(decoder: decoder)
        }
    }

    @discardableResult
    public func appendAutomaticRouteAttentionReasonIfUnchanged(
        basis: TripAutomaticEnrichmentBasis,
        attentionReason: String
    ) throws -> TripSummary? {
        try transaction {
            guard let trip = try fetchTripEntity(id: basis.tripID) else {
                throw TripStoreError.tripNotFound
            }
            guard automaticRouteAssessmentBasisMatches(basis, trip: trip) else {
                return nil
            }
            if let attentionReason = emptyToNil(attentionReason) {
                appendAttentionReason(attentionReason, to: trip)
                trip.updatedAt = Date()
            }
            trip.routeEnrichmentState = .complete
            try deleteEnrichmentAttempts(
                tripID: basis.tripID,
                components: [.route]
            )
            return trip.toSummary(decoder: decoder)
        }
    }

    @discardableResult
    public func appendAutomaticRouteAttentionReason(
        tripID: UUID,
        attentionReason: String
    ) throws -> TripSummary {
        try transaction {
            guard let trip = try fetchTripEntity(id: tripID) else {
                throw TripStoreError.tripNotFound
            }

            if let attentionReason = emptyToNil(attentionReason) {
                appendAttentionReason(attentionReason, to: trip)
                trip.updatedAt = Date()
            }
            return trip.toSummary(decoder: decoder)
        }
    }

    @discardableResult
    public func clearRouteMap(tripID: UUID) throws -> TripSummary {
        try transaction {
            guard let trip = try fetchTripEntity(id: tripID) else {
                throw TripStoreError.tripNotFound
            }
            let startChanged = trip.startCoordinate != nil
            let endChanged = trip.endCoordinate != nil
            trip.startCoordinate = nil
            trip.endCoordinate = nil
            trip.routePolyline = nil
            try updateLegRoute(
                for: trip,
                startCoordinate: nil,
                endCoordinate: nil,
                routePolyline: nil,
                distanceMeters: nil,
                invalidateStartLegRoute: true,
                invalidateEndLegRoute: true,
                clearAllLegRoutes: true
            )
            var userManagedComponents = Set<TripEnrichmentComponent>()
            if startChanged {
                trip.startAddressEnrichmentState = .userManaged
                userManagedComponents.insert(.startAddress)
            }
            if endChanged {
                trip.endAddressEnrichmentState = .userManaged
                userManagedComponents.insert(.endAddress)
            }
            trip.routeEnrichmentState = .userManaged
            userManagedComponents.insert(.route)
            try deleteEnrichmentAttempts(
                tripID: tripID,
                components: userManagedComponents
            )
            markEdited(trip)
            return trip.toSummary(decoder: decoder)
        }
    }

    // MARK: - Lifecycle

    @discardableResult
    public func duplicateTrip(
        id: UUID,
        newID: UUID = UUID(),
        startDate: Date? = nil,
        reversed: Bool = false
    ) throws -> TripSummary {
        try duplicateTripWithSnapshot(
            id: id,
            newID: newID,
            startDate: startDate,
            reversed: reversed
        ).trip
    }

    /// Returns exact redo state from the same transaction as duplication.
    public func duplicateTripWithSnapshot(
        id: UUID,
        newID: UUID = UUID(),
        startDate: Date? = nil,
        reversed: Bool = false
    ) throws -> TripCreationSnapshotResult {
        let summary = try fetchTrip(id: id)
        let newStart = startDate ?? (reversed ? summary.endDate : Date())
        let newEnd = newStart.addingTimeInterval(summary.durationSeconds)
        return try transaction {
            let duplicate = try insertManualTrip(ManualTripInput(
                startDate: newStart,
                endDate: newEnd,
                startCoordinate: reversed ? summary.endCoordinate : summary.startCoordinate,
                endCoordinate: reversed ? summary.startCoordinate : summary.endCoordinate,
                startAddress: reversed ? summary.endAddress : summary.startAddress,
                endAddress: reversed ? summary.startAddress : summary.endAddress,
                distanceMeters: summary.reportableDistanceMeters,
                routePolyline: reversed ? Self.reversedPolyline(summary.routePolyline) : summary.routePolyline,
                classification: summary.classification,
                businessPurpose: summary.businessPurpose,
                notes: summary.notes,
                vehicleID: summary.vehicleID
            ), id: newID)
            let startComponents = reversed ? summary.endAddressComponents : summary.startAddressComponents
            let endComponents = reversed ? summary.startAddressComponents : summary.endAddressComponents
            duplicate.setStartAddressComponents(startComponents, encoder: encoder)
            duplicate.setEndAddressComponents(endComponents, encoder: encoder)
            let duplicatedSummary = duplicate.toSummary(decoder: decoder)
            return TripCreationSnapshotResult(
                trip: duplicatedSummary,
                snapshot: TripEditableSnapshot(
                    trip: duplicatedSummary,
                    fees: try fetchFees(tripID: newID)
                )
            )
        }
    }

    /// Recreates a user-editable trip with its original identity. This is used
    /// by exact redo for New Trip and Duplicate; capture provenance and raw
    /// samples are intentionally outside the editable snapshot.
    @discardableResult
        /// No production caller: this was the native Mac editor's path into the
    /// store, and iOS reaches the same states through other facade methods.
    /// Kept at `package` access — in-package tests use it to construct and
    /// verify those states, and the narrower access keeps the app from
    /// growing a second way to do the same thing.
package func recreateTrip(from snapshot: TripEditableSnapshot) throws -> TripSummary {
        try transaction {
            guard try fetchTripEntity(id: snapshot.tripID) == nil else {
                throw TripStoreError.invalidBulkRequest
            }
            try validateEditableSnapshot(snapshot)
            let placeholder = try insertManualTrip(ManualTripInput(
                startDate: snapshot.startDate,
                endDate: snapshot.endDate,
                startCoordinate: snapshot.startCoordinate,
                endCoordinate: snapshot.endCoordinate,
                startAddress: snapshot.startAddress,
                endAddress: snapshot.endAddress,
                distanceMeters: snapshot.distanceMeters,
                routePolyline: snapshot.routePolyline,
                classification: snapshot.classification,
                businessPurpose: snapshot.businessPurpose,
                notes: snapshot.notes,
                vehicleID: snapshot.vehicleID
            ), id: snapshot.tripID)
            return try restoreEditableSnapshot(snapshot, to: placeholder)
        }
    }

    /// Reverses a route polyline so it traces the return direction: segment
    /// order and each segment's coordinates are both reversed. Returns nil if
    /// the polyline cannot be decoded — no route line is better than one
    /// pointing the wrong way on a reversed trip.
    private static func reversedPolyline(_ polyline: String?) -> String? {
        guard let polyline, let segments = EncodedPolyline.decodeSegments(polyline) else {
            return nil
        }
        let reversedSegments = segments.reversed().map { Array($0.reversed()) }
        return EncodedPolyline.encodeSegments(reversedSegments)
    }

    public func splitMergedTrip(id: UUID, legIDs: [UUID]) throws -> [TripSummary] {
        try transaction {
            guard let merged = try fetchTripEntity(id: id) else {
                throw TripStoreError.tripNotFound
            }
            return try splitMergedTrip(merged, legIDs: legIDs)
        }
    }

    @discardableResult
    public func mergeTrips(ids: [UUID]) throws -> TripSummary {
        try mergeTrips(ids: ids, connectorPolicy: .createNearbyConnectors)
    }

    /// Category for a merged trip: a single real category (business/personal)
    /// wins over unclassified and Not a Drive legs; contradictory real
    /// categories drop to nil so the merge lands in the review queue. Only an
    /// all-Not-a-Drive merge stays Not a Drive.
    public static func resolvedMergeClassification(
        _ values: [TripClassification?]
    ) -> TripClassification? {
        let realCategories = Set(values.compactMap { $0 }.filter { $0 != .notADrive })
        if realCategories.count == 1 { return realCategories.first }
        if realCategories.count > 1 { return nil }
        return !values.isEmpty && values.allSatisfy { $0 == .notADrive } ? .notADrive : nil
    }

    @discardableResult
    private func mergeTrips(
        ids: [UUID],
        connectorPolicy: MergeConnectorPolicy
    ) throws -> TripSummary {
        try transaction {
            guard ids.count >= 2 else { throw TripStoreError.tripNotFound }
            try validateUniqueTripIDs(ids)

            let sources = try ids.map { id in
                guard let entity = try fetchTripEntity(id: id) else {
                    throw TripStoreError.tripNotFound
                }
                return entity
            }
            let sortedSummaries = sources
                .map { $0.toSummary(decoder: decoder) }
                .sorted { $0.startDate < $1.startDate }
            guard !sortedSummaries.isEmpty else {
                throw TripStoreError.tripNotFound
            }
            let classification = Self.resolvedMergeClassification(
                sortedSummaries.map(\.classification)
            )
            // Purpose and vehicle are donated by the longest source trip that
            // defines them; ties go to the earlier trip.
            let byLengthDescending = sortedSummaries.sorted {
                if $0.reportableDistanceMeters != $1.reportableDistanceMeters {
                    return $0.reportableDistanceMeters > $1.reportableDistanceMeters
                }
                return $0.startDate < $1.startDate
            }

            let now = Date()
            let mergedID = UUID()
            let merged = TripEntity.insert(into: context)
            merged.id = mergedID
            merged.createdAt = sortedSummaries.map(\.createdAt).min() ?? now
            merged.updatedAt = now
            merged.captureSource = "merged"
            merged.classification = classification
            merged.reviewStatus = .needsReview
            merged.businessPurpose = byLengthDescending
                .compactMap { emptyToNil($0.businessPurpose) }
                .first
            merged.notes = mergedNotes(from: sortedSummaries)
            merged.needsAttention = false
            merged.setAttentionReasons([], encoder: encoder)
            merged.manualDistanceOverride = nil
            if let vehicleDonor = byLengthDescending.first(where: { $0.vehicleID != nil }) {
                merged.vehicleID = vehicleDonor.vehicleID
                // Carry the donor's real source; fabricating .manual here
                // would permanently exempt the merged trip (and its un-merged
                // children) from automatic re-attribution corrections.
                merged.vehicleAssignmentSource = vehicleDonor.vehicleAssignmentSource
            }

            let sourceLegs = normalizedLegs(sortedSummaries.flatMap { summary in
                let boundaries = summary.legs.tripBoundaryIndices
                return summary.legs.enumerated().map { index, leg in
                    var copy = leg
                    copy.sourceTripID = copy.sourceTripID ?? summary.id
                    copy.captureSource = copy.captureSource.isEmpty ? summary.captureSource : copy.captureSource
                    if index == boundaries?.start {
                        copy.startAddressComponents = summary.startAddressComponents
                    }
                    if index == boundaries?.end {
                        copy.endAddressComponents = summary.endAddressComponents
                    }
                    if summary.legs.count == 1, index == 0 {
                        copy.distanceMeters = summary.reportableDistanceMeters
                    }
                    return copy
                }
            })
            let sourceConnectors = filteredConnectors(
                sortedSummaries.flatMap(\.connectors),
                keepingLegIDs: Set(sourceLegs.map(\.id))
            )
            let mergedConnectors = connectors(
                for: sourceLegs,
                preserving: sourceConnectors,
                policy: connectorPolicy
            )
            try applyLegs(sourceLegs, connectors: mergedConnectors, to: merged)
            if let boundaries = sourceLegs.tripBoundaryIndices {
                merged.setStartAddressComponents(sourceLegs[boundaries.start].startAddressComponents, encoder: encoder)
                merged.setEndAddressComponents(sourceLegs[boundaries.end].endAddressComponents, encoder: encoder)
            }
            merged.startAddressEnrichmentState = .userManaged
            merged.endAddressEnrichmentState = .userManaged
            merged.routeEnrichmentState = .userManaged

            for source in sources {
                if let sourceID = source.id {
                    try reassignRawSamples(from: sourceID, to: mergedID)
                    try reassignFees(from: sourceID, to: mergedID)
                    try deleteEnrichmentAttempts(
                        tripID: sourceID,
                        components: Set(TripEnrichmentComponent.allCases)
                    )
                }
                context.delete(source)
            }
            try recomputeFeeTotals(forTripID: mergedID)

            merged.setStartBluetoothHintHashes(
                Array(Set(sortedSummaries.flatMap(\.startBluetoothHintHashes))),
                encoder: encoder
            )

            normalizeReviewState(for: merged)
            markEdited(merged)
            return merged.toSummary(decoder: decoder)
        }
    }

    @discardableResult
    public func unmergeTrip(id: UUID) throws -> [TripSummary] {
        try transaction {
            guard let merged = try fetchTripEntity(id: id) else {
                throw TripStoreError.tripNotFound
            }
            let summary = merged.toSummary(decoder: decoder)
            guard summary.isMerged else {
                throw TripStoreError.notMergedTrip
            }
            return try splitMergedTrip(merged, legIDs: summary.legs.map(\.id))
        }
    }

    public func deleteTrip(id: UUID) throws {
        try deleteTrips(ids: [id])
    }

    /// Permanently deletes a validated set of trips in one save. Every trip is
    /// resolved before mutation so a missing or duplicate identifier cannot
    /// leave a partial deletion behind.
    public func deleteTrips(ids: [UUID]) throws {
        try transaction {
            try validateUniqueTripIDs(ids)
            let tripsByID = try ids.map { id -> (UUID, [TripEntity]) in
                let trips = try fetchTripEntities(id: id)
                guard !trips.isEmpty else {
                    throw TripStoreError.tripNotFound
                }
                return (id, trips)
            }
            for (id, trips) in tripsByID {
                try TripCascadeDelete.delete(trips, tripID: id, in: context)
            }
        }
    }

    // MARK: - Odometer

    @discardableResult
    public func addOdometerCheckpoint(_ checkpoint: OdometerCheckpoint) throws -> OdometerCheckpoint {
        try transaction {
            try writeOdometerCheckpoint(checkpoint)
            return checkpoint
        }
    }

    public func fetchOdometerCheckpoints() throws -> [OdometerCheckpoint] {
        let request = OdometerCheckpointEntity.fetchRequest()
        return try logicalOdometerEntities(context.fetch(request)).map(\.asCheckpoint)
    }

    public func fetchOdometerCheckpoints(vehicle: VehicleFilter) throws -> [OdometerCheckpoint] {
        let request = OdometerCheckpointEntity.fetchRequest()
        return try logicalOdometerEntities(context.fetch(request))
            .filter { Self.vehicleMatches($0.vehicleID, filter: vehicle) }
            .map(\.asCheckpoint)
    }

    public func deleteOdometerCheckpoint(id: UUID) throws {
        try transaction {
            let entities = try fetchOdometerCheckpointEntities(id: id)
            guard !entities.isEmpty else {
                throw TripStoreError.odometerCheckpointNotFound
            }
            entities.forEach(context.delete)
        }
    }

    /// Moves every odometer checkpoint on `vehicleID` to `newVehicleID`
    /// (nil = default). Used when a vehicle is deleted, alongside
    /// `reassignTrips`, so readings don't dangle on a dead vehicle ID.
    @discardableResult
    public func reassignOdometerCheckpoints(from vehicleID: UUID, to newVehicleID: UUID?) throws -> Int {
        try transaction {
            let request = OdometerCheckpointEntity.fetchRequest()
            request.predicate = NSPredicate(format: "vehicleID == %@", vehicleID as CVarArg)
            let checkpoints = try context.fetch(request)
            for checkpoint in checkpoints {
                checkpoint.vehicleID = newVehicleID
            }
            return Set(checkpoints.compactMap(\.id)).count
        }
    }

    /// Deletes every odometer checkpoint on `vehicleID`. Used when a vehicle is
    /// removed: an odometer reading is a physical measurement of a specific car,
    /// so it can't be reattributed to another vehicle (nil resolves to the
    /// primary in reports) without corrupting that car's interpolated totals.
    @discardableResult
    public func deleteOdometerCheckpoints(forVehicle vehicleID: UUID) throws -> Int {
        try transaction {
            let request = OdometerCheckpointEntity.fetchRequest()
            request.predicate = NSPredicate(format: "vehicleID == %@", vehicleID as CVarArg)
            let checkpoints = try context.fetch(request)
            for checkpoint in checkpoints {
                context.delete(checkpoint)
            }
            return Set(checkpoints.compactMap(\.id)).count
        }
    }

    // MARK: - Raw samples

    /// Persists the one-time interpretation of pre-feature rows. This writes
    /// provenance only: historical route geometry and mileage are never
    /// inspected or changed.
    @discardableResult
    public func normalizeLegacyEnrichmentStates() throws -> Int {
        try transaction {
            let request = TripEntity.fetchRequest()
            let trips = try context.fetch(request)
            var changedTripIDs = Set<UUID>()
            for trip in trips {
                var changed = false
                if trip.startAddressEnrichmentStateRaw == nil {
                    trip.startAddressEnrichmentState = legacyAddressState(
                        trip: trip,
                        address: trip.startAddress,
                        coordinate: trip.startCoordinate
                    )
                    changed = true
                }
                if trip.endAddressEnrichmentStateRaw == nil {
                    trip.endAddressEnrichmentState = legacyAddressState(
                        trip: trip,
                        address: trip.endAddress,
                        coordinate: trip.endCoordinate
                    )
                    changed = true
                }
                if trip.routeEnrichmentStateRaw == nil {
                    trip.routeEnrichmentState = .legacy
                    changed = true
                }
                if changed, let id = trip.id {
                    changedTripIDs.insert(id)
                }
            }
            return changedTripIDs.count
        }
    }

    public func fetchAddressEnrichmentCandidates(
        limit: Int = 10,
        now: Date = Date()
    ) throws -> [TripEnrichmentCandidate] {
        guard limit > 0 else { return [] }
        let trips = try fetchTrips()
            .filter { $0.captureSource == "automatic" }
            .sorted(by: Self.newestTripFirst)
        let attempts = try enrichmentAttemptsByKey(tripIDs: trips.map(\.id))

        return trips.compactMap { trip in
            var components = Set<TripEnrichmentComponent>()
            if trip.startAddressEnrichmentState == .pending,
               isValidEnrichmentCoordinate(trip.startCoordinate),
               emptyToNil(trip.startAddress) == nil,
               enrichmentAttemptIsEligible(
                   attempts[enrichmentAttemptKey(tripID: trip.id, component: .startAddress)],
                   now: now
               ) {
                components.insert(.startAddress)
            }
            if trip.endAddressEnrichmentState == .pending,
               isValidEnrichmentCoordinate(trip.endCoordinate),
               emptyToNil(trip.endAddress) == nil,
               enrichmentAttemptIsEligible(
                   attempts[enrichmentAttemptKey(tripID: trip.id, component: .endAddress)],
                   now: now
               ) {
                components.insert(.endAddress)
            }
            return components.isEmpty
                ? nil
                : TripEnrichmentCandidate(trip: trip, components: components)
        }
        .prefix(limit)
        .map { $0 }
    }

    public func fetchRouteEnrichmentCandidates(
        limit: Int = 2,
        now: Date = Date()
    ) throws -> [TripEnrichmentCandidate] {
        guard limit > 0 else { return [] }
        let trips = try fetchTrips()
            .filter {
                $0.captureSource == "automatic"
                    && $0.routeEnrichmentState == .pending
            }
            .sorted(by: Self.newestTripFirst)
        let attempts = try enrichmentAttemptsByKey(tripIDs: trips.map(\.id))

        return trips.compactMap { trip in
            let attempt = attempts[enrichmentAttemptKey(tripID: trip.id, component: .route)]
            guard enrichmentAttemptIsEligible(attempt, now: now) else { return nil }
            return TripEnrichmentCandidate(trip: trip, components: [.route])
        }
        .prefix(limit)
        .map { $0 }
    }

    public func fetchRawSamples(tripID: UUID) throws -> [LocationSample] {
        guard hasRawSampleStore else {
            throw TripStoreError.rawSampleStoreUnavailable
        }
        let request = RawSampleEntity.fetchRequest()
        request.predicate = NSPredicate(format: "tripID == %@", tripID as CVarArg)
        request.sortDescriptors = [
            NSSortDescriptor(key: "timestamp", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        return try context.fetch(request).map { sample in
            LocationSample(
                timestamp: sample.timestamp,
                latitude: sample.latitude,
                longitude: sample.longitude,
                horizontalAccuracy: sample.horizontalAccuracy,
                speedMetersPerSecond: sample.speedMetersPerSecond?.doubleValue,
                speedAccuracyMetersPerSecond: sample.speedAccuracyMetersPerSecond?.doubleValue,
                courseDegrees: sample.courseDegrees?.doubleValue,
                motionHint: MotionHint(rawValue: sample.motionHintRaw) ?? .unknown,
                motionActivity: sample.motionActivityData.flatMap {
                    try? decoder.decode(MotionActivitySnapshot.self, from: $0)
                }
            )
        }
    }

    @discardableResult
    public func recordEnrichmentFailure(
        basis: TripAutomaticEnrichmentBasis,
        component: TripEnrichmentComponent,
        category: TripEnrichmentFailureCategory,
        at date: Date = Date()
    ) throws -> TripEnrichmentAttempt? {
        guard hasEnrichmentAttemptStore else {
            throw TripStoreError.enrichmentAttemptStoreUnavailable
        }
        return try transaction {
            guard let trip = try fetchTripEntity(id: basis.tripID) else {
                throw TripStoreError.tripNotFound
            }
            guard automaticEnrichmentBasisMatches(
                basis,
                component: component,
                trip: trip
            ) else { return nil }
            let copies = try fetchEnrichmentAttemptEntities(
                tripID: basis.tripID,
                component: component
            )
            let entity: TripEnrichmentAttemptEntity
            if let preferred = copies.max(by: {
                if $0.lastAttemptAt != $1.lastAttemptAt {
                    return $0.lastAttemptAt < $1.lastAttemptAt
                }
                return $0.consecutiveFailures < $1.consecutiveFailures
            }) {
                entity = preferred
                for copy in copies where copy !== preferred {
                    context.delete(copy)
                }
            } else {
                entity = TripEnrichmentAttemptEntity.insert(into: context)
                entity.id = UUID()
                entity.tripID = basis.tripID
                entity.component = component
                entity.consecutiveFailures = 0
            }
            entity.lastAttemptAt = date
            entity.consecutiveFailures += 1
            entity.failureCategory = category
            guard let attempt = entity.asAttempt else {
                throw TripStoreError.invalidBulkRequest
            }
            return attempt
        }
    }

    public func fetchEnrichmentAttempt(
        tripID: UUID,
        component: TripEnrichmentComponent
    ) throws -> TripEnrichmentAttempt? {
        guard hasEnrichmentAttemptStore else { return nil }
        return try fetchEnrichmentAttemptEntities(tripID: tripID, component: component)
            .compactMap(\.asAttempt)
            .max {
                if $0.lastAttemptAt != $1.lastAttemptAt {
                    return $0.lastAttemptAt < $1.lastAttemptAt
                }
                return $0.consecutiveFailures < $1.consecutiveFailures
            }
    }

    /// Removes local retry metadata that no longer describes work the current
    /// logical trip can perform. Attempts are deliberately stored outside the
    /// CloudKit-backed trip store, so remote completion, archival, merging, or
    /// deletion cannot cascade into them automatically.
    @discardableResult
    public func reconcileEnrichmentAttempts() throws -> Int {
        guard hasEnrichmentAttemptStore else { return 0 }
        return try transaction {
            let snapshot = try enrichmentAttemptReconciliationSnapshot()
            let staleAttempts = snapshot.attempts.filter { attempt in
                !enrichmentAttemptRemainsEligible(
                    attempt,
                    trip: snapshot.tripsByID[attempt.tripID]
                )
            }
            staleAttempts.forEach(context.delete)
            return staleAttempts.count
        }
    }

    /// Support exports use this allow-list as a second line of defense. It
    /// keeps export generation read-only while excluding orphaned metadata even
    /// if a remote change arrived immediately before the normal reconciliation
    /// hook ran.
    func eligibleEnrichmentAttemptIDs() throws -> [UUID] {
        guard hasEnrichmentAttemptStore else { return [] }
        let snapshot = try enrichmentAttemptReconciliationSnapshot()
        return snapshot.attempts.compactMap { attempt in
            enrichmentAttemptRemainsEligible(
                attempt,
                trip: snapshot.tripsByID[attempt.tripID]
            ) ? attempt.id : nil
        }
    }

    @discardableResult
    public func markEnrichmentUnavailable(
        basis: TripAutomaticEnrichmentBasis,
        component: TripEnrichmentComponent
    ) throws -> TripSummary? {
        try transaction {
            guard let trip = try fetchTripEntity(id: basis.tripID) else {
                throw TripStoreError.tripNotFound
            }
            guard automaticEnrichmentBasisMatches(
                basis,
                component: component,
                trip: trip
            ) else { return nil }
            switch component {
            case .startAddress where trip.startAddressEnrichmentState == .pending:
                trip.startAddressEnrichmentState = .unavailable
            case .endAddress where trip.endAddressEnrichmentState == .pending:
                trip.endAddressEnrichmentState = .unavailable
            case .route where trip.routeEnrichmentState == .pending:
                trip.routeEnrichmentState = .unavailable
            default:
                return trip.toSummary(decoder: decoder)
            }
            try deleteEnrichmentAttempts(tripID: basis.tripID, components: [component])
            trip.updatedAt = Date()
            return trip.toSummary(decoder: decoder)
        }
    }

    public func purgeExpiredRawSamples(now: Date = Date()) throws -> Int {
        guard hasRawSampleStore else { return 0 }
        return try transaction {
            let request = RawSampleEntity.fetchRequest()
            request.predicate = NSPredicate(format: "expiresAt < %@", now as NSDate)
            let objects = try context.fetch(request)
            objects.forEach(context.delete)
            return objects.count
        }
    }

    public func rawSampleCount(tripID: UUID? = nil) throws -> Int {
        guard hasRawSampleStore else { return 0 }
        let request = RawSampleEntity.fetchRequest()
        if let tripID {
            request.predicate = NSPredicate(format: "tripID == %@", tripID as CVarArg)
        }
        return try context.count(for: request)
    }

    // MARK: - Transaction wrapper

    private func validateUniqueTripIDs(_ ids: [UUID]) throws {
        guard Set(ids).count == ids.count else {
            throw TripStoreError.invalidBulkRequest
        }
    }

    private func validateEditableSnapshot(_ snapshot: TripEditableSnapshot) throws {
        try Validator.validateDateRange(start: snapshot.startDate, end: snapshot.endDate)
        try Validator.validateDistance(snapshot.distanceMeters)
        try Validator.validateDistance(snapshot.manualDistanceOverrideMeters)
        try Validator.validateRoutePolyline(snapshot.routePolyline)
        try Validator.validateAmount(snapshot.tollsAmount)
        try Validator.validateAmount(snapshot.parkingAmount)
        if let coordinate = snapshot.startCoordinate { try Validator.validate(coordinate) }
        if let coordinate = snapshot.endCoordinate { try Validator.validate(coordinate) }
        for leg in snapshot.legs { try Validator.validate(leg) }
        for connector in snapshot.connectors { try Validator.validate(connector) }
        for fee in snapshot.fees { try Validator.validate(fee) }
    }

    private func validateManualTripCreation(
        _ input: ManualTripInput,
        fees: [TripFee],
        id: UUID
    ) throws {
        try Validator.validate(input)
        if input.routePolyline != nil,
           input.startCoordinate == nil || input.endCoordinate == nil {
            throw TripStoreError.invalidRoute
        }
        if input.classification != .business,
           emptyToNil(input.businessPurpose) != nil {
            throw TripStoreError.invalidBusinessPurpose
        }
        if let vehicleID = input.vehicleID,
           try !activeVehicleExists(vehicleID) {
            throw VehicleStoreError.vehicleNotFound
        }

        let feeIDs = fees.map(\.id)
        guard Set(feeIDs).count == feeIDs.count else {
            throw TripStoreError.invalidFeeEdit
        }
        for var fee in fees {
            guard fee.source != .ezPassImport,
                  fee.tripID == nil || fee.tripID == id,
                  try fetchFeeEntity(id: fee.id) == nil else {
                throw TripStoreError.invalidFeeEdit
            }
            fee.tripID = id
            try Validator.validate(fee)
        }
    }

    private func validateEditorUpdate(
        _ update: TripEditorUpdate,
        tripID: UUID,
        currentFees: [TripFee]
    ) throws {
        try Validator.validateDateRange(start: update.startDate, end: update.endDate)
        try Validator.validateDistance(update.distanceMeters)
        try Validator.validateDistance(update.manualDistanceOverrideMeters)
        try Validator.validateRoutePolyline(update.routePolyline)
        if let coordinate = update.startCoordinate { try Validator.validate(coordinate) }
        if let coordinate = update.endCoordinate { try Validator.validate(coordinate) }
        if update.routePolyline != nil,
           update.startCoordinate == nil || update.endCoordinate == nil {
            throw TripStoreError.invalidCoordinate
        }
        if let vehicleID = update.vehicleID, try !activeVehicleExists(vehicleID) {
            throw VehicleStoreError.vehicleNotFound
        }
        if update.classification != .business,
           emptyToNil(update.businessPurpose) != nil,
           emptyToNil(update.businessPurpose) != emptyToNil(try fetchTripEntity(id: tripID)?.businessPurpose) {
            throw TripStoreError.invalidBusinessPurpose
        }

        let ids = update.fees.map(\.id)
        guard Set(ids).count == ids.count else { throw TripStoreError.invalidFeeEdit }
        let currentByID = Dictionary(uniqueKeysWithValues: currentFees.map { ($0.id, $0) })
        let currentImportedIDs = Set(currentFees.filter { $0.source == .ezPassImport }.map(\.id))
        let draftImportedIDs = Set(update.fees.filter { $0.source == .ezPassImport }.map(\.id))
        guard currentImportedIDs == draftImportedIDs else { throw TripStoreError.invalidFeeEdit }

        for var fee in update.fees {
            fee.tripID = tripID
            try Validator.validate(fee)
            if let storedEntity = try fetchFeeEntity(id: fee.id) {
                guard storedEntity.tripID == tripID else { throw TripStoreError.invalidFeeEdit }
            }
            if fee.source == .ezPassImport {
                guard var current = currentByID[fee.id] else { throw TripStoreError.invalidFeeEdit }
                current.tripID = tripID
                guard current == fee else { throw TripStoreError.invalidFeeEdit }
            }
        }
    }

    private func replaceEditorFees(
        _ fees: [TripFee],
        tripID: UUID,
        currentFees: [TripFee]
    ) throws {
        let requestedIDs = Set(fees.map(\.id))
        for current in currentFees
        where current.source != .ezPassImport && !requestedIDs.contains(current.id) {
            try fetchFeeEntities(id: current.id).forEach(context.delete)
        }
        for var fee in fees where fee.source != .ezPassImport {
            fee.tripID = tripID
            let copies = try fetchFeeEntities(id: fee.id)
            let entity = copies.isEmpty
                ? TripFeeEntity.insert(into: context)
                : try convergeFeeCopies(copies)
            write(fee: fee, to: entity)
        }
        try recomputeFeeTotals(forTripID: tripID, marksEdited: false)
    }

    private func restoreEditableSnapshot(
        _ snapshot: TripEditableSnapshot,
        to trip: TripEntity
    ) throws -> TripSummary {
        let current = trip.toSummary(decoder: decoder)
        let normalizedStartComponents = snapshot.startAddressComponents?.hasDisplayableComponent == true
            ? snapshot.startAddressComponents
            : nil
        let normalizedEndComponents = snapshot.endAddressComponents?.hasDisplayableComponent == true
            ? snapshot.endAddressComponents
            : nil
        let startEndpointChanged = snapshot.startCoordinate != current.startCoordinate
            || emptyToNil(snapshot.startAddress) != emptyToNil(current.startAddress)
            || normalizedStartComponents != current.startAddressComponents
        let endEndpointChanged = snapshot.endCoordinate != current.endCoordinate
            || emptyToNil(snapshot.endAddress) != emptyToNil(current.endAddress)
            || normalizedEndComponents != current.endAddressComponents
        let routeChanged = snapshot.startCoordinate != current.startCoordinate
            || snapshot.endCoordinate != current.endCoordinate
            || snapshot.routePolyline != current.routePolyline
            || snapshot.distanceMeters != current.distanceMeters
            || snapshot.manualDistanceOverrideMeters != current.manualDistanceOverrideMeters

        trip.startDate = snapshot.startDate
        trip.endDate = snapshot.endDate
        trip.durationSeconds = snapshot.endDate.timeIntervalSince(snapshot.startDate)
        trip.startCoordinate = snapshot.startCoordinate
        trip.endCoordinate = snapshot.endCoordinate
        trip.startAddress = emptyToNil(snapshot.startAddress)
        trip.endAddress = emptyToNil(snapshot.endAddress)
        trip.setStartAddressComponents(snapshot.startAddressComponents, encoder: encoder)
        trip.setEndAddressComponents(snapshot.endAddressComponents, encoder: encoder)
        trip.distanceMeters = snapshot.distanceMeters
        trip.routePolyline = snapshot.routePolyline
        trip.classification = snapshot.classification
        trip.classificationSource = snapshot.classificationSource
        trip.reviewStatus = snapshot.reviewStatus
        trip.businessPurpose = emptyToNil(snapshot.businessPurpose)
        trip.notes = emptyToNil(snapshot.notes)
        trip.tollsAmount = snapshot.tollsAmount
        trip.parkingAmount = snapshot.parkingAmount
        trip.needsAttention = snapshot.needsAttention
        trip.setAttentionReasons(snapshot.attentionReasons, encoder: encoder)
        trip.manualDistanceOverride = snapshot.manualDistanceOverrideMeters
        trip.vehicleID = snapshot.vehicleID
        trip.vehicleAssignmentSource = snapshot.vehicleAssignmentSource
        try trip.setLegs(snapshot.legs, encoder: encoder)
        try trip.setConnectors(snapshot.connectors, encoder: encoder)
        var userManagedComponents = Set<TripEnrichmentComponent>()
        if startEndpointChanged {
            trip.startAddressEnrichmentState = .userManaged
            userManagedComponents.insert(.startAddress)
        }
        if endEndpointChanged {
            trip.endAddressEnrichmentState = .userManaged
            userManagedComponents.insert(.endAddress)
        }
        if routeChanged {
            trip.routeEnrichmentState = .userManaged
            userManagedComponents.insert(.route)
        }
        try deleteEnrichmentAttempts(
            tripID: snapshot.tripID,
            components: userManagedComponents
        )

        let snapshotFeeIDs = Set(snapshot.fees.map(\.id))
        for fee in try fetchFeeEntities(tripID: snapshot.tripID)
        where fee.id.map({ !snapshotFeeIDs.contains($0) }) ?? true {
            if fee.source == .ezPassImport {
                fee.tripID = nil
            } else {
                context.delete(fee)
            }
        }
        for fee in snapshot.fees {
            var restoredFee = fee
            restoredFee.tripID = snapshot.tripID
            let copies = try fetchFeeEntities(id: restoredFee.id)
            let entity = copies.isEmpty
                ? TripFeeEntity.insert(into: context)
                : try convergeFeeCopies(copies)
            write(fee: restoredFee, to: entity)
        }

        markEdited(trip)
        return trip.toSummary(decoder: decoder)
    }

    @discardableResult
    private func transaction<T>(_ work: () throws -> T) throws -> T {
        do {
            let result = try work()
            if context.hasChanges {
                // Deleted rows lose their attributes at save, so the change set
                // must be captured first; it is delivered only after the save
                // succeeds so observers never see rolled-back state.
                let change = pendingTripChangeSet()
                try context.save()
                if !change.isEmpty {
                    changeObserver?.tripStoreDidChange(change)
                }
            }
            return result
        } catch {
            if context.hasChanges {
                context.rollback()
            }
            throw error
        }
    }

    private func pendingTripChangeSet() -> TripChangeSet {
        let upserted = context.insertedObjects.union(context.updatedObjects)
            .compactMap { $0 as? TripEntity }
            .map { $0.toSummary(decoder: decoder) }
            .reduce(into: [UUID: TripSummary]()) { result, trip in
                if let current = result[trip.id] {
                    result[trip.id] = Self.preferredTripSummary(current, trip)
                } else {
                    result[trip.id] = trip
                }
            }
            .values
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate { return lhs.startDate > rhs.startDate }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        let deletedIDs = Set(context.deletedObjects.compactMap { ($0 as? TripEntity)?.id })
            .sorted { $0.uuidString < $1.uuidString }
        return TripChangeSet(upserted: upserted, deletedIDs: deletedIDs)
    }

    // MARK: - Private builders

    private func insertManualTrip(_ input: ManualTripInput, id: UUID = UUID()) throws -> TripEntity {
        try Validator.validate(input)
        let trip = try fetchTripEntity(id: id) ?? TripEntity.insert(into: context)
        let now = Date()
        trip.id = id
        trip.createdAt = trip.createdAt ?? now
        trip.updatedAt = now
        trip.captureSource = "manual"
        trip.startDate = input.startDate
        trip.endDate = input.endDate
        trip.startCoordinate = input.startCoordinate
        trip.endCoordinate = input.endCoordinate
        trip.startAddress = emptyToNil(input.startAddress)
        trip.endAddress = emptyToNil(input.endAddress)
        trip.startAddressEnrichmentState = .userManaged
        trip.endAddressEnrichmentState = .userManaged
        trip.setStartAddressComponents(nil, encoder: encoder)
        trip.setEndAddressComponents(nil, encoder: encoder)
        trip.distanceMeters = input.distanceMeters
        trip.manualDistanceOverrideMeters = input.manualDistanceOverrideMeters.asNSNumber
        trip.durationSeconds = input.endDate.timeIntervalSince(input.startDate)
        trip.routePolyline = input.routePolyline
        trip.routeEnrichmentState = .userManaged
        try deleteEnrichmentAttempts(
            tripID: id,
            components: Set(TripEnrichmentComponent.allCases)
        )
        try applyLegs([
            TripLeg(
                id: id,
                sourceTripID: id,
                captureSource: "manual",
                startDate: input.startDate,
                endDate: input.endDate,
                startCoordinate: input.startCoordinate,
                endCoordinate: input.endCoordinate,
                startAddress: emptyToNil(input.startAddress),
                endAddress: emptyToNil(input.endAddress),
                distanceMeters: input.distanceMeters,
                routePolyline: input.routePolyline
            )
        ], to: trip)
        trip.classification = input.classification
        trip.businessPurpose = emptyToNil(input.businessPurpose)
        trip.notes = emptyToNil(input.notes)
        if let vehicleID = input.vehicleID {
            trip.vehicleID = vehicleID
            trip.vehicleAssignmentSource = .manual
        }
        trip.needsAttention = false
        trip.setAttentionReasons([], encoder: encoder)
        normalizeReviewState(for: trip)
        return trip
    }

    private func writeOdometerCheckpoint(_ checkpoint: OdometerCheckpoint) throws {
        try Validator.validate(checkpoint)
        let copies = try fetchOdometerCheckpointEntities(id: checkpoint.id)
        let object = copies.isEmpty
            ? OdometerCheckpointEntity.insert(into: context)
            : try convergeOdometerCheckpointCopies(copies)
        object.id = checkpoint.id
        object.date = checkpoint.date
        object.odometerMiles = checkpoint.odometerMiles
        object.note = emptyToNil(checkpoint.note)
        object.vehicleID = checkpoint.vehicleID
        object.createdAt = object.createdAt ?? Date()
    }

    private func fetchOdometerCheckpointEntities(id: UUID) throws -> [OdometerCheckpointEntity] {
        let request = OdometerCheckpointEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request)
    }

    private func logicalOdometerEntities(
        _ entities: [OdometerCheckpointEntity]
    ) throws -> [OdometerCheckpointEntity] {
        let grouped = Dictionary(grouping: entities) { $0.id }
        var logical: [OdometerCheckpointEntity] = []
        logical.reserveCapacity(grouped.count)
        for (id, copies) in grouped {
            guard id != nil else { throw TripStoreError.invalidOdometer }
            logical.append(try preferredLogicalOdometerEntity(in: copies))
        }
        return logical.sorted { lhs, rhs in
            let lhsDate = lhs.date ?? .distantPast
            let rhsDate = rhs.date ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
        }
    }

    private func preferredLogicalOdometerEntity(
        in copies: [OdometerCheckpointEntity]
    ) throws -> OdometerCheckpointEntity {
        guard let first = copies.first else { throw TripStoreError.odometerCheckpointNotFound }
        let expected = first.asCheckpoint
        guard copies.dropFirst().allSatisfy({ $0.asCheckpoint == expected }) else {
            throw TripStoreError.invalidOdometer
        }
        return copies.max { lhs, rhs in
            lhs.objectID.uriRepresentation().absoluteString
                < rhs.objectID.uriRepresentation().absoluteString
        } ?? first
    }

    private func convergeOdometerCheckpointCopies(
        _ copies: [OdometerCheckpointEntity]
    ) throws -> OdometerCheckpointEntity {
        let preferred = try preferredLogicalOdometerEntity(in: copies)
        for copy in copies where copy.objectID != preferred.objectID {
            context.delete(copy)
        }
        return preferred
    }

    private func replaceRawSamples(tripID: UUID, with samples: [LocationSample], retentionDays: Int) throws {
        guard hasRawSampleStore else {
            if samples.isEmpty { return }
            throw TripStoreError.rawSampleStoreUnavailable
        }
        try deleteRawSamples(tripID: tripID)
        let expiresAt = Calendar.current.date(byAdding: .day, value: retentionDays, to: Date())
            ?? Date().addingTimeInterval(30 * 24 * 60 * 60)
        for sample in samples {
            try Validator.validate(sample)
            let entity = RawSampleEntity.insert(into: context)
            entity.id = UUID()
            entity.tripID = tripID
            entity.timestamp = sample.timestamp
            entity.latitude = sample.latitude
            entity.longitude = sample.longitude
            entity.horizontalAccuracy = sample.horizontalAccuracy
            entity.speedMetersPerSecond = sample.speedMetersPerSecond.asNSNumber
            entity.speedAccuracyMetersPerSecond = sample.speedAccuracyMetersPerSecond.asNSNumber
            entity.courseDegrees = sample.courseDegrees.asNSNumber
            entity.motionHintRaw = sample.motionHint.rawValue
            entity.motionActivityData = try? encoder.encode(sample.motionActivity)
            entity.expiresAt = expiresAt
        }
    }

    private func deleteRawSamples(tripID: UUID) throws {
        guard hasRawSampleStore else { return }
        let request = RawSampleEntity.fetchRequest()
        request.predicate = NSPredicate(format: "tripID == %@", tripID as CVarArg)
        try context.fetch(request).forEach(context.delete)
    }

    private func reassignRawSamples(from sourceTripID: UUID, to destinationTripID: UUID) throws {
        guard hasRawSampleStore else { return }
        let request = RawSampleEntity.fetchRequest()
        request.predicate = NSPredicate(format: "tripID == %@", sourceTripID as CVarArg)
        for sample in try context.fetch(request) {
            sample.tripID = destinationTripID
        }
    }

    private func reassignFees(from sourceTripID: UUID, to destinationTripID: UUID) throws {
        let request = TripFeeEntity.fetchRequest()
        request.predicate = NSPredicate(format: "tripID == %@", sourceTripID as CVarArg)
        for fee in try context.fetch(request) {
            fee.tripID = destinationTripID
        }
    }

    private func splitMergedTrip(_ merged: TripEntity, legIDs: [UUID]) throws -> [TripSummary] {
        let summary = merged.toSummary(decoder: decoder)
        guard summary.isMerged else {
            throw TripStoreError.notMergedTrip
        }
        let selectedIDs = Set(legIDs.isEmpty ? summary.legs.map(\.id) : legIDs)
        let selectedLegs = summary.legs.filter { selectedIDs.contains($0.id) }
        guard !selectedLegs.isEmpty else {
            throw TripStoreError.tripNotFound
        }

        let restored = try selectedLegs.map { leg in
            try makeTripEntity(from: merged, leg: leg, id: leg.sourceTripID ?? UUID())
        }
        let remainingLegs = summary.legs.filter { !selectedIDs.contains($0.id) }
        var destinations = restored
        if remainingLegs.isEmpty {
            if let mergedID = merged.id {
                try reassignRawSamplesByDate(from: mergedID, to: destinations)
                try reassignFeesByDate(from: mergedID, to: destinations)
                try deleteEnrichmentAttempts(
                    tripID: mergedID,
                    components: Set(TripEnrichmentComponent.allCases)
                )
            }
            context.delete(merged)
        } else {
            let remainingConnectors = filteredConnectors(summary.connectors, keepingLegIDs: Set(remainingLegs.map(\.id)))
            try applyLegs(remainingLegs, connectors: remainingConnectors, to: merged)
            merged.startAddressEnrichmentState = .userManaged
            merged.endAddressEnrichmentState = .userManaged
            merged.routeEnrichmentState = .userManaged
            normalizeReviewState(for: merged)
            markEdited(merged)
            destinations.append(merged)
            if let mergedID = merged.id {
                try deleteEnrichmentAttempts(
                    tripID: mergedID,
                    components: Set(TripEnrichmentComponent.allCases)
                )
                try reassignRawSamplesByDate(from: mergedID, to: destinations)
                try reassignFeesByDate(from: mergedID, to: destinations)
            }
        }
        for destination in destinations {
            if let id = destination.id {
                try recomputeFeeTotals(forTripID: id)
            }
        }

        return restored.map { $0.toSummary(decoder: decoder) }.sorted { $0.startDate < $1.startDate }
    }

    private func makeTripEntity(from parent: TripEntity, leg: TripLeg, id: UUID) throws -> TripEntity {
        let trip = TripEntity.insert(into: context)
        trip.id = id
        trip.createdAt = parent.createdAt ?? Date()
        trip.updatedAt = Date()
        trip.captureSource = leg.captureSource == "merged" ? "manual" : leg.captureSource
        trip.classification = parent.classification
        trip.reviewStatus = parent.reviewStatus
        trip.businessPurpose = parent.businessPurpose
        trip.notes = parent.notes
        trip.needsAttention = parent.needsAttention
        trip.setAttentionReasons(parent.attentionReasons(decoder: decoder), encoder: encoder)
        trip.manualDistanceOverride = nil
        trip.vehicleID = parent.vehicleID
        trip.vehicleAssignmentSource = parent.vehicleAssignmentSource
        trip.startAddressEnrichmentState = .userManaged
        trip.endAddressEnrichmentState = .userManaged
        trip.routeEnrichmentState = .userManaged

        var normalizedLeg = leg
        normalizedLeg.sourceTripID = id
        normalizedLeg.stopDurationAfterSeconds = nil
        try applyLegs([normalizedLeg], connectors: [], to: trip)
        normalizeReviewState(for: trip, requestedStatus: parent.reviewStatus)
        markEdited(trip)
        return trip
    }

    private enum RoutePolylineWrite {
        case derived
        case exact(String?)
    }

    private func applyLegs(
        _ legs: [TripLeg],
        connectors: [TripLegConnector] = [],
        routePolylineWrite: RoutePolylineWrite = .derived,
        to trip: TripEntity
    ) throws {
        let legs = normalizedLegs(legs)
        let connectors = filteredConnectors(connectors, keepingLegIDs: Set(legs.map(\.id)))
        guard let boundaries = legs.tripBoundaryIndices else {
            throw TripStoreError.invalidDateRange
        }
        let first = legs[boundaries.start]
        let last = legs[boundaries.end]
        for leg in legs {
            try Validator.validate(leg)
        }
        for connector in connectors {
            try Validator.validate(connector)
        }

        if trip.startCoordinate != first.startCoordinate || trip.startAddress != emptyToNil(first.startAddress) {
            trip.setStartAddressComponents(first.startAddressComponents, encoder: encoder)
        }
        if trip.endCoordinate != last.endCoordinate || trip.endAddress != emptyToNil(last.endAddress) {
            trip.setEndAddressComponents(last.endAddressComponents, encoder: encoder)
        }
        trip.startDate = first.startDate
        trip.endDate = last.endDate
        trip.startCoordinate = first.startCoordinate
        trip.endCoordinate = last.endCoordinate
        trip.startAddress = emptyToNil(first.startAddress)
        trip.endAddress = emptyToNil(last.endAddress)
        trip.distanceMeters = legs.reduce(0) { $0 + $1.distanceMeters } + connectors.reduce(0) { $0 + $1.distanceMeters }
        trip.durationSeconds = last.endDate.timeIntervalSince(first.startDate)
        // An exact write must preserve nil. Nil means the user invalidated the
        // prior route; deriving from legs here would silently restore stale map
        // geometry during the same editor transaction.
        switch routePolylineWrite {
        case .derived:
            trip.routePolyline = TripRouteSummary(legs: legs, connectors: connectors).routePolyline
        case .exact(let routePolyline):
            trip.routePolyline = routePolyline
        }
        trip.tollsAmount = legs.reduce(0) { $0 + $1.tollsAmount }
        trip.parkingAmount = legs.reduce(0) { $0 + $1.parkingAmount }
        try trip.setLegs(legs, encoder: encoder)
        try trip.setConnectors(connectors, encoder: encoder)
    }

    private func normalizedLegs(_ legs: [TripLeg]) -> [TripLeg] {
        var result = legs.sorted { $0.startDate < $1.startDate }
        for index in result.indices {
            let nextIndex = result.index(after: index)
            result[index].stopDurationAfterSeconds = result.indices.contains(nextIndex)
                ? max(0, result[nextIndex].startDate.timeIntervalSince(result[index].endDate))
                : nil
        }
        return result
    }

    private func connectors(
        for legs: [TripLeg],
        preserving connectors: [TripLegConnector],
        policy: MergeConnectorPolicy
    ) -> [TripLegConnector] {
        let legs = normalizedLegs(legs)
        var result = filteredConnectors(connectors, keepingLegIDs: Set(legs.map(\.id)))
        guard policy == .createNearbyConnectors, legs.count >= 2 else {
            return result
        }

        var existingPairs = Set(result.map(Self.connectorPairKey))
        for index in legs.indices.dropFirst() {
            let previousIndex = legs.index(before: index)
            let previousLeg = legs[previousIndex]
            let nextLeg = legs[index]
            let pairKey = Self.connectorPairKey(from: previousLeg.id, to: nextLeg.id)
            guard !existingPairs.contains(pairKey),
                  let previousEnd = previousLeg.endCoordinate,
                  let nextStart = nextLeg.startCoordinate else {
                continue
            }

            let connectorDistance = DistanceCalculator.distanceMeters(from: previousEnd, to: nextStart)
            guard connectorDistance.isFinite,
                  connectorDistance <= Self.mergeConnectorMaximumDistanceMeters else { continue }

            result.append(TripLegConnector(
                fromLegID: previousLeg.id,
                toLegID: nextLeg.id,
                startCoordinate: previousEnd,
                endCoordinate: nextStart,
                startAddress: previousLeg.endAddress,
                endAddress: nextLeg.startAddress,
                distanceMeters: connectorDistance,
                routePolyline: EncodedPolyline.encode([previousEnd, nextStart])
            ))
            existingPairs.insert(pairKey)
        }
        return result
    }

    private func filteredConnectors(_ connectors: [TripLegConnector], keepingLegIDs legIDs: Set<UUID>) -> [TripLegConnector] {
        var seenPairs = Set<String>()
        return connectors.filter { connector in
            guard legIDs.contains(connector.fromLegID),
                  legIDs.contains(connector.toLegID) else { return false }
            return seenPairs.insert(Self.connectorPairKey(connector)).inserted
        }
    }

    private static func connectorPairKey(_ connector: TripLegConnector) -> String {
        connectorPairKey(from: connector.fromLegID, to: connector.toLegID)
    }

    private static func connectorPairKey(from fromLegID: UUID, to toLegID: UUID) -> String {
        "\(fromLegID.uuidString)|\(toLegID.uuidString)"
    }

    private func updateLegDates(for trip: TripEntity, startDate: Date, endDate: Date) throws {
        let summary = trip.toSummary(decoder: decoder)
        var legs = summary.legs
        guard let boundaries = legs.tripBoundaryIndices else { return }
        legs[boundaries.start].startDate = startDate
        legs[boundaries.end].endDate = endDate
        // Do not silently ignore an edit that would leave another leg outside
        // the requested range, or rewrite that other capture's timestamps.
        guard legs.allSatisfy({ $0.startDate >= startDate && $0.endDate <= endDate }) else {
            throw TripStoreError.invalidDateRange
        }
        try applyLegs(legs, connectors: summary.connectors, to: trip)
    }

    private func updateLegEndpoints(
        for trip: TripEntity,
        startCoordinate: Coordinate?,
        endCoordinate: Coordinate?,
        startAddress: String?,
        endAddress: String?
    ) throws {
        let summary = trip.toSummary(decoder: decoder)
        var legs = summary.legs
        guard let boundaries = legs.tripBoundaryIndices else { return }
        legs[boundaries.start].startCoordinate = startCoordinate
        legs[boundaries.start].startAddress = emptyToNil(startAddress)
        legs[boundaries.start].startAddressComponents = trip.startAddressComponents(decoder: decoder)
        legs[boundaries.end].endCoordinate = endCoordinate
        legs[boundaries.end].endAddress = emptyToNil(endAddress)
        legs[boundaries.end].endAddressComponents = trip.endAddressComponents(decoder: decoder)
        // Endpoint enrichment must not reinterpret route history. In
        // particular, historical address backfill may run against a route
        // produced by an older encoder (or a retained raw GPS path). Writing
        // only the leg payload preserves the top-level route bytes, mileage,
        // fees, dates, and connectors exactly as they were recorded.
        try trip.setLegs(legs, encoder: encoder)
    }

    private func updateLegRoute(
        for trip: TripEntity,
        startCoordinate: Coordinate?,
        endCoordinate: Coordinate?,
        routePolyline: String?,
        distanceMeters: Double?,
        invalidateStartLegRoute: Bool = false,
        invalidateEndLegRoute: Bool = false,
        clearAllLegRoutes: Bool = false
    ) throws {
        let summary = trip.toSummary(decoder: decoder)
        var legs = summary.legs
        var connectors = summary.connectors
        guard let boundaries = legs.tripBoundaryIndices else { return }
        if legs.count == 1 {
            legs[0].startCoordinate = startCoordinate
            legs[0].endCoordinate = endCoordinate
            legs[0].routePolyline = routePolyline
            if let distanceMeters {
                legs[0].distanceMeters = distanceMeters
            }
        } else {
            legs[boundaries.start].startCoordinate = startCoordinate
            let lastIndex = legs.index(before: legs.endIndex)
            legs[boundaries.end].endCoordinate = endCoordinate
            if let routePolyline,
               let segments = EncodedPolyline.decodeSegments(routePolyline),
               segments.count == legs.count {
                for index in legs.indices {
                    legs[index].routePolyline = EncodedPolyline.encode(segments[index])
                }
            } else if routePolyline == nil {
                if clearAllLegRoutes {
                    for index in legs.indices {
                        legs[index].routePolyline = nil
                    }
                    for index in connectors.indices {
                        connectors[index].routePolyline = nil
                    }
                } else {
                    if invalidateStartLegRoute {
                        legs[boundaries.start].routePolyline = nil
                    }
                    if invalidateEndLegRoute {
                        legs[boundaries.end].routePolyline = nil
                    }
                }
            }
            if let distanceMeters {
                let currentDistance = legs.reduce(0) { $0 + $1.distanceMeters } + summary.connectors.reduce(0) { $0 + $1.distanceMeters }
                legs[lastIndex].distanceMeters = max(0, legs[lastIndex].distanceMeters + (distanceMeters - currentDistance))
            }
        }
        // Preserve the caller's edited polyline as the trip-level route. For merged
        // trips this is the source the map renders, so it must not be clobbered by the
        // per-leg reconstruction inside applyLegs.
        try applyLegs(
            legs,
            connectors: connectors,
            routePolylineWrite: .exact(routePolyline),
            to: trip
        )
    }

    private func reassignRawSamplesByDate(from sourceTripID: UUID, to destinations: [TripEntity]) throws {
        guard hasRawSampleStore else { return }
        let request = RawSampleEntity.fetchRequest()
        request.predicate = NSPredicate(format: "tripID == %@", sourceTripID as CVarArg)
        for sample in try context.fetch(request) {
            if let destinationID = destinationTripID(for: sample.timestamp, destinations: destinations) {
                sample.tripID = destinationID
            }
        }
    }

    private func reassignFeesByDate(from sourceTripID: UUID, to destinations: [TripEntity]) throws {
        let request = TripFeeEntity.fetchRequest()
        request.predicate = NSPredicate(format: "tripID == %@", sourceTripID as CVarArg)
        for fee in try context.fetch(request) {
            guard let occurredAt = fee.occurredAt else {
                fee.tripID = destinations.count == 1 ? destinations[0].id : nil
                continue
            }
            fee.tripID = destinationTripID(for: occurredAt, destinations: destinations)
        }
        for destination in destinations {
            if let id = destination.id {
                try recomputeFeeTotals(forTripID: id)
            }
        }
    }

    private func destinationTripID(for timestamp: Date, destinations: [TripEntity]) -> UUID? {
        if let matched = destinations.first(where: { destination in
            guard let startDate = destination.startDate, let endDate = destination.endDate else { return false }
            return timestamp >= startDate && timestamp <= endDate
        }) {
            return matched.id
        }
        return destinations
            .compactMap { destination -> (id: UUID, distance: TimeInterval)? in
                guard let id = destination.id,
                      let startDate = destination.startDate,
                      let endDate = destination.endDate else { return nil }
                return (id, min(abs(timestamp.timeIntervalSince(startDate)), abs(timestamp.timeIntervalSince(endDate))))
            }
            .min { $0.distance < $1.distance }?
            .id
    }

    private var hasRawSampleStore: Bool {
        PersistenceController.hasLoadedStore(
            configurationName: PersistenceController.localConfigurationName,
            in: context
        )
    }

    private var hasEnrichmentAttemptStore: Bool {
        PersistenceController.hasLoadedStore(
            configurationName: PersistenceController.localConfigurationName,
            in: context
        )
    }

    private static func newestTripFirst(_ lhs: TripSummary, _ rhs: TripSummary) -> Bool {
        if lhs.startDate != rhs.startDate { return lhs.startDate > rhs.startDate }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func legacyAddressState(
        trip: TripEntity,
        address: String?,
        coordinate: Coordinate?
    ) -> TripEnrichmentState {
        if emptyToNil(address) != nil {
            return .complete
        }
        return trip.captureSource == "automatic"
            && isValidEnrichmentCoordinate(coordinate)
            ? .pending
            : .legacy
    }

    private func isValidEnrichmentCoordinate(_ coordinate: Coordinate?) -> Bool {
        guard let coordinate else { return false }
        return coordinate.latitude.isFinite
            && coordinate.longitude.isFinite
            && (-90...90).contains(coordinate.latitude)
            && (-180...180).contains(coordinate.longitude)
    }

    private func enrichmentAttemptKey(
        tripID: UUID,
        component: TripEnrichmentComponent
    ) -> String {
        "\(tripID.uuidString)|\(component.rawValue)"
    }

    private func enrichmentAttemptIsEligible(
        _ attempt: TripEnrichmentAttempt?,
        now: Date
    ) -> Bool {
        attempt.map { $0.nextEligibleAt <= now } ?? true
    }

    private func enrichmentAttemptReconciliationSnapshot() throws -> (
        attempts: [TripEnrichmentAttemptEntity],
        tripsByID: [UUID: TripEntity]
    ) {
        let attempts = try context.fetch(TripEnrichmentAttemptEntity.fetchRequest())
        let tripIDs = Set(attempts.map(\.tripID))
        guard !tripIDs.isEmpty else { return (attempts, [:]) }

        let tripRequest = TripEntity.fetchRequest()
        tripRequest.predicate = NSPredicate(format: "id IN %@", Array(tripIDs) as NSArray)
        let tripsByID = try context.fetch(tripRequest).reduce(
            into: [UUID: TripEntity]()
        ) { result, trip in
            guard let id = trip.id else { return }
            if let current = result[id] {
                result[id] = Self.preferredTripEntity(current, trip)
            } else {
                result[id] = trip
            }
        }
        return (attempts, tripsByID)
    }

    private func enrichmentAttemptRemainsEligible(
        _ attempt: TripEnrichmentAttemptEntity,
        trip: TripEntity?
    ) -> Bool {
        guard let trip,
              trip.captureSource == "automatic",
              let component = attempt.component else {
            return false
        }

        switch component {
        case .startAddress:
            return trip.startAddressEnrichmentState == .pending
                && isValidEnrichmentCoordinate(trip.startCoordinate)
                && emptyToNil(trip.startAddress) == nil
        case .endAddress:
            return trip.endAddressEnrichmentState == .pending
                && isValidEnrichmentCoordinate(trip.endCoordinate)
                && emptyToNil(trip.endAddress) == nil
        case .route:
            return trip.routeEnrichmentState == .pending
        }
    }

    private func enrichmentAttemptsByKey(
        tripIDs: [UUID]
    ) throws -> [String: TripEnrichmentAttempt] {
        guard hasEnrichmentAttemptStore, !tripIDs.isEmpty else { return [:] }
        let request = TripEnrichmentAttemptEntity.fetchRequest()
        request.predicate = NSPredicate(format: "tripID IN %@", tripIDs as NSArray)
        return try context.fetch(request).compactMap(\.asAttempt).reduce(
            into: [String: TripEnrichmentAttempt]()
        ) { result, attempt in
            let key = enrichmentAttemptKey(
                tripID: attempt.tripID,
                component: attempt.component
            )
            if let current = result[key],
               current.lastAttemptAt > attempt.lastAttemptAt
                    || (current.lastAttemptAt == attempt.lastAttemptAt
                        && current.consecutiveFailures >= attempt.consecutiveFailures) {
                return
            }
            result[key] = attempt
        }
    }

    private func fetchEnrichmentAttemptEntities(
        tripID: UUID,
        component: TripEnrichmentComponent
    ) throws -> [TripEnrichmentAttemptEntity] {
        guard hasEnrichmentAttemptStore else { return [] }
        let request = TripEnrichmentAttemptEntity.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "tripID == %@", tripID as CVarArg),
            NSPredicate(format: "componentRaw == %@", component.rawValue)
        ])
        return try context.fetch(request)
    }

    private func deleteEnrichmentAttempts(
        tripID: UUID,
        components: Set<TripEnrichmentComponent>
    ) throws {
        guard hasEnrichmentAttemptStore, !components.isEmpty else { return }
        let request = TripEnrichmentAttemptEntity.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "tripID == %@", tripID as CVarArg),
            NSPredicate(format: "componentRaw IN %@", components.map(\.rawValue))
        ])
        try context.fetch(request).forEach(context.delete)
    }

    private func mergedNotes(from summaries: [TripSummary]) -> String? {
        let notes = summaries.reduce(into: [String]()) { result, summary in
            guard let note = emptyToNil(summary.notes), !result.contains(note) else { return }
            result.append(note)
        }
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    private func fetchTripEntity(id: UUID) throws -> TripEntity? {
        try fetchTripEntities(id: id).reduce(nil) { current, candidate in
            guard let current else { return candidate }
            return Self.preferredTripEntity(current, candidate)
        }
    }

    private func fetchTripEntities(id: UUID) throws -> [TripEntity] {
        let request = TripEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request)
    }

    private func fetchPreferredTripEntities(
        from startDate: Date?,
        to endDate: Date?,
        vehicle: VehicleFilter
    ) throws -> [TripEntity] {
        var candidatePredicates: [NSPredicate] = []
        if let startDate {
            candidatePredicates.append(NSPredicate(format: "endDate >= %@", startDate as NSDate))
        }
        if let endDate {
            candidatePredicates.append(NSPredicate(format: "startDate <= %@", endDate as NSDate))
        }
        if let vehiclePredicate = Self.vehiclePredicate(for: vehicle) {
            candidatePredicates.append(vehiclePredicate)
        }

        let request = TripEntity.fetchRequest()
        if !candidatePredicates.isEmpty {
            let candidateRequest = NSFetchRequest<NSDictionary>(entityName: TripEntity.entityName)
            candidateRequest.resultType = .dictionaryResultType
            candidateRequest.propertiesToFetch = ["id"]
            candidateRequest.predicate = NSCompoundPredicate(
                andPredicateWithSubpredicates: candidatePredicates
            )
            let candidateIDs = Set(
                try context.fetch(candidateRequest).compactMap { Self.uuid($0["id"]) }
            )
            guard !candidateIDs.isEmpty else { return [] }
            request.predicate = NSPredicate(format: "id IN %@", Array(candidateIDs) as NSArray)
        }

        let preferred = try context.fetch(request).reduce(into: [UUID: TripEntity]()) { result, trip in
            guard let id = trip.id else { return }
            if let current = result[id] {
                result[id] = Self.preferredTripEntity(current, trip)
            } else {
                result[id] = trip
            }
        }.values.filter { trip in
            (startDate.map { lowerBound in
                    trip.endDate.map { $0 >= lowerBound } ?? false
                } ?? true)
                && (endDate.map { upperBound in
                    trip.startDate.map { $0 <= upperBound } ?? false
                } ?? true)
                && Self.vehicleMatches(trip.vehicleID, filter: vehicle)
        }

        return preferred.sorted { lhs, rhs in
            let lhsStart = lhs.startDate ?? .distantPast
            let rhsStart = rhs.startDate ?? .distantPast
            if lhsStart != rhsStart { return lhsStart > rhsStart }
            return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
        }
    }

    private static func preferredTripEntity(_ lhs: TripEntity, _ rhs: TripEntity) -> TripEntity {
        let lhsUpdated = lhs.updatedAt ?? .distantPast
        let rhsUpdated = rhs.updatedAt ?? .distantPast
        if lhsUpdated != rhsUpdated { return lhsUpdated > rhsUpdated ? lhs : rhs }
        let lhsCreated = lhs.createdAt ?? .distantPast
        let rhsCreated = rhs.createdAt ?? .distantPast
        if lhsCreated != rhsCreated { return lhsCreated > rhsCreated ? lhs : rhs }
        let lhsStart = lhs.startDate ?? .distantPast
        let rhsStart = rhs.startDate ?? .distantPast
        if lhsStart != rhsStart { return lhsStart > rhsStart ? lhs : rhs }
        let lhsEnd = lhs.endDate ?? .distantPast
        let rhsEnd = rhs.endDate ?? .distantPast
        if lhsEnd != rhsEnd { return lhsEnd > rhsEnd ? lhs : rhs }
        return (lhs.startAddress ?? "") >= (rhs.startAddress ?? "") ? lhs : rhs
    }

    private static func preferredTripSummary(_ lhs: TripSummary, _ rhs: TripSummary) -> TripSummary {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt ? lhs : rhs }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt ? lhs : rhs }
        if lhs.startDate != rhs.startDate { return lhs.startDate > rhs.startDate ? lhs : rhs }
        if lhs.endDate != rhs.endDate { return lhs.endDate > rhs.endDate ? lhs : rhs }
        return (lhs.startAddress ?? "") >= (rhs.startAddress ?? "") ? lhs : rhs
    }

    private func activeVehicleExists(_ id: UUID) throws -> Bool {
        try VehicleEntity.fetchOne(
            in: context,
            where: NSPredicate(format: "id == %@ AND isArchived == NO", id as CVarArg)
        ) != nil
    }

    private func upsertDraftFees(_ fees: [TripFee], tripID: UUID) throws {
        for fee in fees {
            var linkedFee = fee
            linkedFee.tripID = tripID
            try Validator.validate(linkedFee)
            let copies = try fetchFeeEntities(id: linkedFee.id)
            let entity = copies.isEmpty
                ? TripFeeEntity.insert(into: context)
                : try convergeFeeCopies(copies)
            write(fee: linkedFee, to: entity)
        }
    }

    private func automaticEndpointEnrichmentBasisMatches(
        _ basis: TripAutomaticEnrichmentBasis,
        component: TripEnrichmentComponent,
        trip: TripEntity
    ) -> Bool {
        switch component {
        case .startAddress:
            trip.captureSource == "automatic"
                && trip.startAddressEnrichmentState == .pending
                && basis.startAddressEnrichmentState == .pending
                && trip.startCoordinate == basis.startCoordinate
                && trip.startAddress == basis.startAddress
                && trip.startAddressComponents(decoder: decoder) == basis.startAddressComponents
        case .endAddress:
            trip.captureSource == "automatic"
                && trip.endAddressEnrichmentState == .pending
                && basis.endAddressEnrichmentState == .pending
                && trip.endCoordinate == basis.endCoordinate
                && trip.endAddress == basis.endAddress
                && trip.endAddressComponents(decoder: decoder) == basis.endAddressComponents
        case .route:
            false
        }
    }

    private func automaticRouteEnrichmentBasisMatches(
        _ basis: TripAutomaticEnrichmentBasis,
        trip: TripEntity
    ) -> Bool {
        trip.captureSource == "automatic"
            && trip.routeEnrichmentState == .pending
            && basis.routeEnrichmentState == .pending
            && trip.startCoordinate == basis.startCoordinate
            && trip.endCoordinate == basis.endCoordinate
            && trip.routePolyline == basis.routePolyline
            && trip.distanceMeters == basis.distanceMeters
            && trip.manualDistanceOverride == basis.manualDistanceOverrideMeters
    }

    private func automaticEnrichmentBasisMatches(
        _ basis: TripAutomaticEnrichmentBasis,
        component: TripEnrichmentComponent,
        trip: TripEntity
    ) -> Bool {
        switch component {
        case .startAddress, .endAddress:
            automaticEndpointEnrichmentBasisMatches(
                basis,
                component: component,
                trip: trip
            )
        case .route:
            automaticRouteEnrichmentBasisMatches(basis, trip: trip)
        }
    }

    private func automaticRouteAssessmentBasisMatches(
        _ basis: TripAutomaticEnrichmentBasis,
        trip: TripEntity
    ) -> Bool {
        trip.classification == basis.classification
            && trip.reviewStatus == basis.reviewStatus
            && trip.attentionReasons(decoder: decoder) == basis.attentionReasons
            && automaticRouteEnrichmentBasisMatches(basis, trip: trip)
    }

    private func normalizeReviewState(for trip: TripEntity, requestedStatus: ReviewStatus? = nil) {
        if trip.classification == .notADrive {
            // Not-a-drive captures are fully resolved: they carry no business
            // purpose and never demand further review attention.
            trip.businessPurpose = nil
            trip.reviewStatus = .readyToExport
            trip.needsAttention = false
            trip.setAttentionReasons([], encoder: encoder)
            return
        }
        let reasons = TripReviewPolicy.actionableAttentionReasons(
            from: trip.attentionReasons(decoder: decoder)
        )

        trip.reviewStatus = TripReviewPolicy.normalizedStatus(
            classification: trip.classification,
            businessPurpose: trip.businessPurpose,
            hasActionableAttention: !reasons.isEmpty,
            requestedStatus: requestedStatus
        )
        trip.needsAttention = !reasons.isEmpty
        trip.setAttentionReasons(reasons, encoder: encoder)
    }

    private func appendAttentionReason(_ reason: String, to trip: TripEntity) {
        guard trip.classification != .notADrive else {
            normalizeReviewState(for: trip)
            return
        }
        var reasons = TripReviewPolicy.actionableAttentionReasons(
            from: trip.attentionReasons(decoder: decoder)
        )
        guard TripReviewPolicy.isActionableAttentionReason(reason) else {
            normalizeReviewState(for: trip)
            return
        }
        if !reasons.contains(reason) {
            reasons.append(reason)
        }
        trip.reviewStatus = .needsAttention
        trip.needsAttention = true
        trip.setAttentionReasons(reasons, encoder: encoder)
    }

    private func fetchFeeEntity(id: UUID) throws -> TripFeeEntity? {
        let entities = try fetchFeeEntities(id: id)
        guard !entities.isEmpty else { return nil }
        return try preferredLogicalFeeEntity(in: entities)
    }

    private func fetchFeeEntities(id: UUID) throws -> [TripFeeEntity] {
        let request = TripFeeEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request)
    }

    private func fetchFeeEntities(tripID: UUID) throws -> [TripFeeEntity] {
        let request = TripFeeEntity.fetchRequest()
        request.predicate = NSPredicate(format: "tripID == %@", tripID as CVarArg)
        request.sortDescriptors = [
            NSSortDescriptor(key: "occurredAt", ascending: true),
            NSSortDescriptor(key: "amount", ascending: true)
        ]
        return try context.fetch(request)
    }

    private func logicalFeeEntities(_ entities: [TripFeeEntity]) throws -> [TripFeeEntity] {
        let grouped = Dictionary(grouping: entities) { $0.id }
        var logical: [TripFeeEntity] = []
        logical.reserveCapacity(grouped.count)
        for (id, copies) in grouped {
            guard id != nil else { throw TripStoreError.invalidFeeEdit }
            logical.append(try preferredLogicalFeeEntity(in: copies))
        }
        return logical.sorted(by: Self.feeEntityOrder)
    }

    private func preferredLogicalFeeEntity(in copies: [TripFeeEntity]) throws -> TripFeeEntity {
        guard let first = copies.first else { throw TripStoreError.feeNotFound }
        let expected = first.asFee
        guard copies.dropFirst().allSatisfy({ $0.asFee == expected }) else {
            throw TripStoreError.invalidFeeEdit
        }
        return copies.max { lhs, rhs in
            lhs.objectID.uriRepresentation().absoluteString
                < rhs.objectID.uriRepresentation().absoluteString
        } ?? first
    }

    private func convergeFeeCopies(_ copies: [TripFeeEntity]) throws -> TripFeeEntity {
        let preferred = try preferredLogicalFeeEntity(in: copies)
        for copy in copies where copy.objectID != preferred.objectID {
            context.delete(copy)
        }
        return preferred
    }

    private static func feeEntityOrder(_ lhs: TripFeeEntity, _ rhs: TripFeeEntity) -> Bool {
        let lhsDate = lhs.occurredAt ?? .distantPast
        let rhsDate = rhs.occurredAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        if lhs.amount != rhs.amount { return lhs.amount < rhs.amount }
        return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
    }

    private func write(fee: TripFee, to entity: TripFeeEntity) {
        entity.id = fee.id
        entity.tripID = fee.tripID
        entity.category = fee.category
        entity.amount = fee.amount
        entity.occurredAt = fee.occurredAt
        entity.label = emptyToNil(fee.label)
        entity.source = fee.source
        entity.presetID = fee.presetID
        entity.sourceTransactionID = emptyToNil(fee.sourceTransactionID)
        entity.tagOrPlate = emptyToNil(fee.tagOrPlate)
        entity.agency = emptyToNil(fee.agency)
        entity.entryPlaza = emptyToNil(fee.entryPlaza)
        entity.exitPlaza = emptyToNil(fee.exitPlaza)
        entity.vehicleClass = emptyToNil(fee.vehicleClass)
        entity.importedAt = fee.importedAt
    }

    private func replaceLegacyTotalFee(trip: TripEntity, category: TripFeeCategory, totalAmount: Double) throws {
        guard let tripID = trip.id else { throw TripStoreError.tripNotFound }
        let storedFees = try fetchFeeEntities(tripID: tripID)
        let fees = try logicalFeeEntities(storedFees)
        let importedTollAmount = category == .toll
            ? fees.filter { $0.category == .toll && $0.source == .ezPassImport }.reduce(0) { $0 + $1.amount }
            : 0
        guard totalAmount + 0.005 >= importedTollAmount else {
            throw TripStoreError.invalidAmount
        }
        for fee in storedFees where fee.category == category && fee.source != .ezPassImport {
            context.delete(fee)
        }
        let nonImportedAmount = max(0, totalAmount - importedTollAmount)
        if nonImportedAmount > 0.005 {
            for legacyFee in legacyReplacementFees(
                trip: trip,
                category: category,
                targetAmount: nonImportedAmount,
                existingFees: fees
            ) {
                try insertLegacyTotalFee(
                    tripID: tripID,
                    category: category,
                    amount: legacyFee.amount,
                    occurredAt: legacyFee.occurredAt
                )
            }
        }
        try recomputeFeeTotals(forTripID: tripID)
    }

    private func legacyReplacementFees(
        trip: TripEntity,
        category: TripFeeCategory,
        targetAmount: Double,
        existingFees: [TripFeeEntity]
    ) -> [(amount: Double, occurredAt: Date)] {
        let summary = trip.toSummary(decoder: decoder)
        let legs = summary.legs
        guard legs.count > 1 else {
            return [(targetAmount, trip.startDate ?? Date())]
        }

        var existingByLeg = Array(repeating: 0.0, count: legs.count)
        for fee in existingFees where fee.category == category && fee.source != .ezPassImport {
            let index = legIndex(for: fee.occurredAt ?? summary.startDate, legs: legs)
            existingByLeg[index] += fee.amount
        }

        var remaining = targetAmount
        var result: [(amount: Double, occurredAt: Date)] = []
        for index in legs.indices.dropLast() {
            let amount = min(existingByLeg[index], remaining)
            if amount > 0.005 {
                result.append((amount, legs[index].startDate))
                remaining -= amount
            }
        }
        if remaining > 0.005, let last = legs.last {
            result.append((remaining, last.startDate))
        }
        return result
    }

    private func insertLegacyTotalFee(
        tripID: UUID,
        category: TripFeeCategory,
        amount: Double,
        occurredAt: Date
    ) throws {
        try Validator.validateAmount(amount)
        let entity = TripFeeEntity.insert(into: context)
        entity.id = UUID()
        entity.tripID = tripID
        entity.category = category
        entity.amount = amount
        entity.occurredAt = occurredAt
        entity.label = category.displayName
        entity.source = .legacyTotal
    }

    private func recomputeFeeTotals(forTripID tripID: UUID, marksEdited: Bool = true) throws {
        guard let trip = try fetchTripEntity(id: tripID) else {
            throw TripStoreError.tripNotFound
        }
        let fees = try logicalFeeEntities(fetchFeeEntities(tripID: tripID))
        var tollTotal = 0.0
        var parkingTotal = 0.0
        for fee in fees {
            try Validator.validate(fee.asFee)
            switch fee.category {
            case .toll:
                tollTotal += fee.amount
            case .parking:
                parkingTotal += fee.amount
            }
        }

        let summary = trip.toSummary(decoder: decoder)
        var legs = summary.legs
        if !legs.isEmpty {
            for index in legs.indices {
                legs[index].tollsAmount = 0
                legs[index].parkingAmount = 0
            }
            for fee in fees {
                let date = fee.occurredAt ?? summary.startDate
                let index = legIndex(for: date, legs: legs)
                switch fee.category {
                case .toll:
                    legs[index].tollsAmount += fee.amount
                case .parking:
                    legs[index].parkingAmount += fee.amount
                }
            }
            try applyLegs(
                legs,
                connectors: summary.connectors,
                routePolylineWrite: .exact(summary.routePolyline),
                to: trip
            )
        } else {
            trip.tollsAmount = tollTotal
            trip.parkingAmount = parkingTotal
        }
        if marksEdited {
            markEdited(trip)
        }
    }

    private func legIndex(for date: Date, legs: [TripLeg]) -> Array<TripLeg>.Index {
        if let matched = legs.firstIndex(where: { date >= $0.startDate && date <= $0.endDate }) {
            return matched
        }
        return legs.indices.min { lhs, rhs in
            distance(from: date, to: legs[lhs]) < distance(from: date, to: legs[rhs])
        } ?? legs.startIndex
    }

    private func distance(from date: Date, to leg: TripLeg) -> TimeInterval {
        min(abs(date.timeIntervalSince(leg.startDate)), abs(date.timeIntervalSince(leg.endDate)))
    }

    private func emptyToNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func markEdited(_ trip: TripEntity) {
        let now = Date()
        trip.updatedAt = now
        trip.lastEditedAt = now
        trip.lastEditedDeviceName = ProcessInfo.processInfo.hostName
    }

}

// MARK: - Validation

private enum Validator {
    static func validate(_ input: ManualTripInput) throws {
        try validateDateRange(start: input.startDate, end: input.endDate)
        try validateDistance(input.distanceMeters)
        try validateDistance(input.manualDistanceOverrideMeters)
        try validate(input.startCoordinate)
        try validate(input.endCoordinate)
        try validateRoutePolyline(input.routePolyline)
    }

    static func validate(_ draft: TripDraft) throws {
        try validateDateRange(start: draft.startDate, end: draft.endDate)
        try validateDistance(draft.distanceMeters)
        for sample in draft.samples { try validate(sample) }
    }

    static func validate(_ trip: TripSummary) throws {
        try validateDateRange(start: trip.startDate, end: trip.endDate)
        try validateDistance(trip.distanceMeters)
        try validateDistance(trip.manualDistanceOverrideMeters)
        try validateAmount(trip.tollsAmount)
        try validateAmount(trip.parkingAmount)
        try validate(trip.startCoordinate)
        try validate(trip.endCoordinate)
        try validateRoutePolyline(trip.routePolyline)
        guard trip.durationSeconds.isFinite, trip.durationSeconds >= 0 else {
            throw TripStoreError.invalidDateRange
        }
        for leg in trip.legs {
            try validate(leg)
        }
        for connector in trip.connectors {
            try validate(connector)
        }
    }

    static func validate(_ leg: TripLeg) throws {
        try validateDateRange(start: leg.startDate, end: leg.endDate)
        try validate(leg.startCoordinate)
        try validate(leg.endCoordinate)
        try validateDistance(leg.distanceMeters)
        try validateAmount(leg.tollsAmount)
        try validateAmount(leg.parkingAmount)
        try validateRoutePolyline(leg.routePolyline)
        try validateDistance(leg.stopDurationAfterSeconds)
    }

    static func validate(_ connector: TripLegConnector) throws {
        try validate(connector.startCoordinate)
        try validate(connector.endCoordinate)
        try validateDistance(connector.distanceMeters)
        try validateRoutePolyline(connector.routePolyline)
    }

    static func validate(_ fee: TripFee) throws {
        try validateAmount(fee.amount)
        if let sourceTransactionID = fee.sourceTransactionID {
            guard !sourceTransactionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TripStoreError.invalidAmount
            }
        }
    }

    static func validate(_ checkpoint: OdometerCheckpoint) throws {
        try validateOdometer(checkpoint.odometerMiles)
    }

    static func validate(_ report: ReportSnapshot) throws {
        try validateDateRange(start: report.startDate, end: report.endDate)
        try validateDistance(DistanceConversion.meters(fromMiles: report.businessMiles))
        try validateAmount(report.businessValue)
        guard report.rateCentsPerMile.isFinite, report.rateCentsPerMile >= 0 else {
            throw TripStoreError.invalidAmount
        }
    }

    static func validate(_ sample: LocationSample) throws {
        try validate(Coordinate(latitude: sample.latitude, longitude: sample.longitude))
        guard sample.horizontalAccuracy.isFinite, sample.horizontalAccuracy >= 0 else {
            throw TripStoreError.invalidCoordinate
        }
        try validateFinite(sample.speedMetersPerSecond)
        try validateFinite(sample.speedAccuracyMetersPerSecond)
        try validateFinite(sample.courseDegrees)
    }

    static func validate(_ coordinate: Coordinate?) throws {
        guard let coordinate else { return }
        guard coordinate.latitude.isFinite,
              coordinate.longitude.isFinite,
              (-90...90).contains(coordinate.latitude),
              (-180...180).contains(coordinate.longitude) else {
            throw TripStoreError.invalidCoordinate
        }
    }

    static func validateDateRange(start: Date, end: Date) throws {
        guard end > start else { throw TripStoreError.invalidDateRange }
    }

    static func validateDistance(_ value: Double?) throws { try nonNegativeFinite(value, .invalidDistance) }
    static func validateAmount(_ value: Double?) throws { try nonNegativeFinite(value, .invalidAmount) }
    static func validateOdometer(_ value: Double?) throws { try nonNegativeFinite(value, .invalidOdometer) }

    static func validateFinite(_ value: Double?) throws {
        guard let value else { return }
        guard value.isFinite else { throw TripStoreError.invalidCoordinate }
    }

    private static func nonNegativeFinite(_ value: Double?, _ error: TripStoreError) throws {
        guard let value else { return }
        guard value.isFinite, value >= 0 else { throw error }
    }

    static func validateRoutePolyline(_ polyline: String?) throws {
        guard let polyline else { return }
        guard let segments = EncodedPolyline.decodeSegments(polyline),
              segments.allSatisfy({ segment in
                  segment.allSatisfy { coordinate in
                      coordinate.latitude.isFinite &&
                          coordinate.longitude.isFinite &&
                          (-90...90).contains(coordinate.latitude) &&
                          (-180...180).contains(coordinate.longitude)
                  }
              }) else {
            throw TripStoreError.invalidRoute
        }
    }
}
