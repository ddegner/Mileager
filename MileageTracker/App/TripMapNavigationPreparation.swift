import Foundation

/// Holds a stack push until a local cached image has been prepared. A newer
/// selection or a navigation/lifecycle change invalidates an older request.
@MainActor
final class TripMapNavigationPreparation {
    private var task: Task<Void, Never>?
    private var generation = 0

    var isPreparing: Bool { task != nil }

    func open(
        preparing: @escaping @MainActor () async -> Void,
        then navigate: @escaping @MainActor () -> Void
    ) {
        cancel()
        let epoch = generation
        task = Task { [weak self] in
            await preparing()
            guard let self, !Task.isCancelled, generation == epoch else { return }
            task = nil
            navigate()
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    func waitForCurrentPreparation() async { await task?.value }

    deinit { task?.cancel() }
}
