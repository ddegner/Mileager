# Changelog

## 2.9 (147) - 2026-11-03

### Added

- Choose Motion, Bluetooth, or Both for automatic trip starts. Both is the default when no choice is saved; existing choices remain unchanged. Bluetooth starts require a Bluetooth or CarPlay automation in Shortcuts and driving movement before recording.
- Show a green check and the last-received date after a Bluetooth or CarPlay shortcut action reaches Mileager successfully, including manual tests.

### Changed

- Group automatic tracking controls, trip-start options, Bluetooth setup, and permissions together. Show whether tracking is on, off, or paused, with simpler stop, pause-today, and vacation controls. Keep Lock Screen display in a separate group.

### Fixed

- Reject automatic captures with strong flight or cycling evidence, and discard brief movement artifacts after parking.
- Keep road crossings over bridges and through tunnels from being mistaken for water travel.

## 2.8.3 (141) - 2026-10-04

### Added

- QuickBooks mileage CSV export for business trips from month and year export menus, vehicle filters, and Mac commands.
- Schema-backed Siri actions to open the active drive and search saved trips, plus explicit system open semantics for saved trips.
- Opt-in Siri action donations after successful in-app classification, removed when trips expire or are deleted and when Siri & Search is disabled.
- A frozen 40-request language evaluation set, contextual cases, and a separate Siri validation gate that distinguishes direct execution, injected text, and actual speech.

### Changed

- Simplify mileage-rate settings with native collapsed history and update details, and one editor for custom amount, currency, and distance unit.
- Verify official IRS business rates directly on iOS 26 and later without requiring Apple Intelligence; keep unconfigured non-USD rates visibly unset.

### Fixed

- Restore the standard Mac Trips sidebar appearance with individually highlighted rows and system-blue accents.
- Save current-drive category, purpose, and note changes before reporting success; preserve the prior decision on save failure and reject expired drive references.
- Wait briefly for the trip store and active-drive restoration during Siri startup, honor App Lock, and refresh shortcut parameters after restoration and drive identity changes.
- Let a clearly work-related timed calendar event support an advisory Business suggestion for a drive around its time, even when the event has no Location field. Keep unrelated events, tentative plans, direct commutes, and known travel conflicts from supporting Business suggestions.

## 2.8.2 (135) - 2026-09-28

### Fixed

- Suggest Business for a single all-day work event without a location when reciprocal drives bracket a visit on that date. Require a sole all-day event, retain route and event conflict checks, and keep the suggestion advisory.
- Refresh cached suggestions when the paired drive changes so the calendar evidence stays current.

## 2.8.1 (132) - 2026-09-16

### Fixed

- Require a matched place or recorded stationary stop before a calendar event can support Business suggestions. Withhold cited events that conflict with travel, including remote meetings and broad multi-day visits.
- Include stationary-stop times in trip-suggestion evidence and reject confidence values outside the supported range.
- Keep trip-list maps the same size in Select mode, allowing only the text area to narrow for selection checkmarks.
- Try opted-in Private Cloud Compute even when the on-device model is not ready, fall back locally on cloud failures, and skip exhausted cloud quota. Record which model actually answered without logging trip details.
- Keep suggestion settings accessible while models load, and cancel pending generation immediately when an evidence source is turned off.
- Keep explicit phone and video meetings as calendar context so they cannot justify a Business drive, even when an address matches.
- Withhold Business suggestions for direct home-to-work commutes and tentative calendar plans; combined trips with intermediate stops remain eligible for review.

- Restore suggestions for merged trips when a named calendar venue matches a stop’s city and that stop covers the event’s full duration. Conflicting coordinates or street addresses still prevent a match; suggestions remain advisory.
- Keep the pull-down reimbursement caption above the large navigation title, including during shorter pulls.

### Changed

- Simplify Trips: hide Need Review when empty without closing an open review screen, show pending counts only on its row, remove repeated month icons and distance units, and emphasize Full Year totals. VoiceOver continues to announce full distance units, and year/unit headers stack when needed for larger text.
- Show the cited calendar event title after the suggestion sparkle in trip lists and details, instead of a generated explanation. Calendar-free suggestions show only the proposed classification.
- Let the current-drive panel minimize to a slowly pulsing vehicle icon at the bottom left, with matching dark Liquid Glass. Tap the icon or open the current drive from its Live Activity to restore the controls; Reduce Motion keeps the icon still.
- Give the pull-down summary a lighter cream background in light mode and lighter green in dark mode, with soft shadows cast from its upper and lower edges; the lower shadow uses one quarter of the upper shadow's opacity.
- Show reimbursement, distance with a spelled-out unit, and business trip count as three left-aligned green lines centered in the pull-down area of iPhone and iPad trip lists. The caption follows the native bounce and disappears on release; Need Review, the Trips directory, and macOS are excluded.
- Remove the redundant Total reimbursement disclosure from trip lists.
- Remove pull-to-refresh, the Mac Refresh/Command-R command, and refresh feedback. Local edits and iCloud changes continue to update automatically.
- Refresh all six localized iPhone App Store sets with current trip-detail captures and the Mac app badge.

