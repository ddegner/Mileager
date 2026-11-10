# IRS business mileage rates

New USD users start with IRS business rates in Settings → Mileage Rates. The
app bundles the verified 76-cent business rate for July 1–December 31, 2026, so
the starting choice and amount work offline. Existing saved custom choices
remain Custom. New non-USD users start with an unset Custom rate
(`requiresCustomRate`); Settings shows Set Rate and a blank amount editor
instead of presenting a US rate in another currency.

## Settings and custom rates

Mileage Rates uses a native SwiftUI Form. USD users see IRS business rate and
Custom source choices, with Updates automatically beneath the selected IRS
option. A native progress indicator appears beside IRS while checking.
The current rate is shown without an unnecessary trailing zero.
Rate History and Update Details are collapsed disclosure groups. Automatic
Rate History is read-only. Update Details contains Last Checked, an accessible
refresh action, and the IRS website link with a native external-link arrow.
Until a live check succeeds, Last Checked says Not Yet Checked. Automatic mode
has no Effective From or Rates Apply From summary rows or explanatory footers;
effective dates remain in Rate History.

Choosing Custom opens the native editor directly. Opening it does not stop
following IRS or change a saved rate; Cancel leaves those settings intact. Save
validates and commits the amount, currency, mile/kilometer unit, and effective
date together. An ordinary new rate starts today. First-time custom setup
configures the fallback amount for all existing drives; its fixed date label
shows the first recorded drive, or today when there are no drives. Historical
edits reject a rule changed by sync while the editor was open.
Changing currency keeps the existing numeric rates and fees rather than
performing a currency conversion, and the editor explains this when currency
changes. Custom history remains editable, with Add Rate and deletion actions.

Saving a custom rate stops automatic following and removes inherited IRS
changes beginning on or after its effective date. Earlier rate history and
explicitly scheduled future custom rates remain. Replaced or removed IRS rules
receive the existing identity/version/deletion handling so preference sync
cannot restore the inherited future rates over the user's choice.

Choosing IRS from Custom checks and applies verified history in one step.
History begins with the official period covering the first recorded drive;
with no drives, it begins with the current period. Explicit adoption replaces
the complete custom schedule, including future entries, and recalculates trip
values. Files already exported remain unchanged. Failed verification keeps
Custom selected and saved rates intact. The refresh action retries the chosen
source; opening the Custom editor cancels a pending initial IRS selection.

## Checks and application

Checks run quietly after foreground startup or activation, once per Gregorian
calendar day during December 29–January 14 and June 28–July 14, and once per
seven days otherwise. Check Now and initial setup bypass this cadence. There
are no rate notifications, scheduled background tasks, or app-operated server.
Interrupted checks retry on activation, including after a process restart.

The client fetches the official IRS standard-mileage page with HTTP validators
and deterministically extracts its business-rate table. It requires the known
Period / Business use column structure and a cents-per-mile table heading.
The cleaner preserves row and column boundaries, excludes navigation/scripts,
and retains exact period and rate evidence. Only recognized annual or dated
period syntax is accepted. Independent validation rejects missing required
periods, mismatched business amounts, invalid dates, overlapping periods, and
conflicting headline/table evidence, including annual headlines. Unsupported
layouts fail closed. Website text supplies data, never executable instructions.
This path works on iOS 26 and needs no PCC, language-model generation, Apple
Intelligence availability, or model entitlement.

The effective-dated schedule records IRS provenance and the date from which
the user follows IRS rates. Catch-up includes every required period from that
date, while announced future rates activate on their official dates. An older
drive imported later triggers backfill even before the ordinary check cadence
is due. A history change during a check invalidates that response and allows a
retry. IRS quotes remain USD per mile and are converted for kilometer
presentation. Explicit adoption removes custom amounts and stores deletion
markers so preference sync cannot resurrect replaced rules. Later imported
or synced manual rules that overlap IRS periods require review.

Rate History begins with the rule already active on the first drive, followed
by later and future rules. A Custom user with a saved amount but no dated rule
covering that drive sees the existing amount on that first-drive date. IRS
adoption replaces this fallback row with verified IRS entries; the internal
fallback also becomes the first verified IRS amount. An unset Custom rate has
no current amount or history until the user saves one.

