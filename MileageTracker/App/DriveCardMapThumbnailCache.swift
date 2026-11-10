import CryptoKit
import Foundation
import UIKit

enum DriveCardMapCachePolicy {
    static let freshLifetime: TimeInterval = 24 * 60 * 60
    static let retentionLifetime: TimeInterval = 30 * 24 * 60 * 60
    static let memoryCountLimit = 160
    static let memoryCostLimit = 48 * 1_024 * 1_024
    static let diskCountLimit = 400
    static let diskCostLimit = 128 * 1_024 * 1_024
    static let diskFormatVersion = 1
    static let maximumConcurrentSnapshots = 2
}

enum DriveCardMapCacheFreshness: Sendable, Equatable {
    case fresh
    case stale
}

enum DriveCardMapCacheKey {
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct DriveCardMapCachedImage: @unchecked Sendable {
    var image: UIImage
    var renderedAt: Date
    var freshness: DriveCardMapCacheFreshness
}

struct DriveCardMapRenderedImage: @unchecked Sendable {
    var image: UIImage
}

final class DriveCardMapThumbnailMemoryCache: @unchecked Sendable {
    private final class Entry {
        let image: UIImage
        let renderedAt: Date

        init(image: UIImage, renderedAt: Date) {
            self.image = image
            self.renderedAt = renderedAt
        }
    }

    private let cache = NSCache<NSString, Entry>()

    init(
        countLimit: Int = DriveCardMapCachePolicy.memoryCountLimit,
        totalCostLimit: Int = DriveCardMapCachePolicy.memoryCostLimit
    ) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func cachedImage(forKey key: String, now: Date) -> DriveCardMapCachedImage? {
        guard let entry = cache.object(forKey: key as NSString) else { return nil }
        return DriveCardMapCachedImage(
            image: entry.image,
            renderedAt: entry.renderedAt,
            freshness: Self.freshness(renderedAt: entry.renderedAt, now: now)
        )
    }

    func insert(_ image: UIImage, forKey key: String, renderedAt: Date) {
        let pixelCount = image.size.width * image.size.height * image.scale * image.scale
        let cost = Int(pixelCount * 4)
        cache.setObject(
            Entry(image: image, renderedAt: renderedAt),
            forKey: key as NSString,
            cost: cost
        )
    }

    func removeAllObjects() {
        cache.removeAllObjects()
    }

