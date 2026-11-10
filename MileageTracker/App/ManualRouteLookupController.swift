import AppCore
import Foundation
import SwiftUI

struct ManualRouteLookupKey: Equatable {
    var origin: String
    var destination: String

    init?(origin: String, destination: String) {
        let trimmedOrigin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOrigin.isEmpty, !trimmedDestination.isEmpty else {
            return nil
        }
        self.origin = trimmedOrigin
        self.destination = trimmedDestination
    }
}

enum ManualRouteLookupStatus: Equatable {
    case idle
    case resolving
    case resolved(hasDrivingDistance: Bool)
    case failed(String)
}

struct ManualRouteLookupStatusMessage {
    var text: String
    var color: Color
}

@MainActor
struct ManualRouteLookupPresentation {
    var mapContent: RouteMapContent?
    var statusMessage: ManualRouteLookupStatusMessage?
    var endpointsChangedFromStored: Bool
    var shouldClearRouteOnSave: Bool

    init(
        lookup: ManualRouteLookupController,
        currentKey: ManualRouteLookupKey?,
        storedKey: ManualRouteLookupKey? = nil,
        storedTrip: TripSummary? = nil
    ) {
        endpointsChangedFromStored = currentKey != storedKey
        shouldClearRouteOnSave = storedTrip != nil && endpointsChangedFromStored && lookup.resolvedRoute == nil
        statusMessage = Self.statusMessage(for: lookup.status)

        if let resolved = lookup.resolvedRoute {
            mapContent = RouteMapContent(route: resolved)
        } else if let storedTrip, !endpointsChangedFromStored {
            mapContent = RouteMapContent(trip: storedTrip)
        } else {
            mapContent = nil
        }
    }

    private static func statusMessage(for status: ManualRouteLookupStatus) -> ManualRouteLookupStatusMessage? {
        switch status {
        case .idle:
            nil
        case .resolving:
            ManualRouteLookupStatusMessage(
                text: String(localized: "Finding route..."),
                color: .secondary
            )
        case .resolved(let hasDrivingDistance):
            hasDrivingDistance
                ? nil
                : ManualRouteLookupStatusMessage(
                    text: String(
                        localized: "Map added from your origin and destination. Add the distance manually."
                    ),
                    color: .secondary
                )
        case .failed:
            ManualRouteLookupStatusMessage(
                text: String(
                    localized: "Couldn't find a route. Check the addresses and your connection."
                ),
                color: .red
            )
        }
    }
}

@MainActor
@Observable
final class ManualRouteLookupController {
    var resolvedRoute: ResolvedManualRoute?
    var status: ManualRouteLookupStatus = .idle

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let debounce: UInt64

    init(debounceNanoseconds: UInt64 = 500_000_000) {
        self.debounce = debounceNanoseconds
    }

    func endpointsChanged() {
        resolvedRoute = nil
    }

    func schedule(
        currentKey: ManualRouteLookupKey?,
        resolve: @escaping @MainActor (ManualRouteLookupKey) async throws -> ResolvedManualRoute,
        onResolved: @escaping @MainActor (ResolvedManualRoute, ManualRouteLookupKey) -> Void
    ) {
        task?.cancel()
        guard let key = currentKey else {
            status = .idle
            resolvedRoute = nil
            return
        }

        task = Task { [debounce] in
            do {
                try await Task.sleep(nanoseconds: debounce)
                guard !Task.isCancelled else { return }
                status = .resolving
                let route = try await resolve(key)
                onResolved(route, key)
            } catch is CancellationError {
            } catch {
                guard key == currentKey else { return }
                status = .failed(error.localizedDescription)
            }
        }
    }

    func scheduleAndApply(
        currentKey: ManualRouteLookupKey?,
        currentKeyProvider: @escaping @MainActor () -> ManualRouteLookupKey?,
        resolve: @escaping @MainActor (ManualRouteLookupKey) async throws -> ResolvedManualRoute,
        onApplied: @escaping @MainActor (ResolvedManualRoute) -> Void
    ) {
        endpointsChanged()
        schedule(
            currentKey: currentKey,
            resolve: resolve,
            onResolved: { [weak self] route, key in
                guard let self,
                      self.apply(route, for: key, currentKey: currentKeyProvider()) else {
                    return
                }
                onApplied(route)
            }
        )
    }

    func apply(_ route: ResolvedManualRoute, for key: ManualRouteLookupKey, currentKey: ManualRouteLookupKey?) -> Bool {
        guard key == currentKey else { return false }
        resolvedRoute = route
        status = .resolved(hasDrivingDistance: route.distanceMeters != nil)
        return true
    }

    func cancel() {
        task?.cancel()
    }
}
