import AppCoreModels
import AppCorePersistence
import Foundation

public enum ReportExportNaming {
    public static func monthLogicalPeriodID(
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "month.%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    public static func yearLogicalPeriodID(
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let year = calendar.dateComponents([.year], from: date).year ?? 0
        return String(format: "year.%04d", year)
    }

    public static func baseFilename(
        logicalPeriodID: String?,
        reportStartDate: Date,
        reportEndDate: Date
    ) -> String {
        if let logicalPeriodID, let slug = slug(logicalPeriodID) {
            return "Mileage-\(slug)"
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month], from: reportStartDate)
        let year = components.year ?? 0
        if reportEndDate.timeIntervalSince(reportStartDate) > 45 * 86_400 {
            return String(format: "Mileage-%04d", year)
        }
        return String(format: "Mileage-%04d-%02d", year, components.month ?? 0)
    }

    private static func slug(_ logicalPeriodID: String) -> String? {
        if logicalPeriodID.hasPrefix("month.") {
            let value = String(logicalPeriodID.dropFirst("month.".count))
            let pieces = value.split(separator: "-")
            guard pieces.count == 2,
                  pieces[0].count == 4,
                  pieces[1].count == 2,
                  let year = Int(pieces[0]),
                  let month = Int(pieces[1]),
                  (1...9_999).contains(year),
                  (1...12).contains(month) else { return nil }
            return String(format: "%04d-%02d", year, month)
        }
        if logicalPeriodID.hasPrefix("year.") {
            let value = String(logicalPeriodID.dropFirst("year.".count))
            guard value.count == 4,
                  let year = Int(value),
                  (1...9_999).contains(year) else { return nil }
            return String(format: "%04d", year)
        }
        return nil
    }
}
