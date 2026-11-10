# Mileager Privacy Policy

Effective date: September 15, 2026

Mileager is designed as a local-first mileage log. The app does not use third-party analytics, third-party advertising SDKs, or an app-hosted server.

Mileager runs on iPhone and iPad, and as a Designed-for-iPad app on Apple-silicon Macs. Automatic drive capture is available only on iPhone and iPad. On Mac, Mileager reviews and edits trips, creates reports and exports, and accesses data you choose to sync through your private iCloud account; it does not request location, motion, or Bluetooth access for drive capture.

## Data Processed by the App

Mileager processes information you enter or generate while using the app:

- Trip dates, times, distances, classifications, business purposes, notes, tolls, parking, and odometer checkpoints.
- Location data recorded during automatic tracking on iPhone or iPad.
- Route endpoints you enter for map-based manual trips on any supported device, including Mac.
- Motion activity signals used on iPhone or iPad to distinguish driving from walking or stationary movement.
- Optional connected vehicle Bluetooth hints on iPhone or iPad when you enable Bluetooth-assisted detection.
- Optional Calendar event titles, times, and locations near a trip when you enable Calendar evidence for Apple Intelligence suggestions.
- Optional Contacts names and postal addresses, including the home or work addresses from a contact card you select, when you enable Contacts evidence for Apple Intelligence suggestions.
- An optional on-device search index containing trip routes, addresses, dates, and distances when you enable Show Trips in Siri & Search.
- Report snapshots, PDF/CSV exports, and diagnostics exports that you choose to create or share.
- App-only settings such as automatic tracking, iCloud sync, mileage rate, learned Bluetooth, and App Lock preferences.

## How the Data Is Used

The app uses this data to detect trips, help you review trips, generate mileage reports, export records, sync your own data across your devices through iCloud when you turn sync on, and diagnose tracking problems at your request. On supported devices, Apple Intelligence processes optional Calendar and Contacts evidence on the device by default to suggest a trip classification or business purpose. Mileager does not send this evidence to the developer or an app-hosted server.

When you enable Show Trips in Siri & Search, iOS can use the on-device trip index to find a trip or answer a request such as the duration of your last completed drive. Search results can expose trip details even while App Lock is enabled. Turning the setting off removes the index.

Mileager does not sell personal data, track you across other companies' apps or websites, or use your data for advertising.

If you turn on App Lock, Mileager uses the device's built-in authentication system, such as Face ID, Touch ID, or device passcode, to unlock the app. Mileager does not receive or store your biometric data.

## Optional Private Cloud Compute

Starting with Mileager 2.8 on iOS 27, iPadOS 27, and macOS 27, you can enable Use Private Cloud Compute in Suggestion Sources on each supported device. This setting is off by default and is not enabled by iCloud sync. When enabled, trip details, notes, purpose presets, and any enabled calendar or contact evidence may be sent to Apple’s Private Cloud Compute to create suggestions. Apple does not store this data. If unavailable, Mileager uses the on-device model. Suggestions are never applied automatically. Turning the setting off stops new cloud requests and clears cached suggestions; it cannot recall a request already sent. Mileager does not send this evidence to the developer or an app-hosted server.

## Storage and Sync

Trip summaries, preferences, odometer checkpoints, and report snapshots are stored on your device. If you turn on iCloud sync, this durable data is mirrored to your private CloudKit database so it can sync across your Apple devices signed in to the same Apple Account.

Raw GPS samples attached to completed trips are stored locally only and retained for the app's configured trip-sample window, currently 30 days. Diagnostic location samples, including samples that are not attached to a completed trip, are stored locally only for 30 days.

Recent diagnostics events and diagnostic location samples are stored locally for up to 30 days. They are exported only when you choose Report Issue or another diagnostics export action.

## Apple Services

Mileager uses Apple services such as iCloud/CloudKit, MapKit, geocoding, routing, Core Location, Core Motion, Core Bluetooth, Calendar, Contacts, Apple Intelligence/Foundation Models, Siri/App Intents, Spotlight/Core Spotlight, Local Authentication, and audio route detection. Data handled by those Apple services is governed by Apple's applicable terms and privacy policies.

## Sharing

Mileager shares data only when you initiate it, such as exporting a PDF, CSV, or diagnostics file through the system share sheet or Mac save panel, or asking Siri or Shortcuts to return information from the app. The destination or Apple service you choose may have its own privacy practices.

## Deletion and Control

You can delete trips in the app. Reset App deletes local data and attempts to remove Mileager data from iCloud. On iPhone and iPad, you can revoke Location, Motion & Fitness, Calendar, Contacts, and Background App Refresh permissions in system Settings. You can disable Apple Intelligence suggestion sources or Show Trips in Siri & Search in Mileager Settings.

Automatic tracking on iPhone and iPad requires location and motion permissions, but manual trip entry, review, and report export remain available without granting background location permission. Automatic tracking is not available on Mac.

## Contact

For privacy questions, contact David Degner through the support information listed on the App Store product page for Mileager or by email at David@DavidDegner.com.
