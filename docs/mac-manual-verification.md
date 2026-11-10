# Manual Mac verification

There is no Mac CI and no way to build one: nothing can launch this app as a
macOS process in an automated run. The iPad simulator covers the split-view
shell (see below for exactly how far), and everything in the checklist here is
what remains hardware-only. Run it before shipping a release that touched
navigation, the toolbar, sheets, Settings, exports, or App Intents.

## Installing a local build

An iOS-on-Mac app is a wrapper bundle: a top-level `.app` containing
`Wrapper/MileageTracker.app` plus a `WrappedBundle` symlink.

```sh
build_root="$(mktemp -d)"
wrapper_root="$(mktemp -d)/Mileager Dev.app"

xcodebuild build -project MileageTracker.xcodeproj -scheme MileageTracker \
  -configuration Debug -derivedDataPath "$build_root" \
  -destination 'platform=macOS,variant=Designed for iPad,arch=arm64'

mkdir -p "$wrapper_root/Wrapper"
ditto "$build_root/Build/Products/Debug-iphoneos/MileageTracker.app" \
  "$wrapper_root/Wrapper/MileageTracker.app"
ln -s Wrapper/MileageTracker.app "$wrapper_root/WrappedBundle"
xattr -cr "$wrapper_root"
codesign --verify --strict "$wrapper_root/Wrapper/MileageTracker.app"

ditto "$wrapper_root" "$HOME/Applications/Mileager Dev.app"
xattr -cr "$HOME/Applications/Mileager Dev.app"
codesign --verify --strict \
  "$HOME/Applications/Mileager Dev.app/Wrapper/MileageTracker.app"
```

Copy it with `ditto`, **never `cp -R`** — `cp` breaks the signature, and
Gatekeeper then reports the app as damaged and trashes it. `xcodebuild` emits
only the flat inner app in `Debug-iphoneos`; the wrapper is assembled, not
built, and has no outer `Info.plist`. Do not use the `id=` reported by
`xcrun xctrace list devices`; use the Designed-for-iPad destination above or a
destination from `xcodebuild` itself.

An app Xcode is currently running lives in its own temporary wrapper. Replacing
the installed bundle does not disturb that process, but do not launch the
installed copy alongside it: both instances would share the local store and
Production CloudKit.

## Protecting the personal library during QA

Signed Debug builds can access production iCloud. A normal launch opens the
personal library; it is not a safe place to seed, edit, or reset test data.
For manual fixture checks, launch the QA wrapper with all of these arguments:

```sh
open "$HOME/Applications/Mileager Dev.app" --args \
  --uitesting --reset-data --reset-preferences --skip-onboarding \
  --seed-mileage-data --test-store-suffix=mac-release-qa
```

`--uitesting` disables CloudKit, uses a separate preferences suite, and routes
SQLite files and derived caches to test directories. The suffix alone does
not enable isolation. Keep `--uitesting` on every relaunch during the check.
Reset App in a normal synced launch can delete the personal iCloud library.

The release validation script uses iPhone/iPad simulators. Hosted unit tests
start the host in preview mode; UI tests explicitly use `--uitesting`.
Screenshot capture, Live Capture, and the physical-device self-test also pass
`--uitesting`. The device self-test still installs and terminates the phone
app, so use a simulator for routine release validation while the phone is
recording personal drives.

The debug suggestion demo now requires `--uitesting` too. It can use the real
suggestion provider, but never creates an event in the default Calendar,
which may belong to a personal synced account.

## The checklist

