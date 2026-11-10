import AppIntents
import SwiftUI
import UIKit

@main
struct MileageTrackerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: MileageAppModel?
    @State private var overlayPresenter = SecurityOverlayWindowPresenter()

    init() {
        let isRunningHostedUnitTests = MileageAppModel.isRunningHostedUnitTests
        #if DEBUG
        let isPCCEvaluation = PCCEvaluationView.runName != nil
        #else
        let isPCCEvaluation = false
        #endif
        if isPCCEvaluation {
            // Evaluation has no app model: even preview initialization runs
            // migrations and service setup that belong to the normal app.
            _model = State(initialValue: nil)
        } else {
            #if DEBUG
            let appModel = MileageAppModel(
                previewMode: isRunningHostedUnitTests,
                irsRateClient: IRSRateLiveSelfTest.clientOverride()
            )
            #else
            let appModel = MileageAppModel(previewMode: isRunningHostedUnitTests)
            #endif
            _model = State(initialValue: appModel)
            AppLaunchCoordinator.shared.register(model: appModel)
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if PCCEvaluationView.runName != nil {
                PCCEvaluationView()
            } else {
                appContent
            }
            #else
            appContent
            #endif
        }
        .commands {
            DriveCommands()
        }
    }

    @ViewBuilder
    private var appContent: some View {
        if let model {
            ContentView()
                .environment(model)
                .environment(\.distanceUnit, model.distanceUnit)
                .environment(\.currencyCode, model.currencyCode)
                .mileageAppTheme()
                // Holds first-responder status so shake / three-finger undo
                // reach the app. Attached here rather than in ContentView,
                // whose body re-evaluates on every trip change. 1x1 and NOT
                // hidden on purpose: a zero-size or hidden representable may
                // never be realized into the window, and a view that is not in
                // the window can never become first responder.
                .background {
                    UndoResponderBridge(coordinator: model.undoCoordinator)
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                }
                .task {
                    overlayPresenter.ensureWindow(appLock: model.appLock)
                }
                .onOpenURL { url in
                    model.handleOpenURL(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        model.appDidBecomeActive()
                    case .inactive:
                        model.appDidBecomeInactive()
                    case .background:
                        model.appEnteredBackground()
                    @unknown default:
                        break
                    }
                }
                // Separate handler so the lock/privacy layer sees the initial
                // phase too (cold launch with the lock engaged must
                // auto-prompt) without changing the model calls above.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.appLock.handleScenePhaseChange(phase)
                    overlayPresenter.ensureWindow(appLock: model.appLock)
                    if phase == .active { model.scheduleIRSRateCheckOnForeground() }
                }
        }
    }
}
