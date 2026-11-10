import AppCore
import SwiftUI

/// The app's sidebar: Mail's mailbox list, where a mailbox is a month. The
/// review row reports outstanding work; period rows report claimable Business
/// miles. Rows drive the split view's scope selection; in compact width the
/// collapsed split view pushes exactly as the old stack did.
struct MailboxesList: View {
    var directory: MailboxDirectory
    /// The split view's sidebar selection. Nil in the stack shell, where the
    /// rows' own links do the pushing — a `List(selection:)` there would claim
    /// the tap and nothing would navigate.
    var selection: Binding<TripsRoute?>?
    /// Supplied by the root from the WINDOW's size class — the sidebar column
    /// itself hands its content `.compact`, which is the wrong question.
    var showsSettingsRow: Bool = false
    var onLoadSampleData: () -> Void
    var onExportMonth: (Date, MileageReportExportFormat) -> Void
    var onOpenSettings: () -> Void

    @Environment(MileageAppModel.self) private var model
    @Environment(\.distanceUnit) private var distanceUnit

    var body: some View {
        if showsSettingsRow {
            VStack(spacing: 0) {
                mailboxListBody
                Divider()
                settingsFooter
            }
        } else {
            mailboxListBody
        }
    }

    private var mailboxListBody: some View {
        styledList
            .navigationTitle("Trips")
            .navigationBarTitleDisplayMode(.large)
            .navigationSubtitle(statusSubtitle)
            .overlay {
                if directory.isEmpty {
                    // The Mac never captures, so the recorded-automatically
                    // copy would be false there — and sample data is hidden
                    // outright: seeded trips would merge into the user's real
                    // iCloud library on the sync-enabling relaunch.
                    if model.platform.isMac {
                        EmbossedEmptyState(
                            title: Text("No trips yet"),
                            systemImage: "car.fill",
                            description: Text(model.syncEnabled
                                ? String(localized: "Trips from your iPhone or iPad will appear here after iCloud Sync downloads them.")
                                : String(localized: "Mileager on your Mac shows and reports the trips your iPhone or iPad records. Turn on iCloud Sync to see them here."))
                        )
                    } else {
                        EmbossedEmptyState(
                            title: Text("No trips yet"),
                            systemImage: "car.fill",
                            description: Text("Drives you take are recorded automatically. Each month with a trip shows up here, ready to export.")
                        ) {
                            Button("Load Sample Data", action: onLoadSampleData)
                                .accessibilityIdentifier("emptyStateLoadSampleDataButton")
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private var styledList: some View {
        if model.platform.isMac, selection != nil {
            // Grouped phone rows clip the selection to the section's corners
            // on the Mac. Let the system draw individual sidebar selections.
            list
                .listStyle(.sidebar)
                .tint(Color(uiColor: .systemBlue))
        } else {
            list.listStyle(.insetGrouped)
        }
    }

    /// A fixed SwiftUI footer instead of `.bottomBar`: on the Designed-for-iPad
    /// Mac host, a sidebar bottom toolbar lays an invisible view over the whole
    /// column and swallows its clicks. Keeping this outside the scrolling List
    /// pins Settings without introducing that toolbar or covering empty states.
    private var settingsFooter: some View {
        Button(action: onOpenSettings) {
            Label {
                Text("Settings")
                    .foregroundStyle(MileageTheme.appTint)
            } icon: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.blue)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .accessibilityIdentifier("sidebarSettingsRow")
    }

    /// Only the split view's sidebar carries a selection; the stack shell gets
    /// a plain list so its rows' links are the sole tap target.
    @ViewBuilder
    private var list: some View {
        if let selection {
            List(selection: selection) { sections }
        } else {
            List { sections }
        }
    }

    @ViewBuilder
    private var sections: some View {
            Section {
                if reviewPresentation.showsNeedsReviewRow {
                    NavigationLink(value: TripsRoute.needsReview) {
                        LabeledContent {
                            Text(directory.needsReviewCount.formatted())
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(String(localized: "\(directory.needsReviewCount) need review"))
                        } label: {
                            Label("Need Review", systemImage: "tray")
                        }
                    }
                    .accessibilityIdentifier("mailboxNeedsReview")
                }

                NavigationLink(value: TripsRoute.allTrips) {
                    Label("All Trips", systemImage: "car")
                }
                .accessibilityIdentifier("mailboxAllTrips")
            }

            ForEach(directory.years) { year in
                Section {
                    yearSummaryRow(year)
                    ForEach(year.months) { group in
                        monthRow(group)
                    }
                } header: {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: year.yearStart.formatted(.dateTime.year()))
                                .fixedSize()
                            Spacer(minLength: 8)
                            businessDistanceHeader.fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: year.yearStart.formatted(.dateTime.year()))
                            businessDistanceHeader
                        }
                    }
                    .textCase(nil)
                }
            }

    }

    private var businessDistanceHeader: some View {
        Text(distanceUnit == .miles ? "Business miles" : "Business kilometers")
            .font(.caption)
            .accessibilityIdentifier("mailboxBusinessDistanceLabel")
    }

    private func yearSummaryRow(_ year: DriveYearGroup) -> some View {
        NavigationLink(value: TripsRoute.year(year.yearStart)) {
            LabeledContent {
                businessDistanceValue(year.businessMiles)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            } label: {
                Label("Full Year", systemImage: "calendar")
                    .fontWeight(.semibold)
            }
        }
        .accessibilityIdentifier("yearSummaryRow-\(gregorianYear(year.yearStart))")
    }

    /// The year header already supplies the year, so each row needs only the
    /// month name. The trailing value is the same claimable Business mileage
    /// shown by Full Year, making the rows directly comparable.
    private func monthRow(_ group: DriveMonthGroup) -> some View {
        NavigationLink(value: TripsRoute.month(group.monthStart)) {
            LabeledContent {
                businessDistanceValue(group.summary.businessMiles)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } label: {
                Text(verbatim: group.monthStart.formatted(.dateTime.month(.wide)))
            }
        }
        .accessibilityIdentifier("mailboxMonth-\(monthIdentifier(group.monthStart))")
        .contextMenu {
            Button("Export PDF") { onExportMonth(group.monthStart, .pdf) }
            Button("Export CSV") { onExportMonth(group.monthStart, .csv) }
            Button("Export QuickBooks CSV") { onExportMonth(group.monthStart, .quickBooksCSV) }
        }
    }

    /// The column header supplies the visual unit; VoiceOver still receives
    /// the complete localized distance, with the unit spelled out.
    private func businessDistanceValue(_ miles: Double) -> some View {
        let meters = DistanceConversion.meters(fromMiles: miles)
        return Text(verbatim: DistanceFormatting.number(meters: meters, unit: distanceUnit))
            .accessibilityLabel(DistanceFormatting.label(meters: meters, unit: distanceUnit, width: .wide))
            .accessibilityIdentifier("mailboxBusinessDistanceValue")
    }

    private var reviewPresentation: MailboxReviewPresentation {
        MailboxReviewPresentation(
            needsReviewCount: directory.needsReviewCount,
            hasLoadedInitialTrips: model.hasLoadedInitialTrips,
            isReviewSelected: selection?.wrappedValue == .needsReview
        )
    }

    /// Show completion only after loading. Pending counts live on the review
    /// row alone, rather than repeating the same information in the subtitle.
    private var statusSubtitle: String {
        reviewPresentation.showsCaughtUpStatus ? String(localized: "All caught up") : ""
    }

    // Row identifiers are pinned to the Gregorian calendar: the display string
    // follows the user's locale, but a UI test's element id must not change
    // because the system calendar did.
    private func monthIdentifier(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private func gregorianYear(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.component(.year, from: date)
    }
}