    private static func freshness(renderedAt: Date, now: Date) -> DriveCardMapCacheFreshness {
        now.timeIntervalSince(renderedAt) <= DriveCardMapCachePolicy.freshLifetime ? .fresh : .stale
    }
}

struct DriveCardMapDiskCacheHit: Sendable, Equatable {
    var imageData: Data
    var renderedAt: Date
    var freshness: DriveCardMapCacheFreshness
}

actor DriveCardMapDiskCache {
    struct Configuration: Sendable {
        var formatVersion = DriveCardMapCachePolicy.diskFormatVersion
        var freshLifetime = DriveCardMapCachePolicy.freshLifetime
        var retentionLifetime = DriveCardMapCachePolicy.retentionLifetime
        var countLimit = DriveCardMapCachePolicy.diskCountLimit
        var totalCostLimit = DriveCardMapCachePolicy.diskCostLimit
    }

    private struct Record: Codable {
        var formatVersion: Int
        var key: String
        var renderedAt: Date
        var imageData: Data
    }

    private struct StoredRecord {
        var url: URL
        var record: Record
        var lastAccessedAt: Date
        var cost: Int
    }

    private let explicitDirectory: URL?
    private let testSuffix: String?
    private let fileManager: FileManager
    private let configuration: Configuration
    private let nowProvider: @Sendable () -> Date
    private var writeGeneration: UInt64 = 0
    private var visibleKeys: [String] = []

    init(
        directory: URL? = nil,
        testSuffix: String? = nil,
        fileManager: FileManager = .default,
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        explicitDirectory = directory
        self.testSuffix = testSuffix
        self.fileManager = fileManager
        self.configuration = configuration
        nowProvider = now
    }

    func cachedImageData(forKey key: String) -> DriveCardMapDiskCacheHit? {
        let now = nowProvider()
        guard let directory = try? preparedDirectory() else { return nil }
        let url = cacheFileURL(forKey: key, in: directory)

        guard let record = decodeRecord(at: url),
              record.formatVersion == configuration.formatVersion,
              record.key == key,
              !record.imageData.isEmpty else {
            try? fileManager.removeItem(at: url)
            return nil
        }

        let age = max(0, now.timeIntervalSince(record.renderedAt))
        guard age <= configuration.retentionLifetime else {
            try? fileManager.removeItem(at: url)
            return nil
        }

        applyFileAttributes(to: url, accessedAt: now)
        return DriveCardMapDiskCacheHit(
            imageData: record.imageData,
            renderedAt: record.renderedAt,
            freshness: age <= configuration.freshLifetime ? .fresh : .stale
        )
    }

    func insert(
        _ imageData: Data,
        forKey key: String,
        renderedAt: Date? = nil,
        expectedGeneration: UInt64? = nil
    ) {
        guard expectedGeneration == nil || expectedGeneration == writeGeneration,
              !imageData.isEmpty,
              configuration.countLimit > 0,
              configuration.totalCostLimit > 0,
              let directory = try? preparedDirectory() else {
            return
        }

        let now = nowProvider()
        let record = Record(
            formatVersion: configuration.formatVersion,
            key: key,
            renderedAt: renderedAt ?? now,
            imageData: imageData
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let encoded = try? encoder.encode(record) else { return }

        let url = cacheFileURL(forKey: key, in: directory)
        do {
            #if os(iOS)
            try encoded.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            #else
            try encoded.write(to: url, options: .atomic)
            #endif
            applyFileAttributes(to: url, accessedAt: now)
            prune(in: directory, now: now)
        } catch {
            // A derived thumbnail is always recoverable. Treat every storage
            // failure as a cache miss instead of affecting the drive list.
        }
    }

    func protectVisible(_ key: String) {
        visibleKeys.removeAll { $0 == key }
        visibleKeys.append(key)
        if visibleKeys.count > DriveCardMapCachePolicy.memoryCountLimit { visibleKeys.removeFirst() }
    }

    /// Freshness inspection does not decode or promote an image to memory.
    func isFresh(forKey key: String) -> Bool {
        cachedImageData(forKey: key)?.freshness == .fresh
    }

    /// Speculation may evict old, unrelated entries, never visible maps or
    /// maps admitted earlier in this priority-ordered pass. Decide before write.
    func insertSpeculative(_ imageData: Data, forKey key: String, protecting keys: Set<String>,
                           expectedGeneration: UInt64) -> Bool {
        guard expectedGeneration == writeGeneration, !imageData.isEmpty,
              let directory = try? preparedDirectory() else { return false }
        let record = Record(formatVersion: configuration.formatVersion, key: key,
                            renderedAt: nowProvider(), imageData: imageData)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let encoded = try? encoder.encode(record),
              encoded.count <= configuration.totalCostLimit, configuration.countLimit > 0 else { return false }
        let protected = keys.union(visibleKeys)
        let urls = (try? fileManager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        var total = encoded.count
        var count = 1
        var victims: [(URL, Int, Date)] = []
        for url in urls where url.pathExtension == "mapcache" && url != cacheFileURL(forKey: key, in: directory) {
            let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let cost = attributes?.fileSize ?? 0
            total += cost
            count += 1
            if decodeRecord(at: url).map({ protected.contains($0.key) }) != true {
                victims.append((url, cost, attributes?.contentModificationDate ?? .distantPast))
            }
        }
        var removals: [URL] = []
        for victim in victims.sorted(by: { $0.2 < $1.2 }) {
            guard total > configuration.totalCostLimit || count > configuration.countLimit else { break }
            total -= victim.1
            count -= 1
            removals.append(victim.0)
        }
        guard total <= configuration.totalCostLimit, count <= configuration.countLimit else { return false }
        do {
            for url in removals { try fileManager.removeItem(at: url) }
            let url = cacheFileURL(forKey: key, in: directory)
            try encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            applyFileAttributes(to: url, accessedAt: nowProvider())
            return true
        } catch { return false }
    }

    func removeValue(forKey key: String, expectedGeneration: UInt64? = nil) {
        guard expectedGeneration == nil || expectedGeneration == writeGeneration else { return }
        guard let directory = try? preparedDirectory() else { return }
        try? fileManager.removeItem(at: cacheFileURL(forKey: key, in: directory))
    }

    func removeAll(invalidatingTo generation: UInt64? = nil) {
        visibleKeys = []
        if let generation {
            // Concurrent clears may reach this actor out of order. Never move
            // the write barrier backward and accidentally admit an older job.
            writeGeneration = max(writeGeneration, generation)
        }
        guard let directory = try? preparedDirectory() else { return }
        try? fileManager.removeItem(at: directory)
    }

    func fileURL(forKey key: String) -> URL? {
        guard let directory = try? preparedDirectory() else { return nil }
        return cacheFileURL(forKey: key, in: directory)
    }

    private func preparedDirectory() throws -> URL {
        if let explicitDirectory {
            try fileManager.createDirectory(
                at: explicitDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: explicitDirectory.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = explicitDirectory
            try mutableDirectory.setResourceValues(values)
            return explicitDirectory
        }
        return try DerivedArtifactCacheRoot.prepareSubdirectory(
            "maps",
            testSuffix: testSuffix,
            fileManager: fileManager
        )
    }

    private func cacheFileURL(forKey key: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(DriveCardMapCacheKey.digest(key)).mapcache", isDirectory: false)
    }

    private func decodeRecord(at url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(Record.self, from: data)
    }

    private func applyFileAttributes(to url: URL, accessedAt: Date) {
        #if os(iOS)
        try? fileManager.setAttributes(
            [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                .modificationDate: accessedAt,
            ],
            ofItemAtPath: url.path
        )
        #else
        try? fileManager.setAttributes([.modificationDate: accessedAt], ofItemAtPath: url.path)
        #endif

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private func prune(in directory: URL, now: Date) {
        let properties: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
        ]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(properties),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var records: [StoredRecord] = []
        for url in urls where url.pathExtension == "mapcache" {
            guard let record = decodeRecord(at: url),
                  record.formatVersion == configuration.formatVersion,
                  !record.imageData.isEmpty,
                  max(0, now.timeIntervalSince(record.renderedAt)) <= configuration.retentionLifetime else {
                try? fileManager.removeItem(at: url)
                continue
            }
            let values = try? url.resourceValues(forKeys: properties)
            records.append(
                StoredRecord(
                    url: url,
                    record: record,
                    lastAccessedAt: values?.contentModificationDate ?? record.renderedAt,
                    cost: values?.fileSize ?? record.imageData.count
                )
            )
        }

        records.sort {
            if $0.lastAccessedAt != $1.lastAccessedAt {
                return $0.lastAccessedAt < $1.lastAccessedAt
            }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }

        var totalCost = records.reduce(0) { $0 + $1.cost }
        var totalCount = records.count
        for record in records {
            guard totalCount > configuration.countLimit || totalCost > configuration.totalCostLimit else {
                break
            }
            if (try? fileManager.removeItem(at: record.url)) != nil {
                totalCount -= 1
                totalCost -= record.cost
            }
        }
    }
}

enum DriveCardMapWorkPriority: Int, Sendable {
    case prefetch
    case visible
}

/// Shares identical requests, reserves capacity for visible maps, and drops
/// abandoned work. At most one speculative map runs alongside visible work.
actor DriveCardMapSnapshotWorkCoordinator {
    private struct Waiter {
        var priority: DriveCardMapWorkPriority
        var continuation: CheckedContinuation<DriveCardMapRenderedImage, Error>
    }

    private struct Work {
        var id = UUID()
        var priority: DriveCardMapWorkPriority
        var sequence: UInt64
        var operation: @Sendable () async throws -> DriveCardMapRenderedImage
        var waiters: [UUID: Waiter]
        var task: Task<Void, Never>?
    }

    private let maximumConcurrentSnapshots: Int
    private var inFlight: [String: Work] = [:]
    private var active: [UUID: DriveCardMapWorkPriority] = [:]
    private var sequence: UInt64 = 0

    var outstandingRequestCount: Int { inFlight.values.reduce(0) { $0 + $1.waiters.count } }

    init(maximumConcurrentSnapshots: Int = DriveCardMapCachePolicy.maximumConcurrentSnapshots) {
        self.maximumConcurrentSnapshots = max(1, maximumConcurrentSnapshots)
    }

    func renderedImage(
        forKey key: String,
        priority: DriveCardMapWorkPriority = .visible,
        operation: @escaping @Sendable () async throws -> DriveCardMapRenderedImage
    ) async throws -> DriveCardMapRenderedImage {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if var work = inFlight[key] {
                    work.waiters[waiterID] = Waiter(priority: priority, continuation: continuation)
                    if priority.rawValue > work.priority.rawValue {
                        work.priority = priority
                        if work.task != nil { active[work.id] = priority }
                    }
                    inFlight[key] = work
                } else {
                    sequence &+= 1
                    inFlight[key] = Work(
                        priority: priority,
                        sequence: sequence,
                        operation: operation,
                        waiters: [waiterID: Waiter(priority: priority, continuation: continuation)]
                    )
                }
                startAvailableWork()
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, forKey: key) }
        }
    }

    func cancelAll() {
        let work = Array(inFlight.values)
        inFlight.removeAll()
        for item in work {
            item.task?.cancel()
            for waiter in item.waiters.values {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
        // Active jobs retain their permits until their operations finish,
        // including a MapKit operation that takes a moment to cancel.
    }

    private func cancelWaiter(_ id: UUID, forKey key: String) {
        guard var work = inFlight[key], let waiter = work.waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if work.waiters.isEmpty {
            inFlight[key] = nil
            work.task?.cancel()
        } else {
            work.priority = work.waiters.values.contains { $0.priority == .visible } ? .visible : .prefetch
            if work.task != nil { active[work.id] = work.priority }
            inFlight[key] = work
        }
        startAvailableWork()
    }

    private func startAvailableWork() {
        while active.count < maximumConcurrentSnapshots {
            let prefetchIsRunning = active.values.contains(.prefetch)
            let next = inFlight.filter {
                $0.value.task == nil && ($0.value.priority == .visible || !prefetchIsRunning)
            }.min {
                if $0.value.priority != $1.value.priority {
                    return $0.value.priority.rawValue > $1.value.priority.rawValue
                }
                return $0.value.sequence < $1.value.sequence
            }
            guard let (key, work) = next else { return }
            active[work.id] = work.priority
            inFlight[key]?.task = Task {
                let result: Result<DriveCardMapRenderedImage, Error>
                do {
                    try Task.checkCancellation()
                    let image = try await work.operation()
                    try Task.checkCancellation()
                    result = .success(image)
                } catch {
                    result = .failure(error)
                }
                finish(key: key, id: work.id, result: result)
            }
        }
    }

    private func finish(key: String, id: UUID, result: Result<DriveCardMapRenderedImage, Error>) {
        active[id] = nil
        if let work = inFlight[key], work.id == id {
            inFlight[key] = nil
            for waiter in work.waiters.values { waiter.continuation.resume(with: result) }
        }
        startAvailableWork()
    }
}

final class DriveCardMapThumbnailPipeline: @unchecked Sendable {
    private let memoryCache: DriveCardMapThumbnailMemoryCache
    private let diskCache: DriveCardMapDiskCache
    private let workCoordinator: DriveCardMapSnapshotWorkCoordinator
    private let nowProvider: @Sendable () -> Date
    private let generationLock = NSLock()
    private var cacheGeneration: UInt64 = 0
    // Only the current speculative render is held here, until its disk write
    // finishes. Visible requests can use it immediately during PNG encoding.
    private var warmingOwners: [String: UUID] = [:]
    private var warmingImages: [String: DriveCardMapCachedImage] = [:]
    private var isClearing = false
    private var pendingDiskWrites: [UUID: Task<Void, Never>] = [:]
    private var pendingDiskWriteKeys: [String: UUID] = [:]
    private var diskWriteTail: Task<Void, Never>?
    private let encodeImage: @Sendable (DriveCardMapRenderedImage) async -> Data?

    init(
        memoryCache: DriveCardMapThumbnailMemoryCache = DriveCardMapThumbnailMemoryCache(),
        diskCache: DriveCardMapDiskCache = DriveCardMapDiskCache(),
        workCoordinator: DriveCardMapSnapshotWorkCoordinator = DriveCardMapSnapshotWorkCoordinator(),
        now: @escaping @Sendable () -> Date = Date.init,
        encodeImage: @escaping @Sendable (DriveCardMapRenderedImage) async -> Data? = { $0.image.pngData() }
    ) {
        self.encodeImage = encodeImage
        self.memoryCache = memoryCache
        self.diskCache = diskCache
        self.workCoordinator = workCoordinator
        nowProvider = now
    }

    func memoryImage(forKey key: String) -> UIImage? {
        memoryCache.image(forKey: key)
    }

    func cachedImage(forKey key: String, displayScale: CGFloat) async -> DriveCardMapCachedImage? {
        await diskCache.protectVisible(key)
        return await cachedImage(
            forKey: key,
            displayScale: displayScale,
            generation: currentGeneration()
        )
    }

    /// Cache-only navigation preparation: decode before the destination is
    /// pushed, so its first render can read the exact image synchronously.
    /// A miss never starts MapKit or waits for an in-flight snapshot.
    func prepareCachedImage(forKey key: String, displayScale: CGFloat) async -> DriveCardMapCachedImage? {
        let generation = currentGeneration()
        guard !Task.isCancelled,
              let cached = await cachedImage(forKey: key, displayScale: displayScale, generation: generation),
              !Task.isCancelled else { return nil }
        let prepared = await cached.image.byPreparingForDisplay() ?? cached.image
        guard !Task.isCancelled,
              insertMemoryIfCurrent(prepared, forKey: key, renderedAt: cached.renderedAt, generation: generation)
        else { return nil }
        await diskCache.protectVisible(key)
        guard isCurrent(generation), !Task.isCancelled else { return nil }
        return DriveCardMapCachedImage(image: prepared, renderedAt: cached.renderedAt, freshness: cached.freshness)
    }

    private func cachedImage(
        forKey key: String,
        displayScale: CGFloat,
        generation: UInt64
    ) async -> DriveCardMapCachedImage? {
        let now = nowProvider()
        if let memoryHit = memoryHit(forKey: key, now: now, generation: generation) {
            return memoryHit
        }

        guard let diskHit = await diskCache.cachedImageData(forKey: key) else { return nil }
        guard let image = UIImage(data: diskHit.imageData, scale: displayScale) else {
            await diskCache.removeValue(forKey: key, expectedGeneration: generation)
            return nil
        }
        guard insertMemoryIfCurrent(
            image,
            forKey: key,
            renderedAt: diskHit.renderedAt,
            generation: generation
        ) else {
            return nil
        }
        return DriveCardMapCachedImage(
            image: image,
            renderedAt: diskHit.renderedAt,
            freshness: diskHit.freshness
        )
    }

    func revalidatedImage(
        forKey key: String,
        displayScale: CGFloat,
        priority: DriveCardMapWorkPriority = .visible,
        operation: @escaping @Sendable () async throws -> DriveCardMapRenderedImage
    ) async throws -> UIImage {
        try Task.checkCancellation()
        let generation = currentGeneration()
        if priority == .visible { await diskCache.protectVisible(key) }
        if let cached = await cachedImage(
            forKey: key,
            displayScale: displayScale,
            generation: generation
        ),
           cached.freshness == .fresh {
            return cached.image
        }
        guard isCurrent(generation) else { throw CancellationError() }

        let workKey = "\(generation)|\(key)"
        let rendered = try await workCoordinator.renderedImage(forKey: workKey, priority: priority) { [self] in
            let rendered = try await operation()
            try Task.checkCancellation()
            let renderedAt = nowProvider()
            guard insertMemoryIfCurrent(
                rendered.image,
                forKey: key,
                renderedAt: renderedAt,
                generation: generation
            ) else {
                throw CancellationError()
            }
            guard isCurrent(generation) else { throw CancellationError() }
            return rendered
        }
        guard insertMemoryIfCurrent(rendered.image, forKey: key, renderedAt: nowProvider(), generation: generation)
        else { throw CancellationError() }
        scheduleDiskWrite(rendered, forKey: key, renderedAt: nowProvider(), generation: generation)
        return rendered.image
    }

    /// Uses the same work key as visible requests, but keeps speculative hero
    /// images out of NSCache and waits for persistence to bound encoding memory.
    func warm(forKey key: String, protecting keys: Set<String>,
              operation: @escaping @Sendable () async throws -> DriveCardMapRenderedImage) async throws -> Bool {
        try Task.checkCancellation()
        let generation = currentGeneration()
        if await diskCache.isFresh(forKey: key) { return true }
        guard isCurrent(generation) else { throw CancellationError() }
        let owner = beginWarmingImage(key: key, generation: generation)
        defer { releaseWarmingImage(key: key, generation: generation, owner: owner) }
        let rendered: DriveCardMapRenderedImage
        if let hit = memoryHit(forKey: key, now: nowProvider(), generation: generation), hit.freshness == .fresh {
            rendered = DriveCardMapRenderedImage(image: hit.image)
        } else {
            rendered = try await workCoordinator.renderedImage(
                forKey: "\(generation)|\(key)", priority: .prefetch) { [self] in
                    let result = try await operation()
                    retainWarmingImage(result.image, key: key, generation: generation, owner: owner)
                    return result
                }
        }
        try Task.checkCancellation()
        guard isCurrent(generation) else { throw CancellationError() }
        let data = await Task.detached(priority: .utility) { [encodeImage] in
            await encodeImage(rendered)
        }.value
        try Task.checkCancellation()
        guard isCurrent(generation), let data else { return false }
        return await diskCache.insertSpeculative(data, forKey: key, protecting: keys, expectedGeneration: generation)
    }

    func removeAll() async {
        let generation = beginClear()
        await workCoordinator.cancelAll()
        await diskCache.removeAll(invalidatingTo: generation)
        finishClear(generation)
    }

    /// A persistence barrier for callers that explicitly need durable cache
    /// contents. Display never waits for PNG encoding or disk maintenance.
    func waitForPendingWrites() async {
        for task in diskWrites() { await task.value }
    }

    private func diskWrites() -> [Task<Void, Never>] {
        generationLock.lock()
        defer { generationLock.unlock() }
        return Array(pendingDiskWrites.values)
    }

    private func scheduleDiskWrite(
        _ rendered: DriveCardMapRenderedImage,
        forKey key: String,
        renderedAt: Date,
        generation: UInt64
    ) {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard generation == cacheGeneration, !isClearing, pendingDiskWriteKeys[key] == nil else { return }
        let id = UUID()
        pendingDiskWriteKeys[key] = id
        let predecessor = diskWriteTail
        let task = Task.detached(priority: .utility) { [self] in
            defer { finishedDiskWrite(id, key: key) }
            await predecessor?.value
            guard !Task.isCancelled, isCurrent(generation) else { return }
            guard let data = await encodeImage(rendered),
                  !Task.isCancelled, isCurrent(generation) else { return }
            await diskCache.insert(data, forKey: key, renderedAt: renderedAt, expectedGeneration: generation)
        }
        pendingDiskWrites[id] = task
        diskWriteTail = task
    }

    private func finishedDiskWrite(_ id: UUID, key: String) {
        generationLock.lock()
        defer { generationLock.unlock() }
        pendingDiskWrites[id] = nil
        if pendingDiskWriteKeys[key] == id { pendingDiskWriteKeys[key] = nil }
        if pendingDiskWrites.isEmpty { diskWriteTail = nil }
    }

    private func currentGeneration() -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return cacheGeneration
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == cacheGeneration && !isClearing
    }

    private func memoryHit(
        forKey key: String,
        now: Date,
        generation: UInt64
    ) -> DriveCardMapCachedImage? {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard generation == cacheGeneration, !isClearing else { return nil }
        return warmingImages[key] ?? memoryCache.cachedImage(forKey: key, now: now)
    }

    private func beginWarmingImage(key: String, generation: UInt64) -> UUID {
        generationLock.lock()
        defer { generationLock.unlock() }
        let owner = UUID()
        if generation == cacheGeneration, !isClearing { warmingOwners[key] = owner }
        return owner
    }

    private func retainWarmingImage(_ image: UIImage, key: String, generation: UInt64, owner: UUID) {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard generation == cacheGeneration, !isClearing, warmingOwners[key] == owner else { return }
        warmingImages[key] = DriveCardMapCachedImage(image: image, renderedAt: nowProvider(), freshness: .fresh)
    }

    private func releaseWarmingImage(key: String, generation: UInt64, owner: UUID) {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard generation == cacheGeneration, warmingOwners[key] == owner else { return }
        warmingOwners[key] = nil
        warmingImages[key] = nil
    }

    private func insertMemoryIfCurrent(
        _ image: UIImage,
        forKey key: String,
        renderedAt: Date,
        generation: UInt64
    ) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard generation == cacheGeneration, !isClearing else { return false }
        memoryCache.insert(image, forKey: key, renderedAt: renderedAt)
        return true
    }

    private func beginClear() -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        cacheGeneration &+= 1
        warmingImages = [:]
        warmingOwners = [:]
        isClearing = true
        for task in pendingDiskWrites.values { task.cancel() }
        pendingDiskWriteKeys = [:]
        diskWriteTail = nil
        memoryCache.removeAllObjects()
        return cacheGeneration
    }

    private func finishClear(_ generation: UInt64) {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard generation == cacheGeneration else { return }
        // Also clear anything from work that began concurrently with the clear.
        memoryCache.removeAllObjects()
        isClearing = false
    }
}