## 2.8 (113) - 2026-09-15

### Added

- Optional Private Cloud Compute trip suggestions on supported iOS 27, iPadOS 27, and Designed-for-iPad Mac devices. On-device processing remains the default and fallback; the per-device setting includes a data-use explanation and invalidates cached suggestions when changed.
- Ship the held-back iOS 27 visible-trip and current-drive App Entity annotations, system-requested Spotlight rebuilding, and main-app execution target for Last Drive Duration using Xcode 27. Index rebuilding respects the Siri & Search setting and preserves entries when storage is temporarily unavailable.

### Changed

- Include the unreleased refresh feedback, readable Mac forms, and receipt/PDF improvements from builds 111 and 112.
- Update all six App Store locales, in-app privacy disclosures, and Calendar/Contacts permission text for the optional cloud path.
- Keep iOS 26 as the minimum supported version.

## 2.7 (112) - 2026-09-14

### Fixed

- Keep receipt legs together across page breaks, with consistent fonts, dated headings, separate route and distance details, and readable spacing.
- Check rendered PDF text margins, footer clearance, and page numbering before allowing an export.

## 2.7 (111) - 2026-09-13

### Changed

- Make pull-to-refresh and Mac Refresh save pending edits, process received iCloud changes, check account availability, and wait up to ten seconds for active sync operations, with clear delay and error feedback. iCloud transfer scheduling remains automatic.

### Fixed

- Keep the iCloud sync confirmation sheet readable on Mac so its details, Cancel, and Combine and Sync controls remain visible.
- Give purpose, notes, fee, mileage-rate, and support-report dialogs readable Mac sizes without changing phone sheet behavior.

## 2.7 (108) - 2026-09-10

### Fixed

- Restore touch response after unlocking App Lock, including retrying after canceling Face ID or passcode entry, and keep the security window intercepting touches when the app relocks.
- Prevent a crash when opening the macOS save dialog for PDF, CSV, and diagnostics exports by supplying the file's name to the transfer.
- Preserve merged trips' source dates and mileage rates in monthly and annual PDF/CSV exports, while keeping the stored trip merged.
- Apply the same business-purpose eligibility and currency rounding to receipts, report rows, and totals.
- Continue long receipt details and oversized report rows onto additional PDF pages without losing text or repeating charges.

### Changed

- Outline the App Lock unlock button, match its height and alignment to the M seal, and remove the recording caption.
- Use a charcoal notebook with dark stitching, a red seal, and pale Mincho text in dark mode, including the system launch screen. Light mode retains the cream notebook.
- Improve trip text search with punctuation-tolerant names and addresses, quoted phrases, and matching of structured address details on trips and merged legs.
- Match common street abbreviations such as St/Street, Rd/Road, and Ave/Avenue in trip addresses, including quoted phrases, while preserving names and literal matching in notes and purposes.

### Development

- Keep suggestion demo fixtures in isolated UI-test storage and prevent demo seeding from writing to the personal Calendar.

This replaces the pending 2.7 (104) submission and includes all of its changes.

## 2.6 (101) - 2026-09-07

### Fixed

- Correctly preserve the outer start and end points, dates, addresses, and undo state when merging overlapping or nested trips.

- Use the notebook cover for the system launch screen as well as the privacy cover, replacing the old centered Mileager title at startup.
- Prepare cached detail maps before opening a trip so the map is already visible during the slide-in transition. Trips without a cached map still open without waiting for a new map render.

### Changed

- Allow adjacent displayed trips to be merged across dates and classifications, including overlapping captures, with consistent controls across month sections and filtered lists.

- Replaced the plain privacy and app-lock cover with a cream paper logbook, crisp Retina materials, top stitching and a hinge crease, a red M stamp at the bottom left, and small black printed unlock text at the bottom right. Landscape, iPad, and Mac windows use a thinner binding; portrait phones retain camera clearance.
- Moved previous and next trip controls to the bottom toolbar for easier navigation.
- Prepare recent and current-mailbox map thumbnails while the app is open, then prepare detail maps. Warming yields to visible maps and pauses under low-power or thermal constraints; leg maps remain on demand.
- Doubled map cache limits to 160 images / 48 MiB in memory and 400 images / 128 MiB on disk.

## 2.5.3 (93) - 2026-09-06

### Fixed

