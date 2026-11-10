import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

protocol ManagedEntity: NSManagedObject {
    static var entityName: String { get }
}

extension ManagedEntity {
    static func fetchRequest() -> NSFetchRequest<Self> {
        NSFetchRequest<Self>(entityName: entityName)
    }

    static func insert(into context: NSManagedObjectContext) -> Self {
        guard let object = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context) as? Self else {
            fatalError("Entity \(entityName) is not registered as \(Self.self)")
        }
        return object
    }

    static func fetchOne(in context: NSManagedObjectContext, where predicate: NSPredicate) throws -> Self? {
        let request = fetchRequest()
        request.fetchLimit = 1
        request.predicate = predicate
        return try context.fetch(request).first
    }
}

@objc(TripEntity)
final class TripEntity: NSManagedObject, ManagedEntity {
    static let entityName = "TripEntity"

    @NSManaged var id: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var captureSource: String
    @NSManaged var startDate: Date?
    @NSManaged var endDate: Date?
    @NSManaged var startLatitude: NSNumber?
    @NSManaged var startLongitude: NSNumber?
    @NSManaged var endLatitude: NSNumber?
    @NSManaged var endLongitude: NSNumber?
    @NSManaged var startAddress: String?
    @NSManaged var endAddress: String?
    @NSManaged var startAddressComponentsData: Data?
    @NSManaged var endAddressComponentsData: Data?
    @NSManaged var distanceMeters: Double
    @NSManaged var durationSeconds: Double
    @NSManaged var routePolyline: String?
    @NSManaged var classificationRaw: String?
    @NSManaged var classificationSourceRaw: String?
    @NSManaged var reviewStatusRaw: String
    @NSManaged var businessPurpose: String?
    @NSManaged var notes: String?
    @NSManaged var tollsAmount: Double
    @NSManaged var parkingAmount: Double
    @NSManaged var needsAttention: Bool
    @NSManaged var attentionReasonsData: Data?
    @NSManaged var manualDistanceOverrideMeters: NSNumber?
    /// Retired: "Exclude from reports" is gone and nothing reads this except
    /// `RetiredTripMaintenance`, which destroys the rows still carrying it. The
    /// attribute stays in the model because its CloudKit counterpart cannot be
    /// deleted from a schema already deployed to Production.
    @NSManaged var isArchived: Bool
    @NSManaged var lastEditedAt: Date?
    @NSManaged var lastEditedDeviceName: String?
    @NSManaged var legsData: Data?
    @NSManaged var connectorsData: Data?
    @NSManaged var startBluetoothHintHashesData: Data?
    @NSManaged var vehicleID: UUID?
    @NSManaged var vehicleAssignmentSourceRaw: String?
    @NSManaged var startAddressEnrichmentStateRaw: String?
    @NSManaged var endAddressEnrichmentStateRaw: String?
    @NSManaged var routeEnrichmentStateRaw: String?
}

@objc(RawSampleEntity)
final class RawSampleEntity: NSManagedObject, ManagedEntity {
    static let entityName = "RawSampleEntity"

    @NSManaged var id: UUID
    @NSManaged var tripID: UUID
    @NSManaged var timestamp: Date
    @NSManaged var latitude: Double
    @NSManaged var longitude: Double
    @NSManaged var horizontalAccuracy: Double
    @NSManaged var speedMetersPerSecond: NSNumber?
    @NSManaged var speedAccuracyMetersPerSecond: NSNumber?
    @NSManaged var courseDegrees: NSNumber?
    @NSManaged var motionHintRaw: String
    @NSManaged var motionActivityData: Data?
    @NSManaged var expiresAt: Date
}

@objc(TripEnrichmentAttemptEntity)
final class TripEnrichmentAttemptEntity: NSManagedObject, ManagedEntity {
    static let entityName = "TripEnrichmentAttemptEntity"

    @NSManaged var id: UUID
    @NSManaged var tripID: UUID
    @NSManaged var componentRaw: String
    @NSManaged var lastAttemptAt: Date
    @NSManaged var consecutiveFailures: Int64
    @NSManaged var failureCategoryRaw: String
}

@objc(DiagnosticSampleEntity)
final class DiagnosticSampleEntity: NSManagedObject, ManagedEntity {
    static let entityName = "DiagnosticSampleEntity"

