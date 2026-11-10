import AppCore
import Foundation

// MARK: - Reports & exports
// Odometer read accessors and monthly/annual report generation. The
// checkpoint mutations (add/delete) and diagnostics exports stay in
// MileageAppModel.swift — they write private(set) state or read the private
// capture stores.

@MainActor
extension MileageAppModel {
    /// A vehicle's odometer checkpoints, oldest first. `nil`-vehicle readings
    /// belong to the primary vehicle (the implicit default).
    func odometerCheckpoints(for vehicleID: UUID) -> [OdometerCheckpoint] {
        odometerCheckpoints.filter {
            $0.vehicleID == vehicleID || ($0.vehicleID == nil && vehicleID == primaryVehicleID)
        }
    }

    func latestOdometerCheckpoint(for vehicleID: UUID) -> OdometerCheckpoint? {
        odometerCheckpoints(for: vehicleID).last
    }

    func generateMonthlyReport(
        forMonthContaining date: Date,
        vehicleFilter: TripVehicleFilter = .all,
        csvFormat: ReportCSVFormat = .canonical
    ) -> ReportSnapshot? {
        let interval = DriveMonthSummary.monthInterval(containing: date)
        do {
            let filteredTrips = trips.filter { vehicleFilter.matches($0, primaryVehicleID: primaryVehicleID) }
            let report = try reportGenerator.makeReport(
                trips: filteredTrips,
                odometerCheckpoints: reportOdometerCheckpoints(for: vehicleFilter),
                startDate: interval.start,
                endDate: DriveMonthSummary.reportEndDate(forMonthContaining: date),
                rate: mileageRate,
                rateSchedule: mileageRateSchedule,
                formatting: reportFormattingContext,
                vehicleNamesByTripID: vehiclesConfigured ? vehicleNamesByTripID(for: filteredTrips) : nil,
                vehicleTitleSuffix: reportVehicleTitleSuffix(for: vehicleFilter),
                csvFormat: csvFormat
            )
            return report
        } catch {
            present(error, .export)
            return nil
        }
    }

    func prepareMonthlyReportExport(
        forMonthContaining date: Date,
        vehicleFilter: TripVehicleFilter = .all,
        format: MileageReportExportFormat = .csv
    ) async throws -> MileageReportExportFiles {
        let freshnessMessage = await prepareIRSRateForExport()
        irsRateExportStatusMessage = freshnessMessage
        guard isCommandSurfaceAvailable else { throw MileageReportExportError.failedToGenerateReport }
        guard let snapshot = generateMonthlyReport(forMonthContaining: date, vehicleFilter: vehicleFilter, csvFormat: format.csvFormat) else {
            throw MileageReportExportError.failedToGenerateReport
        }
        if format == .quickBooksCSV && snapshot.includedTripIDs.isEmpty {
            throw MileageReportExportError.noBusinessTrips
        }
        var files = try MileageReportFileWriter.write(
            report: snapshot,
            logicalPeriodID: ReportExportNaming.monthLogicalPeriodID(containing: date),
            csvFormat: format.csvFormat
        )
        files.rateFreshnessMessage = freshnessMessage
        return files
    }

    func generateAnnualReport(
        forYearContaining date: Date,
        vehicleFilter: TripVehicleFilter = .all,
        csvFormat: ReportCSVFormat = .canonical
    ) -> ReportSnapshot? {
        let interval = AnnualReportBreakdown.yearInterval(containing: date)
        do {
            let filteredTrips = trips.filter { vehicleFilter.matches($0, primaryVehicleID: primaryVehicleID) }
            return try reportGenerator.makeAnnualReport(
                trips: filteredTrips,
                odometerCheckpoints: reportOdometerCheckpoints(for: vehicleFilter),
                startDate: interval.start,
                endDate: AnnualReportBreakdown.reportEndDate(forYearContaining: date),
                rate: mileageRate,
                rateSchedule: mileageRateSchedule,
                formatting: reportFormattingContext,
                vehicleNamesByTripID: vehiclesConfigured ? vehicleNamesByTripID(for: filteredTrips) : nil,
                vehicleTitleSuffix: reportVehicleTitleSuffix(for: vehicleFilter),
                csvFormat: csvFormat
            )
        } catch {
            present(error, .export)
            return nil
        }
    }

    func prepareAnnualReportExport(
        forYearContaining date: Date,
        vehicleFilter: TripVehicleFilter = .all,
        format: MileageReportExportFormat = .csv
    ) async throws -> MileageReportExportFiles {
        let freshnessMessage = await prepareIRSRateForExport()
        irsRateExportStatusMessage = freshnessMessage
        guard isCommandSurfaceAvailable else { throw MileageReportExportError.failedToGenerateReport }
        guard let snapshot = generateAnnualReport(forYearContaining: date, vehicleFilter: vehicleFilter, csvFormat: format.csvFormat) else {
            throw MileageReportExportError.failedToGenerateReport
        }
        if format == .quickBooksCSV && snapshot.includedTripIDs.isEmpty {
            throw MileageReportExportError.noBusinessTrips
        }
        var files = try MileageReportFileWriter.write(
            report: snapshot,
            period: .year,
            logicalPeriodID: ReportExportNaming.yearLogicalPeriodID(containing: date),
            csvFormat: format.csvFormat
        )
        files.rateFreshnessMessage = freshnessMessage
        return files
    }

    /// Odometer checkpoints for a report. For a single selected vehicle, only
    /// that car's readings (nil-vehicle counts as the primary). For "All
    /// Vehicles" with two or more cars the odometer rows are suppressed —
    /// interpolating across different cars' odometers would be meaningless.
    private func reportOdometerCheckpoints(for filter: TripVehicleFilter) throws -> [OdometerCheckpoint] {
        switch filter {
        case .all:
            guard let filter = ReportOdometerPolicy.allVehiclesFilter(
                activeVehicleIDs: vehicles.map(\.id)
            ) else {
                return []
            }
            return try tripStore.fetchOdometerCheckpoints(vehicle: filter)
        case .unassigned:
            return try tripStore.fetchOdometerCheckpoints(vehicle: .unassigned)
        case let .vehicle(id):
            return try tripStore.fetchOdometerCheckpoints(
                vehicle: .vehicle(id, includesUnassigned: id == primaryVehicleID)
            )
        }
    }

    private func vehicleNamesByTripID(for trips: [TripSummary]) -> [UUID: String] {
        var map: [UUID: String] = [:]
        for trip in trips {
            if let name = vehicleName(for: trip.vehicleID) {
                map[trip.id] = name
            }
        }
        return map
    }

    private func reportVehicleTitleSuffix(for filter: TripVehicleFilter) -> String? {
        switch filter {
        case .all:
            return nil
        case .unassigned:
            return String(localized: "No Vehicle")
        case let .vehicle(id):
            return vehicle(for: id)?.name
        }
    }
}