Pull-to-refresh and Trips > Refresh (Command-R) are removed. On macOS there
is no pull caption and no Summary button. On iPhone and iPad, pulling a month,
year, All Trips, or filtered trip list shows three left-aligned business-green
lines as a centered block:
reimbursement, distance with its spelled-out unit, and business trip count, on
light cream in light mode and lighter green in dark mode.
The color fills only the exposed pull area within the list's column, with soft
shadows along its upper and lower edges, with the lower shadow at one quarter of the upper shadow's opacity.
Check both appearances; the shading stays
inside the exposed background and disappears with the pull.
It follows the native bounce and disappears on release,
with no refresh work, spinner, or held-open panel. Trips overview and Need
Review have no caption. Check short, medium, and deep pulls in All Trips: the
caption stays between the fixed top toolbar and the moving large title, without
covering either. Repeat in a narrow iPad column. The Total reimbursement
disclosure is absent from every trip list. Verify local edits and received
iCloud changes update automatically, including foreground history checks. Use isolated sync tests
for retry and missed-notification coverage; never change the personal iCloud
account for QA.

Verify the **Combine with iCloud** confirmation from Settings and onboarding
using the isolated QA launch above (add `--enable-sync-for-uitesting` and
omit `--skip-onboarding`; complete setup without sync to reach Settings).
It must show its title,
local trip/vehicle counts, explanation, Cancel, and Combine and Sync at a
readable size. A tiny sheet showing only an ellipsis is a failure: this
screen needs `macSheetFrame()` and must not use iPhone presentation detents
on Mac. Cancel must return without enabling sync.

Also open quick Purpose and Notes, Custom Purpose, Add/Edit Fee, Base Rate,
Add Rate, and Report Issue in the isolated library. Their titles, editable
fields, and confirmation controls must be visible without a More menu.
Short editors use 560×480; purpose, fees, and support reports use 560×680.
Check nested sheets as well as those opened from the trip list. Never save
fixture edits or prepare support reports from the personal library for QA.

1. **Every sidebar row clicks.** A `.bottomBar` `ToolbarItemGroup` on the
   expanded sidebar column lays an invisible `UIToolbar` across the whole
   column and swallows every click — the sidebar was completely inert until
   that was gated. On iPad the same bar is perfectly clickable, so no simulator
   run can catch a regression here.
2. **Settings is reachable.** A Settings row sits at the bottom of the sidebar
   and opens Settings; ⌘, does too. The sidebar's toolbar gear must NOT render
   — on the Mac it draws in the window titlebar strip and never delivers
   clicks, so it would be dead furniture.
3. **`DriveListView`'s Filter and "+" still work** in the content column. They
   are deliberately not gated; only the sidebar's bars are.
4. **Full-page sheets use the intended size profile.** Onboarding is 560×680;
   Settings, Manual Trip, and endpoint search are 700×800. Without
   `MacSheetFrame` a `Form`-shaped sheet hugs a ~285pt ideal width;
   `presentationSizing(.form)` and `minWidth` are both ignored.
   `ProcessInfo.isiOSAppOnMac` is false in every simulator, so this is
   unreachable from any automated run.
5. **Type into a sheet field, then resize the window across the compact
   threshold.** The text must survive. This is the `MacSheetFrame` regression
   test: it branches on the process rather than the size class precisely so its
   `if/else` can never switch the sheet content's structural identity
   mid-presentation and discard its `@State`.
6. **Narrow the window to compact and back.** The shell swaps, the toolbar gear
   and the sidebar Settings row trade places, and no sheet loses state. The
   runtime is still a Mac: ordinary clicks retain Mac browse behavior, while
   the directly visible Select/Done button must occupy the same top-bar slot at
   either width.
7. **Close a trip in the reading pane** — including via unmerge, duplicate, and
   delete. The expanded trip is the reading pane's root rather than a pushed
   route, so closing it must reveal the placeholder while keeping the current
   scope selected. Verify that the compact shell still uses ordinary push and
   Back navigation.
8. **Menu commands and ⌘-chords:** ⌘, ⌘N ⌘1–3 ⌘↑/⌘↓, and every bottom-bar
    verb from the menu bar: Classify ▸ Business ▸ (presets, Custom Purpose…
    ⌥⌘P, Business ⇧⌘B, Clear Purpose), Personal ⇧⌘P, Not a Drive ⇧⌘N,
    Unclassify ⇧⌘U, Trips ▸ Assign Vehicle (only with several vehicles),
    Merge ⇧⌘M, Delete ⌘⌫, Deselect All
    ⌥⌘A, Edit ▸ Select All ⌘A. Then turn on App Lock,
   lock the app, and confirm every Trips-menu item is greyed out. Menu commands
   and keyboard chords bypass both lock gates — `SecurityOverlayWindow.hitTest`
   and `.allowsHitTesting` intercept touches only — so the gating is entirely
   `MileageAppModel.isCommandSurfaceAvailable` publishing `nil`.
