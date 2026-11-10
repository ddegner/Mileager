import AppCore
import SwiftUI

struct TripClassificationButtonGroup: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    enum Presentation: Equatable {
        case all
        case compact
    }

    var selection: TripClassification?
    var classifications: [TripClassification] = TripClassification.allCases
    var presentation: Presentation = .all
    var accessibilityPrefix: String
    var onSelect: (TripClassification?) -> Void

    /// Uniform gap between the buttons and the grouped-section container.
    /// Paired with `TripClassificationActionButton.concentricCornerRadius` so
    /// the button corners nest concentrically inside the container's corners
    /// (iOS 26 grouped sections use a 26pt radius; 26 − 8 = 18).
    static let listRowInset: CGFloat = 8

    var body: some View {
        buttons
            .listRowInsets(EdgeInsets(
                top: Self.listRowInset,
                leading: Self.listRowInset,
                bottom: Self.listRowInset,
                trailing: Self.listRowInset
            ))
    }

    @ViewBuilder
    private var buttons: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            if presentation == .all {
                TripClassificationActionButton(
                    title: String(localized: "Not Classified"),
                    systemImage: "questionmark.circle.fill",
                    isSelected: selection == nil,
                    tint: .secondary
                ) {
                    onSelect(nil)
                }
                .accessibilityIdentifier("\(accessibilityPrefix)NotClassified")

                ForEach(classifications) { classification in
                    classificationButton(for: classification)
                }
            } else {
                classificationButton(for: .business)
                classificationButton(for: .personal)
                TripClassificationMoreMenu(
                    selection: selection,
                    accessibilityPrefix: accessibilityPrefix,
                    onSelect: onSelect
                )
            }
        }
    }

    private func classificationButton(for classification: TripClassification) -> some View {
        TripClassificationActionButton(
            title: classification.displayName,
            systemImage: icon(for: classification),
            isSelected: selection == classification,
            tint: tint(for: classification),
            unselectedTint: presentation == .compact ? Color(.systemGray) : .accentColor
        ) {
            onSelect(classification)
        }
        .accessibilityIdentifier("\(accessibilityPrefix)\(classification.rawValue)")
    }

    private func icon(for classification: TripClassification) -> String {
        switch classification {
        case .business: "briefcase.fill"
        case .personal: "person.fill"
        case .notADrive: "nosign"
        }
    }

    private func tint(for classification: TripClassification) -> Color {
        switch classification {
        case .business:
            MileageTheme.businessAccent
        case .personal:
            MileageTheme.personalAccent
        case .notADrive:
            Color(.systemGray)
        }
    }
}

private struct TripClassificationMoreMenu: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var selection: TripClassification?
    var accessibilityPrefix: String
    var onSelect: (TripClassification?) -> Void

    var body: some View {
        Group {
            if isSelected {
                menu
                    .buttonStyle(.borderedProminent)
                    .tint(selectedTint)
            } else {
                menu
                    .buttonStyle(.bordered)
                    .tint(Color(.systemGray))
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: TripClassificationActionButton.concentricCornerRadius))
        // The native bordered style adds horizontal padding outside the label.
        // Keep the overflow control narrow without shrinking its tap height.
        .frame(minWidth: 72)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(accessibilityPrefix)More")
    }

    private var menu: some View {
        Menu {
            Button {
                onSelect(nil)
            } label: {
                if selection == nil {
                    Label("Not Classified", systemImage: "checkmark")
                } else {
                    Text("Not Classified")
                }
            }
            .accessibilityIdentifier("\(accessibilityPrefix)NotClassified")
            .accessibilityAddTraits(selection == nil ? .isSelected : [])

            Button {
                onSelect(.notADrive)
            } label: {
                if selection == .notADrive {
                    Label("Not a Drive", systemImage: "checkmark")
                } else {
                    Text("Not a Drive")
                }
            }
            .accessibilityIdentifier("\(accessibilityPrefix)notADrive")
            .accessibilityAddTraits(selection == .notADrive ? .isSelected : [])
        } label: {
            VStack(spacing: 4) {
                Image(systemName: isSelected ? "nosign" : "ellipsis")
                    .font(.headline)
                Text(isSelected ? "Not a Drive" : "More")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 56)
        }
        .accessibilityLabel(isSelected ? "Not a Drive" : "More")
        .accessibilityValue(accessibilityValue)
    }

    private var isSelected: Bool {
        selection == .notADrive
    }

    private var selectedTint: Color {
        Color(.systemGray)
    }

    private var accessibilityValue: String {
        switch selection {
        case nil:
            String(localized: "Not Classified")
        case .notADrive:
            String(localized: "Not a Drive")
        case .business, .personal:
            ""
        }
    }
}

