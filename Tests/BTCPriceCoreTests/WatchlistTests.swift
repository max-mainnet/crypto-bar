import Foundation
import XCTest
@testable import BTCPriceCore

final class WatchlistTests: XCTestCase {
    private let ethereum = SpotInstrument(instId: "ETH-USDT", baseCcy: "ETH", quoteCcy: "USDT", tickSz: "0.01")
    private let solana = SpotInstrument(instId: "SOL-USDT", baseCcy: "SOL", quoteCcy: "USDT", tickSz: "0.001")

    func testInitializationDeduplicatesByIDAndKeepsFirstMetadataAndOrder() {
        let duplicateBTC = SpotInstrument(instId: "BTC-USDT", baseCcy: "BTC", quoteCcy: "USDT", tickSz: "0.01")
        let watchlist = Watchlist(instruments: [ethereum, .bitcoin, ethereum, duplicateBTC, solana])
        XCTAssertEqual(watchlist.instruments, [ethereum, .bitcoin, solana])
        XCTAssertTrue(watchlist.contains("BTC-USDT"))
        XCTAssertFalse(watchlist.contains("BTC"))
    }

    func testInitializationRejectsNonUSDTMalformedSymbolsAndInvalidTickSizes() {
        var invalid = [
            SpotInstrument(instId: "BTC-USDC", baseCcy: "BTC", quoteCcy: "USDC", tickSz: "0.1"),
            SpotInstrument(instId: "BTC-USDT-SWAP", baseCcy: "BTC", quoteCcy: "USDT", tickSz: "0.1"),
            SpotInstrument(instId: "ETH-USDT", baseCcy: "BTC", quoteCcy: "USDT", tickSz: "0.1"),
            SpotInstrument(instId: "-USDT", baseCcy: "", quoteCcy: "USDT", tickSz: "0.1"),
            SpotInstrument(instId: "BTC USD-USDT", baseCcy: "BTC USD", quoteCcy: "USDT", tickSz: "0.1"),
            SpotInstrument(instId: " BTC-USDT", baseCcy: " BTC", quoteCcy: "USDT", tickSz: "0.1")
        ]
        for tick in ["", "0", "-1", "nan", "inf", "1e999", "invalid"] {
            invalid.append(SpotInstrument(instId: "BTC-USDT", baseCcy: "BTC", quoteCcy: "USDT", tickSz: tick))
        }
        let numberedSymbol = SpotInstrument(instId: "1INCH-USDT", baseCcy: "1INCH", quoteCcy: "USDT", tickSz: "1e-5")
        XCTAssertEqual(Watchlist(instruments: invalid + [numberedSymbol, .bitcoin]).instruments, [numberedSymbol, .bitcoin])
    }

    func testAddAndRemoveAreIdempotentAndReportWhetherMembershipChanged() {
        var watchlist = Watchlist()
        XCTAssertTrue(watchlist.add(ethereum))
        XCTAssertFalse(watchlist.add(ethereum))
        XCTAssertEqual(watchlist.instruments, [ethereum])
        XCTAssertFalse(watchlist.remove("BTC-USDT"))
        XCTAssertTrue(watchlist.remove("ETH-USDT"))
        XCTAssertFalse(watchlist.remove("ETH-USDT"))
        XCTAssertEqual(watchlist.instruments, [])
    }

    func testRemovingAndAddingAgainMovesInstrumentToEnd() {
        var watchlist = Watchlist(instruments: [.bitcoin, ethereum, solana])
        XCTAssertTrue(watchlist.remove("BTC-USDT"))
        XCTAssertTrue(watchlist.add(.bitcoin))
        XCTAssertEqual(watchlist.instruments, [ethereum, solana, .bitcoin])
    }

    func testToggleReturnsMembershipAfterOperation() {
        var watchlist = Watchlist(instruments: [.bitcoin])
        XCTAssertTrue(watchlist.toggle(ethereum))
        XCTAssertTrue(watchlist.contains("ETH-USDT"))
        XCTAssertFalse(watchlist.toggle(.bitcoin))
        XCTAssertFalse(watchlist.contains("BTC-USDT"))
        XCTAssertTrue(watchlist.toggle(.bitcoin))
        XCTAssertEqual(watchlist.instruments, [ethereum, .bitcoin])
        let invalid = SpotInstrument(instId: "ETH-USDC", baseCcy: "ETH", quoteCcy: "USDC", tickSz: "0.01")
        XCTAssertFalse(watchlist.toggle(invalid))
        XCTAssertEqual(watchlist.instruments, [ethereum, .bitcoin])
    }

    func testCatalogUpdateRefreshesMetadataWithoutReorderingOrRemovingMissingIDs() {
        var watchlist = Watchlist(instruments: [solana, .bitcoin, ethereum])
        let updatedBTC = SpotInstrument(instId: "BTC-USDT", baseCcy: "BTC", quoteCcy: "USDT", tickSz: "0.01")
        let unselected = SpotInstrument(instId: "DOGE-USDT", baseCcy: "DOGE", quoteCcy: "USDT", tickSz: "0.00001")
        watchlist.updateKnownInstruments([updatedBTC, unselected])
        XCTAssertEqual(watchlist.instruments, [solana, updatedBTC, ethereum])
        XCTAssertTrue(watchlist.contains("SOL-USDT"))
        XCTAssertFalse(watchlist.contains("DOGE-USDT"))
    }

