import AppCore
import SwiftUI
import MapKit
import UIKit
import XCTest
@testable import MileageTracker

final class DriveCardMapThumbnailCacheTests: XCTestCase {
    func testDiskRoundTripFreshnessRetentionAndFilePolicy() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockedMapCacheClock(Date(timeIntervalSince1970: 1_800_000_000))
        let cache = DriveCardMapDiskCache(directory: root, now: clock.now)
        let imageData = Data((0..<512).map { UInt8($0 % 251) })

        await cache.insert(imageData, forKey: "route-a")

        let fresh = await cache.cachedImageData(forKey: "route-a")
        XCTAssertEqual(fresh?.imageData, imageData)
        XCTAssertEqual(fresh?.freshness, .fresh)

        let optionalFileURL = await cache.fileURL(forKey: "route-a")
        let fileURL = try XCTUnwrap(optionalFileURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #if targetEnvironment(simulator)
        // Simulator filesystems do not implement Data Protection attributes.
        XCTAssertNotNil(attributes[.size])
        #else
        XCTAssertEqual(
            attributes[.protectionKey] as? FileProtectionType,
            .completeUntilFirstUserAuthentication
        )
        #endif
        let resourceValues = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resourceValues.isExcludedFromBackup, true)

        clock.advance(by: DriveCardMapCachePolicy.freshLifetime + 1)
        let stale = await cache.cachedImageData(forKey: "route-a")
        XCTAssertEqual(stale?.imageData, imageData)
        XCTAssertEqual(stale?.freshness, .stale)

        clock.advance(
            by: DriveCardMapCachePolicy.retentionLifetime
                - DriveCardMapCachePolicy.freshLifetime
                + 1
        )
        let expired = await cache.cachedImageData(forKey: "route-a")
        XCTAssertNil(expired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDiskCacheTreatsCorruptionAndFormatMismatchAsMisses() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockedMapCacheClock(Date(timeIntervalSince1970: 1_800_000_000))
        let versionOne = DriveCardMapDiskCache(
            directory: root,
            configuration: .init(formatVersion: 1),
            now: clock.now
        )

        await versionOne.insert(Data("valid".utf8), forKey: "route-a")
        let optionalFileURL = await versionOne.fileURL(forKey: "route-a")
        let fileURL = try XCTUnwrap(optionalFileURL)
        try Data("not a property list".utf8).write(to: fileURL, options: .atomic)

        let corruptHit = await versionOne.cachedImageData(forKey: "route-a")
        XCTAssertNil(corruptHit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        await versionOne.insert(Data("valid again".utf8), forKey: "route-a")
        let versionTwo = DriveCardMapDiskCache(
            directory: root,
            configuration: .init(formatVersion: 2),
            now: clock.now
        )
        let mismatchedHit = await versionTwo.cachedImageData(forKey: "route-a")
        XCTAssertNil(mismatchedHit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDiskCachePrunesLeastRecentlyUsedEntriesByCountAndCost() async {
        let countRoot = temporaryDirectory()
        let costRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: countRoot)
            try? FileManager.default.removeItem(at: costRoot)
        }
        let clock = LockedMapCacheClock(Date(timeIntervalSince1970: 1_800_000_000))
        let countCache = DriveCardMapDiskCache(
            directory: countRoot,
            configuration: .init(countLimit: 2),
            now: clock.now
        )

        await countCache.insert(Data(repeating: 1, count: 64), forKey: "oldest")
        clock.advance(by: 1)
        await countCache.insert(Data(repeating: 2, count: 64), forKey: "middle")
        clock.advance(by: 1)
        await countCache.insert(Data(repeating: 3, count: 64), forKey: "newest")

        let oldest = await countCache.cachedImageData(forKey: "oldest")
        let middle = await countCache.cachedImageData(forKey: "middle")
        let newest = await countCache.cachedImageData(forKey: "newest")
        XCTAssertNil(oldest)
        XCTAssertNotNil(middle)
        XCTAssertNotNil(newest)

        let costCache = DriveCardMapDiskCache(
            directory: costRoot,
            configuration: .init(countLimit: 10, totalCostLimit: 6_000),
            now: clock.now
        )
        await costCache.insert(Data(repeating: 4, count: 4_096), forKey: "large-old")
        clock.advance(by: 1)
        await costCache.insert(Data(repeating: 5, count: 4_096), forKey: "large-new")

        let largeOld = await costCache.cachedImageData(forKey: "large-old")
        let largeNew = await costCache.cachedImageData(forKey: "large-new")
        XCTAssertNil(largeOld)
        XCTAssertNotNil(largeNew)
    }

    func testPipelineReplacesStaleImageAndRetainsItAfterFailedRefresh() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = LockedMapCacheClock(now)
        let diskCache = DriveCardMapDiskCache(directory: root, now: clock.now)
        let pipeline = DriveCardMapThumbnailPipeline(
            memoryCache: DriveCardMapThumbnailMemoryCache(),
            diskCache: diskCache,
            workCoordinator: DriveCardMapSnapshotWorkCoordinator(),
            now: clock.now
        )
        let oldImage = testImage(color: .red)
        let newImage = testImage(color: .green)
        let oldData = try XCTUnwrap(oldImage.pngData())
        let newData = try XCTUnwrap(newImage.pngData())
        let staleDate = now.addingTimeInterval(-DriveCardMapCachePolicy.freshLifetime - 1)

        await diskCache.insert(oldData, forKey: "success", renderedAt: staleDate)
        let stale = await pipeline.cachedImage(forKey: "success", displayScale: 1)
        XCTAssertEqual(stale?.freshness, .stale)

        _ = try await pipeline.revalidatedImage(forKey: "success", displayScale: 1) {
            DriveCardMapRenderedImage(image: newImage)
        }
        await pipeline.waitForPendingWrites()
        let replaced = await diskCache.cachedImageData(forKey: "success")
        XCTAssertEqual(replaced?.imageData, newData)
        XCTAssertEqual(replaced?.freshness, .fresh)

        await diskCache.insert(oldData, forKey: "failure", renderedAt: staleDate)
        let failureStale = await pipeline.cachedImage(forKey: "failure", displayScale: 1)
        XCTAssertEqual(failureStale?.freshness, .stale)
        do {
            _ = try await pipeline.revalidatedImage(forKey: "failure", displayScale: 1) {
                throw MapCacheTestError.renderFailed
            }
            XCTFail("Expected refresh failure")
        } catch MapCacheTestError.renderFailed {
            // Expected. The exact stale entry must remain available.
        }
        let retained = await diskCache.cachedImageData(forKey: "failure")
        XCTAssertEqual(retained?.imageData, oldData)
        XCTAssertEqual(retained?.freshness, .stale)
    }

