import AppCore
#if canImport(MessageUI)
import MessageUI
#endif
import SwiftUI

enum DiagnosticsDayRange: Int, CaseIterable, Identifiable {
    case one = 1
    case three = 3
    case seven = 7
    case thirty = 30

    var id: Int { rawValue }

    var label: String {
        rawValue == 1 ? String(localized: "Last day") : String(localized: "Last \(rawValue) days")
    }
}

struct DiagnosticsConsentView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedRange: DiagnosticsDayRange
    var isPreparing: Bool
    /// On the Mac the flow ends in a save panel (the user attaches the file
    /// to an email themselves), so the email-specific copy would promise a
    /// compose window that never appears. Same pattern as
    /// `SyncEnableConfirmationView.platform`.
    var platform: RunningPlatform = .iOS
    var onPrepare: @MainActor (Int) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Support Report") {
                    Text(platform.isMac
                        ? String(localized: "Your support report can include trip dates and times, GPS coordinates and routes, addresses, notes, business purposes, tolls, parking, odometer readings, Bluetooth device names and metadata, saved report snapshots, app preferences, active-drive state, and tracking diagnostics. It is saved as a file for you to email to David Degner. Send it only if you are comfortable sharing that data.")
                        : String(localized: "Your support report can include trip dates and times, GPS coordinates and routes, addresses, notes, business purposes, tolls, parking, odometer readings, Bluetooth device names and metadata, saved report snapshots, app preferences, active-drive state, and tracking diagnostics. It will be attached to an email to David Degner. Send it only if you are comfortable sharing that data."))
                        .accessibilityIdentifier("settingsDiagnosticsPrivacyWarning")

                    Text("The day range limits dated trip and tracking records. Some app settings, saved reports, Bluetooth metadata, and current tracking state are included regardless of the selected range.")
                }

                Section("Dated Data") {
                    Picker("Data included", selection: $selectedRange) {
                        ForEach(DiagnosticsDayRange.allCases) { range in
                            Text(range.label).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settingsDiagnosticsDayPicker")
                }

                Section {
                    Button {
                        onPrepare(selectedRange.rawValue)
                    } label: {
                        if isPreparing {
                            ProgressView("Preparing Report")
                        } else {
                            Text(platform.isMac
                                ? String(localized: "Prepare Report File")
                                : String(localized: "Prepare Email"))
                        }
                    }
                    .disabled(isPreparing)
                    .accessibilityIdentifier("settingsDiagnosticsPrepareButton")
                }
            }
            .accessibilityIdentifier("settingsDiagnosticsConsentSheet")
            .navigationTitle("Report Issue")
            .navigationBarTitleDisplayMode(.inline)
            .mileageGroupedBackground(MileageTheme.settingsGroupedBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isPreparing)
                    .accessibilityIdentifier("settingsDiagnosticsCancelButton")
                }
            }
        }
        .macSheetFrame()
    }
}

#if canImport(MessageUI)
struct DiagnosticsMailComposeView: UIViewControllerRepresentable {
    var report: DiagnosticsReportItem
    var onFinish: @MainActor () -> Void

    static var canSendMail: Bool {
        MFMailComposeViewController.canSendMail()
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(["David@DavidDegner.com"])
        controller.setSubject(report.subject)
        controller.setMessageBody(
            report.messageBody,
            isHTML: false
        )
        if let attachmentData = try? Data(contentsOf: report.url) {
            controller.addAttachmentData(
                attachmentData,
                mimeType: "application/zip",
                fileName: report.fileName
            )
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        var onFinish: @MainActor () -> Void

        init(onFinish: @escaping @MainActor () -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            let finish = onFinish
            MainActor.assumeIsolated {
                controller.dismiss(animated: true)
                finish()
            }
        }
    }
}
#endif