Source selection and rate history use the existing CloudKit preference merge.
Automatic first-run defaults have lower priority than saved source choices and
are discarded when a real saved schedule arrives through sync; seeded rules
cannot override a restored custom schedule. Older populated stores with no
saved rate retain their previous implicit custom amount. Per-device HTTP
cache, attempt/result timestamps, and interruption state are local. Async
commits reread persisted schedules and reject stale settings. Initial source
selection is owned by the shared model operation, so verification can finish
after leaving Settings. Explicit Custom saves, manual edits, currency changes,
and background cancellation invalidate pending work. Queued UI work rechecks
local intent before starting, and model entry rejects background work.
Changing away from USD stops following without converting numeric rates.

## Exports and failures

Monthly, annual, and single-trip PDF exports join the shared due check before
capturing the schedule, including a pending initial IRS source selection. One
15-second deadline bounds the complete operation. Timeout, offline fetching,
unsupported source layout, or conflicting evidence leaves saved rates intact.
Exports continue with saved rates and identify an unverified check or pending
review in the app's export presentation. With an unset Custom rate, the app
instead explains that the export uses a zero mileage value. These notices are
not added to shared file contents.

Validated cached or synced schedules remain usable when the source cannot be
verified. Failed checks and cancellation retain the previously validated cache
and HTTP validators. The Custom editor and official IRS link remain available.

## Current validation — October 4, 2026

- Focused deterministic client suite: 23 tests passed, zero failures. This covers
  official-table fixtures, business columns and units, exact dates, annual and
  partial-year conflicts, complete period extraction, cached coverage changes,
  conditional HTTP requests, invalid disk cache, and cancellation.
- Required fast validation passed: 738 package tests (2 skipped), 695 hosted
  app tests, unsigned iPhone build, project/static checks, and EN/DE/ES/FR
  localization verification with zero orphaned catalog keys.
- Live iPhone 26.5 and 27 simulator checks: 22/22 checks passed on each using
  the actual IRS HTTP client, including historical backfill, dated PDF/CSV
  totals, and kilometer display invariance. iPhone 27 relaunch persistence:
  14/14 checks passed.
- Native settings UI: 13 distinct iPhone flows passed across iOS 26.5 and 27,
  with 3 iPad 27 flows passed. Initial accessibility-identifier, offscreen-wait,
  and frame-assertion harness issues were corrected and affected flows rerun.
  Automatic settings, expanded history, and custom EUR/km editing were
  visually inspected on iPhone and iPad, including the editor with keyboard.
- Current signed-device installation and CloudKit round-trip verification:
  not performed for this change.

## Test fixtures

Deterministic UI fixtures are DEBUG-only and require `--uitesting` plus
`--irs-rate-fixture=setup|following|conflict|failure|failureSetup|delayedSetup`. They use a fixed October
2026 clock and a synthetic January 2027 future rate. Normal launches and
Release builds cannot activate them. The optional DEBUG live self-test also
requires `--uitesting`, `--irs-live-self-test`, and a nonempty
`--test-store-suffix`; this disables CloudKit and isolates stores/preferences.
Never pass reset or synthetic fixture arguments to a normal personal launch.

## Historical verification — earlier PCC implementation

The following evidence records the earlier implementation and deployment. It
does not verify the current deterministic parser or simplified settings UI.
PCC-specific runtime limits below describe that older implementation only.

Verification of the earlier PCC implementation on October 3–4, 2026:

| Coverage | Build / runtime | Result |
| --- | --- | --- |
| Full AppCore package | 138 | 708 total: 706 passed, 2 skipped |
| Full hosted app tests | 138 | 677 total: 674 passed, 3 skipped |
| IRS app/model tests | Final 139 | 34/34 passed |
| Full IRS settings UI suite | 138: iPhone 26.5, iPhone 27, iPad 27 simulators | 11/11 passed on each |
| Focused IRS source-selection UI suite | 139: the same three simulators | 3/3 passed on each |
| Exact production-client PCC probes | Signed non-GUI Mac harness | 11/11 scenarios passed; 10 actual PCC generations |
| Earlier Mac application self-test | Designed-for-iPad runtime | 21/21 checks passed; 4 PDFs comprising 5 pages rendered and inspected |
| Unrelated LaunchSmoke regression | iOS 27 | `testFinishingLastReviewStaysInInboxAndHidesRowAfterLeaving` remains failing: the keyboard covers the Personal menu action |

