import AppCoreModels
import AppCorePersistence
import DriveCaptureEngine
import Foundation

/// Plain-struct snapshot of one calendar event, mapped from EKEvent by the
/// app target. Keeping the ranking/annotation logic here (AppCore) makes it
/// unit-testable under `swift test` with no EventKit dependency.
public struct CalendarEventCandidate: Equatable, Sendable {
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var isAllDay: Bool
    public var coordinate: Coordinate?
    public var locationText: String?
    /// Display name of the containing calendar ("Work", "Home"). A soft prior
    /// only — freelancer calendars mix jobs and personal events freely, so the
    /// prompt presents it as an unreliable hint, never a verdict.
    public var calendarName: String?

    public init(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        coordinate: Coordinate? = nil,
        locationText: String? = nil,
        calendarName: String? = nil
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.coordinate = coordinate
        self.locationText = locationText
        self.calendarName = calendarName
    }
}

/// A stop inferred from two separate, reciprocal drives. It is weaker than a
/// stop recorded inside one trip: it establishes that the car stayed at the
/// shared endpoint, but does not establish which calendar event was attended.
public struct PairedDriveStop: Codable, Equatable, Sendable {
    public var partnerID: UUID
    public var partnerUpdatedAt: Date
    public var interval: DateInterval

    public init(partnerID: UUID, partnerUpdatedAt: Date, interval: DateInterval) {
        self.partnerID = partnerID
        self.partnerUpdatedAt = partnerUpdatedAt
        self.interval = interval
    }
}

public enum PairedDriveStopFinder {
    /// Only a reciprocal, same-vehicle pair with no intervening drive can
    /// corroborate an all-day event. City-only endpoints are never enough.
    public static func stop(for trip: TripSummary, among trips: [TripSummary]) -> PairedDriveStop? {
        guard trip.legs.count == 1, trip.classification != .notADrive else { return nil }
        let candidates = trips.compactMap { other -> PairedDriveStop? in
            guard other.id != trip.id, other.legs.count == 1,
                  other.classification != .notADrive,
                  other.vehicleID == trip.vehicleID else { return nil }
            let outbound: TripSummary
            let inbound: TripSummary
            if trip.endDate <= other.startDate {
                outbound = trip
                inbound = other
            } else if other.endDate <= trip.startDate {
                outbound = other
                inbound = trip
            } else {
                return nil
            }
            let gap = inbound.startDate.timeIntervalSince(outbound.endDate)
            guard (20 * 60 ... 8 * 3_600).contains(gap),
                  endpointsMatch(outbound.endCoordinate, outbound.endAddressComponents,
                                 inbound.startCoordinate, inbound.startAddressComponents),
                  endpointsMatch(outbound.startCoordinate, outbound.startAddressComponents,
                                 inbound.endCoordinate, inbound.endAddressComponents),
                  !trips.contains(where: { intervening in
                      intervening.id != outbound.id && intervening.id != inbound.id
                          && intervening.classification != .notADrive
                          && intervening.startDate < inbound.startDate
                          && intervening.endDate > outbound.endDate
                  }) else { return nil }
            return PairedDriveStop(
                partnerID: other.id, partnerUpdatedAt: other.updatedAt,
                interval: DateInterval(start: outbound.endDate, end: inbound.startDate)
            )
        }
        return candidates.min { $0.interval.duration < $1.interval.duration }
    }

    private static func endpointsMatch(
        _ firstCoordinate: Coordinate?, _ firstAddress: TripEndpointAddressComponents?,
        _ secondCoordinate: Coordinate?, _ secondAddress: TripEndpointAddressComponents?
    ) -> Bool {
        if let firstCoordinate, let secondCoordinate {
            return DistanceCalculator.distanceMeters(from: firstCoordinate, to: secondCoordinate) <= 150
        }
        guard let firstStreet = AddressNormalizer.normalizedStreetText(firstAddress?.streetLine),
              let secondStreet = AddressNormalizer.normalizedStreetText(secondAddress?.streetLine),
              let firstCity = AddressNormalizer.normalizedStreetText(firstAddress?.city),
              let secondCity = AddressNormalizer.normalizedStreetText(secondAddress?.city) else { return false }
        return firstStreet == secondStreet && firstCity == secondCity
    }
}

