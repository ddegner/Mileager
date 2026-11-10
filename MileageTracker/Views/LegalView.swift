import SwiftUI

struct PrivacyPolicyView: View {
    var body: some View {
        LegalDocumentView(
            title: "Privacy Policy",
            sections: [
                LegalSection(
                    title: "Local-first design",
                    paragraphs: [
                        "Mileager is designed as a local-first mileage log. The app does not use third-party analytics, third-party advertising SDKs, or an app-hosted server."
                    ]
                ),
                LegalSection(
                    title: "Data processed by the app",
                    paragraphs: [
                        "The app processes trip dates, times, distances, classifications, business purposes, notes, tolls, parking, odometer checkpoints, location data, route endpoints, motion activity signals, optional connected vehicle Bluetooth hints, report snapshots, exports, diagnostics you choose to create, and app-only settings.",
                        "Off by default. When enabled, trip details, notes, purpose presets, and any enabled calendar or contact evidence may be sent to Apple’s Private Cloud Compute to create suggestions. Apple does not store this data. If unavailable, Mileager uses the on-device model. Suggestions are never applied automatically.",
                        "When you enable Show Trips in Siri & Search, Mileager creates an on-device index of trip routes, addresses, dates, and distances. The operating system can use it to find a trip or answer a request such as the duration of your last completed drive. Search results can expose trip details even while App Lock is enabled. Turning the setting off removes the index.",
                        "This data is used to detect trips, help you review trips, generate mileage reports, export records, sync your own data across your devices through iCloud when you turn sync on, and diagnose tracking problems at your request.",
                        "If you turn on App Lock, Mileager uses the device's built-in authentication system, such as Face ID, Touch ID, or device passcode, to unlock the app. Mileager does not receive or store your biometric data."
                    ]
                ),
                LegalSection(
                    title: "Storage and sync",
                    paragraphs: [
                        "Trip summaries, preferences, odometer checkpoints, and report snapshots are stored on your device. If you turn on iCloud sync, this durable data is mirrored to your private CloudKit database so it can sync across your Apple devices signed in to the same Apple Account.",
                        "Raw GPS samples attached to completed trips are stored locally only and retained for the configured trip-sample window, currently 30 days. Diagnostic location samples, including samples that are not attached to a completed trip, are stored locally only for 30 days.",
                        "Recent diagnostics events and diagnostic location samples are stored locally for up to 30 days. They are exported only when you choose Report Issue."
                    ]
                ),
                LegalSection(
                    title: "Sharing and tracking",
                    paragraphs: [
                        "Mileager does not sell personal data, track you across other companies' apps or websites, or use your data for advertising.",
                        "The app shares data only when you initiate it, such as exporting a PDF or CSV, saving a diagnostics report through the Mac save panel, sending one through Mail or the system share sheet, or asking Siri or Shortcuts to return information from the app. The destination or Apple service you choose may have its own privacy practices."
                    ]
                ),
                LegalSection(
                    title: "Apple services",
                    paragraphs: [
                        "Mileager uses Apple services such as iCloud/CloudKit, MapKit, geocoding, routing, Core Location, Core Motion, Core Bluetooth, Calendar, Contacts, Apple Intelligence/Foundation Models, Siri/App Intents, Spotlight/Core Spotlight, Local Authentication, and audio route detection. Data handled by those Apple services is governed by Apple's applicable terms and privacy policies."
                    ]
                ),
                LegalSection(
                    title: "Control",
                    paragraphs: [
                        "You can delete trips in the app. Reset App deletes local data and attempts to remove Mileager data from iCloud when iCloud Sync is active.",
                        "You can revoke Location, Motion & Fitness, Calendar, and Contacts permissions in system Settings. You can disable Apple Intelligence evidence sources or Show Trips in Siri & Search in Mileager Settings. Automatic tracking is available on iPhone and iPad, requires location and motion permissions, and is unavailable on Mac. Manual trip entry, review, and report export remain available without granting background location permission."
                    ]
                ),
                LegalSection(
                    title: "Contact",
                    paragraphs: [
                        "For privacy questions, use the support contact listed on the App Store product page for Mileager."
                    ]
                )
            ]
        )
    }
}

