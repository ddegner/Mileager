import AppCoreModels
import Foundation
import XCTest
@testable import AppCoreSuggestions

@MainActor
final class IRSBusinessRateClientTests: XCTestCase {
    private let january = MileageRateEffectiveDate(year: 2026, month: 1, day: 1)
    private let july = MileageRateEffectiveDate(year: 2026, month: 7, day: 1)
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    func testBundledDefaultMatchesOfficialBusinessColumnAndPeriodEvidence() throws {
        let source = try IRSRateHTMLCleaner.clean(Self.html)
        let bundled = IRSBusinessRatePeriod.bundledCurrent
        XCTAssertEqual(try IRSRateSourceEvidence.validate([bundled], source: source, since: july), [bundled])
        var wrongColumn = bundled
        wrongColumn.amountPerMile = 0.235
        wrongColumn.rateEvidence = "23.5"
        XCTAssertThrowsError(try IRSRateSourceEvidence.validate([wrongColumn], source: source, since: july))
    }

    func testCleanerPreservesRealIRSHeaderCellsAndPeriodBoundaries() throws {
        let cleaned = try IRSRateHTMLCleaner.clean(Self.html)
        XCTAssertTrue(cleaned.contains("Period | Business use | Charity use | Medical or military moving | Source |"))
        XCTAssertTrue(cleaned.contains("2026 (July 1 – Dec. 31) | 76 | 14 | 23.5 | IR-2026-29 |"))
        XCTAssertTrue(cleaned.contains("2026 (Jan. 1 – June 30) | 72.5 | 14 | 20.5 | IR-2025-128 |"))
        XCTAssertTrue(cleaned.contains("Self-employed and business: 76 cents/mile"))
        XCTAssertFalse(cleaned.contains("999 cents"))
        XCTAssertFalse(cleaned.contains("menu"))
        XCTAssertFalse(cleaned.contains("related topics"))
    }

    func testCleanerRequiresMainContentAndDecodesNumericEntities() throws {
        XCTAssertThrowsError(try IRSRateHTMLCleaner.clean("<table><tr><td>76</td></tr></table>"))
        let cleaned = try IRSRateHTMLCleaner.clean(Self.html.replacingOccurrences(of: "&ndash;", with: "&#x2013;"))
        XCTAssertTrue(cleaned.contains("2026 (July 1 – Dec. 31)"))
    }

    func testValidatesBothMissedPeriodsAndAnAnnouncedFuturePeriod() throws {
        let source = try IRSRateHTMLCleaner.clean(Self.futureHTML)
        let result = try IRSRateSourceEvidence.validate([Self.future, Self.secondHalf, Self.firstHalf],
                                                       source: source, since: january)
        XCTAssertEqual(try IRSRateSourceEvidence.extract(source, since: january).count, 3)
        XCTAssertEqual(try IRSRateSourceEvidence.extract(source, since: july).count, 2)
        XCTAssertEqual(result.map(\.amountPerMile), [0.725, 0.76, 0.80])
        XCTAssertEqual(result.map(\.effectiveFrom.year), [2026, 2026, 2027])
        XCTAssertEqual(result.first?.effectiveThrough, MileageRateEffectiveDate(year: 2026, month: 6, day: 30))
        XCTAssertEqual(result.last?.sourceURL, IRSBusinessRateClient.sourceURL.absoluteString)
    }

    func testRejectsOmittedIntermediateOrFuturePeriod() throws {
        let source = try IRSRateHTMLCleaner.clean(Self.futureHTML)
        XCTAssertThrowsError(try IRSRateSourceEvidence.validate([Self.secondHalf, Self.future],
                                                               source: source, since: january))
        XCTAssertThrowsError(try IRSRateSourceEvidence.validate([Self.firstHalf, Self.secondHalf],
                                                               source: source, since: january))
    }