    func testCatalogUpdateSkipsBadRowsAndDeduplicatesValidMetadata() {
        var watchlist = Watchlist(instruments: [.bitcoin, ethereum])
        let invalid = SpotInstrument(instId: "BTC-USDT", baseCcy: "BTC", quoteCcy: "USDT", tickSz: "nan")
        let updated = SpotInstrument(instId: "BTC-USDT", baseCcy: "BTC", quoteCcy: "USDT", tickSz: "0.01")
        let duplicate = SpotInstrument(instId: "BTC-USDT", baseCcy: "BTC", quoteCcy: "USDT", tickSz: "0.001")
        watchlist.updateKnownInstruments([invalid, updated, duplicate])
        XCTAssertEqual(watchlist.instruments, [updated, ethereum])
        watchlist.updateKnownInstruments([])
        XCTAssertEqual(watchlist.instruments, [updated, ethereum])
    }

    func testWatchlistCodableRoundTripPreservesOrderAndMetadata() throws {
        let original = Watchlist(instruments: [ethereum, .bitcoin, solana])
        let decoded = try JSONDecoder().decode(Watchlist.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testDecodingSkipsMalformedAndInvalidEntriesButKeepsOtherFavorites() throws {
        let entries: [Any] = [
            row(ethereum), NSNull(), 42, [:] as [String: Any],
            ["instId": "BTC-USDT", "baseCcy": "BTC", "quoteCcy": "USDT", "tickSz": 0.1] as [String: Any],
            row(.bitcoin), row(ethereum),
            ["instId": "DOGE-USDC", "baseCcy": "DOGE", "quoteCcy": "USDC", "tickSz": "0.001"],
            ["instId": "SOL-USDT", "baseCcy": "SOL", "quoteCcy": "USDT", "tickSz": "0"]
        ]
        let decoded = try JSONDecoder().decode(Watchlist.self, from: savedData(entries))
        XCTAssertEqual(decoded.instruments, [ethereum, .bitcoin])
    }

    func testDecodingRejectsInvalidTopLevelStructure() {
        for json in ["not JSON", "null", "[]", "{}", "{\"instruments\":null}", "{\"instruments\":{}}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(Watchlist.self, from: Data(json.utf8))) { error in
                XCTAssertTrue(error is DecodingError)
            }
        }
    }

    func testStoreWithoutSavedValueSeedsCurrentSelectedInstrument() throws {
        try withStore { defaults, store in
            XCTAssertEqual(store.load().instruments, [.bitcoin])
            XCTAssertEqual(store.load(defaultInstrument: ethereum).instruments, [ethereum])
            XCTAssertNil(defaults.object(forKey: "cryptoBar.watchlist.v1"))
        }
    }

    func testStorePersistsFavoritesAcrossStoreInstancesUsingVersionedKey() throws {
        try withStore { defaults, store in
            let expected = Watchlist(instruments: [solana, .bitcoin, ethereum])
            store.save(expected)
            let persistedData = try XCTUnwrap(defaults.data(forKey: "cryptoBar.watchlist.v1"))
            XCTAssertEqual(try JSONDecoder().decode(Watchlist.self, from: persistedData), expected)
            let restored = WatchlistStore(defaults: defaults).load(defaultInstrument: ethereum)
            XCTAssertEqual(restored, expected)
        }
    }

    func testExplicitlySavedEmptyWatchlistRemainsEmptyOnNextLoad() throws {
        try withStore { defaults, store in
            store.save(Watchlist(instruments: [.bitcoin, ethereum]))
            store.save(Watchlist())
            XCTAssertEqual(WatchlistStore(defaults: defaults).load(defaultInstrument: ethereum).instruments, [])
            XCTAssertNotNil(defaults.data(forKey: "cryptoBar.watchlist.v1"))
        }
    }

    func testCorruptStoredDataFallsBackToCurrentSelection() throws {
        try withStore { defaults, store in
            for json in ["not JSON", "null", "[]", "{}", "{\"instruments\":42}"] {
                defaults.set(Data(json.utf8), forKey: "cryptoBar.watchlist.v1")
                XCTAssertEqual(store.load(defaultInstrument: ethereum).instruments, [ethereum])
            }
            defaults.set("wrong stored value type", forKey: "cryptoBar.watchlist.v1")
            XCTAssertEqual(store.load(defaultInstrument: solana).instruments, [solana])
        }
    }

    func testPartiallyCorruptSavedFavoritesKeepValidItemsInsteadOfSeeding() throws {
        try withStore { defaults, store in
            defaults.set(try savedData([row(solana), NSNull(), ["instId": "BTC-USDT"], row(ethereum), row(solana)]), forKey: "cryptoBar.watchlist.v1")
            XCTAssertEqual(store.load().instruments, [solana, ethereum])
        }
    }

    func testStructurallyValidSavedListWithOnlyBadEntriesLoadsEmpty() throws {
        try withStore { defaults, store in
            defaults.set(try savedData([NSNull(), 42, [:] as [String: Any]]), forKey: "cryptoBar.watchlist.v1")
            XCTAssertEqual(store.load(defaultInstrument: ethereum).instruments, [])
        }
    }

    func testInvalidDefaultInstrumentCannotSeedNonUSDTPair() throws {
        try withStore { _, store in
            let invalid = SpotInstrument(instId: "BTC-USDC", baseCcy: "BTC", quoteCcy: "USDC", tickSz: "0.1")
            XCTAssertEqual(store.load(defaultInstrument: invalid).instruments, [])
        }
    }

    private func row(_ instrument: SpotInstrument) -> [String: String] {
        ["instId": instrument.instId, "baseCcy": instrument.baseCcy, "quoteCcy": instrument.quoteCcy, "tickSz": instrument.tickSz]
    }

    private func savedData(_ entries: [Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["instruments": entries])
    }

    private func withStore(_ body: (UserDefaults, WatchlistStore) throws -> Void) throws {
        let domain = "cryptoBar.tests.watchlist.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults, WatchlistStore(defaults: defaults))
    }
}
