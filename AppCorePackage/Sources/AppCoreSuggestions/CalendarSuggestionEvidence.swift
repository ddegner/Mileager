import AppCoreEnrichment
import AppCoreModels
import EventKit
import Foundation

/// Fetches the user's calendar events around one trip for suggestion
/// evidence. Deliberately NOT a Foundation Models `Tool`: the lookup is fully
/// deterministic (fixed window known before generation), and exposing it as a
/// tool made the model call it in a loop until the context window overflowed.
/// The events are prefetched into the prompt instead.
///
/// This is only the thin EKEvent mapping; ranking, destination matching, and
/// prompt-line formatting live in `CalendarEventEvidenceBuilder` (AppCore) so
/// they are unit-testable. The event's location feeds a deterministic
/// destination comparison there — the raw location text is never quoted into
/// the prompt, keeping the privacy surface at titles, times, and one boolean.
public enum CalendarSuggestionEvidence {
    public static func candidates(windowStart: Date, windowEnd: Date) -> [CalendarEventCandidate] {
        let store = EKEventStore()
        let predicate = store.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: nil
        )
        return store.events(matching: predicate)
            // Contact birthdays are all-day noise that overlaps every window
            // on their date and drowns out real events. Subscribed calendars
            // (holidays) leak the same all-day noise; their *timed* events
            // (league schedules, shared work calendars) can be legitimate
            // evidence and now rank by relevance, so only all-day ones drop.
            .filter { event in
                guard let type = event.calendar?.type else { return true }
                if type == .birthday { return false }
                if type == .subscription && event.isAllDay { return false }
                return true
            }
            .compactMap { event in
                let trimmed = event.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let title = trimmed, !title.isEmpty else { return nil }
                let coordinate = event.structuredLocation?.geoLocation.map {
                    Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                }
                return CalendarEventCandidate(
                    title: title,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    coordinate: coordinate,
                    locationText: event.location,
                    calendarName: event.calendar?.title
                )
            }
    }
}
