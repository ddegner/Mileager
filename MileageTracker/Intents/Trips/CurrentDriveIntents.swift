import AppCore
import AppIntents
import Foundation

/// Marks the current in-progress drive so the completed trip already carries
/// the user's review decision.
struct ClassifyCurrentDriveIntent: AppIntent {
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif
    static let title: LocalizedStringResource = "Classify Current Drive"
    static let description = IntentDescription(
        "Marks the current Mileager drive as Business, Personal, or Not a Drive.",
        categoryName: "Current Drive",
        searchKeywords: ["current drive", "business", "personal", "classify", "category"]
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Drive")
    var drive: CurrentDriveAppEntity?

    @Parameter(title: "Category")
    var classification: TripClassificationAppEnum

    @Parameter(title: "Business Purpose")
    var businessPurpose: String?

    // Keep Category required so an omitted category triggers clarification.
    init() {}

    init(classification: TripClassificationAppEnum) {
        self.classification = classification
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$drive) as \(\.$classification)") {
            \.$businessPurpose
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<CurrentDriveAppEntity> & ProvidesDialog {
        let model = try await TripIntentDataProvider.readyModel()
        let current = try CurrentDriveIntentResolver.resolve(drive, in: model)
        let domainClassification = classification.domainValue
        let updated = try CurrentDriveIntentPerformer.commit(
            .classification(domainClassification, purpose: businessPurpose.normalizedIntentText),
            expectedID: current.pendingTripID, in: model
        )
        return .result(
            value: CurrentDriveAppEntity(updated),
            dialog: "Marked your current drive as \(domainClassification.displayName)."
        )
    }
}

/// Sets the current drive's business purpose. A non-empty purpose also marks
/// the drive as Business through the reducer's existing rule.
struct SetCurrentDrivePurposeIntent: AppIntent {
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif
    static let title: LocalizedStringResource = "Set Current Drive Purpose"
    static let description = IntentDescription(
        "Sets the business purpose for the current Mileager drive.",
        categoryName: "Current Drive",
        searchKeywords: ["current drive", "purpose", "business purpose", "client", "work"]
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Drive")
    var drive: CurrentDriveAppEntity?

    @Parameter(title: "Purpose")
    var purpose: String

    init() {
        purpose = ""
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$drive) purpose to \(\.$purpose)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<CurrentDriveAppEntity> & ProvidesDialog {
        let model = try await TripIntentDataProvider.readyModel()
        let current = try CurrentDriveIntentResolver.resolve(drive, in: model)
        guard let normalizedPurpose = Optional(purpose).normalizedIntentText else {
            throw TripIntentError.invalidText
        }

        let updated = try CurrentDriveIntentPerformer.commit(
            .purpose(normalizedPurpose), expectedID: current.pendingTripID, in: model
        )
        return .result(
            value: CurrentDriveAppEntity(updated),
            dialog: "Set your current drive purpose to \(normalizedPurpose)."
        )
    }
}

/// Appends a dictated note to the current drive. The current-drive model has one
/// note field, so repeated voice notes are joined with new lines.
struct AddCurrentDriveNoteIntent: AppIntent {
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif
    static let title: LocalizedStringResource = "Add Current Drive Note"
    static let description = IntentDescription(
        "Adds a note to the current Mileager drive.",
        categoryName: "Current Drive",
        searchKeywords: ["current drive", "note", "memo"]
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Drive")
    var drive: CurrentDriveAppEntity?

    @Parameter(title: "Note")
    var note: String

    init() {
        note = ""
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$note) to \(\.$drive) notes")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<CurrentDriveAppEntity> & ProvidesDialog {
        let model = try await TripIntentDataProvider.readyModel()
        let currentDrive = try CurrentDriveIntentResolver.resolve(drive, in: model)
        guard let normalizedNote = Optional(note).normalizedIntentText else {
            throw TripIntentError.invalidText
        }

        let updated = try CurrentDriveIntentPerformer.commit(
            .appendNote(normalizedNote), expectedID: currentDrive.pendingTripID, in: model
        )
        return .result(
            value: CurrentDriveAppEntity(updated),
            dialog: "Added a note to your current drive."
        )
    }
}

@MainActor
private enum CurrentDriveIntentPerformer {
    static func commit(_ edit: CurrentDriveEdit, expectedID: UUID, in model: MileageAppModel) throws -> CurrentDriveSummary {
        do { return try model.commitCurrentDriveEdit(edit, expectedID: expectedID) }
        catch is CurrentDriveEditError { throw TripIntentError.currentDriveNotFound }
        catch let error as TripIntentError { throw error }
        catch { throw TripIntentError.currentDriveSaveFailed }
    }
}
