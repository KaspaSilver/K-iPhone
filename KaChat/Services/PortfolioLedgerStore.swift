import Foundation

/// Per-wallet persistence for the Portfolio investment ledger and the wallet's list of
/// up-to-5 named portfolios. Each wallet gets its own ledger (all its portfolios' transactions
/// together, self-describing their `portfolioId`) and its own portfolio list, keyed by wallet
/// address, mirroring ColdStorageManager/AddressBookManager's per-wallet UserDefaults key pattern.
enum PortfolioLedgerStore {
    private struct Snapshot: Codable {
        let version: Int
        let transactions: [PortfolioTransaction]
    }

    private static let currentVersion = 2
    private static let legacyKey = "kachat_portfolio_transactions"
    private static let keyPrefix = "kachat_portfolio_transactions_"
    private static let portfoliosKeyPrefix = "kachat_portfolios_"
    private static let activePortfolioKeyPrefix = "kachat_active_portfolio_"
    private static let feesKeyPrefix = "kachat_portfolio_fees_"

    private static func sanitize(_ walletAddress: String) -> String {
        walletAddress.replacingOccurrences(of: ":", with: "_")
    }

    private static func key(forNormalizedWalletAddress walletAddress: String) -> String {
        "\(keyPrefix)\(sanitize(walletAddress))"
    }

    private static func portfoliosKey(forNormalizedWalletAddress walletAddress: String) -> String {
        "\(portfoliosKeyPrefix)\(sanitize(walletAddress))"
    }

    private static func activePortfolioKey(forNormalizedWalletAddress walletAddress: String) -> String {
        "\(activePortfolioKeyPrefix)\(sanitize(walletAddress))"
    }

    // MARK: - Transactions

