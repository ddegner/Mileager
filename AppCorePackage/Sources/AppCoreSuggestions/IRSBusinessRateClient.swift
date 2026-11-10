import AppCoreModels
import Foundation

public protocol IRSBusinessRateFetching: Sendable {
    func fetchPeriods(since: MileageRateEffectiveDate, now: Date, force: Bool) async throws -> [IRSBusinessRatePeriod]
}

public enum IRSBusinessRateClientError: Error, Equatable {
    case invalidSource, invalidResponse, responseTooLarge, missingRate, ambiguousRate
    case invalidExtraction
}

/// Fetches and validates the public IRS business-rate table. Unsupported or
/// conflicting evidence fails closed. This client never changes user rates.
public actor IRSBusinessRateClient: IRSBusinessRateFetching {
    public static let sourceURL = URL(string: "https://www.irs.gov/tax-professionals/standard-mileage-rates")!

    private let cacheURL: URL?
    private let loadPage: @Sendable (URLRequest) async throws -> IRSRatePageResponse
    private var cache: Cache?
    private var loadedCache = false

    public init() {
        cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "IRSBusinessMileageRates-v1.json")
        loadPage = Self.download
    }

    /// Uses the production HTTP/parser pipeline with a caller-owned cache scope.
    public init(cacheURL: URL?) {
        self.cacheURL = cacheURL
        loadPage = Self.download
    }

    /// The injected transport exercises the production parser without a live request.
    init(
        cacheURL: URL? = nil,
        loadPage: @escaping @Sendable (URLRequest) async throws -> IRSRatePageResponse
    ) {
        self.cacheURL = cacheURL
        self.loadPage = loadPage
    }

    public func fetchPeriods(
        since: MileageRateEffectiveDate,
        now: Date,
        force: Bool
    ) async throws -> [IRSBusinessRatePeriod] {
        try Task.checkCancellation()
        loadCacheIfNeeded()
        var request = URLRequest(url: Self.sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        if force { request.setValue("no-cache", forHTTPHeaderField: "Cache-Control") }
        if let etag = cache?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = cache?.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        let response = try await loadPage(request)
        try Task.checkCancellation()
        guard Self.isOfficialURL(response.url) else { throw IRSBusinessRateClientError.invalidSource }

        let cleaned: String
        switch response.statusCode {
        case 304:
            guard let cached = cache else { throw IRSBusinessRateClientError.invalidResponse }
            cleaned = cached.cleanedContent
        case 200:
            guard response.data.count <= 1_048_576 else { throw IRSBusinessRateClientError.responseTooLarge }
            guard response.contentType?.lowercased().contains("text/html") == true,
                  let html = String(data: response.data, encoding: .utf8) else {
                throw IRSBusinessRateClientError.invalidResponse
            }
            cleaned = try IRSRateHTMLCleaner.clean(html)
        default:
            throw IRSBusinessRateClientError.invalidResponse
        }
        let relevant = try IRSRateSourceEvidence.relevantContent(cleaned, since: since)
        if let cached = cache, cached.coverageStart <= since, relevant == (try IRSRateSourceEvidence.relevantContent(cached.cleanedContent, since: since)) {
            let periods = try IRSRateSourceEvidence.validate(cached.periods, source: cleaned, since: since)
            try Task.checkCancellation()
            saveCache(Cache(cleanedContent: cleaned, relevantContent: relevant, coverageStart: since,
                            periods: periods, etag: response.statusCode == 304 ? response.etag ?? cached.etag : response.etag,
                            lastModified: response.statusCode == 304 ? response.lastModified ?? cached.lastModified : response.lastModified, checkedAt: now))
            return periods
        }

        let periods = try IRSRateSourceEvidence.extract(relevant, since: since)
        try Task.checkCancellation()
        saveCache(Cache(cleanedContent: cleaned, relevantContent: relevant, coverageStart: since, periods: periods,
                        etag: response.statusCode == 304 ? response.etag ?? cache?.etag : response.etag,
                        lastModified: response.statusCode == 304 ? response.lastModified ?? cache?.lastModified : response.lastModified,
                        checkedAt: now))
        return periods
    }

    private struct Cache: Codable {
        var version = 1
        var cleanedContent: String
        var relevantContent: String
        var coverageStart: MileageRateEffectiveDate
        var periods: [IRSBusinessRatePeriod]
        var etag: String?
        var lastModified: String?
        var checkedAt: Date
    }

    private func loadCacheIfNeeded() {
        guard !loadedCache else { return }
        loadedCache = true
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL), data.count <= 1_048_576,
              let cached = try? JSONDecoder().decode(Cache.self, from: data), cached.version == 1,
              (try? IRSRateSourceEvidence.validate(cached.periods, source: cached.cleanedContent,
                                                  since: cached.coverageStart)) != nil else { return }
        cache = cached
    }

    private func saveCache(_ value: Cache) {
        cache = value
        guard let cacheURL, let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func isOfficialURL(_ url: URL) -> Bool {
        url.scheme == "https" && ["irs.gov", "www.irs.gov"].contains(url.host?.lowercased() ?? "")
            && url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "tax-professionals/standard-mileage-rates"
    }

    private static func download(_ request: URLRequest) async throws -> IRSRatePageResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, let url = http.url else {
            throw IRSBusinessRateClientError.invalidResponse
        }
        return IRSRatePageResponse(data: data, statusCode: http.statusCode, url: url,
                                   contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                   etag: http.value(forHTTPHeaderField: "ETag"),
                                   lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    }
}

