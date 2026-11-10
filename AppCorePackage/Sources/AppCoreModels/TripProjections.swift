import Foundation

public struct TripRowProjection: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var startDate: Date
    public var endDate: Date
    public var startAddress: String?
    public var endAddress: String?
    public var distanceMeters: Double
    public var durationSeconds: Double
    public var classification: TripClassification?
    public var classificationSource: TripClassificationSource?
    public var reviewStatus: ReviewStatus
    public var businessPurpose: String?
    public var notes: String?
    public var hasNotes: Bool
    public var tollsAmount: Double
    public var parkingAmount: Double
    public var needsAttention: Bool
    public var vehicleID: UUID?
    public var captureSource: String
    public var updatedAt: Date

    public init(
        id: UUID,
        createdAt: Date? = nil,
        startDate: Date,
        endDate: Date,
        startAddress: String?,
        endAddress: String?,
        distanceMeters: Double,
        durationSeconds: Double,
        classification: TripClassification?,
        classificationSource: TripClassificationSource?,
        reviewStatus: ReviewStatus,
        businessPurpose: String?,
        notes: String?,
        hasNotes: Bool,
        tollsAmount: Double,
        parkingAmount: Double,
        needsAttention: Bool,
        vehicleID: UUID?,
        captureSource: String,
        updatedAt: Date
    ) {
        self.id = id
        self.createdAt = createdAt ?? startDate
        self.startDate = startDate
        self.endDate = endDate
        self.startAddress = startAddress
        self.endAddress = endAddress
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.classification = classification
        self.classificationSource = classificationSource
        self.reviewStatus = reviewStatus
        self.businessPurpose = businessPurpose
        self.notes = notes
        self.hasNotes = hasNotes
        self.tollsAmount = tollsAmount
        self.parkingAmount = parkingAmount
        self.needsAttention = needsAttention
        self.vehicleID = vehicleID
        self.captureSource = captureSource
        self.updatedAt = updatedAt
    }

    public var isUnresolved: Bool {
        TripReviewPolicy.isUnresolved(
            classification: classification,
            businessPurpose: businessPurpose
        )
    }

    public init(trip: TripSummary) {
        let trimmedNotes = trip.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            id: trip.id,
            createdAt: trip.createdAt,
            startDate: trip.startDate,
            endDate: trip.endDate,
            startAddress: trip.startAddress,
            endAddress: trip.endAddress,
            distanceMeters: trip.reportableDistanceMeters,
            durationSeconds: trip.durationSeconds,
            classification: trip.classification,
            classificationSource: trip.classificationSource,
            reviewStatus: trip.reviewStatus,
            businessPurpose: trip.businessPurpose,
            notes: trip.notes,
            hasNotes: !(trimmedNotes?.isEmpty ?? true),
            tollsAmount: trip.tollsAmount,
            parkingAmount: trip.parkingAmount,
            needsAttention: trip.needsAttention,
            vehicleID: trip.vehicleID,
            captureSource: trip.captureSource,
            updatedAt: trip.updatedAt
        )
    }
}

/// Privacy-bounded shape for Siri, Shortcuts, and system search. It contains
/// useful review text and accounting scalars, but deliberately excludes route
/// geometry, coordinates, address-component blobs, merged-trip structure,
/// Bluetooth identifiers, diagnostics, and CloudKit metadata.
public struct TripIndexProjection: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var startDate: Date
    public var endDate: Date
    public var startAddress: String?
    public var endAddress: String?
    public var distanceMeters: Double
    public var durationSeconds: Double
    public var classification: TripClassification?
    public var classificationSource: TripClassificationSource?
    public var reviewStatus: ReviewStatus
    public var businessPurpose: String?
    public var notes: String?
    public var tollsAmount: Double
    public var parkingAmount: Double
    public var needsAttention: Bool
    public var attentionReasons: [String]
    public var vehicleID: UUID?
    public var captureSource: String

    public init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        startDate: Date,
        endDate: Date,
        startAddress: String?,
        endAddress: String?,
        distanceMeters: Double,
        durationSeconds: Double,
        classification: TripClassification?,
        classificationSource: TripClassificationSource?,
        reviewStatus: ReviewStatus,
        businessPurpose: String?,
        notes: String?,
        tollsAmount: Double,
        parkingAmount: Double,
        needsAttention: Bool,
        attentionReasons: [String],
        vehicleID: UUID?,
        captureSource: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startDate = startDate
        self.endDate = endDate
        self.startAddress = startAddress
        self.endAddress = endAddress
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.classification = classification
        self.classificationSource = classificationSource
        self.reviewStatus = reviewStatus
        self.businessPurpose = businessPurpose
        self.notes = notes
        self.tollsAmount = tollsAmount
        self.parkingAmount = parkingAmount
        self.needsAttention = needsAttention
        self.attentionReasons = attentionReasons
        self.vehicleID = vehicleID
        self.captureSource = captureSource
    }

    public init(trip: TripSummary) {
        self.init(
            id: trip.id,
            createdAt: trip.createdAt,
            updatedAt: trip.updatedAt,
            startDate: trip.startDate,
            endDate: trip.endDate,
            startAddress: trip.startAddress,
            endAddress: trip.endAddress,
            distanceMeters: trip.reportableDistanceMeters,
            durationSeconds: trip.durationSeconds,
            classification: trip.classification,
            classificationSource: trip.classificationSource,
            reviewStatus: trip.reviewStatus,
            businessPurpose: trip.businessPurpose,
            notes: trip.notes,
            tollsAmount: trip.tollsAmount,
            parkingAmount: trip.parkingAmount,
            needsAttention: trip.needsAttention,
            attentionReasons: trip.attentionReasons,
            vehicleID: trip.vehicleID,
            captureSource: trip.captureSource
        )
    }

    public func mileageValue(at rate: MileageRate) -> Double {
        guard classification == .business else { return 0 }
        return CurrencyRounding.cents(distanceMeters * rate.amountPerMeter)
    }
}