    @MainActor
    func testFreshDiskHitSurvivesPipelineRecreationWithoutRenderingAndResetClearsBothTiers() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockedMapCacheClock(Date(timeIntervalSince1970: 1_800_000_000))
        let rendered = DriveCardMapRenderedImage(image: testImage(color: .blue))
        let callCounter = MapRenderCallCounter()
        let firstDiskCache = DriveCardMapDiskCache(directory: root, now: clock.now)
        let firstLaunch = DriveCardMapThumbnailPipeline(
            memoryCache: DriveCardMapThumbnailMemoryCache(),
            diskCache: firstDiskCache,
            workCoordinator: DriveCardMapSnapshotWorkCoordinator(),
            now: clock.now
        )

        _ = try await firstLaunch.revalidatedImage(forKey: "persisted", displayScale: 2) {
            await callCounter.recordCall()
            return rendered
        }
        await firstLaunch.waitForPendingWrites()
        let callsAfterFirstLaunch = await callCounter.value()
        XCTAssertEqual(callsAfterFirstLaunch, 1)

        let secondDiskCache = DriveCardMapDiskCache(directory: root, now: clock.now)
        let secondLaunch = DriveCardMapThumbnailPipeline(
            memoryCache: DriveCardMapThumbnailMemoryCache(),
            diskCache: secondDiskCache,
            workCoordinator: DriveCardMapSnapshotWorkCoordinator(),
            now: clock.now
        )
        let diskImage = try await secondLaunch.revalidatedImage(forKey: "persisted", displayScale: 2) {
            await callCounter.recordCall()
            return rendered
        }

        let callsAfterSecondLaunch = await callCounter.value()
        XCTAssertEqual(callsAfterSecondLaunch, 1)
        XCTAssertEqual(diskImage.cgImage?.width, rendered.image.cgImage?.width)
        XCTAssertEqual(diskImage.cgImage?.height, rendered.image.cgImage?.height)
        XCTAssertNotNil(secondLaunch.memoryImage(forKey: "persisted"))

