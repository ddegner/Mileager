import Foundation
import os

@MainActor
extension MileageAppModel {
    private static let errorLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "MileageTracker",
        category: "presented-errors"
    )

    /// Present a failure as a titled alert. The title comes from the operation
    /// context; the message is the underlying error's description. Also logged
    /// so presented failures are visible in sysdiagnose/Console after the
    /// alert is dismissed.
    func present(_ error: Error, _ context: AppErrorContext) {
        Self.errorLogger.error("\(context.title, privacy: .public): \(String(describing: error))")
        errorAlert = AppErrorAlert(title: context.title, message: error.localizedDescription)
    }

    /// Present a failure with a custom message under a context title.
    func present(_ message: String, _ context: AppErrorContext) {
        Self.errorLogger.error("\(context.title, privacy: .public): \(message, privacy: .public)")
        errorAlert = AppErrorAlert(title: context.title, message: message)
    }
}
