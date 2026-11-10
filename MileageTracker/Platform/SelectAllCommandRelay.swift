import Foundation

/// The bridge from the system's Edit ▸ Select All to the Mac trip list.
///
/// ⌘A cannot be a Trips-menu item: UIKit's menu builder treats a custom key
/// command that duplicates the system's Select All as a conflict and drops
/// the ENTIRE Trips menu — measured 2026-09-02 on a real Mac, where builds
/// carrying a ⌘A item had no Trips menu at all and the build without one did.
/// The Edit menu's own item instead sends `selectAll:` down the responder
/// chain, which ends at `AppDelegate`; that delegate answers when a Mac list
/// has registered here. A focused text field still claims `selectAll:`
/// before the chain ever reaches the delegate, exactly as it should.
@MainActor
enum SelectAllCommandRelay {
    /// Set by the Mac trip list while it is on screen and the command surface
    /// is available; `nil` grays the Edit menu item out.
    static var handler: (() -> Void)?
}
