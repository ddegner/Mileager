import XCTest
@testable import AppCore
@testable import AppCorePersistence
@testable import DriveCaptureEngine

final class DiagnosticDriveAnalyzerTests: XCTestCase {
    func testSavedCarExclusionPreventsRecoveryEvenAfterPolicyChanges() {
        var samples = strictSpeedOnlySamples()
        XCTAssertEqual(DiagnosticDriveAnalyzer.strictRecoveryDrafts(from: samples).count, 1)
        for index in samples.indices {
            samples[index].acceptedForDetection = false
            samples[index].detectionReason = DriveCaptureReducer.automaticStartSuppressedReason
        }
        XCTAssertTrue(DiagnosticDriveAnalyzer.strictRecoveryDrafts(from: samples).isEmpty)
        XCTAssertTrue(DiagnosticDriveAnalyzer.possibleDriveCandidates(from: samples).isEmpty)
        XCTAssertEqual(DiagnosticDriveAnalyzer.burstSummaries(from: samples).count, 1, "Diagnostics remain inspectable")
    }

    func testExcludedSampleSplitsRecoveryInsteadOfJoiningAllowedMovementAcrossIt() {
        var samples = strictSpeedOnlySamples()
        samples[2].detectionReason = DriveCaptureReducer.automaticStartSuppressedReason
        XCTAssertTrue(DiagnosticDriveAnalyzer.strictRecoveryDrafts(from: samples).isEmpty)
    }

    func testSparseCandidatePlusDelayedStaleSamplesCreatesPossibleDriveDraft() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionID = UUID()
        var samples: [DiagnosticLocationSample] = []
        samples.append(diagnosticSample(
            sessionID: sessionID,
            timestamp: start,
            receivedAt: start,
            latitude: 40,
            longitude: -73,
            accuracy: 35,
            speed: nil,
            motionHint: .automotive,
            phase: "idle",
            output: "candidateStarted, checkpointChanged"
        ))
        samples.append(diagnosticSample(
            sessionID: sessionID,
            timestamp: start.addingTimeInterval(3),
            receivedAt: start.addingTimeInterval(3),
            latitude: 40.0001,
            longitude: -73.0001,
            accuracy: 34,
            speed: 2.3,
            motionHint: .automotive,
            phase: "candidate",
            output: "tripUpdated, checkpointChanged"
        ))
        samples.append(diagnosticSample(
            sessionID: sessionID,
            timestamp: start.addingTimeInterval(7),
            receivedAt: start.addingTimeInterval(7),
            latitude: 40.0002,
            longitude: -73.0002,
            accuracy: 34,
            speed: 2.9,
            motionHint: .automotive,
            phase: "candidate",
            output: "tripUpdated, checkpointChanged"
        ))
        samples.append(diagnosticSample(
            sessionID: sessionID,
            timestamp: start.addingTimeInterval(15),
            receivedAt: start.addingTimeInterval(15),
            latitude: 40.00025,
            longitude: -73.00025,
            accuracy: 33,
            speed: 1.7,
            motionHint: .unknown,
            phase: "candidate",
            output: "ignored, checkpointChanged",
            reason: "No driving signal: samples=4, elapsed=7s, distance=25m, automotive=true, reportedSpeed=true, derivedSpeed=false, displacement=false"
        ))

        for offset in 16..<75 {
            samples.append(diagnosticSample(
                sessionID: sessionID,
                timestamp: start.addingTimeInterval(TimeInterval(offset)),
                receivedAt: start.addingTimeInterval(18 * 60 + TimeInterval(offset)),
                latitude: 40.00025 + Double(offset - 16) * 0.00001,
                longitude: -73.00025,
                accuracy: 12,
                speed: nil,
                motionHint: offset < 20 ? .unknown : .stationary,
                phase: "idle",
                accepted: false,
                output: "ignored, checkpointChanged",
                reason: "Stale wake cached as parked anchor"
            ))
        }

