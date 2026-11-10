import AppCoreModels
import Foundation

/// Transient reporting slices. The stored trip, its identity, and its merge
/// structure never change. Slices share the source Trip ID in CSV; their dates
/// identify the portion being reported. A normal same-month, same-rate merged
/// trip keeps its existing single row.
enum ReportTripAllocation {
    static func sourceIDs(in trips: [TripSummary]) -> [UUID] {
        var seen: Set<UUID> = []
        return trips.compactMap { seen.insert($0.id).inserted ? $0.id : nil }
    }

    static func slices(
        of trip: TripSummary,
        schedule: MileageRateSchedule,
        calendar: Calendar,
        currency: ReportCurrency
    ) -> [TripSummary] {
        struct Key: Hashable {
            var month: Date
            var amountPerMeter: Double
        }
        let legs = trip.effectiveLegs.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.id.uuidString < $1.id.uuidString
        }
        let groups = Dictionary(grouping: legs) { leg in
            Key(
                month: calendar.dateInterval(of: .month, for: leg.startDate)?.start ?? leg.startDate,
                amountPerMeter: schedule.rate(on: leg.startDate, calendar: calendar).amountPerMeter
            )
        }.values.sorted { $0[0].startDate < $1[0].startDate }

        guard groups.count > 1 else { return [roundFees(trip, currency: currency)] }
        let distances = groups.map { $0.reduce(0) { $0 + $1.distanceMeters } }
        let rawDistances = distribute(trip.distanceMeters, weights: distances)
        let reportedDistances = distribute(trip.reportableDistanceMeters, weights: distances)
        let tolls = distribute(trip.tollsAmount, weights: groups.map { $0.reduce(0) { $0 + $1.leg.tollsAmount } })
        let parking = distribute(trip.parkingAmount, weights: groups.map { $0.reduce(0) { $0 + $1.leg.parkingAmount } })

        return groups.enumerated().map { index, group in
            var slice = trip
            // Fold incoming connector mileage into its destination leg, as in
            // the existing CSV leg details, including at a period boundary.
            slice.legs = group.map { display in
                var leg = display.leg
                leg.distanceMeters = display.distanceMeters
                leg.startCoordinate = display.startCoordinate
                leg.startAddress = display.startAddress
                return leg
            }
            slice.connectors = []
            let first = group[0]
            let last = group.max { $0.endDate < $1.endDate }!
            slice.startDate = first.startDate
            slice.endDate = last.endDate
            slice.durationSeconds = max(0, last.endDate.timeIntervalSince(first.startDate))
            slice.startCoordinate = first.startCoordinate
            slice.endCoordinate = last.endCoordinate
            slice.startAddress = first.startAddress
            slice.endAddress = last.endAddress
            slice.startAddressComponents = first.leg.startAddressComponents
            slice.endAddressComponents = last.leg.endAddressComponents
            slice.routePolyline = nil
            slice.distanceMeters = rawDistances[index]
            // Corrections to the whole merged distance are distributed in
            // proportion to recorded leg distance, preserving the exact sum.
            slice.manualDistanceOverrideMeters = trip.manualDistanceOverrideMeters == nil
                ? nil : reportedDistances[index]
            slice.tollsAmount = tolls[index]
            slice.parkingAmount = parking[index]
            return roundFees(slice, currency: currency)
        }
    }

    private static func roundFees(_ trip: TripSummary, currency: ReportCurrency) -> TripSummary {
        var result = trip
        result.tollsAmount = currency.rounded(trip.tollsAmount)
        result.parkingAmount = currency.rounded(trip.parkingAmount)
        return result
    }

    /// Retain recorded fee attribution where it exists. Legacy totals with no
    /// leg attribution stay on the earliest slice. Zero-distance corrections
    /// use the same deterministic fallback instead of losing the amount.
    private static func distribute(_ total: Double, weights: [Double]) -> [Double] {
        guard !weights.isEmpty else { return [] }
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return [total] + Array(repeating: 0, count: weights.count - 1) }
        var result = weights.map { total * $0 / sum }
        let last = weights.lastIndex(where: { $0 > 0 })!
        result[last] += total - result.reduce(0, +)
        return result
    }
}

struct ReportAmounts {
    var mileage: Double = 0
    var tolls: Double = 0
    var parking: Double = 0
    var total: Double { mileage + tolls + parking }

    init(trips: [TripSummary], schedule: MileageRateSchedule, calendar: Calendar, currency: ReportCurrency) {
        for trip in trips where trip.isExportableBusiness {
            mileage += currency.rounded(trip.reportableDistanceMeters * schedule.rate(on: trip.startDate, calendar: calendar).amountPerMeter)
            tolls += currency.rounded(trip.tollsAmount)
            parking += currency.rounded(trip.parkingAmount)
        }
    }
}