    @NSManaged var id: UUID
    @NSManaged var monitoringSessionID: UUID
    @NSManaged var tripID: UUID?
    @NSManaged var receivedAt: Date
    @NSManaged var sampleTimestamp: Date
    @NSManaged var latitude: Double
    @NSManaged var longitude: Double
    @NSManaged var horizontalAccuracy: Double
    @NSManaged var speedMetersPerSecond: NSNumber?
    @NSManaged var speedAccuracyMetersPerSecond: NSNumber?
    @NSManaged var courseDegrees: NSNumber?
    @NSManaged var motionHintRaw: String
    @NSManaged var motionActivityData: Data?
    @NSManaged var trackingPhaseRaw: String
    @NSManaged var powerConnected: Bool
    @NSManaged var recentPowerConnected: Bool
    @NSManaged var recentPowerDisconnected: Bool
    @NSManaged var trustedBluetoothVehicleHint: Bool
    @NSManaged var acceptedForDetection: Bool
    @NSManaged var detectionOutputRaw: String?
    @NSManaged var detectionReason: String?
    @NSManaged var expiresAt: Date
}

@objc(DriveCaptureEventEntity)
final class DriveCaptureEventEntity: NSManagedObject, ManagedEntity {
    static let entityName = "DriveCaptureEventEntity"

    @NSManaged var id: UUID
    @NSManaged var date: Date
    @NSManaged var category: String
    @NSManaged var message: String
    @NSManaged var monitoringSessionID: UUID?
    @NSManaged var captureID: UUID?
    @NSManaged var tripID: UUID?
    @NSManaged var trackingPhaseRaw: String?
    @NSManaged var activityLevelRaw: String?
    @NSManaged var wakeReason: String?
    @NSManaged var sampleTimestamp: Date?
    @NSManaged var staleDelaySeconds: NSNumber?
    @NSManaged var powerConnected: Bool
    @NSManaged var recentPowerConnected: Bool
    @NSManaged var recentPowerDisconnected: Bool
    @NSManaged var trustedBluetoothVehicleHint: Bool
    @NSManaged var detectionOutputRaw: String?
    @NSManaged var detectionReason: String?
    @NSManaged var expiresAt: Date
}

@objc(PendingDriveStartSignalEntity)
final class PendingDriveStartSignalEntity: NSManagedObject, ManagedEntity {
    static let entityName = "PendingDriveStartSignalEntity"

    @NSManaged var id: UUID
    @NSManaged var triggerRaw: String
    @NSManaged var sourceRaw: String
    @NSManaged var confidenceRaw: String
    @NSManaged var createdAt: Date
    @NSManaged var expiresAt: Date
    @NSManaged var consumedAt: Date?
    @NSManaged var statusRaw: String
    @NSManaged var resultRaw: String?
    @NSManaged var captureID: UUID?
    @NSManaged var tripID: UUID?
    @NSManaged var updatedAt: Date?
    @NSManaged var vehicleID: UUID?
}

@objc(ActiveDriveEntity)
final class ActiveDriveEntity: NSManagedObject, ManagedEntity {
    static let entityName = "ActiveDriveEntity"

    @NSManaged var id: String
    @NSManaged var captureID: UUID?
    @NSManaged var pendingTripID: UUID?
    @NSManaged var phaseRaw: String
    @NSManaged var candidateStartedAt: Date?
    @NSManaged var startedAt: Date?
    @NSManaged var lastMovingAt: Date?
    @NSManaged var firstStationaryAt: Date?
    @NSManaged var stopDueAt: Date?
    @NSManaged var lastProcessedLocationTimestamp: Date?
    @NSManaged var sampleCount: Int64
    @NSManaged var stateData: Data
    @NSManaged var updatedAt: Date?
}

@objc(BluetoothHintEntity)
final class BluetoothHintEntity: NSManagedObject, ManagedEntity {
    static let entityName = "BluetoothHintEntity"

    @NSManaged var id: UUID
    @NSManaged var identifierHash: String
    @NSManaged var displayName: String?
    @NSManaged var sourceRaw: String
    @NSManaged var firstSeenAt: Date
    @NSManaged var lastSeenAt: Date
    @NSManaged var correlationCount: Int64
    @NSManaged var notADriveCount: Int64
    @NSManaged var trusted: Bool
    @NSManaged var manualTrustOverride: NSNumber?
    @NSManaged var vehicleID: UUID?
    @NSManaged var connectionAliasID: UUID?
    @NSManaged var connectionKindRaw: String
    @NSManaged var mappingDispositionRaw: String
    @NSManaged var mappingUpdatedAt: Date?
    @NSManaged var identityQualityRaw: String
}

@objc(BluetoothObservationEntity)
final class BluetoothObservationEntity: NSManagedObject, ManagedEntity {
    static let entityName = "BluetoothObservationEntity"