9. **Exports open a save panel, not a share sheet.** Check monthly and annual
   PDF/CSV, a single-trip PDF, and Settings → diagnostics. Confirm the expected
   filename appears, save and open a PDF, then cancel another export and retry.
   A missing Transferable filename can crash the Mac before the panel appears,
   even when the panel's `defaultFilename` is set.
10. **A capture-dependent Shortcut refuses** with the Mac message. Startup skips
    `bootstrapTrackingForLaunch`, which is also the only place spooled start
    signals drain, so a signal written on a Mac would report success to Siri and
    then expire unread.
11. **Split-view dividers are draggable** (the missing macOS resize cursor is
    accepted — Designed-for-iPad apps have no public hook for it).
12. **The trip list's bottom bar carries live verbs now.** Filter, Classify
    (Business is a submenu holding the purposes), (Vehicle), Merge, Delete
    and "+" are all in the content column's
    bottom bar and must all click. On the Mac only the SIDEBAR's bottom bar is
    known-dead, but this is the first time that bar has held anything but
    Filter and "+", and the whole Mac selection model routes through it. In
    browse mode, check them with nothing selected (grayed), with one row
    (Merge alone stays grayed), and with several. Enter explicit Select mode
    and confirm every control keeps the same order, spacing, and glass group;
    only the bulk verbs' enabled state may change.
13. **Mac browse selection and explicit Select mode remain distinct.** In an
    expanded window, first verify that one plain browse click selects a row and
    opens its adjacent detail without showing Done; the item context menu has
    no `primaryAction`. Then verify that ⌘-click and ⇧-click follow the tested
    SwiftUI host behavior: each replaces the selection with the clicked row
    rather than adding or filling a range. Mileager must not read physical
    modifier state or project a different result. Click the directly visible
    Select button (and separately press ⇧⌘L), then plain-click two rows: both
    must show native checkmarks, the unchanged bottom bar must retain Filter
    and "+", and the reading pane must show their summary. Press Done; the
    selection and summary must clear, the button must return to Select, and the
    next plain click must again open
    exactly one detail. Repeat Select/Done after narrowing to the compact shell;
    clicks must check rows instead of opening them while the mode is active.
    Outside Select mode, use Edit ▸ Select All or ⇧⌘↑/⇧⌘↓ to create several
    selected trips and confirm they show the summary pane. Shrink a two-trip
    keyboard range back to one and confirm the remaining trip immediately
    replaces the summary. The browse highlight is Mail's blue chip with white
    text; Select mode must yield to SwiftUI's native row treatment. Right-click
    inside a multi-selection
    and confirm the context menu acts on that exact selection; right-click an
    unselected row and confirm it targets only that row. A non-destructive
    action must preserve a browse/keyboard selection; the same action from
    explicit Select mode must finish that mode and clear its checkmarks.
    Deletion must prune only the removed trips. Finally, Command-Tab to another app and back several times,
    never holding a modifier when returning; after each return, a plain click
    must replace the selection with exactly that row. It must never toggle or
    add a row as though Command were still pressed.
14. **Replace one reading-pane trip with another repeatedly.** With the seeded
    data, alternate **Client ↔ Home** rapidly at least four times, then try
    **Gym → Home**. The
    detail destination must change **Client → Home → Client** in place: no
    "No Trip Selected" flash, no horizontal slide, and no added Back level.
    Repeat with the ↑/↓ detail chevrons and a Spotlight or Siri open. Each must
    move the row selection and replace the detail atomically.