- Fixed route previews that could stay blank after merging trips. Cancelled or stalled map snapshots now release their rendering slots, and previews retry temporary failures and refresh when the app returns to the foreground.
- Added space around the Lock Screen Live Activity so its text and controls sit clear of the rounded edges, including at larger accessibility text sizes.

## 2.5.2 (91) - 2026-09-05

### Added

- Added native trip search for places, purposes, and notes, with a choice of the current mailbox or All Trips.

### Changed

- Made drive maps quicker to revisit with cached detail previews, limited rendering of nearby maps, and immediate display before cache files are saved.

- Simplified trip rows with larger supporting text, clearer mileage, compact thumbnails in narrow columns, and fewer repeated review labels.
- Made unclassified trips visibly distinct from Not a Drive, labeled mailbox totals as business distance, and replaced generic list status with current counts.
- Restored full-bleed maps above Trip Detail and new-trip fields, with a gradual blur and fade while scrolling. Hid the repeated leg summary on trips without multiple legs or stops.
- Matched Trip Detail's leg rows to the trip list, with rounded thumbnails, compact route names, larger supporting text, and clearer mileage.
- Expanded the full release gate to cover the simulator-supported iPhone functional suite and iPad shell, selection, search, and onboarding regressions.

### Removed

- Removed the repeated “Not Classified” footer below the classification controls.
- Removed the separate map-removal action. Route previews update automatically when endpoints change.

### Fixed

- Prevented the trip undo handler from taking focus away from vehicle details, purposes, search, or notes while a text input is active, including when the software keyboard is hidden.
- Kept the detail map stationary behind scrolling content and matched its expand control to the standard Liquid Glass buttons.
- Fixed a freeze or crash when opening a Drive finished notification. Tapping the notification now opens that drive for review without changing its category.

## 2.5.1 (86) - 2026-09-04

### Fixed

- Fixed Mac trip selection after switching between apps, so ordinary clicks no longer behave as though Command is held.

### Added

- Added a directly visible Select/Done button to the Mac trip list, so ordinary clicks can build a native checkmarked multi-selection without a keyboard while normal browse clicks remain single-selection. The bottom action bar now keeps exactly the same controls and spacing in both modes.

## 2.5 (82) - 2026-09-03

### Fixed

- Replaced the trip list's manual keyboard-modifier tracking with SwiftUI's native list selection, so returning to the Mac window can no longer leave ordinary clicks behaving as though Command were still held.

## 2.5 (81) - 2026-09-02

### Added

- Mileager runs on iPad and on Apple silicon Macs from the same app. Wide screens get a three-column layout: mailboxes, the trip list, and the trip you are reading, all at once.
- Multi-trip selection, in the idiom of the machine it is on. iPhone and iPad get Select mode: check the rows you want, act on them from the bar, tap Done. The Mac gets a real list selection instead — a click selects, the verbs sit permanently in the bottom bar and simply enable and disable, and the reading pane shows what is selected: one trip, or a summary of several with their distance and total reimbursement.
- A menu bar and keyboard shortcuts wherever there is a keyboard, Mac or iPad. ⌘1/⌘2/⌘3 for Need Review, All Trips, and the current month; ⌘N to add a trip; ⌘, for Settings; ⇧⌘B/⇧⌘P/⇧⌘N to classify; ⌘E to export. On the Mac, ⌘A selects all, ⌥⌘A deselects all, and ⌘↑/⌘↓ with or without ⇧ walk the selection.
- Exports on the Mac go through a save panel rather than a share sheet.

### Changed

- Drive capture stays on iPhone and iPad. A Mac has no reason to ask for location, motion, or Bluetooth access it can never use, so it does not: the Mac reviews, reports, and exports the trips your other devices record.
- Mac onboarding can begin as an empty manual library. Mileager creates no placeholder vehicle on a Mac; people add one explicitly in Settings, and existing vehicles remain untouched when iCloud sync is enabled.
- Mac saves now use file-backed system transfers, and diagnostics archives stream directly to disk so large exports do not require a second archive-sized allocation in memory.
- Polished wide-screen use with a pinned Settings footer, roomier Mac editing sheets, and one consistent pressed-canvas treatment for empty panes and zero-result lists.
- App Store assets for the iPad and Mac release include an en-US iPad 13" screenshot set (the same images serve the Mac App Store listing), descriptions in all six locales that say drive capture stays on iPhone and iPad, 2.5 promotional text, and one canonical App Review note.

### Fixed

