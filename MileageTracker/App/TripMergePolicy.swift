import AppCore

enum TripMergePolicy {
    static func canMergeAdjacentTrips(_ first: TripSummary, _ second: TripSummary) -> Bool {
        // The displayed list supplies adjacency; the user decides which
        // captures belong together, regardless of dates or classifications.
        first.id != second.id
    }
}
