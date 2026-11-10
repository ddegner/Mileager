import SwiftUI
import UIKit
import XCTest
@testable import MileageTracker

@MainActor
final class LogbookPrivacyCoverTests: XCTestCase {
    func testSystemLaunchStoryboardUsesNotebookAcrossDeviceLayouts() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            try verifySystemLaunchStoryboard(style: style)
        }
    }

    private func verifySystemLaunchStoryboard(style: UIUserInterfaceStyle) throws {
        let bundle = Bundle(for: AppLockController.self)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "UILaunchStoryboardName") as? String, "NotebookLaunchScreen")
        for (name, size, idiom, vertical, bindingHeight) in [
            ("phone", CGSize(width: 402, height: 874), UIUserInterfaceIdiom.phone, UIUserInterfaceSizeClass.regular, CGFloat(98)),
            ("phone-landscape", CGSize(width: 874, height: 402), .phone, .compact, 42),
            ("ipad", CGSize(width: 1032, height: 1376), .pad, .regular, 42),
            ("narrow-ipad", CGSize(width: 400, height: 800), .pad, .regular, 42)
        ] {
            let traits = UITraitCollection {
                $0.userInterfaceIdiom = idiom
                $0.verticalSizeClass = vertical
                $0.horizontalSizeClass = size.width < 600 ? .compact : .regular
                $0.displayScale = 3
                $0.userInterfaceStyle = style
            }
            var controller: UIViewController?
            traits.performAsCurrent {
                controller = UIStoryboard(name: idiom == .pad ? "NotebookTabletLaunchScreen" : "NotebookLaunchScreen",
                                          bundle: bundle).instantiateInitialViewController()
                controller?.loadViewIfNeeded()
            }
            let view = try XCTUnwrap(controller?.view)
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.traitOverrides.userInterfaceStyle = style
            window.traitOverrides.userInterfaceIdiom = idiom
            window.traitOverrides.verticalSizeClass = vertical
            window.traitOverrides.horizontalSizeClass = size.width < 600 ? .compact : .regular
            window.rootViewController = controller
            controller?.traitOverrides.userInterfaceStyle = style
            controller?.traitOverrides.userInterfaceIdiom = idiom
            controller?.traitOverrides.verticalSizeClass = vertical
            controller?.traitOverrides.horizontalSizeClass = size.width < 600 ? .compact : .regular
            view.traitOverrides.userInterfaceStyle = style
            view.traitOverrides.userInterfaceIdiom = idiom
            view.traitOverrides.verticalSizeClass = vertical
            view.traitOverrides.horizontalSizeClass = size.width < 600 ? .compact : .regular
            view.updateTraitsIfNeeded()
            view.frame = CGRect(origin: .zero, size: size)
            view.setNeedsLayout()
            view.layoutIfNeeded()
            XCTAssertEqual(view.traitCollection.verticalSizeClass, vertical)
            let images = view.subviews.compactMap { $0 as? UIImageView }
            XCTAssertEqual(images.count, 3)
            XCTAssertFalse(view.subviews.contains { $0 is UILabel }, "The old centered title must be absent")
            let paper = try XCTUnwrap(images.first)
            XCTAssertEqual(paper.frame, view.bounds)
            XCTAssertEqual(paper.image?.resizingMode, .tile)
            let binding = images[1]
            XCTAssertEqual(binding.frame, CGRect(x: 0, y: bindingHeight - 42, width: size.width, height: 42), name)
            XCTAssertEqual(binding.image?.resizingMode, .tile)
            XCTAssertEqual(images[2].frame, CGRect(x: 29, y: size.height - 76, width: 48, height: 48), name)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            let render = UIGraphicsImageRenderer(size: size, format: format).image { context in
                view.layer.render(in: context.cgContext)
            }
            func grain(at point: CGPoint) throws -> Data? {
                let crop = try XCTUnwrap(render.cgImage?.cropping(to: CGRect(
                    x: point.x * 3, y: point.y * 3, width: 12, height: 12
                )))
                return UIImage(cgImage: crop).pngData()
            }
            XCTAssertEqual(try grain(at: CGPoint(x: 100, y: 120)), try grain(at: CGPoint(x: 356, y: 120)),
                           "Paper must tile at its native size, not stretch to the screen")
            XCTAssertEqual(try grain(at: CGPoint(x: 100, y: 120)), try grain(at: CGPoint(x: 100, y: 376)))
            let brightness = try paperBrightness(in: render)
            if style == .dark {
                XCTAssertLessThan(brightness, 0.30, "System launch must use the charcoal material")
            } else {
                XCTAssertGreaterThan(brightness, 0.60, "Light-mode paper must remain cream")
            }
            let attachment = XCTAttachment(image: render)
            attachment.name = "Notebook-Launch-\(name)-\(style == .dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testAssetHasConsistentPointSizeAtEveryDisplayScale() throws {
        for (name, size) in [
            ("PrivacyPaper", CGSize(width: 256, height: 256)),
            ("PrivacyBinding", CGSize(width: 312, height: 42)),
            ("PrivacyStamp", CGSize(width: 48, height: 48)),
            ("LaunchPaper", CGSize(width: 256, height: 256)),
            ("LaunchBinding", CGSize(width: 312, height: 42)),
            ("LaunchStamp", CGSize(width: 48, height: 48))
        ] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                for scale in [1.0, 2.0, 3.0] {
                    let traits = UITraitCollection {
                        $0.displayScale = scale
                        $0.userInterfaceStyle = style
                    }
                    let image = try XCTUnwrap(UIImage(
                        named: name, in: Bundle(for: AppLockController.self), compatibleWith: traits
                    ))
                    XCTAssertEqual(image.size, size, name)
                    // Thinned builds may contain only the native rendition;
                    // fallback must retain the logical size in both appearances.
                    XCTAssertEqual(CGFloat(try XCTUnwrap(image.cgImage).width) / image.scale, size.width)
                }
            }
        }
    }

    func testCoverUsesCharcoalOnlyInDarkAppearance() throws {
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: LogbookPrivacyCover()
                .frame(width: 402, height: 874)
                .environment(\.colorScheme, scheme))
            renderer.scale = 3
            let brightness = try paperBrightness(in: XCTUnwrap(renderer.uiImage))
            if scheme == .dark {
                XCTAssertLessThan(brightness, 0.30)
            } else {
                XCTAssertGreaterThan(brightness, 0.60)
            }
        }
    }

    func testNotebookFallbackIsOpaqueAndPrintedInkHasReadableContrast() throws {
        let bundle = Bundle(for: AppLockController.self)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection { $0.userInterfaceStyle = style }
            func components(_ name: String) throws -> (CGFloat, CGFloat, CGFloat, CGFloat) {
                let color = try XCTUnwrap(UIColor(named: name, in: bundle, compatibleWith: traits))
                    .resolvedColor(with: traits)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
                return (r, g, b, a)
            }
            let paper = try components("NotebookPaper")
            let ink = try components("NotebookInk")
            XCTAssertEqual(paper.3, 1, accuracy: 0.001, "Fallback must hide trip data even without textures")
            let printed = (ink.0 * ink.3 + paper.0 * (1 - ink.3),
                           ink.1 * ink.3 + paper.1 * (1 - ink.3),
                           ink.2 * ink.3 + paper.2 * (1 - ink.3))
            func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
                func linear(_ c: CGFloat) -> CGFloat {
                    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                }
                return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
            }
            let background = luminance(paper.0, paper.1, paper.2)
            let foreground = luminance(printed.0, printed.1, printed.2)
            XCTAssertGreaterThanOrEqual((max(background, foreground) + 0.05) / (min(background, foreground) + 0.05), 4.5)
        }
    }

    private func paperBrightness(in image: UIImage) throws -> CGFloat {
        let bitmap = try XCTUnwrap(image.cgImage)
        let center = try XCTUnwrap(bitmap.cropping(to: CGRect(
            x: bitmap.width / 2, y: bitmap.height / 2, width: 1, height: 1
        )))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(pixel[3], 255)
        return CGFloat(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
    }

    func testCameraClearanceIsReservedOnlyForPortraitPhones() {
        XCTAssertEqual(LogbookPrivacyCover.bindingTopInset(
            for: CGSize(width: 402, height: 874), isPhone: true
        ), 56)
        for size in [CGSize(width: 956, height: 440), CGSize(width: 1032, height: 1376)] {
            XCTAssertEqual(LogbookPrivacyCover.bindingTopInset(for: size, isPhone: true), 0)
        }
        // Even a narrow, tall iPad/Mac window has no phone island to avoid.
        XCTAssertEqual(LogbookPrivacyCover.bindingTopInset(
            for: CGSize(width: 400, height: 800), isPhone: false
        ), 0)
    }

    func testPrivacyAndLockScreensHideUnderlyingContentWithLargeTextInDarkMode() throws {
        XCTAssertNotNil(
            UIFont(name: AppSecurityOverlay.printedFontName, size: 13),
            "The native Mincho face must be available rather than silently falling back"
        )
        for locked in [false, true] {
            let preferences = Preferences(defaults: try makeTestDefaults())
            preferences.appLockEnabled = locked
            let controller = AppLockController(
                preferences: preferences,
                authenticator: ScreenshotPresentationAuthenticator(),
                platform: .iOS
            )
            controller.refreshAvailability()
            if !locked { controller.handleScenePhaseChange(.background) }
            for textSize in [DynamicTypeSize.large, .accessibility1] {
                for size in [
                    CGSize(width: 375, height: 667),
                    CGSize(width: 402, height: 874), // iPhone 17 Pro at its native 3x scale
                    CGSize(width: 956, height: 440)
                ] {
                    func render(over color: Color) throws -> UIImage {
                        let renderer = ImageRenderer(content: ZStack {
                            color
                            AppSecurityOverlay(appLock: controller)
                        }
                        .frame(width: size.width, height: size.height)
                        .environment(\.colorScheme, .dark)
                        .environment(\.dynamicTypeSize, textSize))
                        renderer.scale = 3
                        return try XCTUnwrap(renderer.uiImage)
                    }
                    let image = try render(over: .red)
                    XCTAssertEqual(
                        image.pngData(), try render(over: .blue).pngData(),
                        "Neither security state may expose the underlying window"
                    )
                    let paperRenderer = ImageRenderer(content: LogbookPrivacyCover()
                        .frame(width: size.width, height: size.height)
                        .environment(\.colorScheme, .dark))
                    paperRenderer.scale = 3
                    if !locked {
                        XCTAssertEqual(
                            image.pngData(), try XCTUnwrap(paperRenderer.uiImage).pngData(),
                            "With App Lock off, the privacy cover must contain no recording note or unlock text"
                        )
                    }
                    let stampRegion = CGRect(
                        x: 0, y: (size.height - 96) * 3,
                        width: 96 * 3, height: 96 * 3
                    )
                    let coveredStamp = try XCTUnwrap(image.cgImage?.cropping(to: stampRegion))
                    let plainStamp = try XCTUnwrap(paperRenderer.cgImage?.cropping(to: stampRegion))
                    XCTAssertEqual(
                        UIImage(cgImage: coveredStamp).pngData(),
                        UIImage(cgImage: plainStamp).pngData(),
                        "Lock controls must leave the stamp unobstructed, including at large text sizes"
                    )
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Logbook-\(locked ? "locked" : "privacy")-\(Int(size.width))-\(textSize == .large ? "normal-text" : "large-text")-dark"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    /// Full-screen aspect-fill would cut off the seal in landscape; ordinary
    /// stretching would distort it on iPad. Verify actual rendered pixels,
    /// including opacity, across those layouts and dark appearance.
    func testCoverStaysOpaqueAndKeepsOneUndistortedSealAcrossWindowSizes() throws {
        let sizes: [(String, CGSize)] = [
            ("compact-phone", CGSize(width: 320, height: 568)),
            ("phone", CGSize(width: 402, height: 874)),
            ("large-phone", CGSize(width: 440, height: 956)),
            ("phone-landscape", CGSize(width: 956, height: 440)),
            ("ipad-portrait", CGSize(width: 1032, height: 1376)),
            ("ipad-landscape", CGSize(width: 1376, height: 1032)),
            ("compact-window", CGSize(width: 400, height: 320)),
            ("wide-window", CGSize(width: 1280, height: 800))
        ]
        for (name, size) in sizes {
            let renderer = ImageRenderer(content: LogbookPrivacyCover()
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark))
            let scale = size.width >= 1000 ? 2 : 3
            renderer.scale = CGFloat(scale)
            let image = try XCTUnwrap(renderer.uiImage, name)
            let bitmap = try XCTUnwrap(image.cgImage)
            let width = bitmap.width
            let height = bitmap.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            XCTAssertEqual(width, Int(size.width) * scale)
            XCTAssertEqual(height, Int(size.height) * scale)
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))

            var minX = width, minY = height, maxX = 0, maxY = 0
            var inkPixels = 0
            var transparentPixels = 0
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    if pixels[offset + 3] != 255 { transparentPixels += 1 }
                    let red = Int(pixels[offset])
                    let green = Int(pixels[offset + 1])
                    let blue = Int(pixels[offset + 2])
                    if red > 130, red - green > 65, red - blue > 70 {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                        inkPixels += 1
                    }
                }
            }
            XCTAssertEqual(transparentPixels, 0, "\(name): trip data must never show through")
            XCTAssertGreaterThan(inkPixels, 150 * scale * scale, "\(name): seal must stay visible")
            let inkWidth = maxX - minX + 1
            let inkHeight = maxY - minY + 1
            XCTAssertTrue((35 * scale...50 * scale).contains(inkWidth), "\(name): seal width \(inkWidth)")
            XCTAssertLessThan(abs(inkWidth - inkHeight), 4 * scale, "\(name): seal must stay square")
            XCTAssertLessThan(maxX, 96 * scale, "\(name): exactly one seal at the left")
            XCTAssertGreaterThan(minY, height - 96 * scale, "\(name): exactly one seal at the bottom")
            XCTAssertTrue((30 * scale...35 * scale).contains(minX), "\(name): left ink inset")
            XCTAssertTrue((30 * scale...35 * scale).contains(height - maxY), "\(name): bottom ink inset")

            let attachment = XCTAttachment(image: image)
            attachment.name = "Logbook-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