- Expanded Mac trip selection keeps SwiftUI's selectable List and reading-pane synchronization, with a minimal modifier projection for the Designed-for-iPad host's missing Command-toggle and Shift-range behavior; compact Mac, iPhone, and iPad navigation are unchanged.
- Boat trips are marked Not a Drive again. The water check used to abstain whenever the phone's motion sensors called the trip "automotive", which a powerboat's engine reliably does, so it never fired on a real lake. It now decides from the recorded path and the map alone: a trip over half a mile whose quarter, half, and three-quarter points mostly sit on ocean or inland water is a boat.

### Removed

- The separate native Mac app. The Mac is served by this app instead, which is one product to keep correct rather than two.
- E-ZPass CSV toll import, which only that app could drive. Tolls already imported are untouched: they still render, total, and export.

## 2.4.3 (77) - 2026-08-29

### Fixed

- Prevented unsupported Business suggestions when Calendar access is off or denied, and blocked unrelated all-day, remote, elsewhere, and overflow calendar events from acting as Business evidence.
- Business suggestions now require a calendar event plausibly linked to the drive, explicit trip notes, or a deterministically identified workplace destination. Home and arbitrary personal-contact addresses no longer count as workplaces.

### Changed

- Refreshed all six localized App Store card sets with a clearer trip-detail route view, corrected kilometer-based Live Activity examples, and more legible iPhone framing.

## 2.4.2 (76) - 2026-08-28

### Fixed

- Fixed a freeze that could lock up the app at launch and on every return to the foreground when iCloud sync is enabled: the CloudKit change check walked the device-only capture store's entire Core Data history — over a million rows on a long-running install — on the main thread. The check is now scoped to the synced store, and the capture store's unused history is purged in the background, so already-frozen installs recover on first launch of this build.
- Fixed multi-second hangs at the end of long drives: the in-flight drive checkpoint re-encoded the entire GPS sample array on every fix. Routine per-second fixes now reuse the recent checkpoint and re-encode at most every 15 seconds, while phase changes, stop deadlines, completions, and all user actions still save immediately.
- Fixed a main-thread spin loop when tracking was paused while a park countdown was armed: the stale stop deadline re-armed a zero-delay timer for the rest of the pause window, and the wedged state survived relaunch and reboot. Pausing now clears the deadline, resuming no longer ends the drive at the stale pre-pause deadline, and existing wedged checkpoints are neutralized on first launch of this build.
- A failed trip completion no longer retries on every GPS fix forever: diagnostics tagging can no longer abort an already-saved trip, and remaining failures retry at most every 30 seconds while preserving the drive and everything entered about it.

### Added

- Optional Lock Screen "Drive finished" notification with Business, Personal, and Not a Drive actions, so a freshly captured drive can be classified without unlocking the phone. Off by default; enable it with the Classify Drives from Lock Screen switch in Settings.

## 2.4.1 (74) - 2026-08-21

### Changed

- Removed price and subscription language from all six localized App Store subtitles, descriptions, and screenshot sets after the Guideline 2.3.7 review.
- Replaced the price-led first screenshot with the `Open` card across all six App Store locales.
- Set the en-US App Store listing name to `Mileager Tracker` without changing the installed app name.

## 2.4.1 (71) - 2026-08-18

### Changed

- Replaced the bottom Add Trip and trip-detail save button with the app's standard top-right confirmation checkmark.
- Kept adjacent-trip merge controls beneath the live-drive Liquid Glass bar when list content scrolls behind it.

## 2.4.1 (70) - 2026-08-18

### Changed

- Moved Add Trip and trip-save actions into a standard always-visible bottom button, outside the rounded list container that distorted their corners.

## 2.4.1 (69) - 2026-08-17

### Changed

- Renamed the iPhone review queue to Need Review, always showed its outstanding count, and removed classification filters that cannot meaningfully narrow that queue.
- Opened Need Review automatically only when unresolved trips are waiting; resolved-only and empty histories now open on the Trips overview.
- Simplified the Trips directory to Full Year and month-only labels, with claimable Business mileage shown consistently at the right of every period row.
- Made the bottom Add Trip and Save buttons use matching top and bottom corner curves.
- Removed the detailed diagnostics-retention paragraph from Settings while preserving the short operational sample window required for transit detection and missed-drive recovery.

## 2.4.1 (67) - 2026-08-17

### Changed

- Refreshed all six localized App Store screenshot sets with a clearer five-card story built around Mileager being not-for-profit, private, automatic, report-ready, and made by a working photographer.

### Release scope

- The app behavior and interface are unchanged from the approved 2.4 build 65; this build updates the public App Store presentation.

## 2.4 (60) - 2026-08-15

### Added