private struct TripClassificationActionButton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var title: String
    var systemImage: String
    var isSelected = false
    var tint: Color = .accentColor
    var unselectedTint: Color = .accentColor
    var action: () -> Void

    /// Concentric with the enclosing grouped-section container: its 26pt
    /// corner radius minus the 8pt `TripClassificationButtonGroup.listRowInset`.
    static let concentricCornerRadius: CGFloat = 18

    var body: some View {
        Group {
            if isSelected {
                button
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
            } else {
                button
                    .buttonStyle(.bordered)
                    .tint(unselectedTint)
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: Self.concentricCornerRadius))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var button: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.headline)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.7)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, -6)
        }
        .accessibilityLabel(title)
    }
}

struct TripTimeRows: View {
    @Binding var startDate: Date
    @Binding var endDate: Date
    var startIdentifier = "tripDetailStart"
    var endIdentifier = "tripDetailEnd"

    var body: some View {
        DatePicker("Start", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
            .accessibilityIdentifier(startIdentifier)
        DatePicker("End", selection: $endDate, displayedComponents: [.date, .hourAndMinute])
            .accessibilityIdentifier(endIdentifier)
    }
}

struct TripFeeRow: View {
    var fee: TripFee

    @Environment(\.currencyCode) private var currencyCode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(fee.amount, format: .currency(code: currencyCode))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    private var title: String {
        guard let label = fee.label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            return fee.category.displayName
        }
        return label
    }

    private var detail: String {
        [
            fee.occurredAt.formatted(date: .abbreviated, time: .shortened),
            fee.source.displayName
        ].joined(separator: " · ")
    }
}

struct TripRowLabel: View {
    var title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .lineLimit(1)
            .frame(width: 116, alignment: .leading)
    }
}

struct TripDistanceField<Field: Hashable>: View {
    @Binding var text: String
    var focus: FocusState<Field?>.Binding
    var field: Field
    var identifier: String
    var usesSystemLabelLayout = false

    @Environment(\.distanceUnit) private var distanceUnit

    @ViewBuilder
    var body: some View {
        if usesSystemLabelLayout {
            LabeledContent {
                valueField
            } label: {
                Text("Distance")
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TripRowLabel(String(localized: "Distance"))
                valueField
            }
        }
    }

    private var valueField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TextField(
                distanceUnit == .miles
                    ? String(localized: "Miles")
                    : String(localized: "Kilometers"),
                text: $text
            )
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused(focus, equals: field)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier(identifier)
            Text(DistanceFormatting.unitSymbol(distanceUnit))
                .foregroundStyle(.secondary)
        }
    }
}

struct TripSectionRows<Field: Hashable, OriginSupplement: View, DestinationSupplement: View, Footer: View>: View {
    @Binding var startDate: Date
    @Binding var endDate: Date
    @Binding var origin: String
    @Binding var destination: String
    @Binding var distanceText: String
    var focus: FocusState<Field?>.Binding
    var originField: Field
    var destinationField: Field
    var distanceField: Field
    var startIdentifier: String
    var endIdentifier: String
    var originIdentifier: String
    var originSearchIdentifier: String
    var destinationIdentifier: String
    var destinationSearchIdentifier: String
    var distanceIdentifier: String
    var onOriginSearch: () -> Void
    var onOriginChange: @MainActor @Sendable () -> Void
    var onDestinationSearch: () -> Void
    var onDestinationChange: @MainActor @Sendable () -> Void
    @ViewBuilder var originSupplement: () -> OriginSupplement
    @ViewBuilder var destinationSupplement: () -> DestinationSupplement
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        TripTimeRows(
            startDate: $startDate,
            endDate: $endDate,
            startIdentifier: startIdentifier,
            endIdentifier: endIdentifier
        )

        TripEndpointField(
            title: String(localized: "Origin"),
            text: $origin,
            focus: focus,
            field: originField,
            submitLabel: .next,
            identifier: originIdentifier,
            searchIdentifier: originSearchIdentifier,
            onSubmit: {
                focus.wrappedValue = destinationField
            },
            onSearch: onOriginSearch,
            onChange: onOriginChange,
            displayText: TripEndpointField<Field>.displayText(for: origin)
        )
        originSupplement()

        TripEndpointField(
            title: String(localized: "Destination"),
            text: $destination,
            focus: focus,
            field: destinationField,
            submitLabel: .next,
            identifier: destinationIdentifier,
            searchIdentifier: destinationSearchIdentifier,
            onSubmit: {
                focus.wrappedValue = distanceField
            },
            onSearch: onDestinationSearch,
            onChange: onDestinationChange,
            displayText: TripEndpointField<Field>.displayText(for: destination)
        )
        destinationSupplement()