struct IRSRatePageResponse: Sendable {
    var data: Data
    var statusCode: Int
    var url: URL
    var contentType: String?
    var etag: String?
    var lastModified: String?
}

/// Preserves row and column boundaries; flattening the table can associate the
/// charity/medical value with the business label. Navigation and scripts never
/// enter the source evidence.
enum IRSRateHTMLCleaner {
    static func clean(_ html: String) throws -> String {
        guard let main = capture("(?is)<main\\b[^>]*>(.*?)</main\\s*>", in: html) else {
            throw IRSBusinessRateClientError.invalidSource
        }
        var body = capture("(?is)<div\\b[^>]*class=[\"'][^\"']*field--name-body[^\"']*[\"'][^>]*>(.*?)</div\\s*>", in: main) ?? main
        for tag in ["script", "style", "noscript", "nav", "aside"] {
            body = replacing("(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", in: body, with: " ")
        }
        body = replacing("(?s)<!--.*?-->", in: body, with: " ")
        body = replacing("(?i)</(?:td|th)\\s*>", in: body, with: " | ")
        body = replacing("(?i)</?(?:tr|p|h[1-6]|li|ul|ol|table|thead|tbody|div|br)\\b[^>]*>", in: body, with: "\n")
        body = replacing("(?s)<[^>]+>", in: body, with: " ")
        body = decodeEntities(body)
        let lines = body.components(separatedBy: .newlines).map {
            replacing("[\\t ]+", in: $0.replacingOccurrences(of: "\u{00a0}", with: " "), with: " ").trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        let content = lines.joined(separator: "\n")
        guard !content.isEmpty, content.count <= 60_000 else { throw IRSBusinessRateClientError.responseTooLarge }
        return content
    }

    static func normalized(_ text: String) -> String {
        replacing("\\s+", in: text, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func capture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let entities = ["&nbsp;": " ", "&ndash;": "–", "&mdash;": "—", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&amp;": "&"]
        for (entity, value) in entities { result = result.replacingOccurrences(of: entity, with: value) }
        guard let expression = try? NSRegularExpression(pattern: "&#(x[0-9A-Fa-f]+|[0-9]+);") else { return result }
        let matches = expression.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let digitsRange = Range(match.range(at: 1), in: result), let fullRange = Range(match.range, in: result) else { continue }
            let digits = String(result[digitsRange])
            let value = digits.first == "x" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            if let value, let scalar = UnicodeScalar(value) { result.replaceSubrange(fullRange, with: String(scalar)) }
        }
        return result
    }
}

/// Only recognized period syntax and the business column of the official
/// cents-per-mile table can produce a rate. Unsupported layouts fail closed.
enum IRSRateSourceEvidence {
    private struct SourcePeriod: Equatable {
        var from: MileageRateEffectiveDate
        var through: MileageRateEffectiveDate
        var cents: Double
        var line: String
        var periodEvidence: String
    }

    static func relevantContent(_ source: String, since: MileageRateEffectiveDate) throws -> String {
        let rows = try sourcePeriods(source, since: since)
        guard !rows.isEmpty else { throw IRSBusinessRateClientError.missingRate }
        let lines = source.components(separatedBy: .newlines)
        guard let headerIndex = lines.firstIndex(where: isBusinessHeader) else { throw IRSBusinessRateClientError.invalidSource }
        return (Array(lines[..<headerIndex]) + [lines[headerIndex]] + rows.map(\.line)).joined(separator: "\n")
    }

    static func extract(_ source: String, since: MileageRateEffectiveDate) throws -> [IRSBusinessRatePeriod] {
        let periods = try sourcePeriods(source, since: since).map {
            IRSBusinessRatePeriod(effectiveFrom: $0.from, effectiveThrough: $0.through,
                amountPerMile: $0.cents / 100, sourceURL: IRSBusinessRateClient.sourceURL.absoluteString,
                rateEvidence: $0.line, periodEvidence: $0.periodEvidence)
        }
        return try validate(periods, source: source, since: since)
    }

    static func validate(
        _ periods: [IRSBusinessRatePeriod], source: String, since: MileageRateEffectiveDate
    ) throws -> [IRSBusinessRatePeriod] {
        let expected = try sourcePeriods(source, since: since)
        guard !expected.isEmpty else { throw IRSBusinessRateClientError.missingRate }
        guard !periods.isEmpty, periods.count <= 40 else { throw IRSBusinessRateClientError.invalidExtraction }
        let sorted: [IRSBusinessRatePeriod]
        do { sorted = try IRSBusinessRateScheduleUpdater.validatedPeriods(periods) }
        catch { throw IRSBusinessRateClientError.invalidExtraction }
        let relevant = sorted.filter { $0.effectiveThrough >= since }
        guard relevant.count == expected.count else { throw IRSBusinessRateClientError.invalidExtraction }
        let normalizedSource = IRSRateHTMLCleaner.normalized(source)
        for period in relevant {
            let rateQuote = IRSRateHTMLCleaner.normalized(period.rateEvidence)
            let periodQuote = IRSRateHTMLCleaner.normalized(period.periodEvidence)
            guard period.sourceURL == IRSBusinessRateClient.sourceURL.absoluteString,
                  period.amountPerMile.isFinite, period.amountPerMile > 0, period.amountPerMile <= 5,
                  !rateQuote.isEmpty, !periodQuote.isEmpty,
                  normalizedSource.contains(rateQuote), normalizedSource.contains(periodQuote),
                  let dates = parsePeriod(periodQuote), dates.0 == period.effectiveFrom, dates.1 == period.effectiveThrough,
                  let row = expected.first(where: { $0.from == period.effectiveFrom && $0.through == period.effectiveThrough }),
                  abs(row.cents / 100 - period.amountPerMile) < 0.000000001,
                  quoteContainsRate(rateQuote, cents: row.cents) else {
                throw IRSBusinessRateClientError.invalidExtraction
            }
        }
        return relevant
    }

    private static func quoteContainsRate(_ quote: String, cents: Double) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: "(?<![0-9.])[0-9]+(?:\\.[0-9]+)?(?![0-9.])") else { return false }
        return expression.matches(in: quote, range: NSRange(quote.startIndex..., in: quote)).contains {
            guard let range = Range($0.range, in: quote), let value = Double(quote[range]) else { return false }
            return abs(value - cents) < 0.000000001
        }
    }

