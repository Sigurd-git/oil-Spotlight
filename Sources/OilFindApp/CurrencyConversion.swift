import Foundation

struct CurrencyQuery: Equatable {
    let expression: String
    let amount: Decimal
    let source: String
    let target: String

    static func parse(_ text: String) -> CurrencyQuery? {
        guard text.utf16.count <= 256 else { return nil }
        let expression = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = expression.replacingOccurrences(of: "−", with: "-")
        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = pattern.firstMatch(in: normalized, range: range), match.range == range,
              let amountRange = Range(match.range(at: 1), in: normalized),
              let sourceRange = Range(match.range(at: 2), in: normalized),
              let targetRange = Range(match.range(at: 3), in: normalized),
              let amount = Decimal(string: normalized[amountRange].replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")),
              !amount.isNaN,
              normalizedNumber(String(normalized[amountRange]).replacingOccurrences(of: ",", with: "")) == normalizedNumber(amount.description),
              let source = aliases[aliasKey(String(normalized[sourceRange]))],
              let target = aliases[aliasKey(String(normalized[targetRange]))] else { return nil }
        return CurrencyQuery(expression: expression, amount: amount, source: source, target: target)
    }

    static let supportedCodes = ["EUR", "USD", "CNY", "GBP", "JPY", "HKD", "CAD", "AUD", "NZD", "SGD", "CHF", "KRW", "INR"]

    // Reject Decimal overflow, underflow or silent rounding before accepting an amount.
    private static func normalizedNumber(_ text: String) -> String {
        var magnitude = text
        let negative = magnitude.hasPrefix("-")
        if negative || magnitude.hasPrefix("+") { magnitude.removeFirst() }
        let parts = magnitude.split(separator: ".", omittingEmptySubsequences: false)
        let integer = parts[0].drop(while: { $0 == "0" })
        let whole = integer.isEmpty ? "0" : String(integer)
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        while fraction.last == "0" { fraction.removeLast() }
        return (negative && (whole != "0" || !fraction.isEmpty) ? "-" : "") + whole
            + (fraction.isEmpty ? "" : "." + fraction)
    }

    private static let names: [String: [String]] = [
        "EUR": ["euro", "euros", "欧元"],
        "USD": ["dollar", "dollars", "us dollar", "us dollars", "american dollar", "american dollars", "美元", "美金"],
        "CNY": ["rmb", "yuan", "renminbi", "chinese yuan", "chinese renminbi", "人民币", "人民幣"],
        "GBP": ["pound", "pounds", "pound sterling", "sterling", "british pound", "british pounds", "英镑", "英鎊"],
        "JPY": ["yen", "japanese yen", "日元", "日圆", "日圓"],
        "HKD": ["hong kong dollar", "hong kong dollars", "hk dollar", "hk dollars", "港币", "港幣", "港元"],
        "CAD": ["canadian dollar", "canadian dollars", "加元", "加币", "加幣"],
        "AUD": ["australian dollar", "australian dollars", "澳元", "澳币", "澳幣"],
        "NZD": ["new zealand dollar", "new zealand dollars", "新西兰元", "新西蘭元", "纽元", "紐元"],
        "SGD": ["singapore dollar", "singapore dollars", "新加坡元", "新加坡币", "新加坡幣", "新元"],
        "CHF": ["swiss franc", "swiss francs", "瑞郎", "瑞士法郎"],
        "KRW": ["won", "korean won", "south korean won", "韩元", "韓元"],
        "INR": ["rupee", "rupees", "indian rupee", "indian rupees", "印度卢比", "印度盧比"]
    ]

    private static func aliasKey(_ text: String) -> String {
        text.lowercased().components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private static let aliases: [String: String] = {
        var result: [String: String] = [:]
        for code in supportedCodes {
            for name in [code] + (names[code] ?? []) { result[aliasKey(name)] = code }
        }
        return result
    }()

    private static let pattern: NSRegularExpression = {
        var currencyNames: [String] = []
        for code in supportedCodes { currencyNames += [code] + (names[code] ?? []) }
        currencyNames.sort { $0.count > $1.count }
        let escapedNames: [String] = currencyNames.map { name in
            let words = name.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            return words.joined(separator: #"\s*"#)
        }
        let currency = escapedNames.joined(separator: "|")
        let number = #"[+-]?(?:(?:[0-9]+|[1-9][0-9]{0,2}(?:,[0-9]{3})+)(?:\.[0-9]+)?|\.[0-9]+)"#
        return try! NSRegularExpression(pattern: #"\A("# + number + #")\s*("# + currency
            + #")\s*(?:in\s*to|to|in|转|換成|换成|兑换成|兑)\s*("# + currency + #")\z"#,
            options: .caseInsensitive)
    }()
}

struct CurrencyQuote: Equatable {
    let value: String
    let date: String
    let isCached: Bool
    let isStale: Bool
}

enum CurrencyLookup: Equatable {
    case ready(CurrencyQuote)
    case loading
    case unavailable
}

// The transport starts on the worker queue; completion may run on any queue.
// Its cancellation action must be thread-safe and idempotent.
typealias CurrencyTransport = (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> (() -> Void)

final class CurrencyRateProvider {
    var onChange: (() -> Void)? {
        didSet { dispatchPrecondition(condition: .onQueue(.main)) }
    }

    private let snapshot: Bool
    private let transport: CurrencyTransport?
    private let session: URLSession?
    private let clock: () -> Date
    private let worker = DispatchQueue(label: "com.oiloil.find.currency", qos: .utility)
    private var cacheURL: URL?
    private var record: CurrencyRateRecord?
    private var loadedFromDisk = false
    private var loadingCache = true
    private var retryRequested = false
    private var stopped = false
    private var requestGeneration = 0
    private var request: CurrencyCancellation?
    private var retryAfter = Date.distantPast
    private var activeQuery: CurrencyQuery?
    private var published: CurrencyLookup?

    private static let refreshInterval: TimeInterval = 24 * 60 * 60
    private static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    private static let failureBackoff: TimeInterval = 60

    init(snapshot: Bool = false, transport: CurrencyTransport? = nil, session: URLSession? = nil,
         clock: @escaping () -> Date = Date.init, cacheURL: URL? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.snapshot = snapshot
        self.transport = transport
        self.session = session
        self.clock = clock
        self.cacheURL = cacheURL
        if snapshot {
            // Deliberately synthetic rates, isolated from the live ECB data and cache.
            record = CurrencyRateRecord(date: "2026-01-01", fetchedAt: Date(timeIntervalSince1970: 1767225600),
                                        rates: ["EUR": 1, "USD": 2, "CNY": 14])
            loadingCache = false
            return
        }
        let now = clock()
        // Bootstrap completes before any lookup/retry download can start, so old disk data cannot replace new rates.
        worker.async { [weak self] in
            let resolvedURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("Oil Find", isDirectory: true)
                .appendingPathComponent("currency-rates.json")
            let restored = resolvedURL.flatMap { CurrencyRateRecord.read(from: $0, now: now) }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.stopped else { return }
                self.cacheURL = resolvedURL
                self.record = restored
                self.loadedFromDisk = restored != nil
                self.loadingCache = false
                if let query = self.activeQuery {
                    if self.retryRequested, Self.supports(query), query.source != query.target { self.startRequest() }
                    else { self.refreshIfNeeded(for: query) }
                }
                self.retryRequested = false
                self.publishIfChanged()
            }
        }
    }

    func lookup(_ query: CurrencyQuery) -> CurrencyLookup {
        dispatchPrecondition(condition: .onQueue(.main))
        activeQuery = query
        refreshIfNeeded(for: query)
        let result = currentResult(for: query)
        published = result
        return result
    }

    func retry(_ query: CurrencyQuery) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !stopped else { return }
        activeQuery = query
        retryAfter = .distantPast
        retryRequested = loadingCache && query.source != query.target && Self.supports(query)
        if !snapshot, !loadingCache, query.source != query.target, Self.supports(query) { startRequest() }
        publishIfChanged()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopped = true
        requestGeneration += 1
        request?.cancel()
        request = nil
        activeQuery = nil
        onChange = nil
    }

    private static func supports(_ query: CurrencyQuery) -> Bool {
        !query.amount.isNaN && CurrencyQuery.supportedCodes.contains(query.source)
            && CurrencyQuery.supportedCodes.contains(query.target)
    }

    private func refreshIfNeeded(for query: CurrencyQuery) {
        guard !stopped, !snapshot, !loadingCache, Self.supports(query), query.source != query.target else { return }
        let now = clock()
        let needsRefresh = record.map { now.timeIntervalSince($0.fetchedAt) >= Self.refreshInterval } ?? true
        if needsRefresh {
            if now >= retryAfter { startRequest() }
        }
    }

    private func currentResult(for query: CurrencyQuery) -> CurrencyLookup {
        guard !stopped, Self.supports(query) else { return .unavailable }
        let now = clock()
        if query.source == query.target {
            guard let value = Self.format(query.amount, target: query.target) else { return .unavailable }
            return .ready(CurrencyQuote(value: value, date: "",
                                        isCached: false, isStale: false))
        }
        if let record = record, let date = CurrencyRateRecord.day(record.date),
           snapshot || now.timeIntervalSince(date) < Self.maximumAge,
           let source = record.rates[query.source], let target = record.rates[query.target] {
            // Decimal arithmetic avoids binary rounding artifacts in monetary display.
            guard let sourceRate = Decimal(string: String(source), locale: Locale(identifier: "en_US_POSIX")),
                  let targetRate = Decimal(string: String(target), locale: Locale(identifier: "en_US_POSIX")),
                  let value = Self.format(query.amount * targetRate / sourceRate, target: query.target) else { return .unavailable }
            let stale = !snapshot && (now.timeIntervalSince(record.fetchedAt) >= Self.refreshInterval
                || now.timeIntervalSince(date) >= 7 * Self.refreshInterval)
            return .ready(CurrencyQuote(value: value, date: record.date,
                                        isCached: loadedFromDisk || stale, isStale: stale))
        }
        return !snapshot && (loadingCache || request != nil) ? .loading : .unavailable
    }

    private static func format(_ amount: Decimal, target: String) -> String? {
        guard !amount.isNaN, NSDecimalNumber(decimal: amount).doubleValue.isFinite else { return nil }
        let digits = ["JPY", "KRW"].contains(target) ? 0 : 2
        var input = amount, rounded = Decimal()
        NSDecimalRound(&rounded, &input, digits, .plain)
        guard !rounded.isNaN else { return nil }
        // Preserve all Decimal digits instead of passing monetary amounts through binary64 formatting.
        var value = (rounded == 0 ? Decimal.zero : rounded).description
        let fractionDigits = value.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        if digits > 0 {
            if !value.contains(".") { value += "." }
            value += String(repeating: "0", count: max(0, digits - fractionDigits))
        }
        return value + " " + target
    }

    private func startRequest() {
        guard request == nil, !stopped else { return }
        requestGeneration += 1
        let generation = requestGeneration
        let cancellation = CurrencyCancellation()
        request = cancellation
        let now = clock(), injectedTransport = transport, injectedSession = session
        worker.async { [weak self] in
            guard !cancellation.isCancelled else { return }
            var components = URLComponents(string: "https://api.frankfurter.dev/v2/rates")!
            components.queryItems = [URLQueryItem(name: "base", value: "EUR"),
                                     URLQueryItem(name: "providers", value: "ecb"),
                                     URLQueryItem(name: "quotes", value: CurrencyQuery.supportedCodes.filter { $0 != "EUR" }.joined(separator: ","))]
            var urlRequest = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            urlRequest.httpMethod = "GET"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            let completion: (Data?, URLResponse?, Error?) -> Void = { [weak self] data, response, error in
                self?.worker.async { [weak self] in
                    let decoded = error == nil ? CurrencyRateRecord.decodeResponse(data, response: response, now: now) : nil
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, !self.stopped, self.requestGeneration == generation,
                              self.request != nil else { return }
                        self.request = nil
                        if var decoded = decoded {
                            decoded.fetchedAt = self.clock()
                            self.record = decoded
                            self.loadedFromDisk = false
                            self.retryAfter = .distantPast
                            if let cacheURL = self.cacheURL {
                                let savedRecord = decoded
                                self.worker.async { savedRecord.save(to: cacheURL) }
                            }
                        } else {
                            self.retryAfter = self.clock().addingTimeInterval(Self.failureBackoff)
                        }
                        self.publishIfChanged()
                    }
                }
            }
            if let injectedTransport = injectedTransport {
                cancellation.install(injectedTransport(urlRequest, completion))
            } else {
                let networkSession: URLSession
                if let injectedSession = injectedSession { networkSession = injectedSession }
                else {
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.urlCache = nil
                    configuration.httpCookieStorage = nil
                    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                    networkSession = URLSession(configuration: configuration)
                }
                let task = networkSession.dataTask(with: urlRequest) { data, response, error in
                    completion(data, response, error)
                    if injectedSession == nil { networkSession.finishTasksAndInvalidate() }
                }
                cancellation.install { task.cancel() }
                if !cancellation.isCancelled { task.resume() }
                else if injectedSession == nil { networkSession.invalidateAndCancel() }
            }
        }
    }

    private func publishIfChanged() {
        guard !stopped, let query = activeQuery else { return }
        let result = currentResult(for: query)
        guard published != result else { return }
        published = result
        onChange?()
    }
}

private struct CurrencyRateRecord: Codable {
    var version = 1
    var base = "EUR"
    var provider = "ECB"
    let date: String
    var fetchedAt: Date
    let rates: [String: Double]