        await secondLaunch.removeAll()
        XCTAssertNil(secondLaunch.memoryImage(forKey: "persisted"))
        let diskAfterReset = await secondDiskCache.cachedImageData(forKey: "persisted")
        XCTAssertNil(diskAfterReset)
    }

    @MainActor
    func testClearWinsOverInFlightRenderThatIgnoresCancellation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockedMapCacheClock(Date(timeIntervalSince1970: 1_800_000_000))
        let diskCache = DriveCardMapDiskCache(directory: root, now: clock.now)
        let pipeline = DriveCardMapThumbnailPipeline(
            memoryCache: DriveCardMapThumbnailMemoryCache(),
            diskCache: diskCache,
            workCoordinator: DriveCardMapSnapshotWorkCoordinator(),
            now: clock.now
        )
        let gate = MapResetRaceGate(
            rendered: DriveCardMapRenderedImage(image: testImage(color: .purple))
        )
        let renderTask = Task {
            try await pipeline.revalidatedImage(forKey: "blocked-render", displayScale: 2) {
                await gate.renderIgnoringCancellation()
            }
        }

        await gate.waitUntilStarted()
        await pipeline.removeAll()
        XCTAssertNil(pipeline.memoryImage(forKey: "blocked-render"))
        let diskImmediatelyAfterClear = await diskCache.cachedImageData(forKey: "blocked-render")
        XCTAssertNil(diskImmediatelyAfterClear)

        await gate.release()
        do {
            _ = try await renderTask.value
            XCTFail("A pre-clear render must not complete as current work")
        } catch is CancellationError {
            // Expected even though the renderer itself ignored cancellation.
        }

        XCTAssertNil(pipeline.memoryImage(forKey: "blocked-render"))
        let diskAfterOldRenderFinished = await diskCache.cachedImageData(forKey: "blocked-render")
        XCTAssertNil(diskAfterOldRenderFinished)
    }

    func testSnapshotCoordinatorDeduplicatesAndLimitsConcurrentWorkToTwo() async throws {
        let deduplicatingCoordinator = DriveCardMapSnapshotWorkCoordinator(maximumConcurrentSnapshots: 2)
        let duplicateProbe = MapSnapshotConcurrencyProbe(delayNanoseconds: 80_000_000)
        let duplicateTasks = (0..<5).map { _ in
            Task {
                try await deduplicatingCoordinator.renderedImage(forKey: "same-key") {
                    try await duplicateProbe.render()
                }
            }
        }
        for task in duplicateTasks {
            _ = try await task.value
        }
        let duplicateStats = await duplicateProbe.stats()
        XCTAssertEqual(duplicateStats.callCount, 1)
        XCTAssertEqual(duplicateStats.maximumActive, 1)

        let limitingCoordinator = DriveCardMapSnapshotWorkCoordinator(maximumConcurrentSnapshots: 2)
        let concurrencyProbe = MapSnapshotConcurrencyProbe(delayNanoseconds: 80_000_000)
        let distinctTasks = (0..<6).map { index in
            Task {
                try await limitingCoordinator.renderedImage(forKey: "key-\(index)") {
                    try await concurrencyProbe.render()
                }
            }
        }
        for task in distinctTasks {
            _ = try await task.value
        }
        let concurrencyStats = await concurrencyProbe.stats()
        XCTAssertEqual(concurrencyStats.callCount, 6)
        XCTAssertEqual(concurrencyStats.maximumActive, 2)
    }

    @MainActor
    func testRequestKeyInvalidatesForRoutePixelsScaleAndAppearance() throws {
        let start = Coordinate(latitude: 40.7128, longitude: -74.0060)
        let end = Coordinate(latitude: 40.7306, longitude: -73.9866)
        var trip = makeTrip(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            miles: 3,
            startCoordinate: start,
            endCoordinate: end
        )
        let baseline = try XCTUnwrap(
            DriveCardMapSnapshotRenderer.request(
                for: trip,
                pointSize: CGSize(width: 50, height: 50),
                displayScale: 2,
                colorScheme: .light
            )
        )
        XCTAssertEqual(baseline.rendererVersion, DriveCardMapSnapshotRenderer.rendererVersion)
        XCTAssertTrue(baseline.key.contains("renderer-v\(DriveCardMapSnapshotRenderer.rendererVersion)"))
        XCTAssertTrue(baseline.key.contains("trip=\(trip.id.uuidString)"))
        XCTAssertEqual(baseline.source.mapFingerprint, RouteMapContent(trip: trip)?.mapFingerprint)

        trip.endCoordinate = Coordinate(latitude: 40.7500, longitude: -73.9500)
        let changedRoute = try XCTUnwrap(
            DriveCardMapSnapshotRenderer.request(
                for: trip,
                pointSize: CGSize(width: 50, height: 50),
                displayScale: 2,
                colorScheme: .light
            )
        )
        XCTAssertNotEqual(changedRoute.key, baseline.key)

        let changedPixels = try XCTUnwrap(
            DriveCardMapSnapshotRenderer.request(
                for: trip,
                pointSize: CGSize(width: 51, height: 50),
                displayScale: 2,
                colorScheme: .light
            )
        )
        XCTAssertNotEqual(changedPixels.key, changedRoute.key)

        let samePixelsDifferentScale = try XCTUnwrap(
            DriveCardMapSnapshotRenderer.request(
                for: trip,
                pointSize: CGSize(width: 100.0 / 3.0, height: 100.0 / 3.0),
                displayScale: 3,
                colorScheme: .light
            )
        )
        XCTAssertEqual(samePixelsDifferentScale.pixelWidth, changedRoute.pixelWidth)
        XCTAssertEqual(samePixelsDifferentScale.pixelHeight, changedRoute.pixelHeight)
        XCTAssertNotEqual(samePixelsDifferentScale.key, changedRoute.key)

        let dark = try XCTUnwrap(
            DriveCardMapSnapshotRenderer.request(
                for: trip,
                pointSize: CGSize(width: 50, height: 50),
                displayScale: 2,
                colorScheme: .dark
            )
        )
        XCTAssertNotEqual(dark.key, changedRoute.key)
    }

    @MainActor
    func testImageIsDeliveredBeforeDiskEncodingCompletes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rendered = DriveCardMapRenderedImage(image: testImage(color: .orange))
        let gate = MapResetRaceGate(rendered: rendered)
        let encodingStarted = expectation(description: "encoding started")
        let delivered = expectation(description: "image delivered while encoding is suspended")
        let diskCache = DriveCardMapDiskCache(directory: root)
        let pipeline = DriveCardMapThumbnailPipeline(diskCache: diskCache, encodeImage: { _ in
            encodingStarted.fulfill()
            return await gate.renderIgnoringCancellation().image.pngData()
        })
        let task = Task {
            let image = try await pipeline.revalidatedImage(forKey: "immediate", displayScale: 1) { rendered }
            delivered.fulfill()
            return image
        }
        await fulfillment(of: [encodingStarted, delivered], timeout: 3)
        // The encoder fulfills its expectation before entering the actor.
        // Wait for the continuation before releasing this one-shot gate.
        await gate.waitUntilStarted()
        XCTAssertNotNil(pipeline.memoryImage(forKey: "immediate"))
        let beforeEncodingFinished = await diskCache.cachedImageData(forKey: "immediate")
        XCTAssertNil(beforeEncodingFinished)
        await gate.release()
        _ = try await task.value
        await pipeline.waitForPendingWrites()
        let persisted = await diskCache.cachedImageData(forKey: "immediate")
        XCTAssertEqual(persisted?.imageData, rendered.image.pngData())
    }

    @MainActor
    func testResetRejectsDelayedDiskWriteAndAllowsNewGenerationToPersist() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rendered = DriveCardMapRenderedImage(image: testImage(color: .blue))
        let gate = MapResetRaceGate(rendered: rendered)
        let counter = MapRenderCallCounter()
        let diskCache = DriveCardMapDiskCache(directory: root)
        let pipeline = DriveCardMapThumbnailPipeline(diskCache: diskCache, encodeImage: { image in
            await counter.recordCall()
            if await counter.value() == 1 {
                return await gate.renderIgnoringCancellation().image.pngData()
            }
            return image.image.pngData()
        })
        _ = try await pipeline.revalidatedImage(forKey: "old", displayScale: 1) { rendered }
        await gate.waitUntilStarted()
        await pipeline.removeAll()
        _ = try await pipeline.revalidatedImage(forKey: "new", displayScale: 1) { rendered }
        await gate.release()
        await pipeline.waitForPendingWrites()
        let oldDisk = await diskCache.cachedImageData(forKey: "old")
        let newDisk = await diskCache.cachedImageData(forKey: "new")
        XCTAssertNil(oldDisk)
        XCTAssertNil(pipeline.memoryImage(forKey: "old"))
        XCTAssertNotNil(newDisk)
    }

    func testVisibleRequestRunsAheadOfQueuedPrefetch() async throws {
        let coordinator = DriveCardMapSnapshotWorkCoordinator(maximumConcurrentSnapshots: 1)
        let gate = MapResetRaceGate(rendered: DriveCardMapRenderedImage(image: UIImage()))
        let order = MapWorkOrder()
        let first = Task {
            try await coordinator.renderedImage(forKey: "first", priority: .prefetch) {
                await gate.renderIgnoringCancellation()
            }
        }
        await gate.waitUntilStarted()
        let speculative = Task {
            try await coordinator.renderedImage(forKey: "speculative", priority: .prefetch) {
                await order.render("speculative")
            }
        }
        await waitForRequests(2, on: coordinator)
        let visible = Task {
            try await coordinator.renderedImage(forKey: "visible") { await order.render("visible") }
        }
        await waitForRequests(3, on: coordinator)
        await gate.release()
        _ = try await first.value
        _ = try await visible.value
        _ = try await speculative.value
        let started = await order.values()
        XCTAssertEqual(started, ["visible", "speculative"])
    }

    func testOnlyOnePrefetchRunsAndVisibleMapUsesReservedCapacity() async throws {
        let coordinator = DriveCardMapSnapshotWorkCoordinator()
        let gate = MapResetRaceGate(rendered: DriveCardMapRenderedImage(image: UIImage()))
        let order = MapWorkOrder()
        let first = Task {
            try await coordinator.renderedImage(forKey: "first", priority: .prefetch) {
                await gate.renderIgnoringCancellation()
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            try await coordinator.renderedImage(forKey: "second", priority: .prefetch) {
                await order.render("second")
            }
        }
        await waitForRequests(2, on: coordinator)
        let visibleCompleted = expectation(description: "visible map completes while prefetch is held")
        let visible = Task {
            let image = try await coordinator.renderedImage(forKey: "visible") { await order.render("visible") }
            visibleCompleted.fulfill()
            return image
        }
        await fulfillment(of: [visibleCompleted], timeout: 3)
        let beforeRelease = await order.values()
        XCTAssertEqual(beforeRelease, ["visible"])
        await gate.release()
        _ = try await first.value
        _ = try await second.value
        _ = try await visible.value
    }

    func testCancelledQueuedPrefetchNeverRenders() async throws {
        let coordinator = DriveCardMapSnapshotWorkCoordinator(maximumConcurrentSnapshots: 1)
        let gate = MapResetRaceGate(rendered: DriveCardMapRenderedImage(image: UIImage()))
        let order = MapWorkOrder()
        let first = Task {
            try await coordinator.renderedImage(forKey: "first") { await gate.renderIgnoringCancellation() }
        }
        await gate.waitUntilStarted()
        let obsolete = Task {
            try await coordinator.renderedImage(forKey: "obsolete", priority: .prefetch) { await order.render("obsolete") }
        }
        await waitForRequests(2, on: coordinator)
        obsolete.cancel()
        do {
            _ = try await obsolete.value
            XCTFail("A cancelled waiter must stop waiting")
        } catch is CancellationError { }
        await gate.release()
        _ = try await first.value
        let started = await order.values()
        XCTAssertTrue(started.isEmpty)
    }

    func testCancellingOneConsumerPreservesSharedRenderForAnother() async throws {
        let coordinator = DriveCardMapSnapshotWorkCoordinator()
        let gate = MapResetRaceGate(rendered: DriveCardMapRenderedImage(image: UIImage()))
        let first = Task {
            try await coordinator.renderedImage(forKey: "shared", priority: .prefetch) {
                await gate.renderIgnoringCancellation()
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            try await coordinator.renderedImage(forKey: "shared") {
                XCTFail("A visible consumer must join the pending prefetch")
                return DriveCardMapRenderedImage(image: UIImage())
            }
        }
        await waitForRequests(2, on: coordinator)
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Cancelled consumer should return promptly")
        } catch is CancellationError { }
        await gate.release()
        _ = try await second.value
    }

    @MainActor
    func testDetailRequestsReusePrefetchedContentAndInvalidateForRouteSizeAndTheme() throws {
        let trip = makeTrip(startDate: Date(), miles: 10,
                            startCoordinate: Coordinate(latitude: 40.71, longitude: -74.01),
                            endCoordinate: Coordinate(latitude: 40.75, longitude: -73.98))
        let content = try XCTUnwrap(RouteMapContent(trip: trip))
        func request(_ source: RouteMapContent, width: CGFloat = 320, dark: Bool = false,
                     presentation: DriveCardMapPresentation = .detail) throws -> DriveCardMapSnapshotRequest {
            try XCTUnwrap(DriveCardMapSnapshotRenderer.request(
                for: source, identityToken: "route-detail", pointSize: CGSize(width: width, height: 180),
                displayScale: 3, colorScheme: dark ? .dark : .light, presentation: presentation
            ))
        }
        let prefetched = try request(content)
        let displayed = try request(XCTUnwrap(RouteMapContent(trip: trip)))
        XCTAssertEqual(prefetched.key, displayed.key)
        XCTAssertNotEqual(prefetched.key, try request(content, width: 500).key)
        XCTAssertNotEqual(prefetched.key, try request(content, dark: true).key)
        XCTAssertNotEqual(prefetched.key, try request(content, presentation: .thumbnail).key)
        XCTAssertNotEqual(prefetched.key, try request(content, presentation: .hero).key)
        var edited = trip
        edited.endCoordinate = Coordinate(latitude: 42.36, longitude: -71.06)
        XCTAssertNotEqual(prefetched.key, try request(XCTUnwrap(RouteMapContent(trip: edited))).key)
    }

    func testDetailViewportFitsRouteInsidePinAndButtonMarginsAtDifferentWidths() throws {
        let content = try XCTUnwrap(RouteMapContent(
            origin: Coordinate(latitude: 40.71, longitude: -74.01),
            destination: Coordinate(latitude: 42.36, longitude: -71.06)
        ))
        for width: CGFloat in [280, 400, 800] {
            let size = CGSize(width: width, height: 180)
            let rect = try XCTUnwrap(DriveCardMapSnapshotRenderer.detailMapRect(for: content, size: size))
            XCTAssertEqual(rect.width / rect.height, width / 180, accuracy: 0.0001)
            for coordinate in content.coordinates {
                let point = MKMapPoint(coordinate)
                let x = (point.x - rect.minX) / rect.width * width
                let y = (point.y - rect.minY) / rect.height * 180
                XCTAssertGreaterThanOrEqual(x, 24)
                XCTAssertLessThanOrEqual(x, width - 24)
                XCTAssertGreaterThanOrEqual(y, 50)
                XCTAssertLessThanOrEqual(y, 180 - 44)
            }
        }
    }

    func testHeroRouteStaysBetweenToolbarAndSummary() throws {
        let content = try XCTUnwrap(RouteMapContent(
            origin: Coordinate(latitude: 40.71, longitude: -74.01),
            destination: Coordinate(latitude: 42.36, longitude: -71.06)
        ))
        for width: CGFloat in [280, 400, 800] {
            let size = CGSize(width: width, height: TripHeroMapLayout.imageHeight)
            let rect = try XCTUnwrap(DriveCardMapSnapshotRenderer.detailMapRect(
                for: content, size: size, padding: TripHeroMapLayout.viewportPadding
            ))
            for coordinate in content.coordinates {
                let point = MKMapPoint(coordinate)
                let x = (point.x - rect.minX) / rect.width * width
                let y = (point.y - rect.minY) / rect.height * size.height
                XCTAssertGreaterThanOrEqual(x, 24)
                XCTAssertLessThanOrEqual(x, width - 24)
                XCTAssertGreaterThanOrEqual(y, 110, "Keep pins below the toolbar")
                XCTAssertLessThanOrEqual(y, TripHeroMapLayout.clearHeight - 48,
                                        "Keep the route above the summary fade and map control")
            }
        }
    }

    @MainActor
    func testDetailEndpointMarkersHaveVisibleArtworkWithoutALiveMap() throws {
        let content = try XCTUnwrap(RouteMapContent(
            origin: Coordinate(latitude: 40.71, longitude: -74.01),
            destination: Coordinate(latitude: 40.75, longitude: -73.98)
        ))
        let markers = DriveCardMapSnapshotRenderer.detailMarkers(
            for: content, traits: UITraitCollection(userInterfaceStyle: .light)
        )
        XCTAssertEqual(markers.count, 2)
        for marker in markers {
            let image = try XCTUnwrap(marker.image.cgImage)
            let width = image.width
            let height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let visiblePixels = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 127 }.count
            XCTAssertGreaterThan(visiblePixels, 100, "A transparent marker loses the route endpoints")
            let attachment = XCTAttachment(image: marker.image)
            attachment.name = "Detail endpoint marker"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testAdvanceRenderingFollowsCurrentOrderAndStaysBoundedAtItsEdges() {
        let ids = (0..<8).map { _ in UUID() }
        XCTAssertEqual(DriveMapPrefetchPolicy.neighbors(of: ids[3], in: ids), [ids[4], ids[2], ids[5]])
        XCTAssertEqual(DriveMapPrefetchPolicy.neighbors(of: ids[0], in: ids), [ids[1], ids[2]])
        XCTAssertEqual(DriveMapPrefetchPolicy.neighbors(of: ids[7], in: ids), [ids[6]])
        XCTAssertTrue(DriveMapPrefetchPolicy.neighbors(of: UUID(), in: ids).isEmpty)
    }

    func testCancelledSnapshotsReleaseBothSlotsForMergedHeroAndLegMaps() async throws {
        let coordinator = DriveCardMapSnapshotWorkCoordinator(maximumConcurrentSnapshots: 2)
        let snapshots = (0..<2).map { _ in SilentMapSnapshotter() }
        let abandoned = snapshots.enumerated().map { index, snapshotter in
            Task {
                try await coordinator.renderedImage(forKey: "before-merge-\(index)") {
                    _ = try await DriveCardMapSnapshotOperation(snapshotter: snapshotter).start()
                    return DriveCardMapRenderedImage(image: UIImage())
                }
            }
        }
        await fulfillment(of: snapshots.map(\.started), timeout: 3)

        let rendered = expectation(description: "merged hero and all three leg maps rendered")
        rendered.expectedFulfillmentCount = 4
        let mergedMaps = (0..<4).map { index in
            Task {
                _ = try await coordinator.renderedImage(forKey: "merged-map-\(index)") {
                    DriveCardMapRenderedImage(image: UIImage())
                }
                rendered.fulfill()
            }
        }
        await waitForRequests(6, on: coordinator)
        for task in abandoned { task.cancel() }

        // The fake deliberately never calls completion from cancel(), matching
        // the failure mode that used to occupy both permits indefinitely.
        await fulfillment(of: snapshots.map(\.cancelled) + [rendered], timeout: 3)
        for snapshotter in snapshots { snapshotter.fail() }
        for task in abandoned {
            do { _ = try await task.value; XCTFail("Cancelled request succeeded") }
            catch is CancellationError { }
        }
        for task in mergedMaps { try await task.value }
        let outstanding = await coordinator.outstandingRequestCount
        XCTAssertEqual(outstanding, 0)
    }

    func testSnapshotCancellationFinishesWithoutCallbackAndIgnoresLateCallbacks() async {
        let snapshotter = SilentMapSnapshotter()
        let operation = DriveCardMapSnapshotOperation(snapshotter: snapshotter)
        let finished = expectation(description: "cancelled operation finished")
        let task = Task {
            do { _ = try await operation.start(); XCTFail("Cancelled snapshot succeeded") }
            catch is CancellationError { }
            catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        await fulfillment(of: [snapshotter.started], timeout: 3)
        task.cancel()
        await fulfillment(of: [snapshotter.cancelled, finished], timeout: 3)
        snapshotter.fail()
        snapshotter.fail()
        await task.value
        // A second start reads the terminal result after the queued callbacks;
        // neither a late failure nor a second callback may replace cancellation.
        do { _ = try await operation.start(); XCTFail("Cancellation was lost") }
        catch is CancellationError { }
        catch { XCTFail("Late callback replaced cancellation: \(error)") }
    }

    func testStalledSnapshotTimesOutAndCancelsUnderlyingWork() async {
        let snapshotter = SilentMapSnapshotter()
        let operation = DriveCardMapSnapshotOperation(snapshotter: snapshotter, timeout: 0.05)
        let finished = expectation(description: "stalled operation timed out")
        let task = Task {
            do { _ = try await operation.start(); XCTFail("Stalled snapshot succeeded") }
            catch DriveCardMapSnapshotOperation.SnapshotError.timedOut { }
            catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        await fulfillment(of: [snapshotter.started, snapshotter.cancelled, finished], timeout: 3)
        snapshotter.fail()
        await task.value
    }

    func testSnapshotCancelledBeforeStartDoesNotStartMapKit() async {
        let snapshotter = SilentMapSnapshotter()
        snapshotter.started.isInverted = true
        let operation = DriveCardMapSnapshotOperation(snapshotter: snapshotter)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await operation.start(); XCTFail("Cancelled snapshot succeeded") }
            catch is CancellationError { }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        await task.value
        await fulfillment(of: [snapshotter.started], timeout: 0.1)
    }

    private func waitForRequests(_ count: Int, on coordinator: DriveCardMapSnapshotWorkCoordinator) async {
        for _ in 0..<1_000 {
            if await coordinator.outstandingRequestCount == count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Requests did not reach the coordinator")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DriveCardMapCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func testImage(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}

private enum MapCacheTestError: Error {
    case renderFailed
}

private final class SilentMapSnapshotter: DriveCardMapSnapshotting, @unchecked Sendable {
    let started = XCTestExpectation(description: "snapshot started")
    let cancelled = XCTestExpectation(description: "snapshot cancelled without callback")
    private let lock = NSLock()
    private var completion: (@Sendable (Result<DriveCardMapSnapshotOperation.CompletedSnapshot, Error>) -> Void)?

    func start(completion: @escaping @Sendable (Result<DriveCardMapSnapshotOperation.CompletedSnapshot, Error>) -> Void) {
        lock.lock()
        self.completion = completion
        lock.unlock()
        started.fulfill()
    }

    func cancel() { cancelled.fulfill() }

    func fail() {
        lock.lock()
        let callback = completion
        lock.unlock()
        callback?(.failure(MapCacheTestError.renderFailed))
    }
}

private final class LockedMapCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private actor MapSnapshotConcurrencyProbe {
    private let delayNanoseconds: UInt64
    private var active = 0
    private var maximumActive = 0
    private var callCount = 0

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func render() async throws -> DriveCardMapRenderedImage {
        active += 1
        callCount += 1
        maximumActive = max(maximumActive, active)
        do {
            try await Task.sleep(nanoseconds: delayNanoseconds)
            active -= 1
            return DriveCardMapRenderedImage(image: UIImage())
        } catch {
            active -= 1
            throw error
        }
    }

    func stats() -> (callCount: Int, maximumActive: Int) {
        (callCount, maximumActive)
    }
}

private actor MapRenderCallCounter {
    private var callCount = 0

    func recordCall() {
        callCount += 1
    }

    func value() -> Int {
        callCount
    }
}

private actor MapResetRaceGate {
    private let rendered: DriveCardMapRenderedImage
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(rendered: DriveCardMapRenderedImage) {
        self.rendered = rendered
    }

    func renderIgnoringCancellation() async -> DriveCardMapRenderedImage {
        started = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return rendered
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor MapWorkOrder {
    private var started: [String] = []
    func render(_ key: String) -> DriveCardMapRenderedImage {
        started.append(key)
        return DriveCardMapRenderedImage(image: UIImage())
    }
    func values() -> [String] { started }
}

@MainActor
extension DriveCardMapThumbnailCacheTests {
    private func warmingContext(ids: [UUID], eligible: Bool = true) -> DriveMapWarmingCoordinator.Context {
        .init(mailboxIDs: ids, thumbnailSize: 70, heroWidth: 393, displayScale: 3,
              colorScheme: .light, isEligible: eligible)
    }

    private func warmingTrip(index: Int) -> TripSummary {
        makeTrip(startDate: Date(timeIntervalSince1970: Double(index) * 86400), miles: 10,
                 startCoordinate: Coordinate(latitude: 40.71, longitude: -74.01),
                 endCoordinate: Coordinate(latitude: 40.75 + Double(index) / 10000, longitude: -73.98))
    }

    func testWarmingCoversLatestFiftyPlusMailboxWithAllThumbnailsBeforeHeroes() async {
        let trips = (0..<55).map(warmingTrip)
        var requests: [DriveCardMapSnapshotRequest] = []
        let worker = DriveMapWarmingCoordinator(delay: .zero, monitorsConnectivity: false, warm: { request, _ in
            requests.append(request)
            return true
        })
        worker.updateTrips(trips)
        let context = warmingContext(ids: [trips[0].id, trips[1].id, trips[54].id])
        worker.update(sceneID: UUID(), context: context)
        await worker.waitForCurrentPass()
        XCTAssertEqual(requests.count, 104)
        XCTAssertTrue(requests.prefix(52).allSatisfy { $0.presentation == .thumbnail })
        XCTAssertTrue(requests.suffix(52).allSatisfy { $0.presentation == .hero })
        XCTAssertEqual(requests[0].key, DriveMapWarmingCoordinator.request(
            trip: trips[0], context: context, presentation: .thumbnail)?.key)
        XCTAssertFalse(requests.contains { $0.key.contains("leg=") })
        XCTAssertEqual(Set(requests.map(\.key)).count, requests.count)
    }

    func testWarmingWaitsForEligibilityAndKnownHeroWidth() async {
        let trip = warmingTrip(index: 1)
        var requests: [DriveCardMapSnapshotRequest] = []
        let worker = DriveMapWarmingCoordinator(delay: .zero, monitorsConnectivity: false, warm: { request, _ in
            requests.append(request); return true
        })
        let scene = UUID()
        worker.updateTrips([trip])
        var context = warmingContext(ids: [trip.id], eligible: false)
        worker.update(sceneID: scene, context: context)
        await worker.waitForCurrentPass()
        XCTAssertTrue(requests.isEmpty)
        context.isEligible = true
        context.heroWidth = 0
        worker.update(sceneID: scene, context: context)
        await worker.waitForCurrentPass()
        XCTAssertEqual(requests.map(\.presentation), [.thumbnail])
        context.heroWidth = 500
        worker.update(sceneID: scene, context: context)
        await worker.waitForCurrentPass()
        XCTAssertEqual(requests.last?.pointSize.width, 500)
    }

    func testWarmingStopsAtCapacityAndProtectsEarlierImages() async {
        let trips = (0..<3).map(warmingTrip)
        var protectedCounts: [Int] = []
        let worker = DriveMapWarmingCoordinator(delay: .zero, monitorsConnectivity: false, warm: { _, keys in
            protectedCounts.append(keys.count)
            return protectedCounts.count < 3
        })
        worker.updateTrips(trips)
        worker.update(sceneID: UUID(), context: warmingContext(ids: trips.map(\.id)))
        await worker.waitForCurrentPass()
        XCTAssertEqual(protectedCounts, [0, 1, 2])
    }

    func testWarmingFailuresContinueAndRespectRetryCooldown() async {
        let trip = warmingTrip(index: 1)
        let clock = LockedMapCacheClock(Date())
        var attempts = 0
        let worker = DriveMapWarmingCoordinator(delay: .zero, monitorsConnectivity: false, now: clock.now, warm: { _, _ in
            attempts += 1
            throw URLError(.notConnectedToInternet)
        })
        worker.updateTrips([trip])
        worker.update(sceneID: UUID(), context: warmingContext(ids: [trip.id]))
        await worker.waitForCurrentPass()
        XCTAssertEqual(attempts, 2)
        worker.retryAfterConnectivityRecovery()
        await worker.waitForCurrentPass()
        XCTAssertEqual(attempts, 2)
        clock.advance(by: 31)
        worker.retryAfterConnectivityRecovery()
        await worker.waitForCurrentPass()
        XCTAssertEqual(attempts, 4)
    }

    func testWarmingCancellationAndResetDoNotAdvanceAbandonedPass() async {
        let trip = warmingTrip(index: 1)
        var started = false
        var cancelled = false
        let worker = DriveMapWarmingCoordinator(delay: .zero, monitorsConnectivity: false, warm: { _, _ in
            started = true
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled = true; throw error }
            return true
        })
        worker.updateTrips([trip])
        let scene = UUID()
        worker.update(sceneID: scene, context: warmingContext(ids: [trip.id]))
        for _ in 0..<1000 where !started { await Task.yield() }
        XCTAssertTrue(started)
        worker.reset()
        for _ in 0..<1000 where !cancelled { await Task.yield() }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(worker.completedCount, 0)
    }

    func testWarmingUsesExactDisplayedHeroAndThumbnailKeysAcrossLayouts() throws {
        let trip = warmingTrip(index: 1)
        let content = try XCTUnwrap(RouteMapContent(trip: trip))
        for width: CGFloat in [320, 393, 700] {
            for size: CGFloat in [48, 70, 96] {
                for scheme in [ColorScheme.light, .dark] {
                    var context = warmingContext(ids: [trip.id])
                    context.heroWidth = width
                    context.thumbnailSize = size
                    context.colorScheme = scheme
                    let hero = DriveMapWarmingCoordinator.request(trip: trip, context: context, presentation: .hero)
                    let displayedHero = DriveCardMapSnapshotRenderer.request(for: content,
                        identityToken: TripHeroMapLayout.identityToken,
                        pointSize: CGSize(width: width, height: TripHeroMapLayout.imageHeight),
                        displayScale: 3, colorScheme: scheme, presentation: .hero)
                    XCTAssertEqual(hero?.key, displayedHero?.key)
                    XCTAssertEqual(DriveMapWarmingCoordinator.request(trip: trip, context: context, presentation: .thumbnail)?.key,
                        DriveCardMapSnapshotRenderer.request(for: trip, pointSize: CGSize(width: size, height: size),
                            displayScale: 3, colorScheme: scheme)?.key)
                }
            }
        }
    }

    func testSpeculativeDiskAdmissionPreservesVisibleAndEarlierMaps() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = DriveCardMapDiskCache.Configuration()
        config.countLimit = 2
        let cache = DriveCardMapDiskCache(directory: root, configuration: config)
        let bytes = Data(repeating: 1, count: 512)
        await cache.insert(bytes, forKey: "visible")
        await cache.protectVisible("visible")
        await cache.insert(bytes, forKey: "old")
        let admitted = await cache.insertSpeculative(bytes, forKey: "first", protecting: [], expectedGeneration: 0)
        XCTAssertTrue(admitted)
        let rejected = await cache.insertSpeculative(bytes, forKey: "second", protecting: ["first"], expectedGeneration: 0)
        XCTAssertFalse(rejected)
        let visible = await cache.isFresh(forKey: "visible")
        let first = await cache.isFresh(forKey: "first")
        let old = await cache.isFresh(forKey: "old")
        XCTAssertTrue(visible)
        XCTAssertTrue(first)
        XCTAssertFalse(old)
    }

    func testWarmPersistsWithoutFillingMemoryAndVisibleRequestReusesDisk() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = DriveCardMapThumbnailPipeline(diskCache: DriveCardMapDiskCache(directory: root))
        let rendered = DriveCardMapRenderedImage(image: testImage(color: .blue))
        let admitted = try await pipeline.warm(forKey: "warm", protecting: []) { rendered }
        XCTAssertTrue(admitted)
        XCTAssertNil(pipeline.memoryImage(forKey: "warm"))
        let image = try await pipeline.revalidatedImage(forKey: "warm", displayScale: 1) {
            XCTFail("Warm disk hit must not start another snapshot")
            return rendered
        }
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertNotNil(pipeline.memoryImage(forKey: "warm"))
    }

    func testPreparedDiskMapIsPresentInFirstRenderBeforeViewTaskRuns() async throws {
        let content = try XCTUnwrap(RouteMapContent(
            origin: Coordinate(latitude: 40.71, longitude: -74.01),
            destination: Coordinate(latitude: 42.36, longitude: -71.06)
        ))
        let identity = "navigation-first-frame-\(UUID())"
        let size = CGSize(width: 402, height: TripHeroMapLayout.imageHeight)
        let request = try XCTUnwrap(DriveCardMapSnapshotRenderer.request(
            for: content, identityToken: identity, pointSize: size,
            displayScale: 3, colorScheme: .light, presentation: .hero
        ))
        let disk = DriveCardMapDiskCache()
        await disk.insert(try XCTUnwrap(testImage(color: .green).pngData()), forKey: request.key)
        XCTAssertNil(DriveCardMapSnapshotRenderer.cachedImage(for: request.key))
        func firstFrame() throws -> UIImage {
            // ImageRenderer does not mount the view or run its .task. This is
            // the map the navigation transition can use on the first layout.
            let renderer = ImageRenderer(content: DriveCardMapThumbnail(
                content: content, identityToken: identity, routeColor: .blue,
                minimumPointSize: CGSize(width: 1, height: size.height), presentation: .hero
            )
            .frame(width: size.width, height: size.height)
            .environment(\.displayScale, 3)
            .environment(\.colorScheme, .light))
            renderer.scale = 3
            return try XCTUnwrap(renderer.uiImage)
        }
        let unprepared = try firstFrame()
        let prepared = await DriveCardMapSnapshotRenderer.prepareCachedImage(for: request)
        XCTAssertNotNil(prepared)
        XCTAssertNotNil(DriveCardMapSnapshotRenderer.cachedImage(for: request.key))
        let ready = try firstFrame()
        XCTAssertNotEqual(unprepared.pngData(), ready.pngData())
        let pixel = try XCTUnwrap(ready.cgImage?.cropping(to: CGRect(x: 603, y: 750, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertLessThan(rgba[0], 20)
        XCTAssertGreaterThan(rgba[1], 235, "The initial frame must contain the cached map, not the loading fill")
        XCTAssertLessThan(rgba[2], 20)
        await disk.removeValue(forKey: request.key, expectedGeneration: 0)
    }

    func testNavigationPreparationDoesNotRenderMissingMap() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = DriveCardMapThumbnailPipeline(diskCache: DriveCardMapDiskCache(directory: root))
        let navigation = TripMapNavigationPreparation()
        var opened = false
        navigation.open {
            let hit = await pipeline.prepareCachedImage(forKey: "missing", displayScale: 3)
            XCTAssertNil(hit)
        } then: {
            opened = true
        }
        await navigation.waitForCurrentPreparation()
        XCTAssertTrue(opened, "A cache miss must proceed without waiting for MapKit")
        XCTAssertFalse(navigation.isPreparing)
    }

    func testPendingMapPreparationCannotOverrideNewNavigationOrCancellation() async {
        for cancelOnly in [false, true] {
            let navigation = TripMapNavigationPreparation()
            let gate = MapResetRaceGate(rendered: .init(image: testImage(color: .blue)))
            let oldLoadFinished = expectation(description: "old cache read finished")
            var opened: [String] = []
            navigation.open {
                _ = await gate.renderIgnoringCancellation()
                oldLoadFinished.fulfill()
            } then: { opened.append("old") }
            await gate.waitUntilStarted()
            XCTAssertTrue(opened.isEmpty, "The destination must wait for cache preparation")
            XCTAssertTrue(navigation.isPreparing, "A pending user selection must suppress the launch redirect")
            if cancelOnly {
                navigation.cancel()
            } else {
                navigation.open(preparing: {}, then: { opened.append("new") })
                await navigation.waitForCurrentPreparation()
            }
            await gate.release()
            await fulfillment(of: [oldLoadFinished], timeout: 2)
            XCTAssertEqual(opened, cancelOnly ? [] : ["new"])
            XCTAssertFalse(navigation.isPreparing)
        }
    }
    func testVisibleRequestUsesWarmImageWhileDiskEncodingIsSuspended() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rendered = DriveCardMapRenderedImage(image: testImage(color: .orange))
        let gate = MapResetRaceGate(rendered: rendered)
        let encoding = expectation(description: "speculative encoding started")
        let memory = DriveCardMapThumbnailMemoryCache()
        memory.insert(testImage(color: .red), forKey: "encoding", renderedAt: Date().addingTimeInterval(-25 * 3600))
        let pipeline = DriveCardMapThumbnailPipeline(memoryCache: memory, diskCache: DriveCardMapDiskCache(directory: root), encodeImage: { _ in
            encoding.fulfill()
            return await gate.renderIgnoringCancellation().image.pngData()
        })
        let warmTask = Task { try await pipeline.warm(forKey: "encoding", protecting: []) { rendered } }
        await fulfillment(of: [encoding], timeout: 3)
        let visible = try await pipeline.revalidatedImage(forKey: "encoding", displayScale: 1) {
            XCTFail("Visible consumer must reuse the image pending disk encoding")
            return rendered
        }
        XCTAssertGreaterThan(visible.size.width, 0)
        await gate.release()
        let admitted = try await warmTask.value
        XCTAssertTrue(admitted)
    }

    func testMailboxContextRecomputesFiltersAndOrderFromUpdatedTrips() {
        var first = warmingTrip(index: 1)
        var second = warmingTrip(index: 2)
        first.classification = .business
        second.classification = .personal
        let context = DriveMapMailboxContext(scope: .allTrips, sort: .newestFirst, filter: .all,
            vehicleFilter: .all, searchText: "unique-destination")
        first.endAddress = "unique-destination"
        XCTAssertEqual(context.order(in: [first, second]), [first.id])
        second.endAddress = "unique-destination"
        XCTAssertEqual(context.order(in: [first, second]), [second.id, first.id])
        first.endAddress = "changed"
        XCTAssertEqual(context.order(in: [first, second]), [second.id])
    }

    func testWarmingRouteEditChangesKeysAndDeletedTripDropsOut() async {
        var trip = warmingTrip(index: 1)
        var keys: [String] = []
        let worker = DriveMapWarmingCoordinator(delay: .zero, monitorsConnectivity: false, warm: { request, _ in
            keys.append(request.key); return true
        })
        worker.updateTrips([trip])
        worker.update(sceneID: UUID(), context: warmingContext(ids: [trip.id]))
        await worker.waitForCurrentPass()
        let original = keys
        keys = []
        trip.endCoordinate = Coordinate(latitude: 42.36, longitude: -71.06)
        worker.updateTrips([trip])
        await worker.waitForCurrentPass()
        XCTAssertEqual(keys.count, 2)
        XCTAssertTrue(Set(keys).isDisjoint(with: original))
        keys = []
        worker.updateTrips([])
        await worker.waitForCurrentPass()
        XCTAssertTrue(keys.isEmpty)
    }

}
