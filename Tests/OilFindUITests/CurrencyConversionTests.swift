import Foundation
import XCTest
@testable import OilFindApp

final class CurrencyConversionTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1767355200) // 2026-01-02 12:00 UTC.
    private var cacheURL: URL { directory.appendingPathComponent("currency-rates.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindCurrencyTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func query(_ text: String = "100 USD to CNY") -> CurrencyQuery {
        CurrencyQuery.parse(text)!
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(condition(), "Timed out waiting for asynchronous currency work", file: file, line: line)
    }

    private func assertQuote(_ result: CurrencyLookup, value: String, date: String = "2026-01-01",
                             cached: Bool = false, stale: Bool = false,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result, .ready(CurrencyQuote(value: value, date: date, isCached: cached, isStale: stale)),
                       file: file, line: line)
    }

    // Every fixture is synthetic; these numbers are not historical ECB quotes.
    private var rates: [String: Double] {
        ["EUR": 1, "USD": 2, "CNY": 14, "GBP": 0.5, "JPY": 100, "HKD": 10,
         "CAD": 3, "AUD": 4, "NZD": 5, "SGD": 6, "CHF": 0.8, "KRW": 1000, "INR": 80]
    }

    private func rows(date: String = "2026-01-01") -> [[String: Any]] {
        CurrencyQuery.supportedCodes.filter { $0 != "EUR" }.map {
            ["date": date, "base": "EUR", "quote": $0, "rate": rates[$0]!]
        }
    }

    private func payload(date: String = "2026-01-01") -> Data {
        try! JSONSerialization.data(withJSONObject: rows(date: date))
    }

    private func waitForSavedCache(date: String = "2026-01-01", fetchedAt: Date? = nil, cny: Double = 14) {
        waitUntil {
            guard let data = try? Data(contentsOf: self.cacheURL),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rates = object["rates"] as? [String: Double] else { return false }
            return (object["date"] as? String) == date && rates["CNY"] == cny
                && (object["fetchedAt"] as? Double) == (fetchedAt ?? self.now).timeIntervalSinceReferenceDate
        }
    }

    private func writeCache(date: String = "2026-01-01", fetchedAt: Date? = nil,
                            replacementRates: [String: Double]? = nil) throws {
        let object: [String: Any] = ["version": 1, "base": "EUR", "provider": "ECB", "date": date,
                                     "fetchedAt": (fetchedAt ?? now).timeIntervalSinceReferenceDate,
                                     "rates": replacementRates ?? rates]
        try JSONSerialization.data(withJSONObject: object).write(to: cacheURL, options: .atomic)
    }

    func testOriginalExamplesAndExpressionIdentity() {
        for input in ["100 usd in to rmb", "100 USD to CNY", "100 usd in rmb", "100美元转人民币",
                      "100 usd INTO rmb", "100USDinCNY"] {
            let result = CurrencyQuery.parse(input)
            XCTAssertEqual(result?.expression, input)
            XCTAssertEqual(result?.amount, 100)
            XCTAssertEqual(result?.source, "USD")
            XCTAssertEqual(result?.target, "CNY")
        }
        let input = " \t−1,234.50  US Dollars  in  to 人民币  \n"
        let result = CurrencyQuery.parse(input)
        XCTAssertEqual(result?.expression, "−1,234.50  US Dollars  in  to 人民币")
        XCTAssertEqual(result?.amount, -1234.5)
        XCTAssertEqual(result?.source, "USD")
        XCTAssertEqual(result?.target, "CNY")
    }

    func testChineseAndEnglishAliasesForAllSupportedCurrencies() {
        let examples = [("人民币", "renminbi", "CNY"), ("美元", "US dollars", "USD"),
                        ("欧元", "euros", "EUR"), ("英镑", "British pounds", "GBP"),
                        ("日元", "Japanese yen", "JPY"), ("港币", "Hong Kong dollars", "HKD"),
                        ("加元", "Canadian dollars", "CAD"), ("澳元", "Australian dollars", "AUD"),
                        ("新西兰元", "New Zealand dollars", "NZD"), ("新加坡元", "Singapore dollars", "SGD"),
                        ("瑞郎", "Swiss francs", "CHF"), ("韩元", "South Korean won", "KRW"),
                        ("印度卢比", "Indian rupees", "INR")]
        for (chinese, english, code) in examples {
            XCTAssertEqual(CurrencyQuery.parse("1\(chinese)转美元")?.source, code)
            XCTAssertEqual(CurrencyQuery.parse("1 usd to \(english)")?.target, code)
            XCTAssertEqual(CurrencyQuery.parse("1 \(code.lowercased()) to EUR")?.source, code)
        }
        XCTAssertEqual(CurrencyQuery.parse("1 rmb to yuan")?.source, "CNY")
        XCTAssertEqual(CurrencyQuery.parse("1 rmb to yuan")?.target, "CNY")
    }

    func testNumbersLengthAndStrictWholeInputRejection() {
        for (input, amount) in [("+1,234,567.89 USD to EUR", 1234567.89), ("-.5 EUR to USD", -0.5),
                                ("0 USD to CNY", 0), ("0.001 USD to EUR", 0.001)] {
            XCTAssertEqual(CurrencyQuery.parse(input)?.amount, Decimal(string: String(amount)))
        }
        let expression = "1 USD to CNY"
        XCTAssertNotNil(CurrencyQuery.parse(expression + String(repeating: " ", count: 256 - expression.utf16.count)))
        XCTAssertNil(CurrencyQuery.parse(expression + String(repeating: " ", count: 257 - expression.utf16.count)))
        for input in ["", "100", "USD to CNY", "100 USD", "100 USD to", "100 USD to CNY extra",
                      "100 USD to CNY to EUR", "100 USD/CNY", "~/100 USD to CNY", "/tmp/100 USD to CNY",
                      "100 USD to CNY.txt", "web:100 USD to CNY", "100 BTC to CNY", "100 RUB to EUR",
                      "100 BGN to EUR", "100 XYZ to CNY", "100 USD to pesos", "NaN USD to CNY",
                      "Infinity USD to CNY", "1e309 USD to CNY", "1e3 USD to CNY", "1,00 USD to CNY",
                      "01,000 USD to CNY", "1,,000 USD to CNY", "1,000,00 USD to CNY", "1. USD to CNY",
                      "1.2.3 USD to CNY", "--1 USD to CNY", "1 000 USD to CNY", "1 USD to CNY\njunk"] {
            XCTAssertNil(CurrencyQuery.parse(input), input)
        }
    }

    func testSnapshotSyntheticPrecisionAndNoIO() {
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(snapshot: true, transport: transport.start, clock: { self.now }, cacheURL: cacheURL)
        defer { provider.stop() }
        assertQuote(provider.lookup(query()), value: "700.00 CNY")
        assertQuote(provider.lookup(query("0.1 USD to CNY")), value: "0.70 CNY")
        assertQuote(provider.lookup(query("1.005 EUR to EUR")), value: "1.01 EUR", date: "")
        assertQuote(provider.lookup(query("-1.005 USD to USD")), value: "-1.01 USD", date: "")
        assertQuote(provider.lookup(query("-0 USD to USD")), value: "0.00 USD", date: "")
        assertQuote(provider.lookup(query("-.0001 USD to USD")), value: "0.00 USD", date: "")
        assertQuote(provider.lookup(query("0.004 EUR to USD")), value: "0.01 USD")
        XCTAssertEqual(provider.lookup(CurrencyQuery(expression: "overflow", amount: .nan, source: "USD", target: "CNY")), .unavailable)
        XCTAssertEqual(provider.lookup(query("1 GBP to CNY")), .unavailable)
        provider.retry(query())
        XCTAssertEqual(transport.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testAmountsKeepDecimalPrecisionAndRejectUnrepresentableValues() {
        let provider = CurrencyRateProvider(snapshot: true)
        defer { provider.stop() }
        assertQuote(provider.lookup(query("9007199254740993 USD to USD")), value: "9007199254740993.00 USD", date: "")
        assertQuote(provider.lookup(query("123456789012345678.125 USD to USD")), value: "123456789012345678.13 USD", date: "")
        assertQuote(provider.lookup(query("9007199254740993 USD to CNY")), value: "63050394783186951.00 CNY")
        XCTAssertNil(CurrencyQuery.parse("1234567890123456789012345678901234567890123456789 USD to USD"))
        XCTAssertNil(CurrencyQuery.parse("0." + String(repeating: "0", count: 150) + "1 USD to USD"))
        XCTAssertNotNil(CurrencyQuery.parse("+0001.2500 USD to EUR"))
    }

    func testSameCurrencyWorksOfflineAndDoesNotClaimECBDate() {
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(transport: transport.start, clock: { self.now }, cacheURL: cacheURL)
        defer { provider.stop() }
        assertQuote(provider.lookup(query("1.005 usd to USD")), value: "1.01 USD", date: "")
        assertQuote(provider.lookup(query("1.5 jpy to JPY")), value: "2 JPY", date: "")
        provider.retry(query("1 EUR to EUR"))
        XCTAssertEqual(transport.count, 0)
    }

    func testConstructorNeverStartsNetworkEvenWithStaleCache() throws {
        try writeCache(fetchedAt: now.addingTimeInterval(-172800))
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(transport: transport.start, clock: { self.now }, cacheURL: cacheURL)
        defer { provider.stop() }
        let forbidden = expectation(description: "No unsolicited network or notification")
        forbidden.isInverted = true
        transport.onStart = { forbidden.fulfill() }
        provider.onChange = { forbidden.fulfill() }
        wait(for: [forbidden], timeout: 0.1)
        XCTAssertEqual(transport.count, 0)
    }

    func testMergedRequestsCrossRatesAndPrivacy() throws {
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(transport: transport.start, clock: { self.now }, cacheURL: cacheURL)
        defer { provider.stop() }
        var notifications = 0
        provider.onChange = { XCTAssertTrue(Thread.isMainThread); notifications += 1 }
        XCTAssertEqual(provider.lookup(query("12345.67 USD to CNY")), .loading)
        waitUntil { transport.count == 1 }
        for _ in 0..<20 { XCTAssertEqual(provider.lookup(query("54321.89 GBP to CAD")), .loading) }
        XCTAssertEqual(transport.count, 1)
        let request = transport.requests[0]
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api.frankfurter.dev")
        XCTAssertEqual(components.path, "/v2/rates")
        XCTAssertEqual(Set(components.queryItems?.map(\.name) ?? []), Set(["base", "providers", "quotes"]))
        XCTAssertEqual(components.queryItems?.first { $0.name == "providers" }?.value, "ecb")
        XCTAssertEqual(components.queryItems?.first { $0.name == "base" }?.value, "EUR")
        let requestedCodes = components.queryItems?.first { $0.name == "quotes" }?.value?.split(separator: ",").map(String.init)
        XCTAssertEqual(Set(requestedCodes ?? []), Set(CurrencyQuery.supportedCodes.filter { $0 != "EUR" }))
        XCTAssertFalse(request.url!.absoluteString.contains("12345"))
        XCTAssertFalse(request.url!.absoluteString.contains("54321"))
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        XCTAssertEqual(request.httpMethod, "GET")
        transport.respond(data: payload())
        waitUntil { notifications == 1 }
        assertQuote(provider.lookup(query()), value: "700.00 CNY")
        assertQuote(provider.lookup(query("12.34 GBP to CAD")), value: "74.04 CAD")
        assertQuote(provider.lookup(query("2 CNY to USD")), value: "0.29 USD")
        assertQuote(provider.lookup(query("1.005 EUR to USD")), value: "2.01 USD")
        assertQuote(provider.lookup(query("0.01 EUR to JPY")), value: "1 JPY")
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(transport.count, 1)
        waitForSavedCache()
    }

    func testAtomicPersistenceRestartAndNoQueriesInCache() throws {
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(transport: transport.start, clock: { self.now }, cacheURL: cacheURL)
        _ = provider.lookup(query("12345.67 USD to CNY"))
        waitUntil { transport.count == 1 }
        transport.respond(data: payload())
        waitUntil { FileManager.default.fileExists(atPath: self.cacheURL.path) }
        provider.stop()
        let data = try Data(contentsOf: cacheURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["version", "base", "provider", "date", "fetchedAt", "rates"]))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("12345"))
        let restartedTransport = ControlledCurrencyTransport()
        let restarted = CurrencyRateProvider(transport: restartedTransport.start, clock: { self.now }, cacheURL: cacheURL)
        defer { restarted.stop() }
        XCTAssertEqual(restarted.lookup(query()), .loading)
        waitUntil { restarted.lookup(self.query()) == .ready(CurrencyQuote(value: "700.00 CNY", date: "2026-01-01", isCached: true, isStale: false)) }
        XCTAssertEqual(restartedTransport.count, 0)
    }

    func testFreshCacheRefreshesOnceAt24HoursAndNotOnEveryLookup() throws {
        try writeCache()
        var currentTime = now
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(transport: transport.start, clock: { currentTime }, cacheURL: cacheURL)
        defer { provider.stop() }
        _ = provider.lookup(query())
        waitUntil { if case .ready = provider.lookup(self.query()) { return true }; return false }
        currentTime = now.addingTimeInterval(86400 - 1)
        assertQuote(provider.lookup(query()), value: "700.00 CNY", cached: true)
        XCTAssertEqual(transport.count, 0)
        currentTime = now.addingTimeInterval(86400)
        assertQuote(provider.lookup(query()), value: "700.00 CNY", cached: true, stale: true)
        waitUntil { transport.count == 1 }
        for _ in 0..<20 { _ = provider.lookup(query()) }
        XCTAssertEqual(transport.count, 1)
        transport.respond(data: payload(date: "2026-01-03"))
        waitUntil { provider.lookup(self.query()) == .ready(CurrencyQuote(value: "700.00 CNY", date: "2026-01-03", isCached: false, isStale: false)) }
        for _ in 0..<20 { _ = provider.lookup(query()) }
        XCTAssertEqual(transport.count, 1)
        waitForSavedCache(date: "2026-01-03", fetchedAt: currentTime)
    }

    func testStaleCacheImmediateFallbackFailureBackoffAndExplicitRetry() throws {
        try writeCache(fetchedAt: now.addingTimeInterval(-86400))
        var currentTime = now
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(transport: transport.start, clock: { currentTime }, cacheURL: cacheURL)
        defer { provider.stop() }
        _ = provider.lookup(query())
        waitUntil { transport.count == 1 }
        assertQuote(provider.lookup(query()), value: "700.00 CNY", cached: true, stale: true)
        let unchanged = expectation(description: "Unchanged stale quote does not notify")
        unchanged.isInverted = true
        provider.onChange = { unchanged.fulfill() }
        transport.respond(error: URLError(.notConnectedToInternet))
        wait(for: [unchanged], timeout: 0.1)
        for _ in 0..<20 { assertQuote(provider.lookup(query()), value: "700.00 CNY", cached: true, stale: true) }
        XCTAssertEqual(transport.count, 1)
        provider.onChange = nil
        provider.retry(query())
        waitUntil { transport.count == 2 }
        transport.respond(data: payload(), index: 1)
        waitUntil { provider.lookup(self.query()) == .ready(CurrencyQuote(value: "700.00 CNY", date: "2026-01-01", isCached: false, isStale: false)) }
        waitForSavedCache()
        currentTime = now.addingTimeInterval(86400)
        _ = provider.lookup(query())
        waitUntil { transport.count == 3 }
    }

    func testNoCacheFailureBackoffAndClockAdvance() {
        var currentTime = now
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(transport: transport.start, clock: { currentTime }, cacheURL: cacheURL)
        defer { provider.stop() }
        _ = provider.lookup(query())
        waitUntil { transport.count == 1 }
        var changes = 0
        provider.onChange = { changes += 1 }
        transport.respond(error: URLError(.timedOut))
        waitUntil { changes == 1 }
        for _ in 0..<30 { XCTAssertEqual(provider.lookup(query()), .unavailable) }
        XCTAssertEqual(transport.count, 1)
        currentTime = now.addingTimeInterval(59)
        XCTAssertEqual(provider.lookup(query()), .unavailable)
        currentTime = now.addingTimeInterval(60)
        XCTAssertEqual(provider.lookup(query()), .loading)
        waitUntil { transport.count == 2 }
    }

    func testExplicitRetryBypassesBackoffButMergesInflightRequest() {
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(transport: transport.start, clock: { self.now }, cacheURL: cacheURL)
        defer { provider.stop() }
        _ = provider.lookup(query())
        waitUntil { transport.count == 1 }
        transport.respond(error: URLError(.timedOut))
        waitUntil { provider.lookup(self.query()) == .unavailable }
        provider.retry(query())
        provider.retry(query())
        waitUntil { transport.count == 2 }
        XCTAssertEqual(provider.lookup(query()), .loading)
        transport.respond(data: payload(), index: 1)
        waitUntil { if case .ready = provider.lookup(self.query()) { return true }; return false }
        waitForSavedCache()
    }

    func testRetryBeforeCacheBootstrapForcesRefreshEvenForFreshCache() throws {
        try writeCache()
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(transport: transport.start, clock: { self.now }, cacheURL: cacheURL)
        defer { provider.stop() }
        provider.retry(query())
        waitUntil { transport.count == 1 }
        assertQuote(provider.lookup(query()), value: "700.00 CNY", cached: true)
        transport.respond(error: URLError(.timedOut))
    }

    func testDuplicateCompletedResponseCannotReplaceRatesOrNotify() throws {
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(transport: transport.start, clock: { self.now }, cacheURL: cacheURL)
        defer { provider.stop() }
        _ = provider.lookup(query())
        waitUntil { transport.count == 1 }
        transport.respond(data: payload())
        waitUntil { if case .ready = provider.lookup(self.query()) { return true }; return false }
        waitForSavedCache()
        let forbidden = expectation(description: "Completed generation cannot notify again")
        forbidden.isInverted = true
        provider.onChange = { forbidden.fulfill() }
        var changed = rows()
        for index in changed.indices where changed[index]["quote"] as? String == "CNY" { changed[index]["rate"] = 18 }
        transport.respond(data: try JSONSerialization.data(withJSONObject: changed))
        wait(for: [forbidden], timeout: 0.1)
        assertQuote(provider.lookup(query()), value: "700.00 CNY")
        waitForSavedCache()
    }

    func testNonHTTPAndExcessiveDeclaredLengthAreRejected() {
        for isHTTP in [false, true] {
            let transport = ControlledCurrencyTransport()
            let provider = CurrencyRateProvider(transport: transport.start, clock: { self.now }, cacheURL: cacheURL)
            _ = provider.lookup(query())
            waitUntil { transport.count == 1 }
            transport.respond(data: payload(), http: isHTTP, headers: ["Content-Length": "65537"])
            waitUntil { provider.lookup(self.query()) == .unavailable }
            provider.stop()
        }
    }

    func testReferenceDateOlderThan30DaysCannotAppearAsCurrentPrice() throws {
        try writeCache(date: "2025-12-01", fetchedAt: now.addingTimeInterval(-3600))
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(transport: transport.start, clock: { self.now }, cacheURL: cacheURL)
        defer { provider.stop() }
        _ = provider.lookup(query())
        // A freshly obtained but too-old reference date is never displayed.
        waitUntil { provider.lookup(self.query()) == .unavailable }
        XCTAssertEqual(transport.count, 0)
        provider.retry(query())
        waitUntil { transport.count == 1 }
        transport.respond(data: payload(date: "2025-12-01"))
        waitUntil { provider.lookup(self.query()) == .unavailable }
        waitForSavedCache(date: "2025-12-01")
    }

    func testSevenDayOldReferenceDateIsStaleEvenWithFreshFetchTime() throws {
        try writeCache(date: "2025-12-26")
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(transport: transport.start, clock: { self.now }, cacheURL: cacheURL)
        defer { provider.stop() }
        _ = provider.lookup(query())
        waitUntil { if case .ready = provider.lookup(self.query()) { return true }; return false }
        assertQuote(provider.lookup(query()), value: "700.00 CNY", date: "2025-12-26", cached: true, stale: true)
        XCTAssertEqual(transport.count, 0)
    }

    func testRejectMalformedPartialInconsistentAndUntrustedResponses() throws {
        var cases: [(Data?, Int)] = [(nil, 200), (Data(), 200), (payload(), 503),
                                    (Data("{}".utf8), 200), (Data("not json".utf8), 200),
                                    (Data(repeating: 32, count: 65537), 200)]
        for mutation in 0..<10 {
            var input = rows()
            switch mutation {
            case 0: input.removeLast()
            case 1: input[0]["base"] = "USD"
            case 2: input[0]["date"] = "2026-01-02"
            case 3: input[0]["quote"] = "RUB"
            case 4: input[0]["quote"] = input[1]["quote"]
            case 5: input[0]["rate"] = 0
            case 6: input[0]["rate"] = -1
            case 7: input[0]["rate"] = "1.1"
            case 8: for index in input.indices { input[index]["date"] = "2026-02-30" }
            default: for index in input.indices { input[index]["date"] = "2026-01-03" }
            }
            cases.append((try JSONSerialization.data(withJSONObject: input), 200))
        }
        var nonFinite = rows()
        nonFinite[0]["rate"] = "NON_FINITE_RATE"
        let nonFiniteJSON = String(decoding: try JSONSerialization.data(withJSONObject: nonFinite), as: UTF8.self)
            .replacingOccurrences(of: "\"NON_FINITE_RATE\"", with: "1e999")
        cases.append((Data(nonFiniteJSON.utf8), 200))
        for (index, item) in cases.enumerated() {
            let transport = ControlledCurrencyTransport()
            let isolated = directory.appendingPathComponent("bad-\(index).json")
            let provider = CurrencyRateProvider(transport: transport.start, clock: { self.now }, cacheURL: isolated)
            _ = provider.lookup(query())
            waitUntil { transport.count == 1 }
            transport.respond(data: item.0, status: item.1)
            waitUntil { provider.lookup(self.query()) == .unavailable }
            XCTAssertFalse(FileManager.default.fileExists(atPath: isolated.path))
            provider.stop()
        }
    }

    func testCorruptAndFutureCacheCannotSuppressDownload() throws {
        for index in 0..<4 {
            if index == 0 { try Data("invalid".utf8).write(to: cacheURL) }
            if index == 1 { try writeCache(fetchedAt: now.addingTimeInterval(3600)) }
            if index == 2 { try writeCache(date: "2026-01-03") }
            if index == 3 {
                var badRates = rates
                badRates["USD"] = -2
                try writeCache(replacementRates: badRates)
            }
            let transport = ControlledCurrencyTransport()
            let provider = CurrencyRateProvider(transport: transport.start, clock: { self.now }, cacheURL: cacheURL)
            _ = provider.lookup(query())
            waitUntil { transport.count == 1 }
            XCTAssertEqual(provider.lookup(query()), .loading)
            provider.stop()
        }
    }

    func testCachedReadCannotOverwriteCompletedDownload() throws {
        try writeCache(fetchedAt: now.addingTimeInterval(-86400))
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(transport: transport.start, clock: { self.now }, cacheURL: cacheURL)
        defer { provider.stop() }
        _ = provider.lookup(query())
        waitUntil { transport.count == 1 }
        var updated = rows()
        for index in updated.indices where updated[index]["quote"] as? String == "CNY" { updated[index]["rate"] = 16 }
        transport.respond(data: try JSONSerialization.data(withJSONObject: updated))
        waitUntil { provider.lookup(self.query()) == .ready(CurrencyQuote(value: "800.00 CNY", date: "2026-01-01", isCached: false, isStale: false)) }
        for _ in 0..<10 { assertQuote(provider.lookup(query()), value: "800.00 CNY") }
        waitForSavedCache(cny: 16)
    }

    func testStopCancelsAndDiscardsLateAndDuplicateCallbacks() {
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(transport: transport.start, clock: { self.now }, cacheURL: cacheURL)
        _ = provider.lookup(query())
        waitUntil { transport.count == 1 }
        var notifications = 0
        provider.onChange = { notifications += 1 }
        provider.stop()
        waitUntil { transport.cancelCount == 1 }
        transport.respond(data: payload())
        transport.respond(data: payload())
        let forbidden = expectation(description: "Stopped callbacks stay invalidated")
        forbidden.isInverted = true
        provider.onChange = { forbidden.fulfill() }
        wait(for: [forbidden], timeout: 0.1)
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(provider.lookup(query()), .unavailable)
        provider.retry(query())
        XCTAssertEqual(transport.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testStopDuringCacheReadPreventsPendingLookupFromNetworking() throws {
        try writeCache(fetchedAt: now.addingTimeInterval(-86400))
        let transport = ControlledCurrencyTransport()
        let provider = CurrencyRateProvider(transport: transport.start, clock: { self.now }, cacheURL: cacheURL)
        _ = provider.lookup(query())
        provider.stop()
        let forbidden = expectation(description: "Stopped cache load cannot start transport")
        forbidden.isInverted = true
        transport.onStart = { forbidden.fulfill() }
        wait(for: [forbidden], timeout: 0.1)
        XCTAssertEqual(transport.count, 0)
    }

    func testInjectedURLSessionUsesProtocolInsteadOfRealNetwork() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CurrencyFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = CurrencyRateProvider(session: session, clock: { self.now }, cacheURL: cacheURL)
        defer { provider.stop() }
        XCTAssertEqual(provider.lookup(query("4 USD to CNY")), .loading)
        waitUntil { if case .ready = provider.lookup(self.query("4 USD to CNY")) { return true }; return false }
        assertQuote(provider.lookup(query("4 USD to CNY")), value: "28.00 CNY")
        waitForSavedCache()
    }
}

