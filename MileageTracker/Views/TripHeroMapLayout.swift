import UIKit

/// A stable snapshot size and a shared clear band keep route pins above the
/// summary and below the native toolbar, regardless of the summary's text size.
enum TripHeroMapLayout {
    static let identityToken = "route-detail"
    static let scrollCoordinateSpace = "tripDetailScroll"
    static let imageHeight: CGFloat = 500
    static let clearHeight: CGFloat = 300
    nonisolated static func opacity(at verticalPosition: CGFloat) -> Double {
        let scroll = verticalPosition.isFinite ? max(0, -verticalPosition) : 0
        let fade = min(max((scroll - 35) / 205, 0), 1)
        return 1 - Double(fade * fade * (3 - 2 * fade))
    }

    static let viewportPadding = UIEdgeInsets(
        top: 116, left: 28, bottom: imageHeight - clearHeight + 52, right: 28
    )
}
