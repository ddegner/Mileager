// The AppCore product keeps its single-import surface while the package is
// split into layered targets: app code writes `import AppCore` and sees every
// extracted target's public API through these re-exports.
@_exported import AppCoreModels
@_exported import DriveCaptureEngine
@_exported import AppCorePersistence
@_exported import AppCoreReporting
@_exported import AppCoreEnrichment
@_exported import AppCoreSuggestions
@_exported import MileageActivityAttributes
