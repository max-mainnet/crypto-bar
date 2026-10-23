import Foundation

public struct SpotInstrument: Codable, Equatable, Hashable {
    public let instId: String
    public let baseCcy: String
    public let quoteCcy: String
    public let tickSz: String

    public init(instId: String, baseCcy: String, quoteCcy: String, tickSz: String) {
        self.instId = instId
        self.baseCcy = baseCcy
        self.quoteCcy = quoteCcy
        self.tickSz = tickSz
    }

    public static let bitcoin = SpotInstrument(instId: "BTC-USDT", baseCcy: "BTC", quoteCcy: "USDT", tickSz: "0.1")
    public var displayName: String { "\(baseCcy)/\(quoteCcy)" }

    public static func matching(query: String, in instruments: [SpotInstrument]) -> [SpotInstrument] {
        let query = normalized(query)
        func rank(_ instrument: SpotInstrument) -> Int? {
            if query.isEmpty { return 3 }
            let base = normalized(instrument.baseCcy)
            let pair = normalized(instrument.instId)
            if base == query || pair == query { return 0 }
            if base.hasPrefix(query) || pair.hasPrefix(query) { return 1 }
            if base.contains(query) || pair.contains(query) || normalized(instrument.quoteCcy).contains(query) { return 2 }
            return nil
        }
        return instruments.compactMap { instrument -> (SpotInstrument, Int)? in
            guard let rank = rank(instrument) else { return nil }
            return (instrument, rank)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            if (lhs.0.quoteCcy == "USDT") != (rhs.0.quoteCcy == "USDT") { return lhs.0.quoteCcy == "USDT" }
            return lhs.0.instId < rhs.0.instId
        }.map { $0.0 }
    }

    private static func normalized(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}

public struct MarketQuote: Equatable {
    public let instrumentID: String
    public let price: Double
    public let updatedAt: Date
    public let receivedAt: Date
    private let tickSize: String

    public init(instrumentID: String = "BTC-USDT", price: Double, updatedAt: Date, receivedAt: Date = Date(), tickSize: String = "0.01") {
        self.instrumentID = instrumentID
        self.price = price
        self.updatedAt = updatedAt
        self.receivedAt = receivedAt
        self.tickSize = tickSize
    }

    public var formattedPrice: String {
        guard price.isFinite, price > 0 else { return "$—" }
        let precision = Self.fractionDigits(for: tickSize)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = precision
        // The cap keeps menu-bar text compact, while scientific notation keeps
        // very small valid prices from appearing to be zero.
        if price <= pow(10, -Double(precision)) / 2 {
            formatter.numberStyle = .scientific
            formatter.usesGroupingSeparator = false
            formatter.exponentSymbol = "e"
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 6
            formatter.usesSignificantDigits = true
            formatter.minimumSignificantDigits = 3
            formatter.maximumSignificantDigits = 8
        }
        return formatter.string(from: NSNumber(value: price)).map { "$" + $0 } ?? "$—"
    }

    /// A late request for a previous symbol cannot replace the current quote.
    public func accepting(_ candidate: MarketQuote) -> MarketQuote {
        candidate.instrumentID == instrumentID && candidate.updatedAt >= updatedAt ? candidate : self
    }

    private static func fractionDigits(for tickSize: String) -> Int {
        guard let tick = Double(tickSize), tick.isFinite, tick > 0 else { return 2 }
        let parts = tickSize.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let fraction = mantissa.count == 2 ? String(mantissa[1]).replacingOccurrences(of: "0+$", with: "", options: .regularExpression) : ""
        return max(2, min(12, fraction.count - exponent))
    }
}

public enum PriceError: LocalizedError, Equatable {
    case invalidResponse
    case missingInstrument
    case rateLimited(retryAfter: TimeInterval)
    case api(message: String)
    case http(status: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "OKX 返回了无法识别的行情数据。"
        case .missingInstrument: return "OKX 没有返回所选现货的有效价格。"
        case .rateLimited: return "OKX 请求受限，稍后自动重试。"
        case .api(let message): return "OKX：\(message)"
        case .http(let status): return "OKX 请求失败（HTTP \(status)），请检查网络连接。"
        }
    }
}

