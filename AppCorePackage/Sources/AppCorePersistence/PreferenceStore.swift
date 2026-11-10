import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

/// Stores a single JSON-encoded value in a row of `PreferenceEntity`, keyed by a string.
/// Use one instance per logical preference key. Multiple stores can share the same context.
final class PreferenceStore {
    private let context: NSManagedObjectContext
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(context: NSManagedObjectContext, key: String) {
        self.context = context
        self.key = key
    }

    func read<Value: Decodable>() throws -> Value? {
        guard let row = try fetchRows().first,
              let data = row.valueData else {
            return nil
        }
        return try? decoder.decode(Value.self, from: data)
    }

    func write<Value: Encodable>(_ value: Value) throws {
        try context.saveTransaction {
            try writeWithoutSaving(value)
        }
    }

    func writeWithoutSaving<Value: Encodable>(
        _ value: Value,
        updatedAt: Date = Date()
    ) throws {
        let rows = try fetchRows()
        let row = rows.first ?? PreferenceEntity.insert(into: context)
        if row.id == nil { row.id = UUID() }
        row.key = key
        row.valueData = try encoder.encode(value)
        row.updatedAt = updatedAt
        for duplicate in rows.dropFirst() {
            context.delete(duplicate)
        }
    }

    private func fetchRows() throws -> [PreferenceEntity] {
        let request = PreferenceEntity.fetchRequest()
        request.predicate = NSPredicate(format: "key == %@", key)
        request.sortDescriptors = [
            NSSortDescriptor(key: "updatedAt", ascending: false),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        return try context.fetch(request)
    }
}
