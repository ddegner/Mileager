import AppCore
import Foundation

struct DriveMonthGroup: Identifiable, Equatable {
    var id: Date { monthStart }
    var monthStart: Date
    var monthEnd: Date
    var summary: DriveMonthSummary
    var trips: [TripSummary]
}

struct DriveMonthSummary: Identifiable, Equatable {
    var id: Date { monthStart }
    var monthStart: Date
    var monthEnd: Date
    var driveCount: Int
    var totalMiles: Double
    var businessDriveCount: Int
    var businessMiles: Double
    var personalMiles: Double
    var businessTolls: Double
    var businessParking: Double
    var unresolvedCount: Int
    var unclassifiedCount: Int

    var businessParkingAndTolls: Double {
        businessTolls + businessParking
    }

    static func groups(
        for trips: [TripSummary],
        sort: DriveSortOption = .newestFirst,
        calendar: Calendar = .current
    ) -> [DriveMonthGroup] {
        let sortedTrips = sort.sorted(trips)
        let groupedTrips = Dictionary(grouping: sortedTrips) { trip in
            monthInterval(containing: trip.startDate, calendar: calendar).start
        }

        let sortedMonthStarts = groupedTrips.keys.sorted {
            sort.usesOldestMonthFirst ? $0 < $1 : $0 > $1
        }

        return sortedMonthStarts.map { monthStart in
            let trips = groupedTrips[monthStart] ?? []
            let interval = monthInterval(containing: monthStart, calendar: calendar)
            return DriveMonthGroup(
                monthStart: interval.start,
                monthEnd: interval.end,
                summary: summary(for: trips, monthStart: interval.start, monthEnd: interval.end),
                trips: trips
            )
        }
    }

    static func monthInterval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 0)
    }

    static func reportEndDate(forMonthContaining date: Date, calendar: Calendar = .current) -> Date {
        monthInterval(containing: date, calendar: calendar).end.addingTimeInterval(-0.001)
    }

    static func summary(
        for trips: [TripSummary],
        monthStart: Date,
        monthEnd: Date
    ) -> DriveMonthSummary {
        // Not-a-drive captures stay visible in the month group's rows but
        // never count toward drive totals.
        let drives = trips.filter { $0.classification?.countsAsDrive ?? true }
        let businessTrips = drives.filter(\.isExportableBusiness)

        return DriveMonthSummary(
            monthStart: monthStart,
            monthEnd: monthEnd,
            driveCount: drives.count,
            totalMiles: drives.reduce(0) { $0 + $1.miles },
            businessDriveCount: businessTrips.count,
            businessMiles: businessTrips.reduce(0) { $0 + $1.miles },
            personalMiles: drives.filter { $0.classification == .personal }.reduce(0) { $0 + $1.miles },
            businessTolls: businessTrips.reduce(0) { $0 + $1.tollsAmount },
            businessParking: businessTrips.reduce(0) { $0 + $1.parkingAmount },
            unresolvedCount: trips.filter(\.isUnresolved).count,
            unclassifiedCount: trips.filter { $0.classification == nil }.count
        )
    }
}