    private static let maximumBytes = 64 * 1024
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func day(_ text: String) -> Date? {
        guard text.utf8.count == 10,
              text.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (2000...9999).contains(parts[0]) else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == parts[0], actual.month == parts[1], actual.day == parts[2] else { return nil }
        return date
    }

    private func isValid(now: Date) -> Bool {
        guard version == 1, base == "EUR", provider == "ECB", let day = Self.day(date),
              day <= Self.calendar.startOfDay(for: now),
              fetchedAt.timeIntervalSince1970.isFinite, fetchedAt.timeIntervalSince1970 > 0,
              fetchedAt <= now.addingTimeInterval(300),
              Set(rates.keys) == Set(CurrencyQuery.supportedCodes), rates["EUR"] == 1 else { return false }
        return rates.values.allSatisfy { $0.isFinite && $0 > 0 }
    }

    private struct Rate: Decodable {
        let date: String
        let base: String
        let quote: String
        let rate: Double
    }

    static func decodeResponse(_ data: Data?, response: URLResponse?, now: Date) -> CurrencyRateRecord? {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength <= Int64(maximumBytes),
              let data = data, !data.isEmpty, data.count <= maximumBytes,
              let rows = try? JSONDecoder().decode([Rate].self, from: data),
              rows.count == CurrencyQuery.supportedCodes.count - 1, let first = rows.first else { return nil }
        var rates: [String: Double] = ["EUR": 1]
        for row in rows {
            guard row.base == "EUR", row.date == first.date, row.quote != "EUR",
                  CurrencyQuery.supportedCodes.contains(row.quote), rates[row.quote] == nil,
                  row.rate.isFinite, row.rate > 0 else { return nil }
            rates[row.quote] = row.rate
        }
        let record = CurrencyRateRecord(date: first.date, fetchedAt: now, rates: rates)
        return record.isValid(now: now) ? record : nil
    }

    static func read(from url: URL, now: Date) -> CurrencyRateRecord? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: maximumBytes + 1), data.count <= maximumBytes,
              let record = try? JSONDecoder().decode(CurrencyRateRecord.self, from: data),
              record.isValid(now: now) else { return nil }
        return record
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // A cache write failure must not discard a valid in-memory quote.
        }
    }
}

// Only cancellation crosses queues; provider and presentation state stay on the main queue.
private final class CurrencyCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (() -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func install(_ action: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            action()
        } else {
            self.action = action
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }
}