    @NSManaged var id: UUID
    @NSManaged var identifierHash: String
    @NSManaged var displayName: String?
    @NSManaged var sourceRaw: String
    @NSManaged var connectionKindRaw: String
    @NSManaged var identityQualityRaw: String
    @NSManaged var observedAt: Date
    @NSManaged var expiresAt: Date
}

@objc(BluetoothMetadataEntity)
final class BluetoothMetadataEntity: NSManagedObject, ManagedEntity {
    static let entityName = "BluetoothMetadataEntity"

    @NSManaged var key: String
    @NSManaged var value: String
}

@objc(OdometerCheckpointEntity)
final class OdometerCheckpointEntity: NSManagedObject, ManagedEntity {
    static let entityName = "OdometerCheckpointEntity"

    @NSManaged var id: UUID?
    @NSManaged var date: Date?
    @NSManaged var odometerMiles: Double
    @NSManaged var note: String?
    @NSManaged var createdAt: Date?
    @NSManaged var vehicleID: UUID?
}

@objc(ReportSnapshotEntity)
final class ReportSnapshotEntity: NSManagedObject, ManagedEntity {
    static let entityName = "ReportSnapshotEntity"

    @NSManaged var id: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var startDate: Date?
    @NSManaged var endDate: Date?
    @NSManaged var title: String?
    @NSManaged var csvText: String
    @NSManaged var pdfData: Data?
    @NSManaged var businessMiles: Double
    @NSManaged var businessValue: Double
    @NSManaged var rateCentsPerMile: Double
    @NSManaged var includedTripIDsData: Data?
}

@objc(TripFeeEntity)
final class TripFeeEntity: NSManagedObject, ManagedEntity {
    static let entityName = "TripFeeEntity"

    @NSManaged var id: UUID?
    @NSManaged var tripID: UUID?
    @NSManaged var categoryRaw: String
    @NSManaged var amount: Double
    @NSManaged var occurredAt: Date?
    @NSManaged var label: String?
    @NSManaged var sourceRaw: String
    @NSManaged var presetID: UUID?
    @NSManaged var sourceTransactionID: String?
    @NSManaged var tagOrPlate: String?
    @NSManaged var agency: String?
    @NSManaged var entryPlaza: String?
    @NSManaged var exitPlaza: String?
    @NSManaged var vehicleClass: String?
    @NSManaged var importedAt: Date?
}

@objc(PreferenceEntity)
final class PreferenceEntity: NSManagedObject, ManagedEntity {
    static let entityName = "PreferenceEntity"

    @NSManaged var id: UUID?
    @NSManaged var key: String?
    @NSManaged var valueData: Data?
    @NSManaged var updatedAt: Date?
}

@objc(VehicleEntity)
final class VehicleEntity: NSManagedObject, ManagedEntity {
    static let entityName = "VehicleEntity"

    @NSManaged var id: UUID?
    @NSManaged var name: String?
    @NSManaged var colorHex: String?
    @NSManaged var symbolName: String?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var sortOrder: Int64
    @NSManaged var isArchived: Bool
}

@objc(VehicleConnectionAliasEntity)
final class VehicleConnectionAliasEntity: NSManagedObject, ManagedEntity {
    static let entityName = "VehicleConnectionAliasEntity"

    @NSManaged var id: UUID?
    @NSManaged var vehicleID: UUID?
    @NSManaged var displayName: String?
    @NSManaged var connectionKindRaw: String
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
}

extension VehicleEntity {
    var asVehicle: Vehicle {
        Vehicle(
            id: id ?? UUID(),
            name: name ?? "",
            colorHex: colorHex,
            symbolName: symbolName,
            createdAt: createdAt ?? Date(),
            sortOrder: Int(sortOrder),
            isArchived: isArchived
        )
    }
}

extension Optional where Wrapped == Double {
    var asNSNumber: NSNumber? { map(NSNumber.init(value:)) }
}

extension TripEntity {
    var startCoordinate: Coordinate? {
        get { Coordinate(latitude: startLatitude, longitude: startLongitude) }
        set {
            startLatitude = newValue?.latitude.asNSNumber
            startLongitude = newValue?.longitude.asNSNumber
        }
    }

    var endCoordinate: Coordinate? {
        get { Coordinate(latitude: endLatitude, longitude: endLongitude) }
        set {
            endLatitude = newValue?.latitude.asNSNumber
            endLongitude = newValue?.longitude.asNSNumber
        }
    }

