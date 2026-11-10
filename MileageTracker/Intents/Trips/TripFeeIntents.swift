import AppCore
import AppIntents
import Foundation

enum TripFeeCategoryAppEnum: String, AppEnum {
    case toll
    case parking

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Fee Type")
    static let caseDisplayRepresentations: [TripFeeCategoryAppEnum: DisplayRepresentation] = [
        .toll: "Toll",
        .parking: "Parking"
    ]

    init(_ category: TripFeeCategory) {
        switch category {
        case .toll:
            self = .toll
        case .parking:
            self = .parking
        }
    }

    var domainValue: TripFeeCategory {
        switch self {
        case .toll:
            .toll
        case .parking:
            .parking
        }
    }
}

/// Siri/Shortcuts entry point for adding a toll or parking fee to a completed
/// trip. Runs against the main store, matching the existing trip-classification
/// intents' before-first-unlock behavior.
struct AddTripFeeIntent: AppIntent {
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif
    static let title: LocalizedStringResource = "Add Trip Fee"
    static let description = IntentDescription(
        "Adds a toll or parking fee to a Mileager trip.",
        categoryName: "Trips",
        searchKeywords: ["toll", "parking", "fee", "expense", "trip"]
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Trip")
    var trip: TripAppEntity

    @Parameter(title: "Type")
    var category: TripFeeCategoryAppEnum

    @Parameter(title: "Amount")
    var amount: Double

    @Parameter(title: "Label")
    var label: String?

    @Parameter(title: "Date")
    var occurredAt: Date?

    init() {
        category = .toll
        amount = 0
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) \(\.$category) to \(\.$trip)") {
            \.$label
            \.$occurredAt
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TripAppEntity> & ProvidesDialog {
        let model = try await TripIntentDataProvider.readyModel()
        guard let current = try? model.tripStore.fetchTripIfExists(id: trip.id) else {
            throw TripIntentError.tripNotFound
        }
        guard amount.isFinite, amount > 0 else {
            throw TripIntentError.invalidAmount
        }

        let normalizedLabel = label.normalizedIntentText
        do {
            _ = try model.tripStore.addFee(
                tripID: current.id,
                category: category.domainValue,
                amount: amount,
                occurredAt: occurredAt ?? Date(),
                label: normalizedLabel,
                source: .manual
            )
            model.refresh()
        } catch {
            throw TripIntentError.feeSaveFailed
        }

        guard let updated = try? model.tripStore.fetchTripIfExists(id: current.id) else {
            throw TripIntentError.tripNotFound
        }
        let entity = model.entity(for: updated)
        return .result(
            value: entity,
            dialog: "Added \(category.domainValue.displayName.lowercased()) to \(entity.routeLabel)."
        )
    }
}

/// Adds a toll or parking fee to the currently recording drive. The fee is
/// stored in the active-drive checkpoint and copied into the completed trip.
struct AddCurrentDriveFeeIntent: AppIntent {
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif
    static let title: LocalizedStringResource = "Add Current Drive Fee"
    static let description = IntentDescription(
        "Adds a toll or parking fee to the current Mileager drive.",
        categoryName: "Current Drive",
        searchKeywords: ["current drive", "toll", "parking", "fee", "expense"]
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Drive")
    var drive: CurrentDriveAppEntity?

    @Parameter(title: "Type")
    var category: TripFeeCategoryAppEnum

    @Parameter(title: "Amount")
    var amount: Double

    @Parameter(title: "Label")
    var label: String?

    @Parameter(title: "Date")
    var occurredAt: Date?

    init() {
        category = .toll
        amount = 0
    }

    init(category: TripFeeCategoryAppEnum) {
        self.category = category
        amount = 0
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) \(\.$category) to \(\.$drive)") {
            \.$label
            \.$occurredAt
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<CurrentDriveAppEntity> & ProvidesDialog {
        let model = try await TripIntentDataProvider.readyModel()
        _ = try CurrentDriveIntentResolver.resolve(drive, in: model)
        guard amount.isFinite, amount > 0 else {
            throw TripIntentError.invalidAmount
        }

        model.addCurrentDriveFee(TripFee(
            tripID: nil,
            category: category.domainValue,
            amount: amount,
            occurredAt: occurredAt ?? Date(),
            label: label.normalizedIntentText,
            source: .manual
        ))
        guard let updated = model.currentDrive else {
            throw TripIntentError.currentDriveNotFound
        }
        return .result(
            value: CurrentDriveAppEntity(updated),
            dialog: "Added \(category.domainValue.displayName.lowercased()) to your current drive."
        )
    }
}

extension Optional where Wrapped == String {
    var normalizedIntentText: String? {
        let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
