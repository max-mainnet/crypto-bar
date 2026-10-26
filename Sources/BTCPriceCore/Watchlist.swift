import Foundation

public struct Watchlist: Codable, Equatable {
    public private(set) var instruments: [SpotInstrument]

    public init(instruments: [SpotInstrument] = []) {
        self.instruments = []
        for instrument in instruments { add(instrument) }
    }

    public func contains(_ instrumentID: String) -> Bool {
        instruments.contains { $0.instId == instrumentID }
    }

    @discardableResult
    public mutating func add(_ instrument: SpotInstrument) -> Bool {
        guard Self.isValid(instrument), !contains(instrument.instId) else { return false }
        instruments.append(instrument)
        return true
    }

    @discardableResult
    public mutating func remove(_ instrumentID: String) -> Bool {
        guard let index = instruments.firstIndex(where: { $0.instId == instrumentID }) else { return false }
        instruments.remove(at: index)
        return true
    }

    @discardableResult
    public mutating func toggle(_ instrument: SpotInstrument) -> Bool {
        if contains(instrument.instId) {
            remove(instrument.instId)
            return false
        }
        return add(instrument)
    }

    public mutating func updateKnownInstruments(_ catalog: [SpotInstrument]) {
        var known: [String: SpotInstrument] = [:]
        for instrument in catalog where Self.isValid(instrument) && known[instrument.instId] == nil {
            known[instrument.instId] = instrument
        }
        instruments = instruments.map { known[$0.instId] ?? $0 }
    }

    private static func isValid(_ instrument: SpotInstrument) -> Bool {
        guard instrument.quoteCcy == "USDT", !instrument.baseCcy.isEmpty,
              instrument.baseCcy.allSatisfy({ $0.isLetter || $0.isNumber }),
              instrument.instId == instrument.baseCcy + "-USDT",
              let tick = Double(instrument.tickSz), tick.isFinite, tick > 0 else { return false }
        return true
    }

    private enum CodingKeys: String, CodingKey { case instruments }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([SavedWatchlistEntry].self, forKey: .instruments)
        self.init(instruments: entries.compactMap { $0.instrument })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(instruments, forKey: .instruments)
    }
}

/// An invalid saved row must not discard other valid favorites.
private struct SavedWatchlistEntry: Decodable {
    let instrument: SpotInstrument?

    init(from decoder: Decoder) throws {
        instrument = try? SpotInstrument(from: decoder)
    }
}

public struct WatchlistStore {
    private static let key = "cryptoBar.watchlist.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(defaultInstrument: SpotInstrument = .bitcoin) -> Watchlist {
        guard let data = defaults.data(forKey: Self.key),
              let watchlist = try? JSONDecoder().decode(Watchlist.self, from: data) else {
            return Watchlist(instruments: [defaultInstrument])
        }
        return watchlist
    }

    public func save(_ watchlist: Watchlist) {
        guard let data = try? JSONEncoder().encode(watchlist) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