    var classification: TripClassification? {
        get { classificationRaw.flatMap(TripClassification.init(rawValue:)) }
        set { classificationRaw = newValue?.rawValue }
    }

    var classificationSource: TripClassificationSource? {
        get { classificationSourceRaw.flatMap(TripClassificationSource.init(rawValue:)) }
        set { classificationSourceRaw = newValue?.rawValue }
    }

    var reviewStatus: ReviewStatus {
        get { ReviewStatus(rawValue: reviewStatusRaw) ?? .needsReview }
        set { reviewStatusRaw = newValue.rawValue }
    }

    var manualDistanceOverride: Double? {
        get { manualDistanceOverrideMeters?.doubleValue }
        set { manualDistanceOverrideMeters = newValue.asNSNumber }
    }

    var vehicleAssignmentSource: VehicleAssignmentSource? {
        get { vehicleAssignmentSourceRaw.flatMap(VehicleAssignmentSource.init(rawValue:)) }
        set { vehicleAssignmentSourceRaw = newValue?.rawValue }
    }

    var startAddressEnrichmentState: TripEnrichmentState {
        get {
            startAddressEnrichmentStateRaw.flatMap(TripEnrichmentState.init(rawValue:))
                ?? legacyAddressEnrichmentState(address: startAddress, coordinate: startCoordinate)
        }
        set { startAddressEnrichmentStateRaw = newValue.rawValue }
    }

    var endAddressEnrichmentState: TripEnrichmentState {
        get {
            endAddressEnrichmentStateRaw.flatMap(TripEnrichmentState.init(rawValue:))
                ?? legacyAddressEnrichmentState(address: endAddress, coordinate: endCoordinate)
        }
        set { endAddressEnrichmentStateRaw = newValue.rawValue }
    }

    var routeEnrichmentState: TripEnrichmentState {
        get {
            routeEnrichmentStateRaw.flatMap(TripEnrichmentState.init(rawValue:)) ?? .legacy
        }
        set { routeEnrichmentStateRaw = newValue.rawValue }
    }

    func attentionReasons(decoder: JSONDecoder) -> [String] {
        guard let data = attentionReasonsData else { return [] }
        return (try? decoder.decode([String].self, from: data)) ?? []
    }

    func setAttentionReasons(_ reasons: [String], encoder: JSONEncoder) {
        attentionReasonsData = try? encoder.encode(reasons)
    }

    func legs(decoder: JSONDecoder) -> [TripLeg] {
        guard let legsData else { return [] }
        return (try? decoder.decode([TripLeg].self, from: legsData)) ?? []
    }

    func setLegs(_ legs: [TripLeg], encoder: JSONEncoder) throws {
        legsData = try encoder.encode(legs)
    }

    func connectors(decoder: JSONDecoder) -> [TripLegConnector] {
        guard let connectorsData else { return [] }
        return (try? decoder.decode([TripLegConnector].self, from: connectorsData)) ?? []
    }

    func setConnectors(_ connectors: [TripLegConnector], encoder: JSONEncoder) throws {
        connectorsData = try encoder.encode(connectors)
    }

    func startAddressComponents(decoder: JSONDecoder) -> TripEndpointAddressComponents? {
        addressComponents(from: startAddressComponentsData, decoder: decoder)
    }

    func endAddressComponents(decoder: JSONDecoder) -> TripEndpointAddressComponents? {
        addressComponents(from: endAddressComponentsData, decoder: decoder)
    }

    func setStartAddressComponents(_ components: TripEndpointAddressComponents?, encoder: JSONEncoder) {
        startAddressComponentsData = encodedAddressComponents(components, encoder: encoder)
    }

    func setEndAddressComponents(_ components: TripEndpointAddressComponents?, encoder: JSONEncoder) {
        endAddressComponentsData = encodedAddressComponents(components, encoder: encoder)
    }

    func startBluetoothHintHashes(decoder: JSONDecoder) -> [String] {
        guard let data = startBluetoothHintHashesData else { return [] }
        return (try? decoder.decode([String].self, from: data)) ?? []
    }

    func setStartBluetoothHintHashes(_ hashes: [String], encoder: JSONEncoder) {
        startBluetoothHintHashesData = hashes.isEmpty ? nil : try? encoder.encode(hashes)
    }

