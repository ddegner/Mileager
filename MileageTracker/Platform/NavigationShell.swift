import SwiftUI
import UIKit

/// Which navigation container is mounted at the root.
///
/// This is a separate axis from `RunningPlatform`: the platform is fixed for
/// the process, the shell can change mid-session when a Mac window crosses the
/// compact threshold.
enum NavigationShell: String, Sendable, Equatable, CaseIterable {
    /// One `NavigationStack`: every iPhone, and any compact-width window.
    case stack
    /// The three-column `NavigationSplitView`: iPad and Mac at regular width,
    /// so it is only ever mounted expanded.
    case split
}

/// Everything the shell decision consults, as plain data so it can be tested
/// without mounting a view.
struct NavigationShellContext: Equatable {
    var horizontalSizeClass: UserInterfaceSizeClass?
    var idiom: UIUserInterfaceIdiom
    /// UI-testing override; nil in every shipping launch.
    var forcedShell: NavigationShell?

    init(
        horizontalSizeClass: UserInterfaceSizeClass?,
        idiom: UIUserInterfaceIdiom,
        forcedShell: NavigationShell? = nil
    ) {
        self.horizontalSizeClass = horizontalSizeClass
        self.idiom = idiom
        self.forcedShell = forcedShell
    }
}

enum NavigationShellResolution {
    /// A split view is a regular-width idiom, and on iPhone it is the wrong
    /// container outright.
    ///
    /// A COLLAPSED `NavigationSplitView` cannot be driven programmatically:
    /// `preferredCompactColumn` is an advisory floor consulted when the view
    /// collapses, so a column change applied afterwards is dropped, and there
    /// is no API to re-front a column once it has settled. Deferring,
    /// retrying, and re-asserting were all measured to fail. Its own back
    /// navigation is equally out of reach — emptying the detail column's stack
    /// leaves the collapsed view fronting that column's placeholder rather
    /// than returning to the list.
    ///
    /// So the phone gets the plain stack it shipped with, and the Mac and iPad
    /// keep the Mail three-column shape, which is only ever mounted expanded.
    /// Apple's guidance says the same: prefer a split view in a regular, not a
    /// compact, environment.
    ///
    /// Tested FOR `.regular` rather than against `.compact` because the size
    /// class is optional: a nil first pass must not briefly mount the split
    /// view. The idiom check keeps a landscape Max-class iPhone — which does
    /// report regular width — on the stack, so no phone ever swaps shells
    /// mid-session.
    ///
    /// Note a "Designed for iPad" app on Apple silicon reports
    /// `UIUserInterfaceIdiom.pad`, not `.mac`. That is why the iPad simulator
    /// and a real Mac take the identical branch here, and why iPad coverage is
    /// a good proxy for this decision specifically.
    static func shell(for context: NavigationShellContext) -> NavigationShell {
        if let forced = context.forcedShell { return forced }
        let isRegular = context.horizontalSizeClass == .regular
        return (isRegular && context.idiom != .phone) ? .split : .stack
    }

    /// Whether the size-class environment has settled yet.
    ///
    /// A distinct question from `shell(for:)`, which cannot express it: the
    /// shell collapses a nil size class to `.stack`, so "no answer yet" and
    /// "the stack" are indistinguishable there. The launch redirect needs to
    /// wait for a real answer rather than act on the nil pass.
    ///
    /// Deliberately ignores `forcedShell`. If a forced shell also made this
    /// true on the nil pass, a UI test would drive a launch-redirect ordering
    /// that ships to nobody, and would be verifying a code path that does not
    /// exist in production.
    static func isEnvironmentSettled(_ context: NavigationShellContext) -> Bool {
        context.horizontalSizeClass != nil
    }
}

/// How far the floating sidebar overlaps the column this view is in.
///
/// Published by the split shell, which is the only place that can measure it
/// (see `SidebarUnderlapConsumed`). Zero in the stack shell and in any column
/// the sidebar does not float over, which makes the consumer a no-op there.
private struct SidebarUnderlapKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var sidebarUnderlap: CGFloat {
        get { self[SidebarUnderlapKey.self] }
        set { self[SidebarUnderlapKey.self] = newValue }
    }
}

/// Restates the floating sidebar's overlap as scroll content margins instead
/// of a safe area, so `List` swipe actions land where they do on iPhone.
///
/// iOS 26 floats the sidebar over the content column rather than beside it.
/// The column's view starts at the window's leading edge and runs underneath
/// the panel, and UIKit keeps content clear of it with a leading safe-area
/// inset — 290pt on a 13-inch iPad, the panel plus its gutter. Almost
/// everything copes. Swipe actions do not: UIKit places the action buttons
/// after the inset, correctly, and then slides the whole *cell* by
/// `inset + buttons`, so the cell's already-inset content view lands a second
/// inset further along, past the end of the column. What fills the swiped-open
/// row is then the cell's own empty background chip, and the button looks like
/// it is refusing to stretch. It is not — the row it should be sitting beside
/// has been pushed out of the column.
///
/// Three presets hide this, because three chips happen to be about as wide as
/// the visible column. One preset leaves most of the row grey.
///
/// So: drop the leading safe area, and put the same distance back as a content
/// margin. The cells become exactly as wide as the visible column and sit at
/// its leading edge with no inset of their own, which is the geometry the
/// iPhone has always had — the cell translation and the buttons now measure
/// from the same origin.
///
/// Leading only. The vertical insets are what let the list scroll under the
/// navigation bar and the drive bar, and nothing double-counts those.
struct SidebarUnderlapConsumed: ViewModifier {
    @Environment(\.sidebarUnderlap) private var underlap

    /// An empty edge set and a zero margin rather than an `if`: with no
    /// overlap — every stack-shell mount, and the split shell whenever the
    /// sidebar is hidden — both modifiers have to do nothing, and they have to
    /// do nothing while still being *there*. Branching the chain instead would
    /// give the list a new identity every time the sidebar is toggled, which
    /// tears down the scroll view and drops the reader's place in the list.
    ///
    /// The empty set is what keeps the stack shell honest too: a landscape
    /// iPhone has a real leading safe area (the notch), and unconditionally
    /// ignoring it would run the rows under the sensor housing.
    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container, edges: underlap > 0 ? .leading : [])
            .contentMargins(.leading, underlap, for: .scrollContent)
    }
}

extension View {
    /// See `SidebarUnderlapConsumed`. Apply to a swipeable `List` that can be
    /// mounted in a split-view column the sidebar floats over.
    func sidebarUnderlapConsumed() -> some View {
        modifier(SidebarUnderlapConsumed())
    }
}
