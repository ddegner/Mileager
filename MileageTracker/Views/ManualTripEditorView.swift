import SwiftUI

struct ManualTripEditorView: View {
    private let now: Date

    init(now: Date = Date()) {
        self.now = now
    }

    var body: some View {
        NavigationStack {
            TripDetailView(creatingAt: now)
        }
    }
}