- Added conservative water-route detection that can mark untouched automatic ferry-like captures as Not a Drive only when motion, recorded path, and structured MapKit water evidence agree.
- Added the native Mileager for Mac companion with a keyboard-friendly month-and-year ledger, trip inspector, bulk editing, missed-trip entry, route and address editing, toll reconciliation, settings, and optional on-device suggestions.
- Added monthly and annual report preview, PDF/CSV export, and printing from the Mac sidebar, backed by effective-dated mileage rates.
- Added a Mail-style trip list as the Mac's default collection view, with month sections, classification and provenance in each row, and the previous table preserved as View → Use Column Layout.
- Added a classification filter (All Trips, Business, Personal, Not a Drive) to the Mac toolbar and View menu, plus ⌘1/⌘2/⌘3 jumps to Needs Review, All Trips, and the current month.

### Changed

- Simplified iPhone trip summary rails so routine Business, Personal, Not a Drive, purpose, and export-state labels stay represented by the leading icon; only user notes and actionable review blockers appear above the bottom-right mileage.
- Tightened iPhone Settings and report copy: the Lock Screen control is more concise, car-audio Shortcuts behavior is clearer, suggestion privacy guidance now sits beside its source controls, and the report estimate disclaimer is easier to scan.
- Rebuilt iPhone Trip Detail around a map-backed summary, compact classification and purpose controls, clearer trip, fee, leg, and detail sections, and a Save & Next Trip review flow.
- Aligned the iPhone trip row and Trip Detail header around the same three-line route, purpose, review-state, time, and mileage hierarchy, with a stable mileage rail as classification changes.
- Split AppCore into compiler-enforced model, capture, persistence, reporting, enrichment, and suggestion layers while keeping the existing app-facing umbrella API.
- Shared CloudKit history monitoring and trip-suggestion orchestration between iPhone and Mac, and reduced the Live Activity widget to leaf model dependencies.
- Kept report generation transient and current-data-driven by removing the dormant canonical-snapshot persistence path.
- Removed the unused CLMonitor parked-wake implementation while retaining the production classic region-monitoring path.
- Redesigned monthly and annual PDFs as a clear Mileager statement with report coverage, vehicle rollups, separate parking and toll totals, and a quieter route-and-purpose ledger.
- Refined Mac review with stable inspector saving, exact undo, anchored endpoint autocomplete, consistent classification styling, year scope, and faster keyboard workflows.
- Re-rooted the Mac window on the iPhone's mail metaphor: the sidebar is now a mailbox tree (Needs Review, All Trips, then years disclosing months with outstanding-review badges that fall silent at zero), new windows open in Needs Review, and the trip inspector behaves like Mail's reading pane — visible with a placeholder and persistent across mailbox changes.
- Renamed the Mac's bulk toolbar menu from "Review Selection" to "Edit Selection" so "Review" names exactly one thing, and renamed the "Trips" scope to "All Trips" to match iPhone.
- Rebuilt the App Store screenshot set around free and private as the two leading claims, rendered from HTML by `app-store-assets/screenshots/cards-v2/` instead of composited in Pillow, with card 04 photographing real per-drive, monthly, and annual reports generated by the shipping report generator.

### Fixed

- Corrected the Caught Up empty-state lettering in dark mode and removed a month-row subtitle that mixed review counts with all-trip totals.
- Kept trip suggestions restartable when evidence changes during inference, when the app backgrounds, and after the feature is disabled and re-enabled.
- Updated the location-permission checklist immediately and prevented the App Lock privacy cover from flashing behind app-initiated system permission prompts.
- Prevented turning off Bluetooth hints from synthesizing a vehicle disconnect that capture could treat as parking evidence.

## 2.3 (58) - 2026-08-03

### Added

- Added reusable toll and parking presets in Settings with one-tap application from Trip Detail.

### Changed

- Redesigned monthly and annual reports with clearer summaries, report coverage, vehicle rollups, odometer readings, and the active mileage rate in the header.
- Matched per-trip receipts to the report design and improved long-note pagination.
- Simplified the Add Fee sheet and renamed the active-drive Shortcuts action to “Open Mileager and Start Drive.”

### Fixed

- Improved drive capture, report generation, reset, and launch reliability.

## 2.2 (57) - 2026-08-03

### Added

- Rebuilt the iPhone Trips experience around a Mail-style index with Needs Review, monthly mailboxes, and All Trips.
- Added a one-tap adjacent-capture merge affordance while retaining multi-select merge and permanent deletion.
- Added a Last Drive Duration action for Siri and Shortcuts that reports how long the most recent completed drive lasted.

### Changed

- Kept overlapping drives as separate user records. Mileager no longer suppresses, flags, or deletes distinct trip IDs because their time windows overlap; the user reviews the records and permanently deletes any extra trip.
- Removed the retired Exclude and Archive disposition. Legacy archived rows are permanently cleaned up after launch and foreign iCloud imports.
- Moved monthly and annual PDF/CSV exports into Trips and its monthly mailboxes.
- Simplified drive-list derivation, filters, selection cleanup, menu ordering, month summaries, and first-launch navigation.
- Completed the German, Spanish, and French localization coverage required by the redesigned iPhone interface.
- Prepared localized 2.2 release notes and advanced the iPhone candidate to build 57.

