import Foundation

/// The single bundle that owns the package's `Localizable.xcstrings` catalog.
///
/// Every `String(localized:)` call in the package passes
/// `bundle: .appCoreStrings` instead of `.module`. `.module` is per-target, so
/// a source file that moves to another package target would silently resolve
/// against that target's (empty) bundle — English masks the fallback because
/// key text equals English copy; only ES/FR/DE regress, with no build error.
/// This accessor pins every lookup to the one bundle that ships the catalog:
/// the catalog and this file always travel together, and `.module` is
/// evaluated only here. `scripts/verify_ios_localizations.py` enforces that no
/// call site under `AppCorePackage/Sources` passes `.module` directly.
extension Bundle {
    package static let appCoreStrings: Bundle = .module
}
