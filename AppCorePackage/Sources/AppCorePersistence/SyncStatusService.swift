import AppCoreModels
import DriveCaptureEngine
import CloudKit
import Foundation

public struct SyncStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case disabled
        case unknown
        case available
        case unavailable
        case restricted
        case noAccount
        case temporarilyUnavailable
    }

    public var state: State
    public var lastCheckedAt: Date?
    public var lastError: String?

    public init(state: State, lastCheckedAt: Date? = nil, lastError: String? = nil) {
        self.state = state
        self.lastCheckedAt = lastCheckedAt
        self.lastError = lastError
    }

    public static let unknown = SyncStatus(state: .unknown, lastCheckedAt: nil, lastError: nil)
}

public final class SyncStatusService {
    private let container: CKContainer

    public init(containerIdentifier: String? = nil) {
        if let containerIdentifier {
            container = CKContainer(identifier: containerIdentifier)
        } else {
            container = .default()
        }
    }

    public func checkStatus(completion: @escaping @Sendable (SyncStatus) -> Void) {
        container.accountStatus { status, error in
            let state: SyncStatus.State
            switch status {
            case .available:
                state = .available
            case .couldNotDetermine:
                state = .unknown
            case .noAccount:
                state = .noAccount
            case .restricted:
                state = .restricted
            case .temporarilyUnavailable:
                state = .temporarilyUnavailable
            @unknown default:
                state = .unknown
            }
            completion(SyncStatus(state: state, lastCheckedAt: Date(), lastError: error?.localizedDescription))
        }
    }
}