        let summaries = DiagnosticDriveAnalyzer.burstSummaries(from: samples)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].staleSampleCount, 59)
        XCTAssertGreaterThan(summaries[0].maxStaleDelaySeconds, 1_000)

        let candidates = DiagnosticDriveAnalyzer.possibleDriveCandidates(from: samples)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].reviewStatus, .needsAttention)
        XCTAssertTrue(candidates[0].needsAttention)
        XCTAssertTrue(candidates[0].reasons.contains(PossibleDriveCandidate.attentionReason))

        let drafts = DiagnosticDriveAnalyzer.possibleDriveDrafts(from: samples)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].draft.id, candidates[0].id)
        XCTAssertTrue(drafts[0].draft.attentionReasons.contains(PossibleDriveCandidate.attentionReason))
    }

    func testContinuousConfirmedDriveDoesNotCreatePossibleDriveCandidate() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionID = UUID()
        let tripID = UUID()
        var samples: [DiagnosticLocationSample] = []
        for index in 0..<90 {
            samples.append(diagnosticSample(
                sessionID: sessionID,
                tripID: tripID,
                timestamp: start.addingTimeInterval(TimeInterval(index)),
                receivedAt: start.addingTimeInterval(TimeInterval(index)),
                latitude: 40 + Double(index) * 0.0001,
                longitude: -73,
                accuracy: 8,
                speed: 10,
                motionHint: .automotive,
                phase: index < 10 ? "candidate" : "recording",
                output: index == 10 ? "tripStarted, tripUpdated, checkpointChanged" : "tripUpdated, checkpointChanged"
            ))
        }

        XCTAssertTrue(DiagnosticDriveAnalyzer.possibleDriveCandidates(from: samples).isEmpty)
        XCTAssertTrue(DiagnosticDriveAnalyzer.possibleDriveDrafts(from: samples).isEmpty)
    }

    func testDiagnosticOnlyDeferredCandidateCreatesPossibleDriveCandidateWithoutAutomotiveHint() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionID = UUID()
        let samples = [
            diagnosticSample(
                sessionID: sessionID,
                timestamp: start,
                receivedAt: start,
                latitude: 40,
                longitude: -73,
                accuracy: 12,
                speed: 8,
                motionHint: .unknown,
                phase: "idle",
                output: "candidateStarted, checkpointChanged"
            ),
            diagnosticSample(
                sessionID: sessionID,
                timestamp: start.addingTimeInterval(10),
                receivedAt: start.addingTimeInterval(10),
                latitude: 40.0005,
                longitude: -73,
                accuracy: 12,
                speed: 8,
                motionHint: .cycling,
                phase: "candidate",
                output: "tripUpdated, checkpointChanged"
            ),
            diagnosticSample(
                sessionID: sessionID,
                timestamp: start.addingTimeInterval(20),
                receivedAt: start.addingTimeInterval(20),
                latitude: 40.001,
                longitude: -73,
                accuracy: 12,
                speed: 8,
                motionHint: .unknown,
                phase: "candidate",
                output: "tripUpdated, checkpointChanged"
            ),
            diagnosticSample(
                sessionID: sessionID,
                timestamp: start.addingTimeInterval(30),
                receivedAt: start.addingTimeInterval(30),
                latitude: 40.0015,
                longitude: -73,
                accuracy: 12,
                speed: 8,
                motionHint: .unknown,
                phase: "candidate",
                output: "ignored, checkpointChanged",
                reason: "\(DriveCandidateDeferralReason.speedOnlyNoAssist.message): samples=4, elapsed=30s, distance=150m"
            )
        ]

        let candidates = DiagnosticDriveAnalyzer.possibleDriveCandidates(from: samples)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].reasons.contains("Deferred from visible trips because trusted vehicle evidence was missing"))
        XCTAssertTrue(candidates[0].reasons.contains("No trusted vehicle Bluetooth hint was active"))
    }

    func testStrictRecoveryAcceptsSustainedSpeedOnlyCandidate() throws {
        let samples = strictSpeedOnlySamples()

        let recoveries = DiagnosticDriveAnalyzer.strictRecoveryDrafts(from: samples)

        XCTAssertEqual(recoveries.count, 1)
        XCTAssertGreaterThanOrEqual(
            recoveries[0].draft.distanceMeters,
            DiagnosticDriveAnalyzer.strictRecoveryMinimumDistanceMeters
        )
        XCTAssertNil(recoveries[0].draft.classification)
        XCTAssertTrue(recoveries[0].draft.attentionReasons.contains(PossibleDriveCandidate.attentionReason))
    }

    func testStrictRecoveryRejectsPedestrianOrCyclingConflict() {
        let samples = strictSpeedOnlySamples(conflictingHint: .cycling)

        XCTAssertEqual(DiagnosticDriveAnalyzer.possibleDriveDrafts(from: samples).count, 1)
        XCTAssertTrue(DiagnosticDriveAnalyzer.strictRecoveryDrafts(from: samples).isEmpty)
    }

    /// A bike ride whose samples never carry a cycling motion hint (CoreMotion
    /// is not reliably attached to deferred background candidates) must still
    /// be rejected on speed alone: cycling cruises at 4–7 m/s, and 2.2's 4 m/s
    /// peak floor recovered rides as review trips.
    func testStrictRecoveryRejectsCyclingSpeedBurstWithoutMotionHint() {
        let samples = strictSpeedOnlySamples(speed: 6)

        XCTAssertEqual(DiagnosticDriveAnalyzer.possibleDriveDrafts(from: samples).count, 1)
        XCTAssertTrue(DiagnosticDriveAnalyzer.strictRecoveryDrafts(from: samples).isEmpty)
    }

    func testStrictRecoveryAcceptsBurstAtPeakSpeedFloor() {
        let samples = strictSpeedOnlySamples(
            speed: DiagnosticDriveAnalyzer.strictRecoveryMinimumPeakSpeedMetersPerSecond
        )

        XCTAssertEqual(DiagnosticDriveAnalyzer.strictRecoveryDrafts(from: samples).count, 1)
    }

    func testStrictRecoveryPersistsOnceAsUnclassifiedAttentionTrip() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let recovery = try XCTUnwrap(
            DiagnosticDriveAnalyzer.strictRecoveryDrafts(from: strictSpeedOnlySamples()).first
        )

        let first = try store.saveCompletedTrip(recovery.draft)
        let second = try store.saveCompletedTrip(recovery.draft)
        let matchingTrips = try store.fetchTrips(
            from: recovery.draft.startDate.addingTimeInterval(-1),
            to: recovery.draft.endDate.addingTimeInterval(1)
        ).filter { $0.id == recovery.draft.id }

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(matchingTrips.count, 1)
        XCTAssertNil(second.classification)
        XCTAssertEqual(second.reviewStatus, .needsAttention)
        XCTAssertTrue(second.needsAttention)
        XCTAssertFalse(TripReviewPolicy.isExportableBusiness(
            classification: second.classification,
            businessPurpose: second.businessPurpose
        ))
    }

    func testDriveCaptureEventStorePersistsAndPurgesEvents() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = DriveCaptureEventStore(context: persistence.container.viewContext)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = DriveCaptureJournalEntry(
            date: now,
            category: "lifecycle",
            message: "Location background wake",
            monitoringSessionID: UUID(),
            trackingPhase: "idle",
            activityLevel: "idle wake",
            wakeReason: "location",
            expiresAt: now.addingTimeInterval(60)
        )

        try store.save(event)

        XCTAssertEqual(try store.fetchEvents(since: now.addingTimeInterval(-1), until: now.addingTimeInterval(1)), [event])
        XCTAssertEqual(try store.purgeExpiredEvents(now: now.addingTimeInterval(120)), 1)
        XCTAssertTrue(try store.fetchEvents(since: nil, until: nil).isEmpty)
    }

    func testDriveCaptureEventStoreRollsBackFailedSave() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = DriveCaptureEventStore(context: context)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = DriveCaptureJournalEntry(
            date: now,
            category: "lifecycle",
            message: "Location background wake",
            expiresAt: now.addingTimeInterval(60)
        )

        _ = DriveCaptureEventEntity.insert(into: context)

        XCTAssertThrowsError(try store.save(event))
        XCTAssertFalse(context.hasChanges)

        try store.save(event)
        XCTAssertEqual(try store.fetchEvents(since: nil, until: nil), [event])
    }

    func testPendingDriveStartSignalStorePersistsConsumesAndExpiresSignals() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = PendingDriveStartSignalStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let pending = try store.save(trigger: .carPlay, at: start, policy: .balanced)
        XCTAssertEqual(pending.source, .externalVehicleAutomation)
        XCTAssertEqual(try store.fetchPending(at: start).map(\.id), [pending.id])

        try store.markConsumed(id: pending.id, consumedAt: start.addingTimeInterval(1), captureID: UUID())
        let consumed = try XCTUnwrap(store.fetchLatest())
        XCTAssertEqual(consumed.status, .consumed)
        XCTAssertNotNil(consumed.consumedAt)

        let chargerPending = try store.save(trigger: .charger, at: start.addingTimeInterval(10), policy: .balanced)
        // Vehicle-trigger sources (charger included) extend expiresAt to the
        // pre-movement grace window, which is longer than the base
        // signalHighFidelityWindow - read the signal's own expiresAt rather
        // than assuming the base window.
        let expiredAt = chargerPending.expiresAt.addingTimeInterval(1)
        XCTAssertEqual(try store.markExpired(now: expiredAt), 1)
        XCTAssertTrue(try store.fetchPending(at: expiredAt).isEmpty)

        let oldConsumed = try store.save(trigger: .vehicleBluetooth, at: start.addingTimeInterval(20), policy: .balanced)
        try store.markConsumed(id: oldConsumed.id, consumedAt: start.addingTimeInterval(21), captureID: UUID())
        let oldExpired = try store.save(trigger: .charger, at: start.addingTimeInterval(30), policy: .balanced)
        try store.markExpired(now: oldExpired.expiresAt.addingTimeInterval(1))
        let pendingToKeep = try store.save(trigger: .manual, at: start.addingTimeInterval(40), policy: .balanced)

        let cutoff = start.addingTimeInterval(Double(PendingDriveStartSignal.retentionDays) * 24 * 60 * 60)
        XCTAssertEqual(try store.purgeResolved(before: cutoff), 4)

        let remaining = try store.fetchSignals(since: nil, until: nil)
        XCTAssertEqual(remaining.map(\.id), [pendingToKeep.id])
        XCTAssertEqual(remaining.first?.status, .pending)
    }

    func testPendingDriveStartSignalStoreRollsBackFailedSave() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = PendingDriveStartSignalStore(context: context)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        _ = PendingDriveStartSignalEntity.insert(into: context)

        XCTAssertThrowsError(try store.save(trigger: .carPlay, at: start, policy: .balanced))
        XCTAssertFalse(context.hasChanges)

        let pending = try store.save(trigger: .carPlay, at: start, policy: .balanced)
        XCTAssertEqual(try store.fetchSignals(since: nil, until: nil).map(\.id), [pending.id])
    }

    private func diagnosticSample(
        sessionID: UUID,
        tripID: UUID? = nil,
        timestamp: Date,
        receivedAt: Date,
        latitude: Double,
        longitude: Double,
        accuracy: Double,
        speed: Double?,
        motionHint: MotionHint,
        phase: String,
        accepted: Bool = true,
        output: String? = nil,
        reason: String? = nil
    ) -> DiagnosticLocationSample {
        DiagnosticLocationSample(
            monitoringSessionID: sessionID,
            tripID: tripID,
            receivedAt: receivedAt,
            sample: LocationSample(
                timestamp: timestamp,
                latitude: latitude,
                longitude: longitude,
                horizontalAccuracy: accuracy,
                speedMetersPerSecond: speed,
                motionHint: motionHint
            ),
            trackingPhase: phase,
            powerConnected: false,
            recentPowerConnected: false,
            recentPowerDisconnected: false,
            trustedBluetoothVehicleHint: false,
            acceptedForDetection: accepted,
            detectionOutput: output,
            detectionReason: reason,
            expiresAt: receivedAt.addingTimeInterval(Double(DiagnosticLocationSample.retentionDays) * 24 * 60 * 60)
        )
    }

    /// Default speed is car-like (12 m/s ≈ 27 mph): well above the strict
    /// recovery peak floor, so tests exercising other guards stay independent
    /// of the speed threshold.
    private func strictSpeedOnlySamples(
        conflictingHint: MotionHint? = nil,
        speed: Double = 12,
        start: Date = Date(timeIntervalSince1970: 1_800_000_000),
        sessionID: UUID = UUID()
    ) -> [DiagnosticLocationSample] {
        var samples: [DiagnosticLocationSample] = []
        for index in 0..<5 {
            let offset = TimeInterval(index * 12)
            let output = index == 0
                ? "candidateStarted, checkpointChanged"
                : "tripUpdated, checkpointChanged"
            let reason = index == 4
                ? "Diagnostic-only drive candidate: speedOnlyNoAssist: samples=5, elapsed=48s, distance=267m"
                : nil
            samples.append(diagnosticSample(
                sessionID: sessionID,
                timestamp: start.addingTimeInterval(offset),
                receivedAt: start.addingTimeInterval(offset),
                latitude: 40 + Double(index) * 0.0006,
                longitude: -73,
                accuracy: 12,
                speed: speed,
                motionHint: index == 2 ? (conflictingHint ?? .unknown) : .unknown,
                phase: index == 0 ? "idle" : "candidate",
                output: output,
                reason: reason
            ))
        }
        return samples
    }
}