### Fixed

- Recovered high-evidence speed-only drives without a Bluetooth trigger into Needs Review while rejecting pedestrian and cycling conflicts.
- Kept Trip Detail on the current drive when saving edits fails instead of navigating away and losing the draft.
- Made Add Return Trip and Un-Merge save pending edits first, remain on screen after a save or mutation failure, and stay unavailable while the draft is invalid.
- Blocked trip and sample-data writes while iPhone protected data is unavailable, then resumed queued navigation only after the real trip store loaded.
- Drained iCloud history after protected-data recovery and added bounded automatic retries when foreign-record maintenance fails.
- Localized trip-validation, vehicle, report, and export errors in German, Spanish, and French.
- Deferred Live Activity fee and vehicle requests until the current sheet, alert, or full-screen presentation has dismissed.
- Reset a hidden vehicle filter when returning to Mailboxes so root totals and exports cannot remain silently narrowed.
- Prevented persistent test-fixture launch arguments from seeding data outside UI-test mode.
- Restored a system-sized hit target and release coverage for adjacent merge, permanent deletion, empty-install navigation, and redesigned localization.

## 2.1 (48) - 2026-07-21

### Added

- Added Car Connections management on iPhone so saved CarPlay and Bluetooth matches can be reviewed, moved between vehicles, removed, ignored, or restored.
- Added durable automatic-trip enrichment retries. Missing automatic-trip endpoint labels can recover after temporary network or Maps failures; route retries apply only to trips explicitly created for the new workflow, leaving historical routes and mileage unchanged.
- Added a grounded Current Drive App Entity and most-recent-trip classification for Siri and Shortcuts. The active-drive editing and fee actions introduced in 2.0.2 now resolve the exact live drive more reliably.
- Added Automatic to the Live Drive vehicle picker so a manual choice can return to Mileager's normal attribution policy.

### Changed

- Hardened automatic capture across background wake-ups, relaunches, brief stops, transit-like movement, checkpoint recovery, and changing vehicle connections.
- Redesigned the existing Live Drive controls for clearer distance and elapsed-time scanning and easier access to the already-shipped purpose, notes, fee, and New Leg actions.
- Rebuilt monthly and annual CSV exports as a stable flat trip ledger with explicit dates, time zone, vehicle, entry method, original and reported distance, reimbursement values, legs, and stops.
- Regenerated explicitly shared reports from current trip records instead of reusing an older period export.
- Unified review readiness across iPhone, Mac, Spotlight, and reports, including the requirement that Business trips have a purpose before export.
- Hardened CloudKit history processing, same-record and preference reconciliation, protected-data recovery, sync enablement, and cross-device preference updates without syncing raw capture samples.
- Improved Trips-list hierarchy in dark mode and refined the current-drive Liquid Glass presentation.

### Fixed

- Improved Siri recognition of “Mileager,” current-drive references, and phrases such as “last drive” or “most recent trip.”
- Prevented delayed address or route enrichment from overwriting changed coordinates, labels, routes, distances, classifications, or manual edits.
- Prevented unrelated iCloud changes from generating false vehicle disconnects or prematurely ending an active drive.
- Kept uncertain or fallback vehicle identities visible for confirmation instead of silently assigning the wrong vehicle.
- Preserved manual distance overrides in trip presentation and isolated Bluetooth callbacks from unsafe cross-thread delivery.

## 2.0.2 (42) - 2026-07-09

### Added

- Added Siri and Shortcuts intents for active drives so voice commands can add tolls or parking, classify the current drive, set a business purpose, and append dictated notes before the trip finishes.
- Added a completed-trip fee intent so Shortcuts can add tolls or parking to an existing trip.

### Changed

- Refreshed the App Shortcuts and localized shortcut metadata for the new iOS 27 voice-command surface.

## 2.0.1 (40) - 2026-07-07

### Added

- Added on-device AI classification suggestions in the To Review list: unclassified trips show a suggested Business/Personal call with a purpose and a one-line "why", accepted with one tap. Suggestions are generated with Apple Intelligence on the device, are advisory only, and never apply automatically; devices without Apple Intelligence see no change.
- Added an optional calendar-evidence source for suggestions (off by default; requires granting calendar access) that lets the on-device model check event titles in the trip window.
- Added an AI Suggestions section in Settings with toggles for the feature and calendar evidence.
- Added contact-address evidence for suggestions: trip endpoints are matched to contacts' postal addresses on-device, and a "My Card" pick identifies your home and work so commutes and home-anchored trips are judged sensibly.

