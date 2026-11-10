// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AppCore",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
        // Leaf products for the widget extension, which needs the Live
        // Activity payload and distance formatting but none of the capture,
        // persistence, or reporting machinery.
        .library(name: "AppCoreModels", targets: ["AppCoreModels"]),
        .library(name: "MileageActivityAttributes", targets: ["MileageActivityAttributes"])
    ],
    targets: [
        // Pure domain vocabulary and formatting, plus the package's single
        // String Catalog: every target resolves strings through
        // Bundle.appCoreStrings, which lives here beside the catalog.
        .target(
            name: "AppCoreModels",
            resources: [
                .process("Resources")
            ]
        ),
        // Pure capture logic: the drive-detection reducer, its policies, and
        // the capture vocabulary that persistence serializes. Foundation-only
        // and resource-free: package-target imports are compiler-enforced, and
        // validate.sh's layer-purity check rejects SDK framework imports.
        .target(
            name: "DriveCaptureEngine",
            dependencies: ["AppCoreModels"]
        ),
        // The Core Data boundary: both store configurations (Cloud/Local),
        // every *Store facade, and the compiled model. The momc plugin emits
        // the .momd into this target's resource bundle.
        .target(
            name: "AppCorePersistence",
            dependencies: ["AppCoreModels", "DriveCaptureEngine"],
            exclude: ["MileageTracker.xcdatamodeld"],
            plugins: [
                .plugin(name: "CompileCoreDataModel")
            ]
        ),
        // Report computation and PDF rendering (SwiftUI/MapKit) — the only
        // layer that turns trips into user-facing documents.
        .target(
            name: "AppCoreReporting",
            dependencies: ["AppCoreModels", "AppCorePersistence"]
        ),
        // Geocoding, route fill, and trip-suggestion plumbing shared by the
        // iPhone, iPad, and Mac shells (one iOS binary).
        .target(
            name: "AppCoreEnrichment",
            dependencies: ["AppCoreModels", "DriveCaptureEngine", "AppCorePersistence"]
        ),
        // AI suggestion evidence and the on-device Foundation Models provider,
        // shared by the one iOS binary's shells (formerly the raw-source-shared
        // SharedSuggestions/ directory).
        .target(
            name: "AppCoreSuggestions",
            dependencies: ["AppCoreModels", "AppCoreEnrichment"]
        ),
        // The Live Activity payload shared by the app and the widget
        // extension. Depends only on Models so the widget's link set stays
        // minimal.
        .target(
            name: "MileageActivityAttributes",
            dependencies: ["AppCoreModels"]
        ),
        // Umbrella target: the capture shell plus @_exported re-exports of the
        // extracted targets, so app targets keep their single `import AppCore`.
        .target(
            name: "AppCore",
            dependencies: ["AppCoreModels", "DriveCaptureEngine", "AppCorePersistence", "AppCoreReporting", "AppCoreEnrichment", "AppCoreSuggestions", "MileageActivityAttributes"]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore", "AppCoreModels", "DriveCaptureEngine", "AppCorePersistence", "AppCoreReporting", "AppCoreEnrichment", "AppCoreSuggestions"],
            resources: [
                .process("Fixtures")
            ]
        ),
        // The fast capture loop: pure reducer replay tests that build without
        // Core Data, the momc plugin, or any platform framework.
        .testTarget(
            name: "DriveCaptureEngineTests",
            dependencies: ["DriveCaptureEngine", "AppCoreModels"]
        ),
        .plugin(
            name: "CompileCoreDataModel",
            capability: .buildTool()
        )
    ]
)