15. **Keyboard selection.** Edit ▸ Select All (⌘A, the system's own item — the
    Trips menu must NOT carry one, or the whole Trips menu disappears) selects
    every visible trip; ⌥⌘A in the Trips menu clears the selection. Confirm the
    Trips menu is present in the menu bar at all. With nothing selected, ⌘↓ selects the first row
    and ⌘↑ the last; with several selected, ⌘↓ collapses onto the row past
    the bottom one. Click a row, then ⇧⌘↓ twice and ⇧⌘↑ once: the range must
    grow to three and shrink back to two from the clicked row, and the list
    must scroll to keep the moving end visible. Put the caret in a text field
    and press ⌘A again: the field must take it, not the trip list. Confirm
    Delete, Classify, and the other app-specific commands still target the
    active list selection before a trip merely open in the reading pane.
16. **A trip opened in a narrow window stays closed after widening.** Narrow the
    window to the stack, double-click a trip, press Back, then widen: the
    reading pane must show the placeholder, not the trip just closed.
17. **Mac onboarding never invents a vehicle.** On a clean install choose **Set
    Up Without iCloud** and confirm setup finishes without showing the vehicle
    editor. Settings → Vehicles must show zero rows and an enabled **Add
    Vehicle** path. Then enable iCloud Sync: the confirmation must count local
    vehicles and warn that similarly named vehicles stay separate. After the
    relaunch/import, only imported or explicitly added vehicles may appear — no
    automatic "My Car". Existing trips and vehicles must remain untouched.

Then, on a Max-class iPhone in landscape: it must still mount the **stack**,
with the toolbar gear and "+" present. That phone reports regular width, so a
rule that gated on the size class alone would hand it the split view and strip
those buttons of their only substitute.

## What the iPad simulator DOES cover

`SplitShellUITests` runs on an iPad in `scripts/validate.sh --full` (the
release tier, and the `Release Gate` workflow; the per-PR fast tier skips
simulator UI automation entirely). A "Designed for
iPad" app on Apple silicon reports `UIUserInterfaceIdiom.pad`, not `.mac`, so an
iPad and a real Mac take the identical branch through
`NavigationShellResolution` — which makes the iPad a genuinely good proxy for
shell selection and cross-column routing, and a poor one for anything that is
really an AppKit-host behavior.

Covered automatically, so it is NOT in the checklist above:

- which shell mounts for a given size class and idiom (`NavigationShellResolutionTests`)
- both `if !usesSplitView` toolbar gates — `settingsButton` and `addTripButton`
  absent in split, `sidebarSettingsRow` present
- sidebar selection driving the content column, and sidebar rows being hittable
- a trip filling the detail column without collapsing the list
- the trip rendering as the reading-pane root without an automatic Back level,
  while the sidebar scope remains selected
- a normal iPad tap replacing **Client** detail with **Home** detail without an
  observable placeholder or horizontal push
- repeated Mac-mode proxy clicks replacing A ↔ B directly, changing the exact
  detail identity, and recording no intermediate empty presentation
  (`testSecondPlainClickReplacesSelection` — the 2026-09-01 field report)
- Mac-mode Select exposing Done, two unmodified taps building a multi-selection
  and summary, Done clearing it, and the next tap returning to singleton browse
  selection (`testMacSelectModeBuildsMultiSelectionAndDoneReturnsToBrowse`)
- forced compact Mac mode using the same Select/Done flow without opening Trip
  Detail, including toggling off the final checkmark and restoring browse
  navigation afterwards
  (`MacCompactSelectionUITests.testSelectModeBuildsMultiSelectionWithoutOpeningTripDetail`)
- one → several → one Mac-mode selection transitions showing detail → summary
  → the remaining trip's detail
- the ↑/↓ chevron changing the exact detail identity and moving the Mac-mode
  row highlight with it (`testSteppingTheReadingPaneMovesTheSelectionWithIt`)

The gates' *presence* is testable; their *necessity* is not. Item 1 above is the
clearest case: the test asserts the bottom bar is absent, but only a Mac can
show you what happens when it is there.
