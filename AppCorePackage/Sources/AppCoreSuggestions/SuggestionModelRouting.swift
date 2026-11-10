import Foundation

/// A route is eligible independently of the other model's readiness.
enum SuggestionModelRoute: String, Equatable {
    case privateCloudCompute = "Private Cloud Compute"
    case onDevice = "on-device"
}

enum SuggestionModelRouting {
    static func routes(
        preferCloud: Bool,
        cloudAvailable: Bool,
        cloudAuthorized: Bool,
        cloudQuotaReached: Bool,
        localAvailable: Bool
    ) -> [SuggestionModelRoute] {
        var result: [SuggestionModelRoute] = []
        if preferCloud && cloudAuthorized && cloudAvailable && !cloudQuotaReached {
            result.append(.privateCloudCompute)
        }
        if localAvailable { result.append(.onDevice) }
        return result
    }

    /// Fall back only after a failed request. Cancellation must neither start
    /// another model request nor publish a response from a cancelled worker.
    @MainActor
    static func generate<Output>(
        routes: [SuggestionModelRoute],
        record: (String) -> Void,
        using generate: (SuggestionModelRoute) async throws -> Output
    ) async throws -> Output? {
        for (index, route) in routes.enumerated() {
            try Task.checkCancellation()
            do {
                let output = try await generate(route)
                try Task.checkCancellation()
                record("Suggestion generated using \(route.rawValue).")
                #if DEBUG
                print("[suggestion-route] completed=\(route.rawValue)")
                #endif
                return output
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard index < routes.count - 1 else { throw error }
                // Error descriptions can contain prompt content. Keep routine
                // routing diagnostics free of trip/calendar data.
                record("\(route.rawValue) suggestion failed; retrying on-device.")
                #if DEBUG
                print("[suggestion-route] failed=\(route.rawValue); fallback=on-device")
                #endif
            }
        }
        return nil
    }
}