    func testRejectsMedicalRateFabricatedEvidenceAndIncorrectDate() throws {
        let source = try IRSRateHTMLCleaner.clean(Self.html)
        var medical = Self.secondHalf
        medical.amountPerMile = 0.235
        medical.rateEvidence = "Medical: 23.5 cents/mile"
        XCTAssertThrowsError(try IRSRateSourceEvidence.validate([medical], source: source, since: july))
        var fabricated = Self.secondHalf
        fabricated.rateEvidence = "The official business rate is 76 cents."
        XCTAssertThrowsError(try IRSRateSourceEvidence.validate([fabricated], source: source, since: july))
        var wrongDate = Self.secondHalf
        wrongDate.effectiveFrom.day = 2
        XCTAssertThrowsError(try IRSRateSourceEvidence.validate([wrongDate], source: source, since: july))
        var invalidDate = Self.secondHalf
        invalidDate.effectiveThrough = .init(year: 2026, month: 11, day: 31)
        XCTAssertThrowsError(try IRSRateSourceEvidence.validate([invalidDate], source: source, since: july))
    }

    func testMissingRequiredPeriodsFailWithoutInventingRates() throws {
        let source = try IRSRateHTMLCleaner.clean(Self.html)
        XCTAssertThrowsError(try IRSRateSourceEvidence.extract(source, since: .init(year: 2027, month: 1, day: 1))) {
            XCTAssertEqual($0 as? IRSBusinessRateClientError, .missingRate)
        }
    }

    func testRejectsConflictingHeadlineAndOverlappingTableRowsBeforeExtraction() throws {
        let conflict = try IRSRateHTMLCleaner.clean(Self.html.replacingOccurrences(of: "business: 76", with: "business: 77"))
        XCTAssertThrowsError(try IRSRateSourceEvidence.relevantContent(conflict, since: july)) {
            XCTAssertEqual($0 as? IRSBusinessRateClientError, .ambiguousRate)
        }
        let overlapping = try IRSRateHTMLCleaner.clean(Self.html.replacingOccurrences(of: "June&nbsp;30", with: "July&nbsp;2"))
        XCTAssertThrowsError(try IRSRateSourceEvidence.relevantContent(overlapping, since: january)) {
            XCTAssertEqual($0 as? IRSBusinessRateClientError, .ambiguousRate)
        }
    }

    func testAnnualHeadlineAndBusinessTableMustAgree() throws {
        let conflicting = Self.futureHTML
            .replacingOccurrences(of: "2026 mileage rates (July 1 &ndash; Dec. 31)", with: "2027 mileage rates")
            .replacingOccurrences(of: "business: 76", with: "business: 81")
        XCTAssertThrowsError(try IRSRateSourceEvidence.extract(IRSRateHTMLCleaner.clean(conflicting), since: july)) {
            XCTAssertEqual($0 as? IRSBusinessRateClientError, .ambiguousRate)
        }
    }

    func testRecognizesAnnualAndHistoricalNumericPeriods() throws {
        let year = try XCTUnwrap(IRSRateSourceEvidence.parsePeriod("2027"))
        XCTAssertEqual(year.0, .init(year: 2027, month: 1, day: 1))
        XCTAssertEqual(year.1, .init(year: 2027, month: 12, day: 31))
        let numeric = try XCTUnwrap(IRSRateSourceEvidence.parsePeriod("7/1/2022-12/31/2022"))
        XCTAssertEqual(numeric.0, .init(year: 2022, month: 7, day: 1))
        XCTAssertNil(IRSRateSourceEvidence.parsePeriod("Page last reviewed July 1, 2026"))
        XCTAssertNil(IRSRateSourceEvidence.parsePeriod("2026 (Juliet 1 – Dec. 31)"))
    }