/// Ranks and formats calendar events for the suggestion prompt. The join to
/// the trip is computed here deterministically — the model reads "at this
/// trip's destination", it never sees the raw event location (privacy surface
/// stays titles, times, and one boolean).
public enum CalendarEventEvidenceBuilder {
    public struct RankedEvent: Equatable, Sendable {
        /// Ground truth for cited-title validation.
        public var title: String
        /// Prompt-facing line.
        public var line: String
        public var isAtDestination: Bool
    }

    /// Prompt dates are fixed-format and English: model-facing, not
    /// user-facing (matches TripSuggestionPromptBuilder).
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE h:mm a"
        return formatter
    }()

    /// Orders events by relevance to the trip — destination matches first,
    /// then time-proximity (all-day last within each group) — and caps AFTER
    /// ranking, so a matching event can't lose the cap to earlier filler.
    public static func rankedEvents(
        candidates: [CalendarEventCandidate],
        tripStart: Date,
        tripEnd: Date,
        tripEndCoordinate: Coordinate?,
        tripEndComponents: TripEndpointAddressComponents?,
        // Looser than the 150 m endpoint radius: event locations geocode to
        // venue centroids/front doors while trips end at parking.
        locationRadiusMeters: Double = 300,
        limit: Int = 8
    ) -> [RankedEvent] {
        let scored = candidates.map { candidate in
            (
                candidate: candidate,
                isAtDestination: matchesDestination(
                    candidate,
                    tripEndCoordinate: tripEndCoordinate,
                    tripEndComponents: tripEndComponents,
                    radiusMeters: locationRadiusMeters
                ),
                proximity: candidate.isAllDay
                    ? Double.greatestFiniteMagnitude
                    : timeDistance(
                        eventStart: candidate.startDate, eventEnd: candidate.endDate,
                        tripStart: tripStart, tripEnd: tripEnd
                    )
            )
        }
        .sorted { first, second in
            if first.isAtDestination != second.isAtDestination { return first.isAtDestination }
            if first.proximity != second.proximity { return first.proximity < second.proximity }
            return first.candidate.startDate < second.candidate.startDate
        }

        return scored.prefix(limit).map { entry in
            RankedEvent(
                title: entry.candidate.title,
                line: line(for: entry.candidate, isAtDestination: entry.isAtDestination),
                isAtDestination: entry.isAtDestination
            )
        }
    }

    // MARK: - Bucketed evidence (linked vs context)

    /// One prompt-ready event with the deterministic facts the output gates
    /// key off. `id` ("L1"/"C2") is the citation vocabulary: the model picks
    /// an ID from a closed set, so a fabricated citation is impossible and
    /// every cited claim resolves to code-computed ground truth.
    public struct BucketedEvent: Equatable, Sendable {
        public var id: String
        public var title: String
        public var line: String
        public var isLinked: Bool
        public var isTentative: Bool
        /// A place match or an actual stationary interval corroborates the
        /// calendar association beyond the outside time range of a drive.
        public var hasPlaceOrStopMatch: Bool = false
        /// A separate return drive brackets a stop on the event's date. This
        /// is weaker than a venue match and caps Business confidence at 3.
        public var hasPairedDriveStop: Bool = false
        /// An explicitly remote/different place, broad visit, or an event
        /// entirely inside a driving leg cannot explain attending in person.
        public var hasTravelConflict: Bool = false
    }

    public struct BucketedEvents: Equatable, Sendable {
        public var linked: [BucketedEvent]
        public var context: [BucketedEvent]

        public init(linked: [BucketedEvent], context: [BucketedEvent]) {
            self.linked = linked
            self.context = context
        }

        public var all: [BucketedEvent] { linked + context }
        public func event(withID id: String) -> BucketedEvent? {
            all.first { $0.id == id }
        }
    }

    /// Where the deterministic location join placed an event relative to the
    /// trip. Field data (2026-08): most real events carry no location at all,
    /// so time relations, not places, carry the linking most of the time.
    enum PlaceRelation {
        case destination, stop, stopLocality, pairedDriveStop, origin, elsewhere, none, remote
    }

    /// Tentative-plan markers in titles ("Possible shoot", "Berlin?",
    /// "RSVP pending"). Title-only on purpose: EKEvent availability is not
    /// mapped into the candidate, and titles are what users actually write.
    /// Covers the app's shipped languages (EN/ES/FR/DE), accented and plain
    /// spellings both — a missed marker fails OPEN (a tentative gig can back
    /// a full-confidence business suggestion), so err toward inclusion.
    private static let tentativePattern = try! NSRegularExpression(
        pattern: "(?i)(possible|potential|maybe|tbd|\\bhold\\b|rsvp|rain day|\\?"
            + "|posible|quiz[áa]s?\\b|por confirmar|provisional"
            + "|peut-[êe]tre|[ée]ventuel|[àa] confirmer|provisoire"
            + "|vielleicht|\\bevtl\\b|eventuell|m[öo]glich|vorl[äa]ufig|unter vorbehalt)"
    )

    static func isTentativeTitle(_ title: String) -> Bool {
        tentativePattern.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    /// Explicit remote meeting titles do not explain travel, even when an
    /// invite also carries an office address. Match phrases rather than the
    /// bare word "call": photo calls, casting calls, and on-call shifts may
    /// require travel. Leading "Call with" and "Zoom:" cover location-free
    /// invites; a bare "Zoom" still permits in-person zoom-lens events.
    /// The remaining phrases cover explicit phone/video meetings in EN/ES/FR/DE.
    private static let remoteTitlePattern = try! NSRegularExpression(
        pattern: #"(?i)(?:^\s*call\s+with\b|\b(?:phone|telephone|video|conference)[\s-]+call\b"#
            + #"|^\s*zoom\s*:\s*\S"#
            + #"|\b(?:zoom|teams|webex|facetime|google\s+meet)\s+(?:call|meeting|interview|consultation)\b"#
            + #"|\b(?:call|meeting)\s+(?:on|via|over)\s+(?:zoom|teams|webex|facetime|google\s+meet)\b"#
            + #"|\btelevisit\b|\btele(?:health|medicine)\s+(?:appointment|visit|consultation)\b"#
            + #"|^\s*llamada\s+con\b|\b(?:llamada\s+telef[oó]nica|videollamada|videoconferencia)\b"#
            + #"|^\s*appel\s+avec\b|\b(?:appel\s+(?:t[eé]l[eé]phonique|vid[eé]o)|visioconf[eé]rence)\b"#
            + #"|\b(?:telefonat|telefonkonferenz|videokonferenz|videoanruf)\b|^\s*anruf\s+(?:mit|bei)\b)"#
    )

    static func isRemoteTitle(_ title: String) -> Bool {
        remoteTitlePattern.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    /// URL/phone/meeting-service location text means a call, not a place a
    /// drive could go; a coordinate always wins over text.
    static func isRemoteLocation(_ text: String?, coordinate: Coordinate?) -> Bool {
        guard coordinate == nil, let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else {
            return false
        }
        if text.hasPrefix("http") || text.hasPrefix("www.") || text.hasPrefix("tel:") { return true }
        for marker in ["zoom", "meet.google", "teams.microsoft", "webex", "gotomeeting", "facetime"] where text.contains(marker) {
            return true
        }
        // Dots and slashes are digit separators in European phone formats
        // ("01.42.68.53.00", "030/1234567"). A missed phone fails OPEN (a
        // call links and can back a business suggestion for a drive that was
        // actually a call), so the class is permissive; letters still break
        // the full-string match, keeping real addresses out.
        return text.range(of: #"^[+()\d\s\-./]{7,}$"#, options: .regularExpression) != nil
    }

    /// Splits the trip-window candidates into "linked" events (the app could
    /// tie them to this drive by place or by a coherent time relation) and
    /// "context" events (merely nearby in time). Only linked events may back
    /// a business suggestion downstream.
    ///
    /// Field-calibrated rules (88 labeled trips, 2026-08-27 eval):
    /// - Timed events link via place match, or via arrive-as-starts /
    ///   leaves-as-ends (−15 min…+45 min), or a short overlap. An event that
    ///   CONTAINS the trip with ≥45 min margin on both sides is incoherent
    ///   (the user was mid-event elsewhere while driving) and stays context.
    /// - Tentative titles link only through a place match.
    /// - All-day events only link through one corroborated reciprocal-drive
    ///   stop when they have no competing event or contrary location.
    /// - Remote (video/phone) and located-elsewhere events never link.
    public static func bucketedEvents(
        candidates: [CalendarEventCandidate],
        tripStart: Date,
        tripEnd: Date,
        tripEndCoordinate: Coordinate?,
        tripEndComponents: TripEndpointAddressComponents?,
        stopCoordinates: [Coordinate?] = [],
        stopComponents: [TripEndpointAddressComponents?] = [],
        pairedDriveStop: DateInterval? = nil,
        originCoordinate: Coordinate? = nil,
        originComponents: TripEndpointAddressComponents? = nil,
        locationRadiusMeters: Double = 300,
        linkedLimit: Int = 3,
        contextLimit: Int = 4
    ) -> BucketedEvents {
        bucketedEvents(
            candidates: candidates, tripStart: tripStart, tripEnd: tripEnd,
            tripEndCoordinate: tripEndCoordinate, tripEndComponents: tripEndComponents,
            stopCoordinates: stopCoordinates, stopComponents: stopComponents,
            stopIntervals: [], pairedDriveStop: pairedDriveStop,
            originCoordinate: originCoordinate,
            originComponents: originComponents, locationRadiusMeters: locationRadiusMeters,
            linkedLimit: linkedLimit, contextLimit: contextLimit
        )
    }

    /// Internal enrichment path: real stationary intervals add a conservative
    /// city match without changing the public evidence-builder contract.
    package static func bucketedEvents(
        candidates: [CalendarEventCandidate],
        tripStart: Date,
        tripEnd: Date,
        tripEndCoordinate: Coordinate?,
        tripEndComponents: TripEndpointAddressComponents?,
        stopCoordinates: [Coordinate?] = [],
        stopComponents: [TripEndpointAddressComponents?] = [],
        stopIntervals: [DateInterval?],
        pairedDriveStop: DateInterval? = nil,
        travelIntervals: [DateInterval] = [],
        originCoordinate: Coordinate? = nil,
        originComponents: TripEndpointAddressComponents? = nil,
        locationRadiusMeters: Double = 300,
        linkedLimit: Int = 3,
        contextLimit: Int = 4
    ) -> BucketedEvents {
        struct Annotated {
            let candidate: CalendarEventCandidate
            let place: PlaceRelation
            let tentative: Bool
            let linked: Bool
            let timeRelation: String?
            let hasPlaceOrStopMatch: Bool
            let hasPairedDriveStop: Bool
            let hasTravelConflict: Bool
        }

        let deduped = collapseDuplicates(candidates)
        // An all-day entry with no venue is only useful when it is the sole
        // event that could explain an out-and-back outing. A timed event in
        // the inferred stop is more specific and takes precedence.
        let allDayCandidates = deduped.filter(\.isAllDay)
        let timedEventAtPairedStop = pairedDriveStop.map { stop in
            deduped.contains { !$0.isAllDay && $0.startDate < stop.end && $0.endDate > stop.start }
        } ?? false
        let annotated = deduped.map { candidate -> Annotated in
            var place = placeRelation(
                candidate,
                tripEndCoordinate: tripEndCoordinate, tripEndComponents: tripEndComponents,
                stopCoordinates: stopCoordinates, stopComponents: stopComponents,
                originCoordinate: originCoordinate, originComponents: originComponents,
                radiusMeters: locationRadiusMeters
            )
            let tentative = isTentativeTitle(candidate.title)
            if place == .elsewhere, !tentative,
               matchesStopLocality(candidate, components: stopComponents, intervals: stopIntervals) {
                place = .stopLocality
            }
            let pairedAllDay = candidate.isAllDay && allDayCandidates.count == 1
                && !timedEventAtPairedStop && !tentative && place == .none
                && pairedDriveStop.map { stop in
                    let duration = candidate.endDate.timeIntervalSince(candidate.startDate)
                    return (22 * 3_600 ... 26 * 3_600).contains(duration)
                        && candidate.startDate <= stop.start && stop.end <= candidate.endDate
                        && Calendar.current.isDate(stop.start, inSameDayAs: stop.end)
                } == true
            if pairedAllDay { place = .pairedDriveStop }
            var timeRelation: String? = nil
            var coherentChannel = false
            if !candidate.isAllDay {
                // A multi-day visit does not become drive evidence merely
                // because the trip happens near either end of its span.
                let shortEnough = candidate.endDate.timeIntervalSince(candidate.startDate) <= 4 * 3_600
                if candidate.startDate <= tripEnd && tripStart <= candidate.endDate {
                    timeRelation = "during this trip"
                    // Coherent overlaps only: an event that CONTAINS the trip
                    // with ≥45 min margin on both sides means the user was
                    // mid-event elsewhere while driving, and a multi-hour
                    // timed span ("Family visit", three days) overlaps every
                    // drive it touches. An event fully INSIDE the trip is the
                    // opposite — a round trip wrapped around the engagement.
                    let containsTrip = candidate.startDate < tripStart.addingTimeInterval(-2_700)
                        && candidate.endDate > tripEnd.addingTimeInterval(2_700)
                    let insideTrip = candidate.startDate >= tripStart && candidate.endDate <= tripEnd
                    coherentChannel = !containsTrip && (shortEnough || insideTrip)
                } else if candidate.startDate.timeIntervalSince(tripEnd) >= -900,
                          candidate.startDate.timeIntervalSince(tripEnd) <= 2_700 {
                    timeRelation = "trip arrives as this event starts"
                    coherentChannel = shortEnough
                } else if tripStart.timeIntervalSince(candidate.endDate) >= -900,
                          tripStart.timeIntervalSince(candidate.endDate) <= 2_700 {
                    timeRelation = "trip leaves as this event ends"
                    coherentChannel = shortEnough
                } else if candidate.endDate < tripStart {
                    timeRelation = "about \(gapPhrase(tripStart.timeIntervalSince(candidate.endDate))) before this trip"
                } else if candidate.startDate > tripEnd {
                    timeRelation = "about \(gapPhrase(candidate.startDate.timeIntervalSince(tripEnd))) after this trip"
                }
            }
            let canLink = (!candidate.isAllDay || pairedAllDay) && place != .remote && place != .elsewhere
            let linked = canLink && (
                place == .destination || place == .stop || place == .stopLocality || place == .pairedDriveStop
                    || ((place == .none || place == .origin) && !tentative && coherentChannel)
            )
            let hasPlaceMatch = place == .destination || place == .stop
                || place == .stopLocality || (place == .origin && coherentChannel)
            let hasStopOverlap = !candidate.isAllDay && stopIntervals.contains { interval in
                guard let interval else { return false }
                return max(interval.start, candidate.startDate) < min(interval.end, candidate.endDate)
            }
            let duringDriving = candidate.endDate > candidate.startDate && travelIntervals.contains {
                $0.start <= candidate.startDate && candidate.endDate <= $0.end
            }
            let isBroadVisit = candidate.endDate.timeIntervalSince(candidate.startDate) >= 24 * 3_600
            let hasTravelConflict = place == .remote || place == .elsewhere
                || (!hasPlaceMatch && !pairedAllDay && (isBroadVisit || duringDriving))
            return Annotated(
                candidate: candidate, place: place, tentative: tentative,
                linked: linked, timeRelation: timeRelation,
                hasPlaceOrStopMatch: hasPlaceMatch || hasStopOverlap,
                hasPairedDriveStop: pairedAllDay,
                hasTravelConflict: hasTravelConflict
            )
        }

        var linked = annotated.filter(\.linked)
        linked.sort { first, second in
            if (first.place == .destination) != (second.place == .destination) { return first.place == .destination }
            return first.candidate.startDate < second.candidate.startDate
        }
        linked = Array(linked.prefix(linkedLimit))
        // Linked overflow is deliberately omitted. Reissuing a fourth linked
        // event as C1 would preserve `entry.linked` and let a context citation
        // pass the downstream business-evidence gate.
        var context = annotated.filter { !$0.linked }
        context.sort { first, second in
            if first.candidate.isAllDay != second.candidate.isAllDay { return second.candidate.isAllDay }
            return first.candidate.startDate < second.candidate.startDate
        }
        context = Array(context.prefix(contextLimit))

        func bucketed(_ entry: Annotated, id: String) -> BucketedEvent {
            BucketedEvent(
                id: id,
                title: entry.candidate.title,
                line: bucketLine(id: id, entry.candidate, place: entry.place, tentative: entry.tentative, timeRelation: entry.timeRelation),
                isLinked: entry.linked,
                isTentative: entry.tentative,
                hasPlaceOrStopMatch: entry.hasPlaceOrStopMatch,
                hasPairedDriveStop: entry.hasPairedDriveStop,
                hasTravelConflict: entry.hasTravelConflict
            )
        }
        return BucketedEvents(
            linked: linked.enumerated().map { bucketed($1, id: "L\($0 + 1)") },
            context: context.enumerated().map { bucketed($1, id: "C\($0 + 1)") }
        )
    }

    /// Invite-plus-own-copy collapse: equal punctuation-insensitive titles
    /// with overlapping intervals merge, keeping the copy with location data.
    static func collapseDuplicates(_ candidates: [CalendarEventCandidate]) -> [CalendarEventCandidate] {
        func normalizedTitle(_ value: String) -> String {
            value.lowercased().unicodeScalars
                .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
                .reduce(into: "") { $0.append($1) }
                .split(separator: " ").joined(separator: " ")
        }
        var kept: [CalendarEventCandidate] = []
        for candidate in candidates {
            if let index = kept.firstIndex(where: {
                normalizedTitle($0.title) == normalizedTitle(candidate.title)
                    && $0.startDate <= candidate.endDate && candidate.startDate <= $0.endDate
            }) {
                let existing = kept[index]
                let existingHasLocation = existing.coordinate != nil || existing.locationText?.isEmpty == false
                let newHasLocation = candidate.coordinate != nil || candidate.locationText?.isEmpty == false
                if !existingHasLocation && newHasLocation { kept[index] = candidate }
            } else {
                kept.append(candidate)
            }
        }
        return kept
    }

    static func placeRelation(
        _ candidate: CalendarEventCandidate,
        tripEndCoordinate: Coordinate?,
        tripEndComponents: TripEndpointAddressComponents?,
        stopCoordinates: [Coordinate?],
        stopComponents: [TripEndpointAddressComponents?],
        originCoordinate: Coordinate?,
        originComponents: TripEndpointAddressComponents?,
        radiusMeters: Double
    ) -> PlaceRelation {
        if isRemoteTitle(candidate.title)
            || isRemoteLocation(candidate.locationText, coordinate: candidate.coordinate) { return .remote }
        if candidate.coordinate == nil, AddressNormalizer.normalizedStreetText(candidate.locationText) == nil { return .none }
        if matchesDestination(candidate, tripEndCoordinate: tripEndCoordinate, tripEndComponents: tripEndComponents, radiusMeters: radiusMeters) {
            return .destination
        }
        for (coordinate, components) in zip(stopCoordinates, stopComponents) {
            if matchesDestination(candidate, tripEndCoordinate: coordinate, tripEndComponents: components, radiusMeters: radiusMeters) {
                return .stop
            }
        }
        if matchesDestination(candidate, tripEndCoordinate: originCoordinate, tripEndComponents: originComponents, radiusMeters: radiusMeters) {
            return .origin
        }
        // Any remaining nonremote location is explicitly somewhere other than
        // the route. Failing closed here is important: `.none` may link from a
        // coherent time overlap, so treating an unmatched international
        // address or venue name as unknown could authorize Business evidence.
        return .elsewhere
    }

    /// A loose venue name ("East Meadow Office") can link only when its city
    /// matches a stop that contains the full timed event. A conflicting point
    /// or street address must never be overridden by the broader city match.
    private static func matchesStopLocality(
        _ candidate: CalendarEventCandidate,
        components: [TripEndpointAddressComponents?],
        intervals: [DateInterval?]
    ) -> Bool {
        guard !candidate.isAllDay, candidate.coordinate == nil,
              candidate.endDate > candidate.startDate,
              !isRemoteLocation(candidate.locationText, coordinate: nil),
              let location = AddressNormalizer.normalizedStreetText(candidate.locationText),
              !location.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) else {
            return false
        }
        let streetWords: Set<Substring> = [
            "st", "street", "ave", "avenue", "rd", "road", "blvd", "boulevard",
            "dr", "drive", "ln", "lane", "ct", "court", "way", "strasse", "rue", "calle"
        ]
        return zip(components, intervals).contains { component, interval in
            guard let city = AddressNormalizer.normalizedStreetText(component?.city),
                  (" " + location + " ").contains(" " + city + " "),
                  let interval, interval.duration > 0,
                  interval.start <= candidate.startDate, candidate.endDate <= interval.end else {
                return false
            }
            let cityWords = Set(city.split(separator: " "))
            let remainingWords = Set(location.split(separator: " ")).subtracting(cityWords)
            return remainingWords.isDisjoint(with: streetWords)
        }
    }

    private static func gapPhrase(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h\(remainder)m"
    }

    private static func bucketLine(
        id: String,
        _ candidate: CalendarEventCandidate,
        place: PlaceRelation,
        tentative: Bool,
        timeRelation: String?
    ) -> String {
        var parts: [String] = []
        if let calendar = candidate.calendarName?.trimmingCharacters(in: .whitespaces), !calendar.isEmpty {
            parts.append("\(calendar) calendar")
        }
        if tentative { parts.append("tentative") }
        parts.append(candidate.isAllDay
            ? "all day"
            : "\(timeFormatter.string(from: candidate.startDate))–\(timeFormatter.string(from: candidate.endDate))")
        if let timeRelation { parts.append(timeRelation) }
        switch place {
        case .destination: parts.append("at this trip's destination")
        case .stop: parts.append("at a stop on this trip")
        case .stopLocality: parts.append("in the same city as a stop that spans this event; exact venue unverified")
        case .pairedDriveStop: parts.append("two reciprocal drives bracket a stop on this date; event venue unverified")
        case .origin: parts.append("at this trip's starting point")
        case .elsewhere: parts.append("at a different location")
        case .remote: parts.append("video or phone call")
        case .none: parts.append("location unknown")
        }
        return "\(id): \"\(candidate.title)\" — \(parts.joined(separator: ", "))"
    }

    /// Coordinate within the radius when both sides have one; otherwise the
    /// normalized freeform location text must contain the trip destination's
    /// normalized street line (number + name, so containment stays tight —
    /// "AltaMark Studio, 350 5th Ave, New York" matches "350 5th Avenue").
    private static func matchesDestination(
        _ candidate: CalendarEventCandidate,
        tripEndCoordinate: Coordinate?,
        tripEndComponents: TripEndpointAddressComponents?,
        radiusMeters: Double
    ) -> Bool {
        if let eventCoordinate = candidate.coordinate, let tripEndCoordinate,
           DistanceCalculator.distanceMeters(from: eventCoordinate, to: tripEndCoordinate) <= radiusMeters {
            return true
        }
        guard let locationText = AddressNormalizer.normalizedStreetText(candidate.locationText),
              let streetLine = AddressNormalizer.normalizedStreetText(tripEndComponents?.streetLine) else {
            return false
        }
        // Token-set containment, not substring: the geocoder's street line is
        // always number-first ("123 Hauptstraße") while German-style location
        // text is number-last ("Hauptstraße 123, Berlin"). Requiring every
        // street-line token keeps the join tight (number AND name must both
        // appear) while ignoring word order.
        let locationTokens = Set(locationText.split(separator: " "))
        return streetLine.split(separator: " ").allSatisfy(locationTokens.contains)
    }

    /// 0 when the event and trip intervals overlap, else the gap between them.
    private static func timeDistance(
        eventStart: Date, eventEnd: Date,
        tripStart: Date, tripEnd: Date
    ) -> TimeInterval {
        if eventStart <= tripEnd && tripStart <= eventEnd { return 0 }
        return min(
            abs(eventStart.timeIntervalSince(tripEnd)),
            abs(tripStart.timeIntervalSince(eventEnd))
        )
    }

    private static func line(for candidate: CalendarEventCandidate, isAtDestination: Bool) -> String {
        let timePart = candidate.isAllDay
            ? "all day"
            : "\(timeFormatter.string(from: candidate.startDate))–\(timeFormatter.string(from: candidate.endDate))"
        let locationPart = isAtDestination ? "; at this trip's destination" : ""
        return "\(candidate.title) (\(timePart)\(locationPart))"
    }
}
