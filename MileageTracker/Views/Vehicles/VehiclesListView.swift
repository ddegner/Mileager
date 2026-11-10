import AppCore
import SwiftUI

/// Settings sub-screen listing the user's vehicles with add / reorder / delete.
/// Reached from the Settings "Vehicles" row.
struct VehiclesListView: View {
    @Environment(MileageAppModel.self) private var model
    @State private var pendingDeletion: Vehicle?
    @State private var ignoredConnections: [BluetoothDriveHint] = []

    var body: some View {
        List {
            vehiclesSection
            ignoredConnectionsSection
            addSection
        }
        .navigationTitle("Vehicles")
        .navigationBarTitleDisplayMode(.inline)
        .mileageGroupedBackground(MileageTheme.settingsGroupedBackground)
        .toolbar {
            EditButton()
        }
        .task {
            reloadIgnoredConnections()
        }
        .confirmationDialog(
            pendingDeletion.map { removalPrompt(for: $0).title } ?? "",
            isPresented: deletionBinding,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { vehicle in
            Button("Remove Vehicle", role: .destructive) {
                model.deleteVehicle(id: vehicle.id)
            }
            .accessibilityIdentifier("vehicleDeleteConfirm")
            Button("Cancel", role: .cancel) {}
        } message: { vehicle in
            Text(removalPrompt(for: vehicle).message)
        }
    }

    private var vehiclesSection: some View {
        Section {
            ForEach(model.vehicles) { vehicle in
                NavigationLink {
                    VehicleDetailView(mode: .edit(vehicle))
                } label: {
                    row(for: vehicle)
                }
                .accessibilityIdentifier("vehicleRow")
                // Mirrors .deleteDisabled below: the sole vehicle is undeletable.
                .contextMenu {
                    if model.vehicles.count > 1 {
                        Button(role: .destructive) {
                            pendingDeletion = vehicle
                        } label: {
                            Label("Remove Vehicle", systemImage: "trash.fill")
                        }
                    }
                }
            }
            .onDelete { offsets in
                if let index = offsets.first {
                    pendingDeletion = model.vehicles[index]
                }
            }
            .onMove(perform: move)
            .deleteDisabled(model.vehicles.count == 1)
        }
    }

    private var addSection: some View {
        Section {
            NavigationLink {
                VehicleDetailView(mode: .create)
            } label: {
                Label("Add Vehicle", systemImage: "plus.circle.fill")
            }
            .accessibilityIdentifier("vehiclesAddButton")
        }
    }

    @ViewBuilder
    private var ignoredConnectionsSection: some View {
        if !ignoredConnections.isEmpty {
            Section {
                ForEach(ignoredConnections) { hint in
                    HStack(spacing: 12) {
                        Image(systemName: connectionSystemImage(hint.connectionKind))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hint.displayName ?? String(localized: "Unknown Car Connection"))
                            Text(connectionKindTitle(hint.connectionKind))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") {
                            model.restoreIgnoredVehicleConnection(hint)
                            reloadIgnoredConnections()
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("ignoredVehicleConnectionRestore")
                    }
                    .accessibilityIdentifier("ignoredVehicleConnectionRow")
                }
            } header: {
                Text("Ignored Car Connections")
            } footer: {
                Text("Restoring a connection lets it help detect drives and allows Mileager to ask which vehicle it belongs to again.")
            }
        }
    }

    private func row(for vehicle: Vehicle) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(vehicle.name)
                let count = deviceCount(for: vehicle)
                if count > 0 {
                    Text("^[\(count) car connection](inflect: true)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: VehicleAppearance.symbol(vehicle.symbolName))
                .foregroundStyle(VehicleAppearance.color(forHex: vehicle.colorHex))
        }
    }

    private func deviceCount(for vehicle: Vehicle) -> Int {
        model.vehicleConnectionCount(for: vehicle.id)
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func removalPrompt(for vehicle: Vehicle) -> VehicleRemovalPrompt {
        VehicleRemovalPrompt.make(
            removedVehicleID: vehicle.id,
            removedVehicleName: vehicle.name,
            vehicles: model.vehicles,
            primaryVehicleID: model.primaryVehicleID
        )
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        var ids = model.vehicles.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        model.setVehicleOrder(ids)
    }

    private func reloadIgnoredConnections() {
        ignoredConnections = model.ignoredVehicleConnections
    }

    private func connectionKindTitle(_ kind: VehicleConnectionKind) -> String {
        switch kind {
        case .carPlay: String(localized: "CarPlay")
        case .bluetooth: String(localized: "Bluetooth")
        case .unknown: String(localized: "Car connection")
        }
    }

    private func connectionSystemImage(_ kind: VehicleConnectionKind) -> String {
        switch kind {
        case .carPlay: "car.side.fill"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .unknown: "car.fill"
        }
    }
}