    /// `defaultPortfolioId` is used only to back-fill rows persisted before multi-portfolio
    /// support existed (both the legacy global key and version-1 per-wallet snapshots) — callers
    /// should resolve/create the wallet's default portfolio (see `PortfolioManager`) before
    /// calling this, so every pre-existing transaction lands somewhere real rather than under a
    /// throwaway id.
    static func load(walletAddress: String?, defaultPortfolioId: UUID, userDefaults: UserDefaults = .standard) -> [PortfolioTransaction] {
        guard let walletAddress else { return [] }
        let key = key(forNormalizedWalletAddress: walletAddress)
        if let data = userDefaults.data(forKey: key),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            if snapshot.version == currentVersion {
                return snapshot.transactions
            }
            // v1 -> v2: back-fill every pre-portfolio-scoping row into the caller's default
            // portfolio, then persist at the new version so this only runs once.
            let migrated = backfill(snapshot.transactions, defaultPortfolioId: defaultPortfolioId)
            save(migrated, walletAddress: walletAddress, userDefaults: userDefaults)
            return migrated
        }
        // One-time migration: this key predates per-wallet scoping. Claim it for the
        // first wallet that loads after the update, then remove it so no other wallet
        // can also claim it.
        if let legacyData = userDefaults.data(forKey: legacyKey),
           let legacySnapshot = try? JSONDecoder().decode(Snapshot.self, from: legacyData) {
            userDefaults.removeObject(forKey: legacyKey)
            let migrated = backfill(legacySnapshot.transactions, defaultPortfolioId: defaultPortfolioId)
            save(migrated, walletAddress: walletAddress, userDefaults: userDefaults)
            return migrated
        }
        return []
    }

    private static func backfill(_ transactions: [PortfolioTransaction], defaultPortfolioId: UUID) -> [PortfolioTransaction] {
        transactions.map { tx in
            var tx = tx
            tx.portfolioId = defaultPortfolioId
            return tx
        }
    }

    static func save(_ transactions: [PortfolioTransaction], walletAddress: String?, userDefaults: UserDefaults = .standard) {
        guard let walletAddress else { return }
        let key = key(forNormalizedWalletAddress: walletAddress)
        let snapshot = Snapshot(version: currentVersion, transactions: transactions)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        userDefaults.set(data, forKey: key)
    }

    /// Removes every transaction belonging to `portfolioId`, used when that portfolio is deleted.
    static func deleteTransactions(portfolioId: UUID, walletAddress: String?, userDefaults: UserDefaults = .standard) {
        guard let walletAddress else { return }
        let key = key(forNormalizedWalletAddress: walletAddress)
        guard let data = userDefaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        let remaining = snapshot.transactions.filter { $0.portfolioId != portfolioId }
        save(remaining, walletAddress: walletAddress, userDefaults: userDefaults)
    }

    // MARK: - Fees

    private static func feesKey(forNormalizedWalletAddress walletAddress: String) -> String {
        "\(feesKeyPrefix)\(sanitize(walletAddress))"
    }

    static func loadFees(walletAddress: String?, userDefaults: UserDefaults = .standard) -> [PortfolioFeeRecord] {
        guard let walletAddress,
              let data = userDefaults.data(forKey: feesKey(forNormalizedWalletAddress: walletAddress)),
              let fees = try? JSONDecoder().decode([PortfolioFeeRecord].self, from: data) else { return [] }
        return fees
    }

    static func saveFees(_ fees: [PortfolioFeeRecord], walletAddress: String?, userDefaults: UserDefaults = .standard) {
        guard let walletAddress, let data = try? JSONEncoder().encode(fees) else { return }
        userDefaults.set(data, forKey: feesKey(forNormalizedWalletAddress: walletAddress))
    }

    // MARK: - Portfolio list

    static func loadPortfolios(walletAddress: String?, userDefaults: UserDefaults = .standard) -> [Portfolio] {
        guard let walletAddress else { return [] }
        let key = portfoliosKey(forNormalizedWalletAddress: walletAddress)
        guard let data = userDefaults.data(forKey: key),
              let portfolios = try? JSONDecoder().decode([Portfolio].self, from: data) else {
            return []
        }
        return portfolios
    }

    static func savePortfolios(_ portfolios: [Portfolio], walletAddress: String?, userDefaults: UserDefaults = .standard) {
        guard let walletAddress else { return }
        let key = portfoliosKey(forNormalizedWalletAddress: walletAddress)
        guard let data = try? JSONEncoder().encode(portfolios) else { return }
        userDefaults.set(data, forKey: key)
    }

    static func loadActivePortfolioId(walletAddress: String?, userDefaults: UserDefaults = .standard) -> UUID? {
        guard let walletAddress else { return nil }
        let key = activePortfolioKey(forNormalizedWalletAddress: walletAddress)
        guard let raw = userDefaults.string(forKey: key) else { return nil }
        return UUID(uuidString: raw)
    }

    static func saveActivePortfolioId(_ id: UUID?, walletAddress: String?, userDefaults: UserDefaults = .standard) {
        guard let walletAddress else { return }
        let key = activePortfolioKey(forNormalizedWalletAddress: walletAddress)
        if let id {
            userDefaults.set(id.uuidString, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }

    /// Wipes this wallet's entire portfolio ledger and portfolio list — used when a saved
    /// account is removed from the device entirely. Mirrors ColdStorageManager.clearAllLocalData.
    static func clearAllLocalData(walletAddress: String?, userDefaults: UserDefaults = .standard) {
        guard let walletAddress else { return }
        userDefaults.removeObject(forKey: key(forNormalizedWalletAddress: walletAddress))
        userDefaults.removeObject(forKey: portfoliosKey(forNormalizedWalletAddress: walletAddress))
        userDefaults.removeObject(forKey: activePortfolioKey(forNormalizedWalletAddress: walletAddress))
        userDefaults.removeObject(forKey: feesKey(forNormalizedWalletAddress: walletAddress))
        userDefaults.removeObject(forKey: "\(legacyTombstonesKeyPrefix)\(sanitize(walletAddress))")
    }

    /// Deletions recorded for a Nextcloud portfolio sync this app no longer has; only cleared
    /// now (`clearAllLocalData`).
    private static let legacyTombstonesKeyPrefix = "kachat_portfolio_tombstones_"

    /// `current` as it will be saved: every item new since `previous`, or changed in anything
    /// but its stamp, stamped `now`.
    static func stamped<T: Identifiable & Equatable>(
        previous: [T], current: [T], now: Date,
        stamp: (inout T, Date?) -> Void
    ) -> [T] where T.ID: Hashable {
        func unstamped(_ item: T) -> T { var copy = item; stamp(&copy, nil); return copy }
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return current.map { item -> T in
            if let old = before[item.id], unstamped(old) == unstamped(item) { return item }
            var changed = item
            stamp(&changed, now)
            return changed
        }
    }

    /// A wallet's untouched seed - "Portfolio 1", never edited, holding nothing. A CSV import
    /// renames it rather than adding a second portfolio beside an empty one.
    static func isPristineSeed(_ p: Portfolio, transactions: [PortfolioTransaction], fees: [PortfolioFeeRecord]) -> Bool {
        p.updatedAt == nil && p.name == "Portfolio 1"
            && !transactions.contains { $0.portfolioId == p.id } && !fees.contains { $0.portfolioId == p.id }
    }
}