public struct OKXClient {
    public static let refreshInterval: TimeInterval = 30
    private let session: URLSession

    public init(session: URLSession = OKXClient.makeSession()) {
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    public static func request(instrumentID: String = "BTC-USDT") -> URLRequest {
        makeRequest(path: "/api/v5/market/ticker", query: [URLQueryItem(name: "instId", value: instrumentID)])
    }

    public static func instrumentsRequest() -> URLRequest {
        makeRequest(path: "/api/v5/public/instruments", query: [URLQueryItem(name: "instType", value: "SPOT")])
    }

    public static func tickersRequest() -> URLRequest {
        makeRequest(path: "/api/v5/market/tickers", query: [URLQueryItem(name: "instType", value: "SPOT")])
    }

    private static func makeRequest(path: String, query: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(string: "https://www.okx.com" + path)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public func fetch(instrument: SpotInstrument = .bitcoin) async throws -> MarketQuote {
        let (data, response) = try await session.data(for: Self.request(instrumentID: instrument.instId))
        guard let http = response as? HTTPURLResponse else { throw PriceError.invalidResponse }
        return try Self.decode(data: data, response: http, instrument: instrument)
    }

    public func fetchInstruments() async throws -> [SpotInstrument] {
        let (data, response) = try await session.data(for: Self.instrumentsRequest())
        guard let http = response as? HTTPURLResponse else { throw PriceError.invalidResponse }
        return try Self.decodeInstruments(data: data, response: http)
    }

    public func fetchQuotes(for instruments: [SpotInstrument]) async throws -> [String: MarketQuote] {
        guard !instruments.isEmpty else { return [:] }
        let (data, response) = try await session.data(for: Self.tickersRequest())
        guard let http = response as? HTTPURLResponse else { throw PriceError.invalidResponse }
        return try Self.decodeQuotes(data: data, response: http, instruments: instruments)
    }

    public static func decode(data: Data, response: HTTPURLResponse, now: Date = Date(), instrument: SpotInstrument = .bitcoin) throws -> MarketQuote {
        let payload: Envelope<Ticker> = try decodeEnvelope(data: data, response: response, now: now)
        guard let ticker = payload.data?.first(where: { $0.instId == instrument.instId && $0.instType == "SPOT" }),
              let price = Double(ticker.last), price.isFinite, price > 0 else { throw PriceError.missingInstrument }
        guard let milliseconds = Double(ticker.ts), milliseconds.isFinite, milliseconds > 0 else { throw PriceError.invalidResponse }
        return MarketQuote(instrumentID: instrument.instId, price: price, updatedAt: Date(timeIntervalSince1970: milliseconds / 1000), receivedAt: now, tickSize: instrument.tickSz)
    }

    public static func decodeInstruments(data: Data, response: HTTPURLResponse) throws -> [SpotInstrument] {
        let payload: Envelope<InstrumentRow> = try decodeEnvelope(data: data, response: response)
        guard let rows = payload.data else { throw PriceError.invalidResponse }
        var seen = Set<String>()
        return rows.compactMap { row -> SpotInstrument? in
            guard row.instType == "SPOT", row.state == "live",
                  let id = row.instId, let base = row.baseCcy, let quote = row.quoteCcy, let tickSize = row.tickSz,
                  !base.isEmpty, !quote.isEmpty,
                  base.allSatisfy({ $0.isLetter || $0.isNumber }), quote.allSatisfy({ $0.isLetter || $0.isNumber }),
                  id == "\(base)-\(quote)", let tick = Double(tickSize), tick.isFinite, tick > 0,
                  seen.insert(id).inserted else { return nil }
            return SpotInstrument(instId: id, baseCcy: base, quoteCcy: quote, tickSz: tickSize)
        }.sorted { $0.instId < $1.instId }
    }

    public static func decodeQuotes(data: Data, response: HTTPURLResponse, instruments: [SpotInstrument], now: Date = Date()) throws -> [String: MarketQuote] {
        let payload: Envelope<BatchTickerRow> = try decodeEnvelope(data: data, response: response, now: now)
        guard let rows = payload.data else { throw PriceError.invalidResponse }
        var requested: [String: SpotInstrument] = [:]
        for instrument in instruments where requested[instrument.instId] == nil {
            requested[instrument.instId] = instrument
        }
        var quotes: [String: MarketQuote] = [:]
        for row in rows {
            guard let ticker = row.ticker, ticker.instType == "SPOT",
                  let instrument = requested[ticker.instId],
                  let price = Double(ticker.last), price.isFinite, price > 0,
                  let milliseconds = Double(ticker.ts), milliseconds.isFinite, milliseconds > 0 else { continue }
            let quote = MarketQuote(instrumentID: instrument.instId, price: price, updatedAt: Date(timeIntervalSince1970: milliseconds / 1000), receivedAt: now, tickSize: instrument.tickSz)
            quotes[instrument.instId] = quotes[instrument.instId]?.accepting(quote) ?? quote
        }
        return quotes
    }

    private static func decodeEnvelope<Row: Decodable>(data: Data, response: HTTPURLResponse, now: Date = Date()) throws -> Envelope<Row> {
        let envelope = try? JSONDecoder().decode(Envelope<Row>.self, from: data)
        if response.statusCode == 429 || ["50011", "50040"].contains(envelope?.code ?? "") {
            throw PriceError.rateLimited(retryAfter: retryAfter(response, now: now))
        }
        guard (200..<300).contains(response.statusCode) else { throw PriceError.http(status: response.statusCode) }
        guard let payload = envelope else { throw PriceError.invalidResponse }
        guard payload.code == "0" else {
            let message = payload.msg?.isEmpty == false ? payload.msg! : "错误码 \(payload.code)"
            throw PriceError.api(message: message)
        }
        return payload
    }

    private static func retryAfter(_ response: HTTPURLResponse, now: Date) -> TimeInterval {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return 60 }
        if let seconds = TimeInterval(value), seconds.isFinite { return max(30, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return max(30, formatter.date(from: value)?.timeIntervalSince(now) ?? 60)
    }
}

private struct Envelope<Row: Decodable>: Decodable {
    let code: String
    let msg: String?
    let data: [Row]?
    enum CodingKeys: String, CodingKey { case code, msg, data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? container.decode(String.self, forKey: .code) { code = string }
        else { code = String(try container.decode(Int.self, forKey: .code)) }
        msg = try container.decodeIfPresent(String.self, forKey: .msg)
        data = try container.decodeIfPresent([Row].self, forKey: .data)
    }
}

private struct Ticker: Decodable {
    let instType: String
    let instId: String
    let last: String
    let ts: String
}

/// A malformed ticker affects only its own row in a market-wide snapshot.
private struct BatchTickerRow: Decodable {
    let ticker: Ticker?

    init(from decoder: Decoder) throws {
        ticker = try? Ticker(from: decoder)
    }
}

private struct InstrumentRow: Decodable {
    let instType: String?
    let state: String?
    let instId: String?
    let baseCcy: String?
    let quoteCcy: String?
    let tickSz: String?
    enum CodingKeys: String, CodingKey { case instType, state, instId, baseCcy, quoteCcy, tickSz }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        instType = try? container?.decode(String.self, forKey: .instType)
        state = try? container?.decode(String.self, forKey: .state)
        instId = try? container?.decode(String.self, forKey: .instId)
        baseCcy = try? container?.decode(String.self, forKey: .baseCcy)
        quoteCcy = try? container?.decode(String.self, forKey: .quoteCcy)
        tickSz = try? container?.decode(String.self, forKey: .tickSz)
    }
}
