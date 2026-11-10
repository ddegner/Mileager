import UIKit

extension UIApplication.LaunchOptionsKey {
    /// Raw UIKit keys preserve launch-dictionary compatibility while avoiding
    /// references to the iOS 26-deprecated convenience members.
    static let mileageLocationWake = Self(rawValue: "UIApplicationLaunchOptionsLocationKey")
    static let mileageRemoteNotificationWake = Self(
        rawValue: "UIApplicationLaunchOptionsRemoteNotificationKey"
    )
}

enum MileageAppLaunchReason: Equatable {
    case foreground
    case locationWake
    case nonLocationBackground

    init(applicationState: UIApplication.State, launchedForLocation: Bool) {
        if launchedForLocation {
            self = .locationWake
        } else if applicationState == .background {
            self = .nonLocationBackground
        } else {
            self = .foreground
        }
    }
}

@MainActor
final class AppLaunchCoordinator {
    static let shared = AppLaunchCoordinator()

    private var launchOptionsRecorded = false
    private var launchedForLocation = false
    private var startupStarted = false
    private var startupTask: Task<Void, Never>?
    private var registeredStartup: (@MainActor (MileageAppLaunchReason) async -> Void)?
    /// The registered app model, exposed for in-process App Intents (see
    /// `TripIntentDataProvider`). Weak: the coordinator outlives test models.
    private(set) weak var model: MileageAppModel?

    func register(model: MileageAppModel) {
        self.model = model
        registeredStartup = { [weak model] launchReason in
            await model?.startup(launchReason: launchReason)
        }
        startRegisteredStartupIfReady()
    }

    func recordLaunchOptions(_ launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        launchOptionsRecorded = true
        launchedForLocation = launchedForLocation || launchOptions?[.mileageLocationWake] != nil
        startRegisteredStartupIfReady()
    }

    func consumeLaunchReason(applicationState: UIApplication.State) -> MileageAppLaunchReason {
        if launchedForLocation {
            launchedForLocation = false
            return .locationWake
        }
        return MileageAppLaunchReason(applicationState: applicationState, launchedForLocation: false)
    }

    @discardableResult
    func startIfNeeded(
        applicationState: UIApplication.State,
        startup: @MainActor @escaping (MileageAppLaunchReason) async -> Void
    ) -> Bool {
        guard launchOptionsRecorded, !startupStarted else { return false }
        startupStarted = true
        let launchReason = consumeLaunchReason(applicationState: applicationState)
        startupTask = Task { @MainActor in await startup(launchReason) }
        return true
    }

    func resetForTesting() {
        startupTask?.cancel()
        launchOptionsRecorded = false
        launchedForLocation = false
        startupStarted = false
        startupTask = nil
        registeredStartup = nil
        model = nil
    }

    private func startRegisteredStartupIfReady() {
        guard let registeredStartup else { return }
        startIfNeeded(
            applicationState: UIApplication.shared.applicationState,
            startup: registeredStartup
        )
    }
}

/// A `UIResponder`, not a plain `NSObject`: the application delegate is the
/// last link of the responder chain only when it is a responder, and that is
/// how the system Edit ▸ Select All reaches the Mac trip list (see
/// `SelectAllCommandRelay`).
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private(set) var launchedForLocation = false

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(selectAll(_:)) {
            return SelectAllCommandRelay.handler != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func selectAll(_ sender: Any?) {
        SelectAllCommandRelay.handler?()
    }

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        launchedForLocation = launchOptions?[.mileageLocationWake] != nil
        #if DEBUG
        // The frozen-history evaluator must not replace live notification
        // categories or start normal launch work.
        if PCCEvaluationView.runName != nil { return true }
        #endif
        // The center delegate must exist before launch finishes or a
        // Lock Screen action tap that launched the process is never delivered.
        if !MileageAppModel.isRunningHostedUnitTests {
            TripCompletionNotificationDelegate.shared.install()
            TripCompletionNotifier.registerCategory(
                businessPurposes: AppLaunchCoordinator.shared.model?.businessPurposePresets ?? []
            )
        }
        AppLaunchCoordinator.shared.recordLaunchOptions(launchOptions)
        return true
    }
}
