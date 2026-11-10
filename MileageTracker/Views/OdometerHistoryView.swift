import AppCore
import SwiftUI

/// A single vehicle's odometer checkpoints, newest first, with swipe-to-delete.
/// Reached from the vehicle's detail page.
struct OdometerHistoryView: View {
    @Environment(MileageAppModel.self) private var model

    private let vehicleID: UUID

    init(vehicleID: UUID) {
        self.vehicleID = vehicleID
    }

    private var rows: [OdometerCheckpoint] {
        model.odometerCheckpoints(for: vehicleID).reversed()
    }

    var body: some View {
        List {
            if !rows.isEmpty {
                Section {
                    ForEach(rows) { checkpoint in
                        checkpointRow(checkpoint)
                    }
                    .onDelete { offsets in delete(from: rows, at: offsets) }
                } footer: {
                    Text("Swipe to delete a mistaken entry.")
                }
            }
        }
        .overlay {
            if rows.isEmpty {
                EmbossedEmptyState(
                    title: Text("No Readings"),
                    systemImage: "gauge.with.dots.needle.33percent",
                    description: Text("Add a reading on the vehicle page. Two readings a year keep report estimates accurate.")
                )
            }
        }
        .navigationTitle("Odometer History")
        .navigationBarTitleDisplayMode(.inline)
        .mileageGroupedBackground(MileageTheme.settingsGroupedBackground)
    }

    private func checkpointRow(_ checkpoint: OdometerCheckpoint) -> some View {
        LabeledContent(
            Self.dateFormatter.string(from: checkpoint.date),
            value: readingText(checkpoint)
        )
        .accessibilityIdentifier("odometerHistoryRow")
        // Pointer path beside the swipe: deletes by id directly, so the
        // reversed-offset dance in delete(from:at:) is not needed here.
        .contextMenu {
            Button(role: .destructive) {
                model.deleteOdometerCheckpoint(id: checkpoint.id)
            } label: {
                Label("Delete", systemImage: "trash.fill")
            }
        }
    }

    private func readingText(_ checkpoint: OdometerCheckpoint) -> String {
        // Odometer storage is always miles; display follows the unit setting.
        let unit = model.distanceUnit
        let display = DistanceConversion.value(
            meters: DistanceConversion.meters(fromMiles: checkpoint.odometerMiles),
            in: unit
        )
        return "\(OdometerFormatting.readingText(display)) \(DistanceFormatting.unitSymbol(unit))"
    }

    private func delete(from source: [OdometerCheckpoint], at offsets: IndexSet) {
        // Delete by id from the reversed snapshot so offsets stay valid against
        // the model's ascending array.
        for offset in offsets {
            model.deleteOdometerCheckpoint(id: source[offset].id)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
