import Foundation
import XCTest
@testable import BTCPriceCore

final class OKXClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_782_752_400)

    func testDecodesActualTickerShapeAndSelectsBitcoinUSDTSpot() throws {
        let quote = try decode("""
        {"code":"0","msg":"","data":[
          {"instType":"SPOT","instId":"ETH-USDT","last":"3500","ts":"1782752398123"},
          {"instType":"SWAP","instId":"BTC-USDT","last":"107000","ts":"1782752398123"},
          {"instType":"SPOT","instId":"BTC-USDT","last":"107321.456","lastSz":"0.002","askPx":"107322","bidPx":"107321","ts":"1782752398123"}
        ]}
        """)

        XCTAssertEqual(quote.price, 107321.456)
        XCTAssertEqual(quote.formattedPrice, "$107,321.46")
        XCTAssertEqual(quote.receivedAt, now)
        XCTAssertEqual(quote.updatedAt.timeIntervalSince1970, 1_782_752_398.123, accuracy: 0.001)
    }

    func testAcceptsIntegerSuccessCode() throws {
        let quote = try decode(payload(code: "0", price: "95000"))
        XCTAssertEqual(quote.price, 95000)
        XCTAssertEqual(quote.formattedPrice, "$95,000.00")
    }

    func testConvertsMillisecondsToSecondsWithoutLosingTimestampPrecision() throws {
        let quote = try decode(payload(timestamp: "1782752398999"))
        XCTAssertEqual(quote.updatedAt.timeIntervalSince1970, 1_782_752_398.999, accuracy: 0.001)
    }

    func testReportsAPIErrorWithStringCode() {
        assertError(.api(message: "Instrument ID does not exist"), json: """
        {"code":"51001","msg":"Instrument ID does not exist","data":[]}
        """)
    }

    func testReportsAPIErrorWithIntegerCodeAndMissingMessage() {
        assertError(.api(message: "错误码 50001"), json: "{\"code\":50001}")
    }

    func testEmptyAPIMessageFallsBackToCode() {
        assertError(.api(message: "错误码 50001"), json: "{\"code\":\"50001\",\"msg\":\"\"}")
    }

    func testReportsMissingBitcoinWhenOtherAssetsArePresent() {
        assertError(.missingInstrument, json: """
        {"code":"0","data":[{"instType":"SPOT","instId":"ETH-USDT","last":"3500","ts":"1782752398123"}]}
        """)
    }

    func testReportsMissingBitcoinForNonSpotInstrument() {
        for type in ["SWAP", "FUTURES", "OPTION"] {
            assertError(.missingInstrument, json: """
            {"code":"0","data":[{"instType":"\(type)","instId":"BTC-USDT","last":"95000","ts":"1782752398123"}]}
            """)
        }
    }

    func testReportsMissingBitcoinForDifferentQuoteCurrencyOrPerpetualSymbol() {
        for id in ["BTC-USD", "BTC-USDT-SWAP", "BTC-USDC"] {
            assertError(.missingInstrument, json: """
            {"code":"0","data":[{"instType":"SPOT","instId":"\(id)","last":"95000","ts":"1782752398123"}]}
            """)
        }
    }

    func testReportsMissingBitcoinWhenDataIsEmptyOrAbsent() {
        assertError(.missingInstrument, json: "{\"code\":\"0\",\"data\":[]}")
        assertError(.missingInstrument, json: "{\"code\":\"0\"}")
    }

    func testRejectsZeroNegativeNonNumericAndNonFinitePrice() {
        for price in ["0", "-1", "-95000.23", "", "abc", "nan", "inf", "1e999"] {
            assertError(.missingInstrument, json: payload(price: price))
        }
    }

    func testRejectsZeroNegativeNonNumericAndNonFiniteTimestamp() {
        for timestamp in ["0", "-1", "", "yesterday", "nan", "inf", "1e999"] {
            assertError(.invalidResponse, json: payload(timestamp: timestamp))
        }
    }

    func testRejectsMalformedPayloadAndWrongJSONTypes() {
        for json in ["not JSON", "[]", "{\"data\":[]}", """
            {"code":"0","data":[{"instType":"SPOT","instId":"BTC-USDT","last":95000,"ts":"1782752398123"}]}
            """, """
            {"code":"0","data":[{"instType":"SPOT","instId":"BTC-USDT","last":"95000","ts":null}]}
            """] {
            assertError(.invalidResponse, json: json)
        }
    }

    func testHTTPFailureKeepsStatusCodeEvenWithInvalidPayload() {
        for status in [401, 403, 404, 503] {
            assertError(.http(status: status), json: "Service unavailable", status: status)
        }
    }

    func testRateLimitWithNumericRetryAfterUsesServerDelayAndMinimumInterval() {
        assertError(.rateLimited(retryAfter: 120), json: "", status: 429, headers: ["Retry-After": "120"])
        assertError(.rateLimited(retryAfter: 30), json: "", status: 429, headers: ["Retry-After": "5"])
        assertError(.rateLimited(retryAfter: 30), json: "", status: 429, headers: ["Retry-After": "-10"])
    }

    func testRateLimitWithHTTPDateCalculatesDelayFromNow() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        let retryDate = formatter.string(from: now.addingTimeInterval(180))
        assertError(.rateLimited(retryAfter: 180), json: "", status: 429, headers: ["Retry-After": retryDate])
        let pastDate = formatter.string(from: now.addingTimeInterval(-60))
        assertError(.rateLimited(retryAfter: 30), json: "", status: 429, headers: ["Retry-After": pastDate])
    }

    func testRateLimitWithoutUsableHeaderDefaultsToOneMinute() {
        assertError(.rateLimited(retryAfter: 60), json: "", status: 429)
        assertError(.rateLimited(retryAfter: 60), json: "", status: 429, headers: ["Retry-After": "unknown"])
        assertError(.rateLimited(retryAfter: 60), json: "", status: 429, headers: ["Retry-After": "nan"])
    }

    func testAPIRateLimitCodesAreHandledForStringAndIntegerCodes() {
        for code in ["50011", "50040"] {
            for encodedCode in [code, "\"\(code)\""] {
                assertError(.rateLimited(retryAfter: 60), json: """
                {"code":\(encodedCode),"msg":"Too many requests","data":[]}
                """)
            }
        }
    }

    func testRequestUsesPublicHTTPSBitcoinUSDTSpotTickerWithoutCredentials() throws {
        let request = OKXClient.request()
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.okx.com")
        XCTAssertEqual(components.path, "/api/v5/market/ticker")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "instId", value: "BTC-USDT")])
        XCTAssertNil(components.user)
        XCTAssertNil(components.password)
        XCTAssertNil(components.fragment)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.allHTTPHeaderFields, ["Accept": "application/json"])
        XCTAssertEqual(request.timeoutInterval, 12)
    }

    func testSessionBypassesCachedPricesAndUsesBoundedTimeouts() {
        let session = OKXClient.makeSession()
        defer { session.invalidateAndCancel() }
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 12)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 20)
    }

    func testRefreshIntervalIsThirtySeconds() {
        XCTAssertEqual(OKXClient.refreshInterval, 30)
    }

    func testOlderSourceTimestampKeepsExistingQuoteDespiteLaterReceipt() {
        let existing = MarketQuote(price: 95000, updatedAt: now, receivedAt: now)
        let older = MarketQuote(price: 94000, updatedAt: now.addingTimeInterval(-1), receivedAt: now.addingTimeInterval(30))
        XCTAssertEqual(existing.accepting(older), existing)
    }

    func testEqualSourceTimestampAcceptsCandidateAndUpdatesReceipt() {
        let existing = MarketQuote(price: 95000, updatedAt: now, receivedAt: now)
        let sameTimestamp = MarketQuote(price: 95000, updatedAt: now, receivedAt: now.addingTimeInterval(30))
        XCTAssertEqual(existing.accepting(sameTimestamp), sameTimestamp)
    }

    func testNewerSourceTimestampAcceptsCandidateRegardlessOfPriceDirection() {
        let existing = MarketQuote(price: 95000, updatedAt: now, receivedAt: now)
        for price in [94000.0, 96000.0] {
            let newer = MarketQuote(price: price, updatedAt: now.addingTimeInterval(1), receivedAt: now.addingTimeInterval(30))
            XCTAssertEqual(existing.accepting(newer), newer)
        }
    }

    func testSelectedInstrumentDecodesItsOwnTickerAndTickPrecision() throws {
        let pepe = SpotInstrument(instId: "PEPE-USDT", baseCcy: "PEPE", quoteCcy: "USDT", tickSz: "0.000000001")
        let quote = try decode("""
        {"code":"0","data":[
          {"instType":"SPOT","instId":"BTC-USDT","last":"95000","ts":"1782752398123"},
          {"instType":"SPOT","instId":"PEPE-USDT","last":"0.000007123","ts":"1782752398123"}
        ]}
        """, instrument: pepe)
        XCTAssertEqual(quote.instrumentID, "PEPE-USDT")
        XCTAssertEqual(quote.price, 0.000007123)
        XCTAssertEqual(quote.formattedPrice, "$0.000007123")
    }

    func testDifferentInstrumentTickerCannotSupplySelectedPrice() throws {
        let eth = SpotInstrument(instId: "ETH-USDT", baseCcy: "ETH", quoteCcy: "USDT", tickSz: "0.01")
        XCTAssertThrowsError(try decode(payload(), instrument: eth)) { error in
            XCTAssertEqual(error as? PriceError, .missingInstrument)
        }
    }

    func testLateQuoteForDifferentSymbolCannotOverwriteCurrentSelection() {
        let existing = MarketQuote(instrumentID: "ETH-USDT", price: 3500, updatedAt: now)
        let bitcoin = MarketQuote(instrumentID: "BTC-USDT", price: 95000, updatedAt: now.addingTimeInterval(60))
        XCTAssertEqual(existing.accepting(bitcoin), existing)
    }

    func testPriceFormattingUsesTickSizeAndRemovesUnnecessaryTrailingZeros() {
        XCTAssertEqual(MarketQuote(price: 1.23456789, updatedAt: now, tickSize: "0.01000000").formattedPrice, "$1.23")
        XCTAssertEqual(MarketQuote(price: 0.00001234, updatedAt: now, tickSize: "0.00000001").formattedPrice, "$0.00001234")
        XCTAssertEqual(MarketQuote(price: 0.000012, updatedAt: now, tickSize: "0.00000001").formattedPrice, "$0.000012")
        XCTAssertEqual(MarketQuote(price: 4.2, updatedAt: now, tickSize: "1").formattedPrice, "$4.20")
    }

    func testScientificTickSizeHasCorrectDecimalPrecision() {
        XCTAssertEqual(MarketQuote(price: 0.00001234, updatedAt: now, tickSize: "1e-8").formattedPrice, "$0.00001234")
        XCTAssertEqual(MarketQuote(price: 0.00001234, updatedAt: now, tickSize: "1.200e-7").formattedPrice, "$0.00001234")
    }

    func testPriceFormattingCapsDecimalPlacesAtTwelveAndKeepsTinyPriceNonzero() {
        XCTAssertEqual(MarketQuote(price: 1.23456789123456, updatedAt: now, tickSize: "1e-15").formattedPrice, "$1.234567891235")
        XCTAssertEqual(MarketQuote(price: 0.000000000001, updatedAt: now, tickSize: "1e-15").formattedPrice, "$0.000000000001")
        XCTAssertEqual(MarketQuote(price: 1e-13, updatedAt: now, tickSize: "1e-15").formattedPrice, "$1.00e-13")
        XCTAssertEqual(MarketQuote(price: 5e-13, updatedAt: now, tickSize: "1e-15").formattedPrice, "$5.00e-13")
    }

    func testInvalidTickSizeFallsBackToTwoDecimalPlaces() {
        for tick in ["", "0", "-1", "nan", "inf", "unknown"] {
            XCTAssertEqual(MarketQuote(price: 1234.56789, updatedAt: now, tickSize: tick).formattedPrice, "$1,234.57")
        }
    }

    func testRequestUsesSelectedInstrumentWithoutAddingQueryParameters() throws {
        let request = OKXClient.request(instrumentID: "ETH-USDT")
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "instId", value: "ETH-USDT")])
        let escaped = OKXClient.request(instrumentID: "BTC-USDT&other=value")
        let escapedComponents = try XCTUnwrap(URLComponents(url: XCTUnwrap(escaped.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(escapedComponents.queryItems, [URLQueryItem(name: "instId", value: "BTC-USDT&other=value")])
    }

    func testInstrumentsRequestOnlyAsksForPublicSpotList() throws {
        let request = OKXClient.instrumentsRequest()
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.okx.com")
        XCTAssertEqual(components.path, "/api/v5/public/instruments")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "instType", value: "SPOT")])
        XCTAssertEqual(request.allHTTPHeaderFields, ["Accept": "application/json"])
        XCTAssertEqual(request.timeoutInterval, 12)
    }

    func testInstrumentListKeepsOnlyValidLiveSpotPairsAndDeduplicatesIDs() throws {
        let btcUSDC = SpotInstrument(instId: "BTC-USDC", baseCcy: "BTC", quoteCcy: "USDC", tickSz: "0.1")
        let eth = SpotInstrument(instId: "ETH-USDT", baseCcy: "ETH", quoteCcy: "USDT", tickSz: "0.01")
        let rows: [[String: Any]] = [
            instrumentRow(), instrumentRow(),
            instrumentRow(id: "BTC-USDC", quote: "USDC"),
            instrumentRow(id: "ETH-USDT", base: "ETH", tick: "0.01"),
            instrumentRow(id: "SOL-USDT", base: "SOL", state: "preopen"),
            instrumentRow(id: "DOGE-USDT", base: "DOGE", state: "suspend"),
            instrumentRow(type: "SWAP"),
            instrumentRow(id: "BTC-USDT-SWAP"),
            instrumentRow(id: "", base: ""),
            instrumentRow(tick: "0"), instrumentRow(tick: "-1"),
            instrumentRow(tick: "nan"), instrumentRow(tick: "inf")
        ]
        XCTAssertEqual(try decodeInstruments(rows), [btcUSDC, .bitcoin, eth])
    }

    func testMalformedInstrumentRowsAreSkippedWithoutDiscardingValidRows() throws {
        let rows: [Any] = [NSNull(), 42, [:] as [String: Any], ["instId": 1], instrumentRow()]
        XCTAssertEqual(try decodeInstruments(rows), [.bitcoin])
    }

    func testEmptyInstrumentListIsValidButMissingDataIsInvalid() throws {
        XCTAssertEqual(try decodeInstruments([]), [])
        let response = try response(status: 200)
        XCTAssertThrowsError(try OKXClient.decodeInstruments(data: Data("{\"code\":\"0\"}".utf8), response: response)) { error in
            XCTAssertEqual(error as? PriceError, .invalidResponse)
        }
    }

    func testInstrumentListSharesAPIAndRateLimitErrorHandling() throws {
        XCTAssertThrowsError(try OKXClient.decodeInstruments(data: Data("{\"code\":\"50001\",\"msg\":\"API unavailable\"}".utf8), response: response(status: 200))) { error in
            XCTAssertEqual(error as? PriceError, .api(message: "API unavailable"))
        }
        XCTAssertThrowsError(try OKXClient.decodeInstruments(data: Data("".utf8), response: response(status: 429, headers: ["Retry-After": "120"]))) { error in
            XCTAssertEqual(error as? PriceError, .rateLimited(retryAfter: 120))
        }
    }

    func testInstrumentMetadataCanBePersistedAndRestoredLosslessly() throws {
        let encoded = try JSONEncoder().encode(SpotInstrument.bitcoin)
        let decoded = try JSONDecoder().decode(SpotInstrument.self, from: encoded)
        XCTAssertEqual(decoded, .bitcoin)
        XCTAssertEqual(Set([decoded, .bitcoin]).count, 1)
        XCTAssertEqual(decoded.displayName, "BTC/USDT")
    }

    func testLocalSearchIgnoresCaseWhitespaceAndPairSeparators() {
        let eth = SpotInstrument(instId: "ETH-USDT", baseCcy: "ETH", quoteCcy: "USDT", tickSz: "0.01")
        for query in ["btc", "BTC", " btc ", "$BtC / usdt", "BTC-USDT", "btc_usdt", "btc usdt"] {
            XCTAssertEqual(SpotInstrument.matching(query: query, in: [eth, .bitcoin]), [.bitcoin])
        }
        XCTAssertEqual(SpotInstrument.matching(query: "unknown-coin", in: [eth, .bitcoin]), [])
    }

    func testSearchRanksExactBaseBeforePrefixesAndSubstringsAndPrefersUSDT() {
        let btcUSDC = SpotInstrument(instId: "BTC-USDC", baseCcy: "BTC", quoteCcy: "USDC", tickSz: "0.1")
        let btcb = SpotInstrument(instId: "BTCB-USDT", baseCcy: "BTCB", quoteCcy: "USDT", tickSz: "0.1")
        let wbtc = SpotInstrument(instId: "WBTC-USDT", baseCcy: "WBTC", quoteCcy: "USDT", tickSz: "0.1")
        XCTAssertEqual(SpotInstrument.matching(query: "btc", in: [wbtc, btcb, btcUSDC, .bitcoin]), [.bitcoin, btcUSDC, btcb, wbtc])
        XCTAssertEqual(SpotInstrument.matching(query: "btc/usdc", in: [.bitcoin, btcUSDC]), [btcUSDC])
    }

    func testEmptySearchReturnsDeterministicListWithUSDTPairsFirst() {
        let btcUSDC = SpotInstrument(instId: "BTC-USDC", baseCcy: "BTC", quoteCcy: "USDC", tickSz: "0.1")
        let eth = SpotInstrument(instId: "ETH-USDT", baseCcy: "ETH", quoteCcy: "USDT", tickSz: "0.01")
        XCTAssertEqual(SpotInstrument.matching(query: "", in: [btcUSDC, eth, .bitcoin]), [.bitcoin, eth, btcUSDC])
    }

    func testBatchTickerRequestOnlyAsksForPublicSpotSnapshot() throws {
        let request = OKXClient.tickersRequest()
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.okx.com")
        XCTAssertEqual(components.path, "/api/v5/market/tickers")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "instType", value: "SPOT")])
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.allHTTPHeaderFields, ["Accept": "application/json"])
        XCTAssertEqual(request.timeoutInterval, 12)
    }

    func testBatchQuotesMatchRequestedSpotIDsAndPreserveEachTickSize() throws {
        let eth = SpotInstrument(instId: "ETH-USDT", baseCcy: "ETH", quoteCcy: "USDT", tickSz: "0.01")
        let pepe = SpotInstrument(instId: "PEPE-USDT", baseCcy: "PEPE", quoteCcy: "USDT", tickSz: "0.000000001")
        let quotes = try decodeQuotes([
            tickerRow(),
            tickerRow(id: "ETH-USDT", price: "3500.126"),
            tickerRow(id: "PEPE-USDT", price: "0.000007123"),
            tickerRow(id: "XRP-USDT", price: "2.25"),
            tickerRow(price: "99999", type: "SWAP")
        ], instruments: [.bitcoin, eth, pepe])
        XCTAssertEqual(Set(quotes.keys), ["BTC-USDT", "ETH-USDT", "PEPE-USDT"])
        XCTAssertEqual(quotes["BTC-USDT"]?.formattedPrice, "$95,000.25")
        XCTAssertEqual(quotes["ETH-USDT"]?.formattedPrice, "$3,500.13")
        XCTAssertEqual(quotes["PEPE-USDT"]?.formattedPrice, "$0.000007123")
        XCTAssertEqual(quotes["PEPE-USDT"]?.instrumentID, "PEPE-USDT")
        XCTAssertEqual(quotes["PEPE-USDT"]?.receivedAt, now)
        XCTAssertEqual(try XCTUnwrap(quotes["PEPE-USDT"]).updatedAt.timeIntervalSince1970, 1_782_752_398.123, accuracy: 0.001)
    }

    func testMalformedBatchRowsAreSkippedWithoutDiscardingValidQuotes() throws {
        let eth = SpotInstrument(instId: "ETH-USDT", baseCcy: "ETH", quoteCcy: "USDT", tickSz: "0.01")
        let rows: [Any] = [
            NSNull(), 42, [:] as [String: Any],
            ["instType": "SPOT", "instId": "BTC-USDT", "last": 95000, "ts": "1782752398123"] as [String: Any],
            tickerRow(price: "0"), tickerRow(price: "-1"), tickerRow(price: "nan"), tickerRow(price: "inf"), tickerRow(price: "1e999"),
            tickerRow(timestamp: "0"), tickerRow(timestamp: "-1"), tickerRow(timestamp: "nan"), tickerRow(timestamp: "unknown"),
            tickerRow(id: "ETH-USDT", price: "3500.25"), tickerRow()
        ]
        let quotes = try decodeQuotes(rows, instruments: [.bitcoin, eth])
        XCTAssertEqual(quotes.count, 2)
        XCTAssertEqual(quotes["BTC-USDT"]?.price, 95000.25)
        XCTAssertEqual(quotes["ETH-USDT"]?.price, 3500.25)
    }

    func testBatchDuplicateTickerIDsKeepNewestTimestampInEitherOrder() throws {
        let older = tickerRow(price: "94000", timestamp: "1782752397000")
        let newest = tickerRow(price: "96000", timestamp: "1782752399000")
        let middle = tickerRow(price: "95000", timestamp: "1782752398000")
        for rows in [[older, newest, middle], [newest, middle, older]] {
            let quotes = try decodeQuotes(rows)
            XCTAssertEqual(quotes.count, 1)
            XCTAssertEqual(quotes["BTC-USDT"]?.price, 96000)
            XCTAssertEqual(quotes["BTC-USDT"]?.updatedAt, Date(timeIntervalSince1970: 1_782_752_399))
        }
    }

    func testBatchEqualTimestampAcceptsLaterValidRowAndInvalidRowCannotEraseIt() throws {
        let quotes = try decodeQuotes([
            tickerRow(price: "94000"), tickerRow(price: "95000"), tickerRow(price: "not-a-price")
        ])
        XCTAssertEqual(quotes["BTC-USDT"]?.price, 95000)
    }

    func testBatchDuplicateInputIDsUseFirstMetadataWithoutCrashing() throws {
        let precise = SpotInstrument(instId: "PEPE-USDT", baseCcy: "PEPE", quoteCcy: "USDT", tickSz: "0.00000001")
        let duplicate = SpotInstrument(instId: "PEPE-USDT", baseCcy: "PEPE", quoteCcy: "USDT", tickSz: "0.01")
        let quotes = try decodeQuotes([tickerRow(id: "PEPE-USDT", price: "0.00001234")], instruments: [precise, precise, duplicate])
        XCTAssertEqual(quotes.count, 1)
        XCTAssertEqual(quotes["PEPE-USDT"]?.formattedPrice, "$0.00001234")
    }

    func testBatchEmptyOrUnmatchedTargetsReturnEmptyDictionary() throws {
        XCTAssertEqual(try decodeQuotes([tickerRow()], instruments: []), [:])
        XCTAssertEqual(try decodeQuotes([]), [:])
        XCTAssertEqual(try decodeQuotes([tickerRow(id: "ETH-USDT")]), [:])
        XCTAssertEqual(try decodeQuotes([tickerRow(type: "FUTURES")]), [:])
    }

    func testMalformedBatchEnvelopeIsReportedAsInvalidResponse() throws {
        for json in ["not JSON", "[]", "{\"data\":[]}", "{\"code\":\"0\"}", "{\"code\":\"0\",\"data\":{}}"] {
            XCTAssertThrowsError(try OKXClient.decodeQuotes(data: Data(json.utf8), response: response(status: 200), instruments: [.bitcoin], now: now)) { error in
                XCTAssertEqual(error as? PriceError, .invalidResponse)
            }
        }
    }

    func testBatchQuotesShareHTTPAPIAndRateLimitErrors() throws {
        let cases: [(String, Int, [String: String], PriceError)] = [
            ("Service unavailable", 503, [:], .http(status: 503)),
            ("{\"code\":\"50001\",\"msg\":\"API unavailable\"}", 200, [:], .api(message: "API unavailable")),
            ("{\"code\":50040,\"msg\":\"Too frequent\",\"data\":[]}", 200, [:], .rateLimited(retryAfter: 60)),
            ("", 429, ["Retry-After": "120"], .rateLimited(retryAfter: 120)),
            ("", 429, ["Retry-After": "2"], .rateLimited(retryAfter: 30))
        ]
        for (json, status, headers, expected) in cases {
            XCTAssertThrowsError(try OKXClient.decodeQuotes(data: Data(json.utf8), response: response(status: status, headers: headers), instruments: [.bitcoin], now: now)) { error in
                XCTAssertEqual(error as? PriceError, expected)
            }
        }
    }

    func testFetchingMultipleInstrumentsMakesOneBatchRequest() throws {
        let requests = LockedTestValue<[URLRequest]>([])
        let eth = SpotInstrument(instId: "ETH-USDT", baseCcy: "ETH", quoteCcy: "USDT", tickSz: "0.01")
        let data = try JSONSerialization.data(withJSONObject: ["code": "0", "data": [tickerRow(), tickerRow(id: "ETH-USDT", price: "3500")]] as [String: Any])
        BatchQuoteURLProtocol.handler = { request in
            requests.withValue { $0.append(request) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BatchQuoteURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            BatchQuoteURLProtocol.handler = nil
        }
        let quotes = try fetchQuotesSynchronously([.bitcoin, eth, .bitcoin], session: session)
        let sent = requests.withValue { $0 }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.url, OKXClient.tickersRequest().url)
        XCTAssertEqual(Set(quotes.keys), ["BTC-USDT", "ETH-USDT"])
    }

    func testFetchingEmptyDirectoryMakesNoRequest() throws {
        let requests = LockedTestValue<Int>(0)
        BatchQuoteURLProtocol.handler = { request in
            requests.withValue { $0 += 1 }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{\"code\":\"0\",\"data\":[]}".utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BatchQuoteURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            BatchQuoteURLProtocol.handler = nil
        }
        XCTAssertEqual(try fetchQuotesSynchronously([], session: session), [:])
        XCTAssertEqual(requests.withValue { $0 }, 0)
    }

    private func fetchQuotesSynchronously(_ instruments: [SpotInstrument], session: URLSession) throws -> [String: MarketQuote] {
        let result = LockedTestValue<Result<[String: MarketQuote], Error>?>(nil)
        let completed = DispatchSemaphore(value: 0)
        let client = OKXClient(session: session)
        Task.detached {
            do {
                let quotes = try await client.fetchQuotes(for: instruments)
                result.withValue { $0 = .success(quotes) }
            } catch {
                result.withValue { $0 = .failure(error) }
            }
            completed.signal()
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        return try XCTUnwrap(result.withValue { $0 }).get()
    }

    private func tickerRow(id: String = "BTC-USDT", price: String = "95000.25", timestamp: String = "1782752398123", type: String = "SPOT") -> [String: Any] {
        ["instId": id, "last": price, "ts": timestamp, "instType": type]
    }

    private func decodeQuotes(_ rows: [Any], instruments: [SpotInstrument] = [.bitcoin]) throws -> [String: MarketQuote] {
        let envelope: [String: Any] = ["code": "0", "msg": "", "data": rows]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return try OKXClient.decodeQuotes(data: data, response: response(status: 200), instruments: instruments, now: now)
    }

    private func instrumentRow(id: String = "BTC-USDT", base: String = "BTC", quote: String = "USDT", tick: String = "0.1", type: String = "SPOT", state: String = "live") -> [String: Any] {
        ["instId": id, "baseCcy": base, "quoteCcy": quote, "tickSz": tick, "instType": type, "state": state]
    }

    private func decodeInstruments(_ rows: [Any]) throws -> [SpotInstrument] {
        let envelope: [String: Any] = ["code": "0", "msg": "", "data": rows]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return try OKXClient.decodeInstruments(data: data, response: response(status: 200))
    }

    private func response(status: Int, headers: [String: String] = [:]) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://www.okx.com/api/v5/public/instruments?instType=SPOT")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
    }

    private func payload(code: String = "\"0\"", price: String = "95000.25", timestamp: String = "1782752398123") -> String {
        """
        {"code":\(code),"msg":"","data":[{"instType":"SPOT","instId":"BTC-USDT","last":"\(price)","ts":"\(timestamp)"}]}
        """
    }

    private func decode(_ json: String, status: Int = 200, headers: [String: String] = [:], instrument: SpotInstrument = .bitcoin) throws -> MarketQuote {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://www.okx.com/api/v5/market/ticker?instId=BTC-USDT")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
        return try OKXClient.decode(data: Data(json.utf8), response: response, now: now, instrument: instrument)
    }

    private func assertError(_ expected: PriceError, json: String, status: Int = 200, headers: [String: String] = [:], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(json, status: status, headers: headers), file: file, line: line) { error in
            XCTAssertEqual(error as? PriceError, expected, file: file, line: line)
        }
    }
}

private final class LockedTestValue<Value> {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class BatchQuoteURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