        TripDistanceField(
            text: $distanceText,
            focus: focus,
            field: distanceField,
            identifier: distanceIdentifier
        )

        footer()
    }
}

struct TripNotesField<Field: Hashable>: View {
    @Binding var text: String
    var focus: FocusState<Field?>.Binding
    var field: Field
    var identifier: String
    var usesSystemLabelLayout = false

    @ViewBuilder
    var body: some View {
        if usesSystemLabelLayout {
            notesField
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes")
                notesField
            }
        }
    }

    private var notesField: some View {
        TextField(usesSystemLabelLayout ? String(localized: "Notes") : "", text: $text, axis: .vertical)
            .lineLimit(3, reservesSpace: true)
            .textInputAutocapitalization(.sentences)
            .focused(focus, equals: field)
            .accessibilityLabel("Notes")
            .accessibilityIdentifier(identifier)
    }
}

struct TripEndpointField<Field: Hashable>: View {
    var title: String
    @Binding var text: String
    var focus: FocusState<Field?>.Binding
    var field: Field
    var submitLabel: SubmitLabel
    var identifier: String
    var searchIdentifier: String
    var onSubmit: () -> Void
    var onSearch: () -> Void
    var onChange: @MainActor @Sendable () -> Void
    var usesSystemLabelLayout = false
    /// Cleaned-up form shown while the field is unfocused. Geocoders hand back
    /// addresses whose components repeat ("22 Example St, 22 Example St,
    /// Cambridge, MA"), and the row is the one place that used to render that
    /// raw string. Focusing the field reveals the stored text again, so an
    /// edit still starts from — and saves — exactly what is persisted.
    var displayText: String?

    /// The standard `displayText` derivation every endpoint row uses: nil for
    /// an empty field (so the placeholder shows), else the deduplicated
    /// readable address.
    static func displayText(for address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AddressDisplayFormatter.readableAddress(trimmed)
    }

    @ViewBuilder
    var body: some View {
        if usesSystemLabelLayout {
            LabeledContent {
                valueField
            } label: {
                Text(title)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TripRowLabel(title)
                valueField
            }
        }
    }

    private var valueField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            TextField(
                usesSystemLabelLayout ? "" : title,
                text: TripEndpointTextChangeBinding.userEditable(
                    $text,
                    onChange: onChange,
                    displayedAs: focus.wrappedValue == field ? nil : displayText
                )
            )
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(true)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .submitLabel(submitLabel)
                .focused(focus, equals: field)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier(identifier)
                .onSubmit(onSubmit)

            Button {
                onSearch()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Search \(title)")
            .accessibilityIdentifier(searchIdentifier)
        }
    }
}

/// Routes only edits made through the text field to the manual-route workflow.
/// Parent-owned state can also change when automatic enrichment refreshes a
/// trip; observing the value itself would misclassify that refresh as a user
/// edit and could replace the enriched route on the next autosave.
enum TripEndpointTextChangeBinding {
    /// `displayedAs` substitutes a read-only presentation form (see
    /// `TripEndpointField.displayText`); writes always land on the source.
    @MainActor
    static func userEditable(
        _ source: Binding<String>,
        onChange: @escaping @MainActor @Sendable () -> Void,
        displayedAs displayText: String? = nil
    ) -> Binding<String> {
        Binding(
            get: { displayText ?? source.wrappedValue },
            set: { newValue in
                // A field showing the display form can echo that form back as
                // focus changes. Writing it through would silently replace the
                // stored address and count as a manual route edit.
                guard newValue != source.wrappedValue, newValue != displayText else { return }
                source.wrappedValue = newValue
                onChange()
            }
        )
    }
}

/// Fee section content (without the enclosing `Section`) laid out as
/// Add Fee button (top) → fee rows → Total (bottom). Rows and Total only
/// appear once at least one fee exists; an empty section is just the button.
struct TripFeeSection: View {
    var fees: [TripFee]
    var total: Double
    var addAccessibilityIdentifier: String
    var totalAccessibilityIdentifier: String
    var rowAccessibilityIdentifier: ((TripFee) -> String)?
    var onAddFee: () -> Void
    var onSelectFee: (TripFee) -> Void
    var onDeleteFee: (TripFee) -> Void

    @Environment(\.currencyCode) private var currencyCode