The iPhone 27 focused UI run preceded the final model background entry guard;
the final 34 IRS app/model tests and iPad 27 focused run include that guard.
The earlier Mac self-test preceded the final one-step UI. Native Mac GUI
launches, physical-iPhone PCC execution, and a two-device iCloud/CloudKit round
trip remain unverified. Build 139 was separately installed and read back on
the physical iPhone and at `/Applications/Mileager.app`. Strict signatures and
Mac executable identity passed; all 27 iPhone data files and all nine Mac data
files matched their pre-install backups. Neither installed app was launched
for this final deployment. Receipts and rollback backups are preserved locally
in `build/deployments/20261004-build139/`.

The historical domain suites covered adoption, contiguous catch-up, future dates, manual
conflicts, corrections, idempotence, legacy decoding, and CloudKit source merge.
The historical client suites covered cleaning, business evidence, missing/ambiguous results,
complete period extraction, HTTP caching, changed coverage, and cancellation.
The historical app suites covered cadence, first-drive history, explicit replacement of all
custom amounts, missing history, older-drive imports during and after checks,
shared monthly/annual/single-trip
export checks, background cancellation, non-cooperative late replies, settings
changes arriving through sync, unavailable PCC, and failure freshness across
relaunch. An annual catch-up test verifies both sides of the June/July effective
date and byte-for-byte preservation of files exported before the update.

The eleven historical IRS settings UI cases exercised one-step source selection, initial
failure/retry/cancellation, delayed Custom cancellation, verification after
leaving Settings, USD eligibility, kilometer presentation, both custom-conflict
choices, manual overrides, stopping following, failure status, and retained
scheduled history.
Expanded iPad suites use landscape to expose all three split-view columns;
the compact-shell suite keeps portrait. These test choices do not change app
navigation. Upcoming rate accessibility includes its full effective date.

On October 3–4, 2026, the then-current production client was rebuilt in Swift 6 mode
and tested in a strictly signed, non-GUI Mac PCC harness. All nine scenarios
passed in 44.84 seconds: three fresh official-page repeats, June 30 and July 1
boundaries, missing business data, two synthetic announced-future cases, and
conflicting prose/table evidence. Eight scenarios generated real PCC responses;
the missing-business source was rejected by deterministic preflight before PCC.
Each case used a new client with no cache. The five public-source cases each
downloaded the official page and returned both 2026 periods. Boundary checks
resolved 72.5 cents on June 30 and 76 cents on July 1. Synthetic future cases
returned all three periods while retaining 76 cents as the current 2026 rate
and activating the synthetic 80-cent rate only on January 1, 2027. PCC returned
`ambiguous` for conflicting prose/table evidence. Successful full-client cases
took 5.78–6.82 seconds; ambiguity rejection took 2.26 seconds. The source hash was
`9f4583c9d4a23ecf1fce9f8c3e5a9ee9177ef0a3a45e3c4da342fd7938bec825`.
These results cover the earlier extraction and independent evidence and date
checks in the signed harness.

The earlier client also passed two multi-year PCC scenarios after the
first-drive history change. An official-page request since January 15, 2024
returned all four business periods for 2024, 2025, and both halves of 2026 in
10.892 seconds, including download, PCC, validation, and schedule adoption. A
synthetic 2027 future announcement returned all five periods in 9.710 seconds
and activated the future rate only on its start date. Both runs removed a
custom 2030 entry and reset the fallback to the first verified IRS amount.
These tests used the same exact client source and strictly signed non-GUI
harness, with no cache, personal stores, CloudKit, or app launch.

An earlier signed-app self-test on October 3–4, 2026 ran the production HTTP/PCC
path on the actual Designed-for-iPad Mac runtime: all 21 live checks passed in
7.4 seconds. It independently validated both 2026 periods, used explicit adoption,
persisted and reread the schedule, and wrote/read monthly, annual, and trip
exports using two synthetic 10-mile trips. June's $7.25 and July's $7.60 sum to
$14.85; kilometer presentation preserves those amounts. All four PDFs (five
pages) were rendered and visually inspected without clipping or overlapping
text. The native Mac Settings/save-panel interactions, a second Mac process
relaunch, physical-iPhone PCC execution, and a two-device CloudKit round trip
remain separate verification boundaries.

Temporary Mac QA wrappers caused Gatekeeper launch-path mismatch warnings.
Those launches and registrations were stopped. A later explicit install
request used the canonical `/Applications/Mileager.app` wrapper, verified its
relative `WrappedBundle` link and strict signatures, and preserved personal
stores. Installation readback does not prove a subsequent Mac launch.