## 1.0.9 (28) - 2026-07-02

### Added

- Added a New Leg action to the active-drive bar so a driver can save the drive so far and continue recording as a new trip.
- Added Odometer History in Settings, including deletion for mistaken readings and a warning when a new reading is lower than the last saved reading.
- Added sparse odometer interpolation to monthly CSV/PDF reports so reports can show estimated vehicle miles and business-use percentage from occasional readings.
- Added Add Return Trip in trip detail, reversing endpoints and route geometry for the return drive.
- Added full-screen route map expansion from trip detail.

### Changed

- Refined the active-drive bar for at-a-glance mounted-phone use with larger distance, elapsed time, and labeled actions.
- Compacted report addresses and rounded mileage reimbursement line items so exported totals foot to cents.

## 1.0.8 (24) - 2026-06-30

### Added

- Added a Business Drive sheet from the current-drive bar so active business trips can get a purpose and note before the drive finishes.
- Persisted current-drive notes through active capture so they are written onto the completed trip.

### Changed

- Kept Bluetooth, CarPlay, and charger-triggered drive candidates alive while the car is idling before the first real movement sample.
- Measured assisted-start confirmation from first real movement instead of the trigger time so parked delay does not cause instant confirmation later.
- Released the location service session while parked idle, keeping high-fidelity location active only during capture, idle-wake grace, and short permission leases.

### Fixed

- Journaled missing or unreadable active-drive checkpoints during wake bootstrap so device diagnostics can distinguish "no row" from decode failures.

## 1.0.7 (21) - 2026-06-30

### Added

- Added a one-line current-drive Liquid Glass bar with quick Business, Personal, Toll, and Parking actions while automatic capture is active.
- Added shared deep-link parsing for current-drive and fee-entry routes used by the app, Live Activity, and widget actions.
- Added UI coverage for the current-drive bar and refreshed the App Store screenshot set for the current UI.

### Changed

- Replaced the older current-drive sheet and status pill with the compact glass bar so the trip list remains visible during active capture.
- Updated Live Activity controls so toll and parking actions deep-link directly into the matching fee sheet.

## 1.0.6 (20) - 2026-06-29

### Added

- Added current-drive status surfaces so active automatic capture progress is visible in the app.
- Added the Mileager Live Activity/widget extension and shared ActivityKit state for in-progress drives.
- Added `mileager://` App Intent handoff wiring for Shortcut-triggered drive starts.

### Changed

- Persisted current-drive summaries alongside capture state so app UI, widgets, and relaunches can stay aligned.
- Refined active-drive review/editing surfaces around live capture context.
- Updated current-drive and performance documentation for the release candidate.

## 1.0.5 (19) - 2026-06-28

### Changed

- Preserved very short automatic captures while automatically marking trips under 0.2 mi as Not a Drive.
- Added route-fill corridor diagnostics and downgraded suspicious inflated/off-corridor routes to raw GPS distance.

### Fixed

- Recovered parked-start anchoring when a signal-only candidate starts before the first usable GPS sample.
- Cleared stale pending trip IDs after completion and repaired old idle checkpoints on load.
- Coalesced duplicate same-second candidate starts so repeated wake signals do not mint extra trip IDs.

## 1.0.4 (18) - 2026-06-27

### Changed

- Strengthened background wake coverage so locked parked devices keep both parked-anchor and significant-location/visit fallback wake paths available.
- Refined tracking setup and health guidance around Location Always, Precise Location, Motion & Fitness, Background App Refresh, and Bluetooth/CarPlay/charger shortcuts.
- Hardened persistent trip-capture state, duplicate cleanup, SQLite indexes, and protected-data relaunch handling.

### Fixed

- Protected quick traffic stops and short resumptions from being prematurely split into separate trips.
- Preserved visible trip data during ordinary locked launches by opening the protected store directly when it is readable instead of showing a placeholder first.
- Added regression coverage for late parked-start route backfill so SLC-delayed wakeups can still recover the parked-origin distance.

## 1.0.4 (12) - 2026-06-22

### Added

- Added context-specific error alerts for loading, saving, importing, exporting, settings, and sample-data failures.
- Added clearer Shortcuts automation setup controls and a Settings footer with the installed app version.

### Changed

- Refined trip review, reports, settings, onboarding, and export wording for the public App Store candidate.
- Reduced background wake monitoring after idle anchoring so parked-region monitoring remains the primary wake source when live capture is not active.
- Bumped the build metadata to `1.0.4 (12)` for the App Store replacement candidate.

### Fixed

- Cleared idle high-fidelity capture after rejected probes so the GPS indicator does not linger after a no-driving wake.
- Preserved the fresh-install automatic-tracking default after Reset App clears local data.