    init(
        fees: [TripFee],
        total: Double,
        addAccessibilityIdentifier: String,
        totalAccessibilityIdentifier: String,
        rowAccessibilityIdentifier: ((TripFee) -> String)? = nil,
        onAddFee: @escaping () -> Void,
        onSelectFee: @escaping (TripFee) -> Void,
        onDeleteFee: @escaping (TripFee) -> Void
    ) {
        self.fees = fees
        self.total = total
        self.addAccessibilityIdentifier = addAccessibilityIdentifier
        self.totalAccessibilityIdentifier = totalAccessibilityIdentifier
        self.rowAccessibilityIdentifier = rowAccessibilityIdentifier
        self.onAddFee = onAddFee
        self.onSelectFee = onSelectFee
        self.onDeleteFee = onDeleteFee
    }

    var body: some View {
        Button {
            onAddFee()
        } label: {
            Label("Add Fee", systemImage: "plus.circle.fill")
        }
        .accessibilityIdentifier(addAccessibilityIdentifier)

        if !fees.isEmpty {
            ForEach(fees) { fee in
                Button {
                    onSelectFee(fee)
                } label: {
                    TripFeeRow(fee: fee)
                }
                .buttonStyle(.plain)
                .modifier(OptionalAccessibilityIdentifier(identifier: rowAccessibilityIdentifier?(fee)))
                .swipeActions {
                    Button(role: .destructive) {
                        onDeleteFee(fee)
                    } label: {
                        Label("Delete", systemImage: "trash.fill")
                    }
                }
                .contextMenu {
                    Button {
                        onSelectFee(fee)
                    } label: {
                        Label("Edit Fee", systemImage: "square.and.pencil")
                    }
                    Button(role: .destructive) {
                        onDeleteFee(fee)
                    } label: {
                        Label("Delete Fee", systemImage: "trash.fill")
                    }
                }
            }

            LabeledContent("Total", value: total, format: .currency(code: currencyCode))
                .accessibilityIdentifier(totalAccessibilityIdentifier)
        }
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    var identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

/// Returns the field `offset` positions away from `current` in `order`, or nil
/// if there is no such field. Shared by the trip editor keyboard action bar.
func adjacentFormField<F: Hashable>(in order: [F], from current: F?, offset: Int) -> F? {
    guard let current, let index = order.firstIndex(of: current) else {
        return nil
    }
    let destinationIndex = index + offset
    guard order.indices.contains(destinationIndex) else {
        return nil
    }
    return order[destinationIndex]
}

/// Pure helpers shared by the manual trip editor and trip detail editor for
/// resolving origin/destination endpoints into route lookups.
enum TripRouteEditing {
    static func routeKey(origin: String, destination: String) -> ManualRouteLookupKey? {
        ManualRouteLookupKey(origin: origin, destination: destination)
    }

    static func endpointText(
        for target: TripEndpointSearchTarget,
        origin: String,
        destination: String
    ) -> String {
        switch target {
        case .origin: origin
        case .destination: destination
        }
    }

    static func manualRouteEndpoint(
        for target: TripEndpointSearchTarget,
        text: String,
        originResult: TripEndpointSearchResult?,
        destinationResult: TripEndpointSearchResult?,
        storedTrip: TripSummary? = nil
    ) -> ManualRouteEndpoint {
        let result: TripEndpointSearchResult? = switch target {
        case .origin: originResult
        case .destination: destinationResult
        }
        // Reopening a saved trip has no in-memory search selections. An
        // unchanged endpoint still has a confirmed coordinate we can route to.
        let storedCoordinate: Coordinate? = switch target {
        case .origin:
            text == storedTrip?.startAddress
                ? storedTrip?.routeSummary.startCoordinate ?? storedTrip?.startCoordinate : nil
        case .destination:
            text == storedTrip?.endAddress
                ? storedTrip?.routeSummary.endCoordinate ?? storedTrip?.endCoordinate : nil
        }
        let coordinate: Coordinate? = if let result, result.endpointText == text {
            Coordinate(result.coordinate)
        } else {
            storedCoordinate
        }
        return ManualRouteEndpoint(address: text, coordinate: coordinate)
    }

    static func endpointMapContent(
        origin: String,
        destination: String,
        originResult: TripEndpointSearchResult?,
        destinationResult: TripEndpointSearchResult?,
        storedTrip: TripSummary?
    ) -> RouteMapContent? {
        let selectedOrigin = manualRouteEndpoint(
            for: .origin, text: origin,
            originResult: originResult, destinationResult: destinationResult,
            storedTrip: storedTrip
        ).coordinate
        let selectedDestination = manualRouteEndpoint(
            for: .destination, text: destination,
            originResult: originResult, destinationResult: destinationResult,
            storedTrip: storedTrip
        ).coordinate
        return RouteMapContent(origin: selectedOrigin, destination: selectedDestination)
    }

    static func isStaleResult(
        _ result: TripEndpointSearchResult?,
        currentText: String
    ) -> Bool {
        guard let result else { return false }
        return result.endpointText != currentText
    }
}