    func toSummary(decoder: JSONDecoder) -> TripSummary {
        TripSummary(
            id: id ?? UUID(),
            createdAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? Date(),
            captureSource: captureSource,
            startDate: startDate ?? Date(),
            endDate: endDate ?? Date(),
            startCoordinate: startCoordinate,
            endCoordinate: endCoordinate,
            startAddress: startAddress,
            endAddress: endAddress,
            startAddressComponents: startAddressComponents(decoder: decoder),
            endAddressComponents: endAddressComponents(decoder: decoder),
            distanceMeters: distanceMeters,
            routePolyline: routePolyline,
            classification: classification,
            reviewStatus: reviewStatus,
            businessPurpose: businessPurpose,
            notes: notes,
            tollsAmount: tollsAmount,
            parkingAmount: parkingAmount,
            needsAttention: needsAttention,
            attentionReasons: attentionReasons(decoder: decoder),
            manualDistanceOverrideMeters: manualDistanceOverride,
            legs: legs(decoder: decoder),
            connectors: connectors(decoder: decoder),
            startBluetoothHintHashes: startBluetoothHintHashes(decoder: decoder),
            classificationSource: classificationSource,
            vehicleID: vehicleID,
            vehicleAssignmentSource: vehicleAssignmentSource,
            startAddressEnrichmentState: startAddressEnrichmentState,
            endAddressEnrichmentState: endAddressEnrichmentState,
            routeEnrichmentState: routeEnrichmentState,
            deriveRoutePolylineWhenMissing: false
        )
    }

    private func legacyAddressEnrichmentState(
        address: String?,
        coordinate: Coordinate?
    ) -> TripEnrichmentState {
        if let address,
           !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .complete
        }
        let hasValidCoordinate = coordinate.map {
            $0.latitude.isFinite
                && $0.longitude.isFinite
                && (-90...90).contains($0.latitude)
                && (-180...180).contains($0.longitude)
        } ?? false
        return captureSource == "automatic" && hasValidCoordinate
            ? .pending
            : .legacy
    }

    private func addressComponents(
        from data: Data?,
        decoder: JSONDecoder
    ) -> TripEndpointAddressComponents? {
        guard let data else { return nil }
        let components = try? decoder.decode(TripEndpointAddressComponents.self, from: data)
        return components?.hasDisplayableComponent == true ? components : nil
    }

    private func encodedAddressComponents(
        _ components: TripEndpointAddressComponents?,
        encoder: JSONEncoder
    ) -> Data? {
        guard components?.hasDisplayableComponent == true else { return nil }
        return try? encoder.encode(components)
    }
}

extension TripEnrichmentAttemptEntity {
    var component: TripEnrichmentComponent? {
        get { TripEnrichmentComponent(rawValue: componentRaw) }
        set { componentRaw = newValue?.rawValue ?? TripEnrichmentComponent.route.rawValue }
    }

    var failureCategory: TripEnrichmentFailureCategory {
        get { TripEnrichmentFailureCategory(rawValue: failureCategoryRaw) ?? .unknown }
        set { failureCategoryRaw = newValue.rawValue }
    }

    var asAttempt: TripEnrichmentAttempt? {
        guard let component else { return nil }
        return TripEnrichmentAttempt(
            tripID: tripID,
            component: component,
            lastAttemptAt: lastAttemptAt,
            consecutiveFailures: Int(consecutiveFailures),
            failureCategory: failureCategory
        )
    }
}

extension TripFeeEntity {
    var category: TripFeeCategory {
        get { TripFeeCategory(rawValue: categoryRaw) ?? .toll }
        set { categoryRaw = newValue.rawValue }
    }

    var source: TripFeeSource {
        get { TripFeeSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    var asFee: TripFee {
        TripFee(
            id: id ?? UUID(),
            tripID: tripID,
            category: category,
            amount: amount,
            occurredAt: occurredAt ?? Date(),
            label: label,
            source: source,
            presetID: presetID,
            sourceTransactionID: sourceTransactionID,
            tagOrPlate: tagOrPlate,
            agency: agency,
            entryPlaza: entryPlaza,
            exitPlaza: exitPlaza,
            vehicleClass: vehicleClass,
            importedAt: importedAt
        )
    }
}

extension OdometerCheckpointEntity {
    var asCheckpoint: OdometerCheckpoint {
        OdometerCheckpoint(
            id: id ?? UUID(),
            date: date ?? Date(),
            odometerMiles: odometerMiles,
            note: note,
            vehicleID: vehicleID
        )
    }
}

private extension Coordinate {
    init?(latitude: NSNumber?, longitude: NSNumber?) {
        guard let latitude, let longitude else { return nil }
        self.init(latitude: latitude.doubleValue, longitude: longitude.doubleValue)
    }
}

private extension Double {
    var asNSNumber: NSNumber { NSNumber(value: self) }
}