    private static func sourcePeriods(_ source: String, since: MileageRateEffectiveDate) throws -> [SourcePeriod] {
        let lines = source.components(separatedBy: .newlines)
        let headerIndices = lines.indices.filter { isBusinessHeader(lines[$0]) }
        guard headerIndices.count == 1, let headerIndex = headerIndices.first,
              headerIndex > 0,
              IRSRateHTMLCleaner.capture("(?i)(cents\\s*(?:/|per\\s+)\\s*mile)", in: lines[headerIndex - 1]) != nil else {
            throw IRSBusinessRateClientError.invalidSource
        }
        var rows: [SourcePeriod] = []
        for line in lines.dropFirst(headerIndex + 1) where line.contains("|") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2 else { continue }
            guard let dates = parsePeriod(cells[0]) else {
                if let yearString = IRSRateHTMLCleaner.capture("([0-9]{4})", in: cells[0]),
                   let year = Int(yearString), year >= since.year { throw IRSBusinessRateClientError.invalidSource }
                continue
            }
            guard dates.1 >= since else { continue }
            guard let cents = Double(cells[1]), cents.isFinite, cents > 0, cents <= 500 else {
                throw IRSBusinessRateClientError.invalidSource
            }
            rows.append(SourcePeriod(from: dates.0, through: dates.1, cents: cents, line: line, periodEvidence: cells[0]))
        }
        rows.sort { $0.from < $1.from }
        for (first, second) in zip(rows, rows.dropFirst()) where first.through >= second.from {
            throw IRSBusinessRateClientError.ambiguousRate
        }
        // A headline business bullet is an independent statement. A conflict
        // with the table must not be resolved by choosing one over the other.
        var headlineDates: (MileageRateEffectiveDate, MileageRateEffectiveDate)?
        for line in lines[..<headerIndex] {
            if line.lowercased().contains("mileage rates"), let dates = parsePeriod(line) { headlineDates = dates }
            if line.lowercased().contains("business"), !line.contains("|"),
               let number = IRSRateHTMLCleaner.capture("(?i)business\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)\\s*cents", in: line),
               let cents = Double(number), let dates = headlineDates,
               let row = rows.first(where: { $0.from == dates.0 && $0.through == dates.1 }), abs(row.cents - cents) > 0.000000001 {
                throw IRSBusinessRateClientError.ambiguousRate
            }
        }
        return rows
    }

    private static func isBusinessHeader(_ line: String) -> Bool {
        let cells = line.lowercased().split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.count >= 2 && cells[0] == "period" && cells[1] == "business use"
    }

    static func parsePeriod(_ text: String) -> (MileageRateEffectiveDate, MileageRateEffectiveDate)? {
        let period = IRSRateHTMLCleaner.normalized(text).replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        if let yearText = IRSRateHTMLCleaner.capture("^([0-9]{4})(?: mileage rates)?$", in: period), let year = Int(yearText) {
            return (.init(year: year, month: 1, day: 1), .init(year: year, month: 12, day: 31))
        }
        if let yearText = IRSRateHTMLCleaner.capture("^([0-9]{4})(?: mileage rates)? \\(.*\\)$", in: period), let year = Int(yearText),
           let rangeText = IRSRateHTMLCleaner.capture("^[0-9]{4}(?: mileage rates)? \\((.*)\\)$", in: period) {
            let halves = rangeText.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            guard halves.count == 2, let start = monthAndDay(halves[0], year: year), let end = monthAndDay(halves[1], year: year) else { return nil }
            return (start, end)
        }
        let halves = period.split(separator: "-").map(String.init)
        guard halves.count == 2, let start = numericDate(halves[0]), let end = numericDate(halves[1]) else { return nil }
        return (start, end)
    }

    private static func monthAndDay(_ text: String, year: Int) -> MileageRateEffectiveDate? {
        let parts = text.replacingOccurrences(of: ".", with: "").lowercased().split(separator: " ")
        let months = ["jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
                      "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
                      "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9,
                      "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12]
        guard parts.count == 2, let month = months[String(parts[0])], let day = Int(parts[1]) else { return nil }
        return .init(year: year, month: month, day: day)
    }

    private static func numericDate(_ text: String) -> MileageRateEffectiveDate? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return .init(year: parts[2], month: parts[0], day: parts[1])
    }
}