    func testUnchangedContentAnd304ReuseValidatedRatesWithConditionalRequests() async throws {
        let stub = Stub(responses: [Self.page(Self.html), Self.page(status: 304), Self.page(Self.html)])
        let client = makeClient(stub)
        let first = try await client.fetchPeriods(since: july, now: now, force: false)
        let second = try await client.fetchPeriods(since: july, now: now, force: false)
        let third = try await client.fetchPeriods(since: july, now: now, force: true)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, third)
        let state = await stub.state()
        XCTAssertEqual(state[1].value(forHTTPHeaderField: "If-None-Match"), "version-a")
        XCTAssertEqual(state[1].value(forHTTPHeaderField: "If-Modified-Since"), "Sat, 03 Oct 2026 12:00:00 GMT")
        XCTAssertEqual(state[2].value(forHTTPHeaderField: "Cache-Control"), "no-cache")
    }

    func testEarlierCoverageRequestReextractsCachedPageEvenOn304() async throws {
        let stub = Stub(responses: [Self.page(Self.html), Self.page(status: 304)])
        let client = makeClient(stub)
        _ = try await client.fetchPeriods(since: july, now: now, force: false)
        let all = try await client.fetchPeriods(since: january, now: now, force: false)
        XCTAssertEqual(all.count, 2)
    }

    func testNarrowingCoverageReusesPreviouslyValidatedPeriods() async throws {
        let stub = Stub(responses: [Self.page(Self.html), Self.page(status: 304)])
        let client = makeClient(stub)
        _ = try await client.fetchPeriods(since: january, now: now, force: false)
        let narrowed = try await client.fetchPeriods(since: july, now: now, force: false)
        XCTAssertEqual(narrowed.count, 1)
    }

    func testFutureAnnouncementChangesRelevantEvidenceAndIncludesEveryAnnouncedPeriod() async throws {
        let stub = Stub(responses: [Self.page(Self.html), Self.page(Self.futureHTML, etag: "version-b")])
        let client = makeClient(stub)
        _ = try await client.fetchPeriods(since: july, now: now, force: false)
        let periods = try await client.fetchPeriods(since: july, now: now, force: false)
        XCTAssertEqual(periods.map(\.amountPerMile), [0.76, 0.80])
    }

    func testDiskCacheReadbackUsesValidatedPeriodsAndConditionalRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appending(path: "cache.json")
        let firstStub = Stub(responses: [Self.page(Self.html)])
        let first = makeClient(firstStub, cacheURL: cacheURL)
        let expected = try await first.fetchPeriods(since: july, now: now, force: false)
        let secondStub = Stub(responses: [Self.page(status: 304)])
        let second = makeClient(secondStub, cacheURL: cacheURL)
        let actual = try await second.fetchPeriods(since: july, now: now, force: false)
        XCTAssertEqual(actual, expected)
        let state = await secondStub.state()
        XCTAssertEqual(state[0].value(forHTTPHeaderField: "If-None-Match"), "version-a")
    }

    func testConflictingSourceRetainsLastValidatedCacheAndETag() async throws {
        let conflict = Self.html.replacingOccurrences(of: "business: 76", with: "business: 77")
        let stub = Stub(responses: [Self.page(Self.html), Self.page(conflict, etag: "version-b"), Self.page(status: 304)])
        let client = makeClient(stub)
        let expected = try await client.fetchPeriods(since: july, now: now, force: false)
        do {
            _ = try await client.fetchPeriods(since: july, now: now, force: false)
            XCTFail("Conflicting official statements must fail the check")
        } catch { XCTAssertEqual(error as? IRSBusinessRateClientError, .ambiguousRate) }
        let retained = try await client.fetchPeriods(since: july, now: now, force: false)
        XCTAssertEqual(retained, expected)
        let state = await stub.state()
        XCTAssertEqual(state[2].value(forHTTPHeaderField: "If-None-Match"), "version-a")
    }

    func testUnofficialRedirectAndUnexpected304FailWithoutExtraction() async throws {
        var redirected = Self.page(Self.html)
        redirected.url = URL(string: "https://example.com/irs")!
        for response in [redirected, Self.page(status: 304)] {
            let stub = Stub(responses: [response])
            do {
                _ = try await makeClient(stub).fetchPeriods(since: july, now: now, force: false)
                XCTFail("An unverified response must not produce rates")
            } catch { }
        }
    }

    func testProductionParserReturnsBusinessColumnWithExactSourceEvidence() async throws {
        let client = makeClient(Stub(responses: [Self.page(Self.html)]))
        let periods = try await client.fetchPeriods(since: january, now: now, force: false)
        XCTAssertEqual(periods.map(\.amountPerMile), [0.725, 0.76])
        XCTAssertEqual(periods.map(\.effectiveFrom), [january, july])
        XCTAssertTrue(periods.allSatisfy { $0.sourceURL == IRSBusinessRateClient.sourceURL.absoluteString })
        XCTAssertEqual(periods.last?.rateEvidence, "2026 (July 1 – Dec. 31) | 76 | 14 | 23.5 | IR-2026-29 |")
        XCTAssertEqual(periods.last?.periodEvidence, "2026 (July 1 – Dec. 31)")
    }

    func testUnsupportedColumnsAndUnitsFailClosed() async throws {
        let unsupported = [
            Self.html.replacingOccurrences(of: "<th>Business use</th>", with: "<th>Non-business use</th>"),
            Self.html.replacingOccurrences(of: "<th>Business use</th><th>Charity use</th>", with: "<th>Charity use</th><th>Business use</th>"),
            Self.html.replacingOccurrences(of: "Mileage rates for all years (cents/mile)", with: "Mileage rates for all years (dollars/mile)"),
            Self.html.replacingOccurrences(of: "Mileage rates for all years (cents/mile)", with: "Mileage rates for all years")
        ]
        for html in unsupported {
            do {
                _ = try await makeClient(Stub(responses: [Self.page(html)])).fetchPeriods(since: july, now: now, force: false)
                XCTFail("Unsupported table structure must not choose a rate")
            } catch { XCTAssertEqual(error as? IRSBusinessRateClientError, .invalidSource) }
        }
    }

    func testInvalidDatesAndMalformedRelevantPeriodFailClosed() async throws {
        for html in [
            Self.html.replacingOccurrences(of: "Dec.&nbsp;31", with: "Nov.&nbsp;31"),
            Self.html.replacingOccurrences(of: "July&nbsp;1", with: "Someday&nbsp;1"),
            Self.html.replacingOccurrences(of: "<td>76</td>", with: "<td>76 or 77</td>")
        ] {
            do {
                _ = try await makeClient(Stub(responses: [Self.page(html)])).fetchPeriods(since: july, now: now, force: false)
                XCTFail("Unclear rate evidence must not be guessed")
            } catch { XCTAssertTrue([.invalidSource, .invalidExtraction].contains(error as? IRSBusinessRateClientError)) }
        }
    }

    func testDuplicateOfficialPeriodsAreAmbiguous() async throws {
        let duplicate = Self.html.replacingOccurrences(of: "<tbody>", with:
            "<tbody><tr><td>2026 (July 1 – Dec. 31)</td><td>77</td><td>14</td><td>23.5</td><td>conflicting-fixture</td></tr>")
        do {
            _ = try await makeClient(Stub(responses: [Self.page(duplicate)])).fetchPeriods(since: july, now: now, force: false)
            XCTFail("Conflicting periods must not be selected by row order")
        } catch { XCTAssertEqual(error as? IRSBusinessRateClientError, .ambiguousRate) }
    }

    func testInvalidDiskCacheIsIgnoredBeforeConditionalRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appending(path: "cache.json")
        let first = makeClient(Stub(responses: [Self.page(Self.html)]), cacheURL: cacheURL)
        _ = try await first.fetchPeriods(since: july, now: now, force: false)
        var cached = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        var periods = try XCTUnwrap(cached["periods"] as? [[String: Any]])
        periods[0]["amountPerMile"] = 0.235
        cached["periods"] = periods
        try JSONSerialization.data(withJSONObject: cached).write(to: cacheURL)
        let stub = Stub(responses: [Self.page(status: 304)])
        do {
            _ = try await makeClient(stub, cacheURL: cacheURL).fetchPeriods(since: july, now: now, force: false)
            XCTFail("Invalid cached rates cannot satisfy a 304 response")
        } catch { XCTAssertEqual(error as? IRSBusinessRateClientError, .invalidResponse) }
        let requests = await stub.state()
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "If-Modified-Since"))
    }

    func testCancellationAfterDownloadDoesNotWriteCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appending(path: "cache.json")
        let client = IRSBusinessRateClient(cacheURL: cacheURL, loadPage: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return Self.page(Self.html)
        })
        let task = Task { try await client.fetchPeriods(since: july, now: now, force: false) }
        do { _ = try await task.value; XCTFail("Cancelled result must be discarded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    private func makeClient(_ stub: Stub, cacheURL: URL? = nil) -> IRSBusinessRateClient {
        IRSBusinessRateClient(cacheURL: cacheURL, loadPage: { try await stub.load($0) })
    }

    private actor Stub {
        var responses: [IRSRatePageResponse]
        var requests: [URLRequest] = []
        init(responses: [IRSRatePageResponse]) { self.responses = responses }
        func load(_ request: URLRequest) throws -> IRSRatePageResponse {
            requests.append(request)
            guard !responses.isEmpty else { throw IRSBusinessRateClientError.invalidResponse }
            return responses.removeFirst()
        }
        func state() -> [URLRequest] { requests }
    }

    nonisolated private static func page(_ html: String = "", status: Int = 200, etag: String = "version-a") -> IRSRatePageResponse {
        IRSRatePageResponse(data: Data(html.utf8), statusCode: status, url: IRSBusinessRateClient.sourceURL,
                            contentType: "text/html; charset=UTF-8", etag: etag, lastModified: "Sat, 03 Oct 2026 12:00:00 GMT")
    }

    nonisolated private static var firstHalf: IRSBusinessRatePeriod {
        .init(effectiveFrom: .init(year: 2026, month: 1, day: 1), effectiveThrough: .init(year: 2026, month: 6, day: 30),
              amountPerMile: 0.725, sourceURL: IRSBusinessRateClient.sourceURL.absoluteString,
              rateEvidence: "2026 (Jan. 1 – June 30) | 72.5", periodEvidence: "2026 (Jan. 1 – June 30)")
    }
    nonisolated private static var secondHalf: IRSBusinessRatePeriod {
        .init(effectiveFrom: .init(year: 2026, month: 7, day: 1), effectiveThrough: .init(year: 2026, month: 12, day: 31),
              amountPerMile: 0.76, sourceURL: IRSBusinessRateClient.sourceURL.absoluteString,
              rateEvidence: "Self-employed and business: 76 cents/mile", periodEvidence: "2026 (July 1 – Dec. 31)")
    }
    nonisolated private static var future: IRSBusinessRatePeriod {
        .init(effectiveFrom: .init(year: 2027, month: 1, day: 1), effectiveThrough: .init(year: 2027, month: 12, day: 31),
              amountPerMile: 0.80, sourceURL: IRSBusinessRateClient.sourceURL.absoluteString,
              rateEvidence: "2027 | 80", periodEvidence: "2027")
    }

    // Narrow fixture copied from the live IRS page's body and table structure;
    // surrounding distractions exercise the cleaner, without a live dependency.
    nonisolated private static let html = """
    <html><nav>menu</nav><main role="main"><script>business: 999 cents</script>
    <div class="clearfix field field--name-body field__item">
    <h2>2026 mileage rates (July 1 &ndash; Dec. 31)</h2>
    <p>The standard mileage rates for 2026 are:</p><ul>
    <li>Self-employed and business: 76 cents/mile</li><li>Charities: 14 cents/mile</li>
    <li>Medical: 23.5 cents/mile</li><li>Moving (military only): 23.5 cents/mile</li></ul>
    <h2>Mileage rates for all years (cents/mile)</h2>
    <table><thead><tr><th>Period</th><th>Business use</th><th>Charity use</th><th>Medical or military moving</th><th>Source</th></tr></thead>
    <tbody><tr><td>2026 (July&nbsp;1 &ndash; Dec.&nbsp;31)</td><td>76</td><td>14</td><td>23.5</td><td><a href="/irb/2026-29_irb">IR-2026-29</a></td></tr>
    <tr><td>2026 (Jan.&nbsp;1 &ndash; June&nbsp;30)</td><td>72.5</td><td>14</td><td>20.5</td><td>IR-2025-128</td></tr>
    <tr><td>2025</td><td>70</td><td>14</td><td>21</td><td>IR-2024-312</td></tr></tbody></table>
    </div><aside>related topics</aside></main></html>
    """
    nonisolated private static var futureHTML: String {
        html.replacingOccurrences(of: "<tbody>", with: "<tbody><tr><td>2027</td><td>80</td><td>14</td><td>22</td><td>future-announcement-fixture</td></tr>")
    }
}