struct TermsAccuracyAndNoticesView: View {
    var body: some View {
        LegalDocumentView(
            title: "Terms, Accuracy & Notices",
            sections: [
                LegalSection(
                    title: "Recordkeeping tool",
                    paragraphs: [
                        "Mileager helps you record, review, classify, and export mileage information. It is a recordkeeping tool, not tax, legal, accounting, financial, or reimbursement advice.",
                        "You are responsible for reviewing your trips, classifications, distances, purposes, notes, tolls, parking, odometer checkpoints, mileage rates, exports, and reports before relying on them."
                    ]
                ),
                LegalSection(
                    title: "Measurement accuracy",
                    paragraphs: [
                        "Automatic tracking, route lookup, GPS, motion activity, Bluetooth hints, background location delivery, map data, sync, and user-entered information can be delayed, incomplete, unavailable, or incorrect.",
                        "Trips may be missed, duplicated, split, merged, misclassified, or assigned inaccurate routes, endpoints, distances, dates, times, reimbursement estimates, or report totals. You should correct records in the app and keep any backup documentation required by your tax professional, employer, or government authority."
                    ]
                ),
                LegalSection(
                    title: "No tax guarantee",
                    paragraphs: [
                        "Mileager does not guarantee that any record, report, export, mileage rate, deduction estimate, reimbursement estimate, or app setting satisfies IRS rules, state or local tax rules, employer policies, audit requirements, or any other legal or business requirement.",
                        "Consult a qualified tax, legal, accounting, or reimbursement professional before using Mileager records for tax filings, reimbursement claims, audits, or other formal submissions."
                    ]
                ),
                LegalSection(
                    title: "No warranties",
                    paragraphs: [
                        "To the maximum extent allowed by law, Mileager is provided as is and as available, without warranties of accuracy, completeness, reliability, availability, fitness for a particular purpose, or non-infringement.",
                        "David Degner does not warrant that Mileager will detect every trip, preserve every record, calculate every distance correctly, remain uninterrupted, or prevent lost deductions, rejected reimbursements, tax adjustments, penalties, interest, audit costs, or other losses."
                    ]
                ),
                LegalSection(
                    title: "Limitation of liability",
                    paragraphs: [
                        "To the maximum extent allowed by law, David Degner is not liable for taxes, penalties, interest, denied deductions, denied reimbursements, lost records, inaccurate reports, data loss, business interruption, lost profits, or any indirect, incidental, special, consequential, exemplary, or punitive damages arising from your use of or inability to use Mileager.",
                        "Some jurisdictions do not allow certain warranty disclaimers or liability limitations, so parts of these terms may not apply to you."
                    ]
                ),
                LegalSection(
                    title: "Safe use",
                    paragraphs: [
                        "Use Mileager only when it is safe and legal to do so. Do not interact with the app while driving or in any situation where doing so could distract you or create risk."
                    ]
                ),
                LegalSection(
                    title: "App Store license",
                    paragraphs: [
                        "Compiled copies downloaded from the App Store are licensed to end users under Apple's Standard End User License Agreement unless the App Store listing provides a custom end-user license agreement.",
                        "Mileager is a free App Store app. The app does not include subscriptions, in-app purchases, ads, external purchase links, or external license-key unlocks."
                    ]
                ),
                LegalSection(
                    title: "Source code",
                    paragraphs: [
                        "Mileager source code is available under the MIT License. You may use, copy, modify, distribute, and sell it for commercial or private purposes while retaining the copyright and license notices."
                    ]
                ),
                LegalSection(
                    title: "Bundled components",
                    paragraphs: [
                        "The screenshot seed routes contain data from © OpenStreetMap contributors under the Open Database License (ODbL) 1.0. Attribution and license information is available at https://www.openstreetmap.org/copyright and https://opendatacommons.org/licenses/odbl/1-0/."
                    ]
                ),
                LegalSection(
                    title: "Apple frameworks",
                    paragraphs: [
                        "The app uses Apple platform frameworks and services, including SwiftUI, UIKit, Core Data, CloudKit, Core Location, Core Motion, Core Bluetooth, MapKit, AVFoundation, Local Authentication, MessageUI, and Uniform Type Identifiers. Those frameworks and services are provided under the applicable Apple developer agreements and platform terms."
                    ]
                )
            ]
        )
    }
}

private struct LegalDocumentView: View {
    @Environment(\.locale) private var locale

    var title: String
    var sections: [LegalSection]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if locale.language.languageCode?.identifier != "en" {
                    Label(
                        String(localized: "Legal documents are currently provided in English."),
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        // Legal copy is intentionally English-only for this
                        // release and must remain verbatim until reviewed
                        // translations are available.
                        Text(verbatim: section.title)
                            .font(.headline)

                        ForEach(section.paragraphs, id: \.self) { paragraph in
                            Text(verbatim: paragraph)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }
}

private struct LegalSection: Identifiable {
    var title: String
    var paragraphs: [String]

    var id: String {
        title
    }
}