private final class ControlledCurrencyTransport {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    private var completions: [(Data?, URLResponse?, Error?) -> Void] = []
    private var cancellations = 0
    var onStart: (() -> Void)?

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return storedRequests }
    var count: Int { requests.count }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }

    func start(_ request: URLRequest, completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> (() -> Void) {
        XCTAssertFalse(Thread.isMainThread)
        lock.lock()
        storedRequests.append(request)
        completions.append(completion)
        let onStart = self.onStart
        lock.unlock()
        onStart?()
        return { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.cancellations += 1
            self.lock.unlock()
        }
    }

    func respond(data: Data? = nil, status: Int = 200, error: Error? = nil, index: Int = 0,
                 http: Bool = true, headers: [String: String] = [:]) {
        lock.lock()
        let completion = completions[index], request = storedRequests[index]
        lock.unlock()
        let response: URLResponse?
        if http {
            response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                      headerFields: headers.merging(["Content-Type": "application/json"]) { first, _ in first })
        } else {
            response = URLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: data?.count ?? 0, textEncodingName: nil)
        }
        DispatchQueue.global(qos: .utility).async { completion(data, response, error) }
    }
}

// This protocol has immutable per-request fixtures and never falls through to the network.
private final class CurrencyFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let rows: [[String: Any]] = CurrencyQuery.supportedCodes.filter { $0 != "EUR" }.map { code in
            ["date": "2026-01-01", "base": "EUR", "quote": code,
             "rate": code == "USD" ? 2.0 : code == "CNY" ? 14.0 : 1.0]
        }
        let data = try! JSONSerialization.data(withJSONObject: rows)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
