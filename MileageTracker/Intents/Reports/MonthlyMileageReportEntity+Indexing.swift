import AppIntents
import CoreSpotlight
import CryptoKit
import Foundation

extension MonthlyMileageReportEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = titleText
        attributes.startDate = monthStart
        attributes.endDate = monthEnd
        attributes.contentDescription = summarySentence
        attributes.keywords = keywords
        return attributes
    }

    private var keywords: [String] {
        [
            String(localized: "mileage", comment: "Spotlight search keyword"),
            String(localized: "report", comment: "Spotlight search keyword"),
            String(localized: "business miles", comment: "Spotlight search keyword"),
            String(localized: "reimbursement", comment: "Spotlight search keyword"),
            monthStart.formatted(.dateTime.month(.wide)),
            monthStart.formatted(.dateTime.year())
        ]
    }

    /// Stable fingerprint of every donated field. The month manifest diffs on
    /// it, so any content change — a new trip, a reclassification, a mi↔km
    /// flip, a rate/currency change, a language change — re-donates exactly
    /// the months whose text actually moved. (String.hashValue is randomized
    /// per process, hence a real digest.)
    var indexDigest: String {
        let fields = [
            id,
            titleText,
            subtitleText,
            summarySentence,
            String(businessDistance),
            String(businessTripCount),
            String(driveCount),
            String(unclassifiedCount)
        ]
        return SHA256.hash(data: Data(fields.joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