## 1.0.3 (11) - 2026-06-21

### Added

- Added App Store website icon assets and live website URL metadata for the free public launch.

### Changed

- Switched App Store release copy to the free/no-IAP launch model.
- Simplified the Mileager app icon route mark for the current App Store asset set.
- Bumped the build metadata to `1.0.3 (11)` for the App Store submission candidate.
- Scoped the App Store submission build to iPhone only.

### Fixed

- Expanded E-ZPass CSV timestamp parsing for downloaded E-ZPass NY rows that include seconds and four-digit years.
- Fixed Reset App so local data is still cleared when iCloud Sync is off or iCloud cleanup cannot run.
- Turned automatic tracking on by default after onboarding once location and motion health checks are ready, while preserving an explicit Stop choice.

## 1.0.2 (9) - 2026-06-18

### Added

- Added parked-anchor beacon persistence and background wake coverage for locked-device drive-start testing.
- Added ADR notes and regression coverage for parked-anchor, significant-location-change/visit wake, route labels, and endpoint address components.

### Changed

- Refined automatic drive-capture policy/runtime handling for idle, low-signal, and wake-driven candidates.
- Preserved structured endpoint address components for trip storage and route-card labels.
- Refreshed App Store screenshot fixtures for the current Trips, trip detail, reports, and settings screens.
- Bumped the build metadata to `1.0.2 (9)` for the installed iPhone builds.

### Fixed

- Assigning a purpose from the Purpose quick-entry sheet now also classifies the drive as Business and marks it ready to export, instead of leaving it in "To Review"; clearing the purpose leaves the existing classification untouched.

## 1.0 (6) - 2026-06-11

### Added

- Optional App Lock (Face ID / Touch ID / passcode) under Settings → Security that gates the app's UI while leaving automatic trip capture running in the background.
- Privacy screen that covers app content in the app switcher and behind the unlock prompt, unified with the launch screen into one branded surface.

### Changed

- Pinned both Core Data stores to an explicit `completeUntilFirstUserAuthentication` data-protection class and raised exported reports and diagnostics archives to complete file protection.
- Renamed "Forget Learned Bluetooth" to "Reset Learned Bluetooth" and moved it into the Support section; removed the tracking-section Bluetooth-learning subtext.

### Fixed

- Prevented a background crash when iOS relaunches the app for a location event before the device's first unlock; the app now falls back to an in-memory store and reloads the on-disk store once the device is unlocked.

## 1.0 (5) - 2026-06-09

### Changed

- Deferred movement-only drive candidates without trusted vehicle evidence to diagnostics instead of showing them as visible trips.
- Preserved diagnostic-only drive candidates and journal evidence for missed-drive review without auto-completing them as trips.
- Distinguished true location background launches from other background launches before starting capture.
- Bumped the build metadata to `1.0 (5)` for the installed iPhone build.

### Fixed

- Restored full-height review-card map thumbnails when drive cards grow taller than their minimum height.
- Made vehicle-start Shortcut triggers run silently without returning a visible App Intent dialog.

## 1.0 (4) - 2026-06-07

### Changed

- Focused the app surface around mileage capture, review, fees, reports, diagnostics, Shortcuts starts, and iCloud sync by removing unsupported backup, saved-place, hidden classification/status, stale tracking-mode, and backend-only trip-operation residue.
- Centralized miles/meters conversion, numeric text parsing, route lookup presentation, monthly report export preparation, sync configuration resolution, and adjacent-trip merge eligibility.
- Removed the Settings fee-preset management screen while keeping per-trip toll and parking fee entry.
- Rebuilt automatic drive capture around persisted runtime state, explicit start policy, and background relaunch recovery so tracking decisions survive app lifecycle changes.
- Added Bluetooth, CarPlay, and charger App Intent signals to help seed drive-start detection without treating weak signals as sufficient trip proof.
- Added diagnostic drive analysis, event persistence, pending start-signal storage, and expanded export evidence for missed-drive forensics.
- Added Bluetooth vehicle-name matching, trusted vehicle hint tests, and the required Bluetooth usage description.
- Expanded focused drive-capture, diagnostic, launch, settings, and UI test coverage.
- Added the GitHub `Validate` workflow and pinned it to `macos-26` so CI runs with Swift tools compatible with the app package.
- Bumped the build metadata to `1.0 (4)` for the installed iPhone build.

### Fixed

- Prevented cold foreground/relaunch churn from restarting no-anchor GPS priming after the one allowed startup window has already been exhausted.
- Suppressed post-parking speed-only restart candidates near a just-ended trip unless there is trusted vehicle or automotive evidence.
- Preserved parked idle anchors and pending completion checkpoints across capture state reloads.
