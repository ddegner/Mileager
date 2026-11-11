# Mileager

Local-first, security focused mileage tracker app for US solo small-business use: automatic capture on
iPhone and iPad, with review, reporting, and export on Apple-silicon Macs.

See [About Mileager](ABOUT.md), [Support](SUPPORT.md), and the
[Privacy Policy](PRIVACY_POLICY.md) for information about the app.

## Current Implementation

- SwiftUI iOS app generated with XcodeGen.
- Testable `AppCore` Swift package.
- Core Data persistence with separate configurations:
  - Cloud-backed durable trip summaries, review decisions, preferences, and odometer checkpoints.
  - Local-only dense raw GPS samples for short-term diagnostics.
- Private CloudKit wiring through `NSPersistentCloudKitContainer` and encrypted CloudKit attributes for sensitive fields.
- Replayable trip-detection engine with synthetic location/motion fixtures.
- Background location service, Core Motion hints, optional learned Bluetooth hints, pause/resume controls, and tracking-health reporting. Start Trips With offers Motion, Bluetooth, and Both (the default). Bluetooth uses a Bluetooth or CarPlay connection automation in Shortcuts.
- Mail-style Trips index with Need Review, monthly mailboxes, All Trips, Business-mile totals, swipe classification, bulk review, manual missed-trip creation, consecutive-segment merge/unmerge, return-trip duplication, and route maps.
- Local trip search by place, purpose, and notes, within a mailbox or across All Trips. Words can match different fields; double quotes keep a phrase together (for example, `"north market" portrait`). Search ignores case, accents, and punctuation differences in names, and includes structured addresses and intermediate places in merged trips. Common English street suffixes match their abbreviations in addresses, including quoted phrases (`"Main Street"` finds `Main St.`); notes and purposes retain literal word matching. Cached route previews and inline location search are available while editing.
- Settings-based odometer checkpoints, mileage-rate and fee presets, and diagnostics export.
- Fresh monthly and annual CSV/PDF exports from the Trips index and monthly mailboxes, plus single-trip PDFs.
- QuickBooks mileage CSV exports for monthly and annual business trips. See [QuickBooks import instructions and format research](docs/quickbooks-mileage-export.md).

## Build and Test

Use a Mac with Xcode and an installed iOS 26 or newer iPhone Simulator
runtime, Python 3, and XcodeGen 2.46.0. This snapshot was verified with
Xcode 27.2. Run the fast validation from the repository root.

```sh
scripts/validate.sh
```

The default (fast) tier regenerates the Xcode project, runs the AppCore package tests, runs the app-hosted unit tests on the newest available iPhone simulator, and finishes with an unsigned simulator build and a localization check. `scripts/validate.sh --full` is the release tier: it adds the clean iOS package build, all simulator-supported iPhone functional UI tests, and iPad split-shell, Mac selection, search, and onboarding tests. This includes notifications, manual editing, search, reports, settings, localization, and accessibility. Screenshot capture and hardware-dependent Siri/intent tests run separately; the actual Mac host still needs the checks in [Manual Mac verification](docs/mac-manual-verification.md). Derived data and result bundles are written outside tracked source by default. UI phases allow up to 90 minutes each; override this with `MILEAGE_XCODEBUILD_UI_TEST_TIMEOUT`.

See the [changelog](CHANGELOG.md) for version history.

Simulator validation uses an unsigned build. For device builds,
configure your own signing team, bundle identifiers, and
matching iCloud entitlements before using a development device. The
deterministic device self-test installs the Debug app and uses an isolated
test store.

```sh
scripts/device-self-test.sh
```

The device self-test uses the bundle identifier set by `MILEAGE_BUNDLE_ID`
when provided. Run `scripts/device-self-test.sh --help` for options.

## Notes

- Real background trip capture must be validated on a physical iPhone with Always Location, Precise Location, Motion & Fitness, and Background App Refresh enabled.
- The device self-test is deterministic replay only. It does not prove Always Location wakeups, Background App Refresh behavior, or real-road capture without a manual field check.
- Both is the default and combines passive movement detection with Bluetooth or CarPlay automation triggers; it can use movement detection before an automation is configured. Existing saved mode selections are preserved. Motion does not require Bluetooth. The Bluetooth option requires a Bluetooth or CarPlay connection automation configured in Shortcuts; selecting the mode does not create that automation. Settings shows a green check and a last-received date after Mileager accepts a Bluetooth or CarPlay shortcut action. Manual tests count; this records past delivery, not whether the automation remains enabled. Driving movement is still required before recording, and existing parking logic handles trip ends. Automation delivery and real-road capture still need physical-device validation.
- The app avoids tax-advice claims and exports IRS-style mileage log fields for user review.
- Bundle and CloudKit container identifiers are configured in `project.yml`; regenerate the Xcode project with XcodeGen before release builds.

IRS business rate updates: [behavior, architecture, and verification](docs/irs-mileage-rates.md).

## License

Mileager is open source under the [MIT License](LICENSE.md). You can use,
modify, redistribute, and sell the software for commercial or private purposes
while retaining its copyright and license notices. Third-party data and Apple
content retain the terms described in [Third-Party Notices](THIRD_PARTY_NOTICES.md).

Bug reports and pull requests are welcome.
