import Foundation

struct ColdStorageAccount: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    let kpubString: String
    var maxAddressIndex: Int
    let importedAt: Date
    /// Whether a receive to one of this account's addresses posts a notification
    /// (AddressActivityNotifier). Per account, so one busy account can be quiet while the
    /// others still tell you. Stored per wallet with the account; older records decode as on.
    var notifyOnReceive: Bool = true
    /// The KasSigner's quantum-resistant (KCC-3, `m/22'`) addresses watched in this account,
    /// in the order added. A unit never exports a `22'` kpub - it would show every key the
    /// addresses hide - so each is scanned from the unit's address screen, one at a time
    /// (owner, 2026-11-25: Cold Storage matches the hot wallet's quantum addresses).
    var quantumAddresses: [ColdQuantumAddress] = []

    init(id: UUID = UUID(), label: String, kpubString: String, maxAddressIndex: Int = 0, importedAt: Date = Date(), notifyOnReceive: Bool = true) {
        self.id = id
        self.label = label
        self.kpubString = kpubString
        self.maxAddressIndex = maxAddressIndex
        self.importedAt = importedAt
        self.notifyOnReceive = notifyOnReceive
    }

    private enum CodingKeys: String, CodingKey { case id, label, kpubString, maxAddressIndex, importedAt, notifyOnReceive, quantumAddresses }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        kpubString = try container.decode(String.self, forKey: .kpubString)
        maxAddressIndex = try container.decode(Int.self, forKey: .maxAddressIndex)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        notifyOnReceive = try container.decodeIfPresent(Bool.self, forKey: .notifyOnReceive) ?? true
        quantumAddresses = try container.decodeIfPresent([ColdQuantumAddress].self, forKey: .quantumAddresses) ?? []
    }
}

/// One KasSigner quantum-resistant (KCC-3) address: P2SH of `<P> OP_CHECKSIG`, P at
/// `m/22'/111111'/0'/0/<unitIndex>` on the unit. Known only by its text: the key stays on the
/// unit until the address spends, and the unit supplies the script when it signs.
struct ColdQuantumAddress: Codable, Equatable, Hashable {
    /// Which of the unit's two KCC-3 chains the address is on (`m/22'/111111'/0'/<chain>/n`).
    /// It matters for change: KasSigner marks a script-hash output as CHANGE only when it is one
    /// of its KCC-3 change-chain keys #0-4 (firmware `Keyring::kcc3_change_index`, its bank);
    /// any other, a receive address included, shows on the unit as an ordinary payment.
    enum Chain: UInt32, Codable, CaseIterable {
        case receive = 0
        case change = 1
    }

    /// The change-chain numbers KasSigner recognises as its own change when reviewing outputs
    /// (`CHANGE_DEPTH` keys of its bank).
    static let unitMarkedChangeRange: ClosedRange<UInt32> = 0...4

    let address: String
    /// The address's number on the unit's KCC-3 chain, when the person gave it: sent as the
    /// request's KCC-3 hint so the unit finds the key at once. Without it the unit searches its
    /// KCC-3 chains itself.
    var unitIndex: UInt32?
    var chain: Chain
    var addedAt: Date

    init(address: String, unitIndex: UInt32?, chain: Chain = .receive, addedAt: Date = Date()) {
        self.address = address
        self.unitIndex = unitIndex
        self.chain = chain
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey { case address, unitIndex, chain, addedAt }

    // Records saved before the chain was asked for decode as receive, which is what they were
    // sent as.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decode(String.self, forKey: .address)
        unitIndex = try container.decodeIfPresent(UInt32.self, forKey: .unitIndex)
        chain = (try? container.decodeIfPresent(Chain.self, forKey: .chain)) ?? .receive
        addedAt = (try? container.decodeIfPresent(Date.self, forKey: .addedAt)) ?? Date()
    }

    /// The unit will show change sent here as CHANGE, not as a payment to someone.
    var unitMarksAsChange: Bool {
        guard chain == .change, let unitIndex else { return false }
        return Self.unitMarkedChangeRange.contains(unitIndex)
    }

    /// The default name, by chain and number ("Quantum Address #3", "Quantum Change Address #0").
    static func defaultLabel(chain: Chain, unitIndex: UInt32?) -> String {
        switch (chain, unitIndex) {
        case (.receive, nil):
            return AppLocalization.string("Quantum Address")
        case (.change, nil):
            return AppLocalization.string("Quantum Change Address")
        case (.receive, let number?):
            return String(format: AppLocalization.string("Quantum Address #%lld"),
                          locale: AppLocalization.locale, Int64(number))
        case (.change, let number?):
            return String(format: AppLocalization.string("Quantum Change Address #%lld"),
                          locale: AppLocalization.locale, Int64(number))
        }
    }
}

struct ColdStorageAddressEntry: Identifiable {
    let index: Int
    let address: String
    let balanceSompi: UInt64
    var everUsed: Bool = false
    var label: String?
    var hidden: Bool = false
    /// A KasSigner quantum-resistant (KCC-3) address, added by scan (`ColdQuantumAddress`). Its
    /// `index` is `ColdStorageManager.quantumIndexBase` + its place in the account's list.
    var isQuantum: Bool = false
    /// The unit's number for a quantum address, when known.
    var unitIndex: UInt32? = nil
    /// The unit's KCC-3 chain for a quantum address.
    var quantumChain: ColdQuantumAddress.Chain = .receive

    var id: String { address }
    var displayLabel: String {
        if label?.isEmpty == false { return label! }
        return defaultLabel
    }
    /// The name it goes by with no label of its own.
    var defaultLabel: String {
        if isQuantum {
            return ColdQuantumAddress.defaultLabel(chain: quantumChain, unitIndex: unitIndex)
        }
        return String(format: AppLocalization.string("Address #%lld"), locale: AppLocalization.locale, Int64(index))
    }
    var shortAddress: String {
        guard address.count > 20 else { return address }
        return address.prefix(14) + "..." + address.suffix(6)
    }
}

enum ColdStorageError: LocalizedError {
    case invalidKpub
    case notQuantumAddress
    case alreadyAdded
    /// The address is already watched by another Cold Storage account (its name).
    case inOtherAccount(String)

    var errorDescription: String? {
        switch self {
        case .invalidKpub:
            return "That doesn't look like a valid Kaspa extended public key (kpub)."
        case .notQuantumAddress:
            return AppLocalization.string("That isn't a quantum-resistant address. Scan the KCC-3 address KasSigner shows.")
        case .alreadyAdded:
            return AppLocalization.string("That address is already in this account.")
        case .inOtherAccount(let name):
            return String(format: AppLocalization.string("That address is already in your Cold Storage account “%@”."),
                          locale: AppLocalization.locale, name)
        }
    }
}

/// Cold storage receive addresses, derived off the main thread and kept per kpub, network and
/// index (audit 2026-11-21 #34). An address is two elliptic-curve steps; Discover wants a thousand
/// at once, and every list load derived the whole list again on the main thread. Now each one is
/// derived once per launch, and the bulk work runs on a background thread. A lock rather than an
/// actor, so a single lookup (`ColdStorageManager.address(for:at:)`) can still answer at once.
final class ColdStorageAddressCache: @unchecked Sendable {
    static let shared = ColdStorageAddressCache()

    private struct ChainKey: Hashable {
        let kpub: String
        let network: NetworkType
    }

    private let lock = NSLock()
    /// Each kpub's receive chain key (kpub -> 0), the step every address shares.
    private var receiveChains: [String: KaspaExtendedPublicKey] = [:]
    private var derivedByChain: [ChainKey: [UInt32: String]] = [:]

    private init() {}

    /// The receive addresses at `indices`, in order, on the calling thread. With `stopOnFailure`
    /// the list ends at the first index that can't be derived; otherwise that index is skipped.
    func addresses(kpub: String, network: NetworkType, indices: Range<UInt32>, stopOnFailure: Bool) -> [(UInt32, String)] {
        guard !indices.isEmpty, let chain = receiveChain(kpub: kpub) else { return [] }
        let key = ChainKey(kpub: kpub, network: network)
        lock.lock()
        let known = derivedByChain[key] ?? [:]
        lock.unlock()

        var result: [(UInt32, String)] = []
        result.reserveCapacity(indices.count)
        var derived: [UInt32: String] = [:]
        for index in indices {
            if let address = known[index] {
                result.append((index, address))
            } else if let child = try? chain.deriveChild(index: index) {
                let address = child.address(network: network)
                derived[index] = address
                result.append((index, address))
            } else if stopOnFailure {
                break
            }
        }
        if !derived.isEmpty {
            lock.lock()
            derivedByChain[key, default: [:]].merge(derived) { old, _ in old }
            lock.unlock()
        }
        return result
    }

    /// One receive address (nil when the kpub or the index can't be derived).
    func address(kpub: String, network: NetworkType, index: UInt32) -> String? {
        guard index < UInt32.max else { return nil }
        return addresses(kpub: kpub, network: network, indices: index..<(index + 1), stopOnFailure: true).first?.1
    }

    /// `addresses(kpub:network:indices:stopOnFailure:)` on a background thread, for the bulk asks.
    func addressesInBackground(kpub: String, network: NetworkType, indices: Range<UInt32>, stopOnFailure: Bool) async -> [(UInt32, String)] {
        await Task.detached(priority: .userInitiated) {
            self.addresses(kpub: kpub, network: network, indices: indices, stopOnFailure: stopOnFailure)
        }.value
    }

    private func receiveChain(kpub: String) -> KaspaExtendedPublicKey? {
        lock.lock()
        let cached = receiveChains[kpub]
        lock.unlock()
        if let cached { return cached }
        guard let key = KaspaExtendedPublicKey(kpubString: kpub),
              let chain = try? key.deriveChild(index: 0) else { return nil }
        lock.lock()
        receiveChains[kpub] = chain
        lock.unlock()
        return chain
    }
}

/// Manages watch-only "cold storage" accounts imported via kpub extended public key
/// (e.g. exported from a KasSigner hardware device). Storage here is intentionally
/// separate from WalletManager/KeychainService — a kpub contains no private key or
/// mnemonic material, so it needs none of the Secure Enclave wrapping used for the app's
/// spending wallet.
@MainActor
final class ColdStorageManager: ObservableObject {
    static let shared = ColdStorageManager()

    @Published private(set) var accounts: [ColdStorageAccount] = []

    private let legacyStorageKey = "kachat_cold_storage_accounts"
    /// Bumped whenever an account's hidden addresses change: receive notifications watch only the
    /// addresses an account shows (`AddressActivityNotifier`).
    private(set) var hiddenRevision = 0
    private let storageKeyPrefix = "kachat_cold_storage_accounts_"
    private var activeWalletAddress: String?

    private init() {
        // No wallet set yet at app launch; setCurrentWallet(_:) is called once the
        // active wallet is known, which loads (and migrates, if needed) the real list.
        accounts = []
    }

    /// Cold storage accounts are watch-only imports, but they must still be scoped per
    /// spending wallet — otherwise switching accounts on this device leaks one wallet's
    /// imported kpubs/labels/hidden-address state into another's view. Mirrors
    /// AddressBookManager.setActiveWalletAddress's key-per-wallet pattern.
    func setCurrentWallet(_ walletAddress: String?) {
        let normalizedAddress = normalizeWalletAddress(walletAddress)
        guard activeWalletAddress != normalizedAddress else { return }
        activeWalletAddress = normalizedAddress
        accounts = normalizedAddress == nil ? [] : loadAccounts()
        AddressActivityNotifier.shared.coldStorageAccountsChanged()
    }

    private func normalizeWalletAddress(_ walletAddress: String?) -> String? {
        guard let walletAddress = walletAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              !walletAddress.isEmpty else {
            return nil
        }
        return walletAddress.lowercased()
    }

    private var storageKey: String? {
        guard let activeWalletAddress else { return nil }
        return walletStorageKey(for: activeWalletAddress)
    }

    private func walletStorageKey(for walletAddress: String) -> String {
        "\(storageKeyPrefix)\(walletAddress.replacingOccurrences(of: ":", with: "_"))"
    }

    // MARK: - Import / management

    /// Re-importing an already-known kpub updates that account's name in place rather than
    /// creating a duplicate entry.
    /// Ties the store to the signed-in account if that was missed. Untied, `saveAccounts` has no
    /// key and writes nothing, so an import would last only until the app closed.
    func ensureTiedToSignedInAccount() {
        guard activeWalletAddress == nil, let wallet = WalletManager.shared.currentWallet?.publicAddress else { return }
        setCurrentWallet(wallet)
    }

    @discardableResult
    func importAccount(kpubString: String, label: String) -> Result<ColdStorageAccount, ColdStorageError> {
        ensureTiedToSignedInAccount()
        let trimmedKpub = kpubString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KaspaExtendedPublicKey(kpubString: trimmedKpub) != nil else {
            return .failure(.invalidKpub)
        }

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLabel = trimmedLabel.isEmpty ? "Cold Storage \(accounts.count + 1)" : trimmedLabel

        if let idx = accounts.firstIndex(where: { $0.kpubString == trimmedKpub }) {
            accounts[idx].label = resolvedLabel
            saveAccounts()
            return .success(accounts[idx])
        }

        let account = ColdStorageAccount(label: resolvedLabel, kpubString: trimmedKpub)
        accounts.append(account)
        saveAccounts()
        return .success(account)
    }

    func removeAccount(_ account: ColdStorageAccount) {
        accounts.removeAll { $0.id == account.id }
        saveAccounts()
        removePerAccountData(of: [account])
    }

    /// Turns receive notifications on or off for one account (see `ColdStorageAccount.notifyOnReceive`).
    func setNotifyOnReceive(_ enabled: Bool, for account: ColdStorageAccount) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].notifyOnReceive = enabled
        saveAccounts()
    }

    // MARK: - Quantum-resistant (KCC-3) addresses

    /// Where quantum addresses start in an account's index space (labels, hidden flags), clear
    /// of any receive index a kpub could reach. The hot wallet uses the same base.
    nonisolated static let quantumIndexBase = 1_000_000

    nonisolated static func isQuantumIndex(_ index: Int) -> Bool { index >= quantumIndexBase }

    /// Adds a KasSigner KCC-3 address scanned (or pasted) from the unit's address screen. Only a
    /// pay-to-script-hash address of this network reads: the text can't say what is behind the
    /// hash, so the unit is the one that checks it holds the key, when it signs.
    func addQuantumAddress(_ text: String, unitIndex: UInt32?, chain: ColdQuantumAddress.Chain = .receive, to account: ColdStorageAccount) -> Result<ColdQuantumAddress, ColdStorageError> {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // a QR may carry a payment URI ("kaspa:...?amount=")
        if let query = raw.firstIndex(of: "?") { raw = String(raw[..<query]) }
        let address = raw.lowercased()
        guard KaspaAddress.isValidOnActiveNetwork(address), Self.isScriptHashAddress(address) else {
            return .failure(.notQuantumAddress)
        }
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return .failure(.notQuantumAddress) }
        guard !accounts[idx].quantumAddresses.contains(where: { $0.address == address }) else {
            return .failure(.alreadyAdded)
        }
        // One address, one account: watched twice, its coins would count in both totals and a
        // send from one could pick it as the other's change.
        if let other = accounts.first(where: { $0.id != account.id && $0.quantumAddresses.contains { $0.address == address } }) {
            return .failure(.inOtherAccount(other.label))
        }
        let entry = ColdQuantumAddress(address: address, unitIndex: unitIndex, chain: chain)
        accounts[idx].quantumAddresses.append(entry)
        saveAccounts()
        AddressActivityNotifier.shared.coldStorageAccountsChanged()
        return .success(entry)
    }

    /// Stops watching a quantum address (its coins stay where they are on chain).
    func removeQuantumAddress(_ address: String, from account: ColdStorageAccount) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }),
              let position = accounts[idx].quantumAddresses.firstIndex(where: { $0.address == address.lowercased() }) else { return }
        accounts[idx].quantumAddresses.remove(at: position)
        saveAccounts()
        // Labels and hidden flags are kept by index: the ones after it move up a place with
        // their addresses.
        let removedIndex = Self.quantumIndexBase + position
        func shifted(_ index: Int) -> Int? {
            guard Self.isQuantumIndex(index), index >= removedIndex else { return index }
            return index == removedIndex ? nil : index - 1
        }
        let labels = loadAddressLabels(accountId: account.id)
        var newLabels: [Int: String] = [:]
        for (index, label) in labels { if let moved = shifted(index) { newLabels[moved] = label } }
        saveAddressLabels(newLabels, accountId: account.id)
        saveHiddenIndices(Set(loadHiddenIndices(accountId: account.id).compactMap(shifted)), accountId: account.id)
        AddressActivityNotifier.shared.coldStorageAccountsChanged()
    }

    /// Sets or clears a quantum address's number and chain on the unit (Edit Address Number): a
    /// wrong one makes the unit refuse the request, which only the person can put right.
    func updateQuantumAddress(_ address: String, unitIndex: UInt32?, chain: ColdQuantumAddress.Chain, in account: ColdStorageAccount) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }),
              let position = accounts[idx].quantumAddresses.firstIndex(where: { $0.address == address.lowercased() }) else { return }
        accounts[idx].quantumAddresses[position].unitIndex = unitIndex
        accounts[idx].quantumAddresses[position].chain = chain
        saveAccounts()
    }

    /// Where a quantum address sits in its account's index space now, nil once it's no longer
    /// watched. Labels and hidden flags of quantum entries are filed by this index, which moves
    /// when an earlier one is removed, so an edit made from a row loaded before that resolves
    /// its index here, by address, at the moment it saves.
    func currentQuantumIndex(of address: String, in account: ColdStorageAccount) -> Int? {
        currentQuantumAddresses(of: account)
            .firstIndex(where: { $0.address == address.lowercased() })
            .map { Self.quantumIndexBase + $0 }
    }

    /// The name a quantum address shows: the person's label, else its default by chain and number.
    func quantumDisplayLabel(of address: String) -> String? {
        guard let record = quantumAddressRecord(address),
              let index = currentQuantumIndex(of: address, in: record.account) else { return nil }
        let (account, entry) = record
        if let label = loadAddressLabels(accountId: account.id)[index], !label.isEmpty { return label }
        return ColdQuantumAddress.defaultLabel(chain: entry.chain, unitIndex: entry.unitIndex)
    }

    /// Every address of the Cold Storage account holding `address`, lowercased: its derived
    /// receive addresses up to the highest shown, and its quantum ones. What a history row counts
    /// as the account's own, so change sent to another of them (a quantum source's change goes
    /// to a fresh quantum address) isn't shown as Sent. Just `address` when no account holds it.
    func accountAddresses(containing address: String) async -> Set<String> {
        let lowered = address.lowercased()
        let network = AppSettings.load().networkType
        for account in accounts {
            let quantum = account.quantumAddresses.map(\.address)
            let regular = await ColdStorageAddressCache.shared.addressesInBackground(
                kpub: account.kpubString,
                network: network,
                indices: 0..<UInt32(max(account.maxAddressIndex, 0) + 1),
                stopOnFailure: true
            ).map { $0.1.lowercased() }
            let all = Set(quantum + regular)
            if all.contains(lowered) { return all }
        }
        return [lowered]
    }

    /// The unit's number for one of this account's quantum addresses, nil when not given.
    func quantumUnitIndex(of address: String, in account: ColdStorageAccount) -> UInt32? {
        accounts.first(where: { $0.id == account.id })?
            .quantumAddresses.first(where: { $0.address == address.lowercased() })?.unitIndex
    }

    /// The account's quantum addresses as stored now (the value passed in may be an older copy).
    func currentQuantumAddresses(of account: ColdStorageAccount) -> [ColdQuantumAddress] {
        accounts.first(where: { $0.id == account.id })?.quantumAddresses ?? account.quantumAddresses
    }

    /// The account and record holding quantum address `address`, if any.
    func quantumAddressRecord(_ address: String) -> (account: ColdStorageAccount, entry: ColdQuantumAddress)? {
        let lowered = address.lowercased()
        for account in accounts {
            if let entry = account.quantumAddresses.first(where: { $0.address == lowered }) {
                return (account, entry)
            }
        }
        return nil
    }

    /// A pay-to-script-hash address: its script is `OP_BLAKE2B <32> OP_EQUAL`.
    nonisolated static func isScriptHashAddress(_ address: String) -> Bool {
        guard let script = KaspaAddress.scriptPublicKey(from: address) else { return false }
        return script.count == 35 && script.first == 0xAA && script.last == 0x87
    }

    func renameAccount(_ account: ColdStorageAccount, to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].label = trimmed
        saveAccounts()
    }

    // MARK: - Address list / balances

    /// Derives addresses 0...maxAddressIndex for the account and fetches live balances with a
    /// single batched `getUtxosByAddresses` call covering every address at once (mirrors
    /// Kaspium's `UtxosNotifier.refresh`, which does the same one-call-for-the-whole-set fetch
    /// rather than a request per address) instead of the previous per-address `withTaskGroup`,
    /// which fired one gRPC round trip per address even though `getUtxosByAddresses` already
    /// accepts the whole address list. Safe to batch here (unlike the spending chain's
    /// sequential "used" scan below) since this is only balance lookups against a gRPC node,
    /// not the REST call that was previously implicated in rate-limit-driven false "used" results.
    func getAddressList(for account: ColdStorageAccount) async -> [ColdStorageAddressEntry] {
        guard KaspaExtendedPublicKey(kpubString: account.kpubString) != nil else { return [] }
        let network = AppSettings.load().networkType
        let labels = loadAddressLabels(accountId: account.id)
        let hidden = loadHiddenIndices(accountId: account.id)

        // Off the main thread, and only the indices not derived before (audit 2026-11-21 #34).
        var addressesByIndex: [Int: String] = [:]
        let derived = await ColdStorageAddressCache.shared.addressesInBackground(
            kpub: account.kpubString, network: network,
            indices: 0..<(UInt32(max(account.maxAddressIndex, 0)) + 1), stopOnFailure: false
        )
        for (index, address) in derived {
            addressesByIndex[Int(index)] = address
        }

        let allAddresses = Array(addressesByIndex.values) + currentQuantumAddresses(of: account).map(\.address)
        var balanceByAddress: [String: UInt64] = [:]
        let balancesKey = addressBalancesKey(for: account.id)
        if let utxos = try? await NodePoolService.shared.getUtxosByAddresses(allAddresses) {
            for utxo in utxos {
                balanceByAddress[utxo.address, default: 0] += utxo.amount
            }
            UserDefaults.standard.set(try? JSONEncoder().encode(balanceByAddress), forKey: balancesKey)
        } else if let saved = UserDefaults.standard.data(forKey: balancesKey),
                  let known = try? JSONDecoder().decode([String: UInt64].self, from: saved) {
            // a failed read isn't an empty address: the last figures known
            balanceByAddress = known
        }

        let regular = addressesByIndex.map { index, address in
            ColdStorageAddressEntry(
                index: index,
                address: address,
                balanceSompi: balanceByAddress[address] ?? 0,
                label: labels[index],
                hidden: hidden.contains(index)
            )
        }.sorted { $0.index < $1.index }
        // The quantum addresses added by scan, after the regular ones, in the order added.
        let quantum = currentQuantumAddresses(of: account).enumerated().map { position, entry in
            let index = Self.quantumIndexBase + position
            return ColdStorageAddressEntry(
                index: index,
                address: entry.address,
                balanceSompi: balanceByAddress[entry.address] ?? 0,
                label: labels[index],
                hidden: hidden.contains(index),
                isQuantum: true,
                unitIndex: entry.unitIndex,
                quantumChain: entry.chain
            )
        }
        return regular + quantum
    }

    /// Scans forward from index 0, stopping after `gapLimit` consecutive never-used
    /// addresses, and raises maxAddressIndex to cover every used address found. Sequential
    /// by design, matching WalletManager.discoverSpendingAddresses' rate-limit reasoning.
    /// Scan progress: the index being checked, and how many used addresses have been found.
    ///
    /// Discovery walks addresses one at a time until it has seen `gapLimit` unused ones in a row,
    /// and each step is a network call - it can easily take half a minute. Reported so the caller
    /// can show what is happening rather than an unmoving spinner.
    struct DiscoveryProgress: Equatable {
        let checkingIndex: Int
        let foundCount: Int
    }

    /// Swept whatever the gaps, so a run of empty addresses can never end the scan early.
    static let deepScanFloor: UInt32 = 1000
    /// Hard stop, so the scan always terminates.
    static let maxScanIndex: UInt32 = 5000
    /// Addresses per bulk UTXO request.
    static let scanBatchSize: UInt32 = 100
    /// KNS has no bulk endpoint, so domain ownership is only probed this far in.
    static let knsProbeDepth: UInt32 = 200

    @discardableResult
    func discoverAddresses(
        for account: ColdStorageAccount,
        gapLimit: Int = 60,
        onProgress: (@MainActor (DiscoveryProgress) -> Void)? = nil
    ) async -> Int {
        guard KaspaExtendedPublicKey(kpubString: account.kpubString) != nil else {
            return account.maxAddressIndex
        }
        let network = AppSettings.load().networkType

        var lastMatchIndex = -1
        var matchCount = 0
        var matchedIndices: Set<Int> = []

        // An address is worth surfacing when it HOLDS SOMETHING: a balance, or a KNS domain.
        //
        // This used to also count transaction history, which is why a scan reported 49 addresses
        // on an account with a handful worth looking at - every address ever touched and emptied
        // came back forever. History still matters for the "Unused" badge on a row (reusing an
        // address is a privacy problem), but it is not what this list is for.
        //
        // Always from index 0, never from a stored high-water mark: the answer CHANGES over time.
        // An address that was empty last month can hold a balance today, and a scan that starts
        // past it would never look again.
        //
        // ## Why this is no longer a per-address gap-limit walk
        //
        // It was: one UTXO request per address, stop after 20 consecutive empties. That cannot
        // find what it is asked to find. Any run of 20 empty addresses ends the scan, and a
        // funded account can easily have one, so anything past the first gap was unreachable with
        // no way for the reader to make it look further. The spending-address scan had the
        // identical bug and was reported for exactly that: a balance at index 291 discovery would
        // never see.
        //
        // It sweeps a floor of `deepScanFloor` indices whatever the gaps now, in batches.
        // `getUtxosByAddresses` has always taken an array; asking it for one address at a time is
        // what made this hundreds of round trips.
        // ## Why the batched UTXO sweep is not the shape of this any more
        //
        // The sweep itself was already batched and already fast: ten `getUtxosByAddresses` calls
        // covered a thousand addresses. What made a discover take the better part of two minutes
        // was the line under it - KNS was asked about the first two hundred addresses ONE AT A
        // TIME, and a KNS lookup measures between a third of a second and two thirds. That is
        // sixty to a hundred and thirty seconds of sequential HTTP, and no amount of batching the
        // balances touches it.
        //
        // `AddressActivityService` answers "was this address ever used" for the whole window in a
        // handful of requests. That turns the expensive steps into cheap ones: balances are asked
        // only about addresses the chain says were touched, and so is KNS. A balance or a domain
        // cannot sit on an address that has never been touched, so the filter loses nothing, and
        // the ~200 sequential lookups become a handful of concurrent ones.
        // Derived off the main thread and kept, so the list loads after this one derive nothing.
        let derivedWindow = await ColdStorageAddressCache.shared.addressesInBackground(
            kpub: account.kpubString, network: network,
            indices: 0..<min(Self.deepScanFloor, Self.maxScanIndex), stopOnFailure: true
        )
        if let onProgress {
            let snapshot = DiscoveryProgress(checkingIndex: 0, foundCount: 0)
            await MainActor.run { onProgress(snapshot) }
        }

        if let activity = await AddressActivityService.lastActivity(for: derivedWindow.map { $0.1 }) {
            let touched = derivedWindow.filter { activity[$0.1] != nil }

            var funded: Set<String> = []
            if !touched.isEmpty,
               let utxos = try? await NodePoolService.shared.getUtxosByAddresses(touched.map { $0.1 }) {
                funded = Set(utxos.map { $0.address })
            }
            if let onProgress {
                let snapshot = DiscoveryProgress(checkingIndex: touched.last.map { Int($0.0) } ?? 0, foundCount: funded.count)
                await MainActor.run { onProgress(snapshot) }
            }

            // KNS only for touched, unfunded addresses inside the probe depth - typically none,
            // and never the two hundred sequential lookups this used to be. Concurrent, because
            // there is no longer any reason for them to wait on each other.
            let knsCandidates = touched.filter { Int($0.0) < Int(Self.knsProbeDepth) && !funded.contains($0.1) }
            var domainOwners: Set<String> = []
            if !knsCandidates.isEmpty {
                domainOwners = await withTaskGroup(of: String?.self) { group -> Set<String> in
                    for (_, address) in knsCandidates {
                        group.addTask { await NameServicesClient.shared.ownsAnyName(address) ? address : nil }
                    }
                    var owners: Set<String> = []
                    for await owner in group { if let owner { owners.insert(owner) } }
                    return owners
                }
            }

            for (i, address) in touched where funded.contains(address) || domainOwners.contains(address) {
                lastMatchIndex = max(lastMatchIndex, Int(i))
                matchCount += 1
                matchedIndices.insert(Int(i))
            }
        } else {
            // The configured REST server does not serve /addresses/active, or could not be
            // reached. Fall back to the batched sweep this replaced - slower, and it still pays
            // for the sequential KNS probes, but a slow answer beats none.
            AppLog.log("%@", "[ColdStorage] Discovery: bulk activity unavailable, using the batched sweep")
            var consecutiveMisses = 0
            var index: UInt32 = 0
            while index < Self.maxScanIndex {
                if index >= Self.deepScanFloor && consecutiveMisses >= gapLimit { break }

                let upper = min(index + Self.scanBatchSize, Self.maxScanIndex)
                if let onProgress {
                    let snapshot = DiscoveryProgress(checkingIndex: Int(index), foundCount: matchCount)
                    await MainActor.run { onProgress(snapshot) }
                }

                let derived = await ColdStorageAddressCache.shared.addressesInBackground(
                    kpub: account.kpubString, network: network, indices: index..<upper, stopOnFailure: true
                )
                if derived.isEmpty { break }

                guard let utxos = try? await NodePoolService.shared.getUtxosByAddresses(derived.map { $0.1 }) else {
                    AppLog.log("[ColdStorage] Discovery: balances unavailable at %d, stopping", Int(index))
                    break
                }
                let funded = Set(utxos.map { $0.address })

                for (i, address) in derived {
                    let matches: Bool
                    if funded.contains(address) {
                        matches = true
                    } else if i < Self.knsProbeDepth {
                        matches = await NameServicesClient.shared.ownsAnyName(address)
                    } else {
                        matches = false
                    }
                    if matches {
                        lastMatchIndex = Int(i)
                        matchCount += 1
                        matchedIndices.insert(Int(i))
                        consecutiveMisses = 0
                    } else {
                        consecutiveMisses += 1
                    }
                }
                index += UInt32(derived.count)
            }
        }

        // The stored bound has to cover the highest MATCH so those rows can be derived and shown.
        // It only ever grows: an address that held funds last month and is empty now should not
        // vanish from the list.
        let bound = lastMatchIndex + 1
        // Tested against the STORED bound, not the snapshot this scan was handed. The two are the
        // same value most of the time and diverge exactly when it matters: the account can grow
        // mid-scan (Generate More Addresses, or revealing a row in Address Visibility), and the
        // range below is built from the stored one. Guarding on the snapshot while indexing from
        // the stored value is what let `previousMax` overtake `lastMatchIndex`.
        //
        // Strict `>`, and a HALF-OPEN range below - the same shape
        // `WalletManager.discoverSpendingAddresses` uses, which is correct. With `>=` and a closed
        // range, a scan whose highest match sat exactly ON the current bound passed the guard and
        // then built `(max + 1)...max`, whose lowerBound is greater than its upperBound: a fatal
        // error, not an empty loop. Reported from a real Discover Addresses run.
        let storedMax = accounts.first(where: { $0.id == account.id })?.maxAddressIndex ?? account.maxAddressIndex
        if lastMatchIndex > storedMax, let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            let previousMax = accounts[idx].maxAddressIndex
            accounts[idx].maxAddressIndex = bound
            saveAccounts()
            // Rows default to VISIBLE unless explicitly hidden, so hide the empty indices the new
            // bound sweeps in - exactly as `revealAddress` already does. The scan reaches a
            // thousand addresses deep now, and a match at index 291 would otherwise fill this
            // account's list with 290 empty rows. Anything the scan MATCHED is un-hidden instead:
            // a previously-hidden address that now holds a balance would otherwise be found and
            // dropped straight back out of the list, which reads as not finding it at all.
            var hiddenSet = loadHiddenIndices(accountId: account.id)
            // Half-open: `lastMatchIndex` is itself a match, and matches are un-hidden on the
            // next line anyway, so including it only to subtract it again bought nothing and cost
            // the crash.
            for i in (previousMax + 1)..<lastMatchIndex where !matchedIndices.contains(i) {
                hiddenSet.insert(i)
            }
            hiddenSet.subtract(matchedIndices)
            saveHiddenIndices(hiddenSet, accountId: account.id)
        } else if !matchedIndices.isEmpty {
            var hiddenSet = loadHiddenIndices(accountId: account.id)
            let before = hiddenSet
            hiddenSet.subtract(matchedIndices)
            if hiddenSet != before { saveHiddenIndices(hiddenSet, accountId: account.id) }
        }
        // The COUNT of addresses worth showing - not the bound. "Found 49" for six funded
        // addresses was the old return value leaking a high-water mark into a user-facing number.
        return matchCount
    }

    func generateNextAddress(for account: ColdStorageAccount) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].maxAddressIndex += 1
        saveAccounts()
    }

    /// "Generate More Addresses" - a SEQUENCE, not a single answer (mirrors
    /// WalletManager.lowestUnusedRegularAddress): every press yields the NEXT fresh address,
    /// forever. The chosen index is the lowest one that is truly unused (zero balance, no
    /// on-chain history) AND currently hidden - i.e. not already sitting in the visible list.
    /// Recycling un-hides it. An index that is already visible is never picked (that was the
    /// old stall: the lowest unused index, once revealed, satisfied every check again on the
    /// next press, so Generate kept returning the same row). When no hidden unused index
    /// remains, the chain extends by one past the all-time max, which is always safe. A probe
    /// failure (used-ness unknown) skips that index rather than recycling it. Returns the
    /// chosen index.
    func lowestUnusedAddress(for account: ColdStorageAccount) async -> Int {
        let entries = await getAddressList(for: account)
        // Only the kpub's chain: a quantum entry (index 1,000,000+) is a scanned address, not the
        // next one to hand out, and Generate More must never un-hide one.
        for entry in entries where !entry.isQuantum {
            guard entry.hidden else { continue } // already visible - the user has it; move on
            if entry.balanceSompi > 0 { continue }
            // Recycle only on a CONFIRMED-unused probe; nil (probe failed) skips the index -
            // extending the chain below is always safe, recycling an unknown one is not.
            let usedState = await ChatService.shared.spendingAddressUsedState(entry.address)
            if usedState == false {
                setAddressHidden(accountId: account.id, index: entry.index, hidden: false, balanceSompi: 0)
                return entry.index
            }
        }
        generateNextAddress(for: account)
        let newIndex = (accounts.first(where: { $0.id == account.id })?.maxAddressIndex) ?? (account.maxAddressIndex + 1)
        setAddressHidden(accountId: account.id, index: newIndex, hidden: false, balanceSompi: 0)
        return newIndex
    }

    /// Reveals a specific index from the Address Visibility pager, extending the chain when the
    /// index is beyond the current max - intermediate newly-covered indices are marked hidden so
    /// checking ONE far-out row doesn't flood the main list with everything below it. Mirrors
    /// WalletManager.revealSpendingAddress.
    func revealAddress(for account: ColdStorageAccount, at index: Int) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let currentMax = accounts[idx].maxAddressIndex
        if index > currentMax {
            accounts[idx].maxAddressIndex = index
            saveAccounts()
            if index - 1 > currentMax {
                var hiddenSet = loadHiddenIndices(accountId: account.id)
                for i in (currentMax + 1)..<index { hiddenSet.insert(i) }
                saveHiddenIndices(hiddenSet, accountId: account.id)
            }
        }
        setAddressHidden(accountId: account.id, index: index, hidden: false, balanceSompi: 0)
    }

    /// Read-only snapshot of the hidden set, so the detail screen can apply bulk visibility
    /// edits to its already-loaded rows instantly on sheet dismiss (before the full balance
    /// reload finishes). Mirrors WalletManager.hiddenSpendingIndexSet().
    func hiddenIndexSet(accountId: UUID) -> Set<Int> {
        loadHiddenIndices(accountId: accountId)
    }

    /// Derives a single receive address on demand (used by the Address Visibility pager for
    /// rows beyond the derived chain). Returns nil on kpub/derivation failure.
    func address(for account: ColdStorageAccount, at index: Int) -> String? {
        guard index >= 0 else { return nil }
        if Self.isQuantumIndex(index) {
            let list = currentQuantumAddresses(of: account)
            let position = index - Self.quantumIndexBase
            return list.indices.contains(position) ? list[position].address : nil
        }
        let network = AppSettings.load().networkType
        return ColdStorageAddressCache.shared.address(kpub: account.kpubString, network: network, index: UInt32(index))
    }

    /// Hide variant with the same live-balance re-check the spending side does
    /// (WalletManager.setSpendingAddressHidden): the cached row balance the UI holds may be
    /// stale, so hiding re-fetches UTXOs for the derived address before committing.
    @discardableResult
    func setAddressHidden(account: ColdStorageAccount, index: Int, hidden: Bool) async -> Bool {
        if hidden {
            guard let address = address(for: account, at: index) else { return false }
            // Fail CLOSED: hiding requires a live zero-balance confirmation. A network error
            // must refuse the hide, not read as an empty balance.
            guard let utxos = try? await NodePoolService.shared.getUtxosByAddresses([address]) else { return false }
            let balance = utxos.reduce(UInt64(0)) { $0 + $1.amount }
            guard balance == 0 else { return false }
        }
        return setAddressHidden(accountId: account.id, index: index, hidden: hidden, balanceSompi: 0)
    }

    // MARK: - Per-address labels

    func setAddressLabel(accountId: UUID, index: Int, label: String?) {
        var labels = loadAddressLabels(accountId: accountId)
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            labels.removeValue(forKey: index)
        } else {
            labels[index] = trimmed
        }
        saveAddressLabels(labels, accountId: accountId)
    }

    private func loadAddressLabels(accountId: UUID) -> [Int: String] {
        guard let data = UserDefaults.standard.data(forKey: addressLabelsKey(for: accountId)),
              let decoded = try? JSONDecoder().decode([Int: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveAddressLabels(_ labels: [Int: String], accountId: UUID) {
        guard let data = try? JSONEncoder().encode(labels) else { return }
        UserDefaults.standard.set(data, forKey: addressLabelsKey(for: accountId))
    }

    private func addressLabelsKey(for accountId: UUID) -> String {
        "kachat_cold_storage_labels_" + accountId.uuidString
    }

    // MARK: - Per-UTXO labels

    /// Keyed by address (the UTXOs tab is per-address, not per-account) + `"txId:index"` outpoint
    /// key, mirroring per-address labels above exactly.
    func setUtxoLabel(address: String, outpointKey: String, label: String?) {
        var labels = loadUtxoLabels(address: address)
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            labels.removeValue(forKey: outpointKey)
        } else {
            labels[outpointKey] = trimmed
        }
        saveUtxoLabels(labels, address: address)
    }

    func loadUtxoLabels(address: String) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: utxoLabelsKey(for: address)),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveUtxoLabels(_ labels: [String: String], address: String) {
        guard let data = try? JSONEncoder().encode(labels) else { return }
        UserDefaults.standard.set(data, forKey: utxoLabelsKey(for: address))
    }

    private func utxoLabelsKey(for address: String) -> String {
        "kachat_cold_storage_utxo_labels_" + address
    }

    // MARK: - Hidden addresses

    /// Refuses to hide the address currently holding a balance (mirrors
    /// WalletManager.setSpendingAddressHidden — hiding is a display preference, never a way
    /// to lose sight of real funds). Unhiding always succeeds.
    @discardableResult
    func setAddressHidden(accountId: UUID, index: Int, hidden: Bool, balanceSompi: UInt64) -> Bool {
        if hidden && balanceSompi > 0 { return false }
        var indices = loadHiddenIndices(accountId: accountId)
        if hidden {
            indices.insert(index)
        } else {
            indices.remove(index)
        }
        saveHiddenIndices(indices, accountId: accountId)
        return true
    }

    private func loadHiddenIndices(accountId: UUID) -> Set<Int> {
        guard let data = UserDefaults.standard.data(forKey: hiddenIndicesKey(for: accountId)),
              let decoded = try? JSONDecoder().decode(Set<Int>.self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveHiddenIndices(_ indices: Set<Int>, accountId: UUID) {
        guard let data = try? JSONEncoder().encode(indices) else { return }
        UserDefaults.standard.set(data, forKey: hiddenIndicesKey(for: accountId))
        hiddenRevision &+= 1
        AddressActivityNotifier.shared.coldStorageAccountsChanged()
    }

    /// The account's balance as last read (every address; a hidden one is always empty), for the
    /// account card to show at once while `getAddressList` reads it live. Nil before any read.
    func lastKnownBalance(of account: ColdStorageAccount) -> UInt64? {
        guard let saved = UserDefaults.standard.data(forKey: addressBalancesKey(for: account.id)),
              let known = try? JSONDecoder().decode([String: UInt64].self, from: saved) else { return nil }
        return known.values.reduce(0, +)
    }

    private func addressBalancesKey(for accountId: UUID) -> String {
        "kachat_cold_storage_balances_" + accountId.uuidString
    }

    private func hiddenIndicesKey(for accountId: UUID) -> String {
        "kachat_cold_storage_hidden_" + accountId.uuidString
    }

    // MARK: - Persistence

    private func loadAccounts() -> [ColdStorageAccount] {
        guard let storageKey else { return [] }
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ColdStorageAccount].self, from: data) {
            return decoded
        }
        // One-time migration: this key predates per-wallet scoping. Claim it for the
        // first wallet that loads after the update, then remove it so no other wallet
        // can also claim it.
        if let legacyData = UserDefaults.standard.data(forKey: legacyStorageKey),
           let legacyDecoded = try? JSONDecoder().decode([ColdStorageAccount].self, from: legacyData) {
            UserDefaults.standard.removeObject(forKey: legacyStorageKey)
            UserDefaults.standard.set(legacyData, forKey: storageKey)
            return legacyDecoded
        }
        return []
    }

    private func saveAccounts() {
        // Receive notifications follow the accounts: a switch, a removal or a grown address list.
        defer { AddressActivityNotifier.shared.coldStorageAccountsChanged() }
        guard let storageKey, let data = try? JSONEncoder().encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Permanently deletes this wallet's cold storage data (accounts list plus each
    /// account's labels/hidden-address state), used when a saved account is removed
    /// from the device entirely.
    func clearAllLocalData() {
        let removed = accounts
        if let storageKey {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        accounts = []
        AddressActivityNotifier.shared.coldStorageAccountsChanged()
        removePerAccountData(of: removed)
    }

    /// `clearAllLocalData` for any wallet, read from its own key: never switched to, so the
    /// one-time migration above can't hand the pre-per-wallet list to an account being removed.
    func removeAllData(forWalletAddress walletAddress: String) {
        guard let normalized = normalizeWalletAddress(walletAddress) else { return }
        let key = walletStorageKey(for: normalized)
        let stored = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([ColdStorageAccount].self, from: $0) } ?? []
        UserDefaults.standard.removeObject(forKey: key)
        if activeWalletAddress == normalized {
            accounts = []
            AddressActivityNotifier.shared.coldStorageAccountsChanged()
        }
        removePerAccountData(of: stored)
    }

    /// What each removed account filed besides the list: its labels, hidden indexes, balances,
    /// and the UTXO labels filed under its addresses. Those go only when no other wallet on
    /// this device still holds the same kpub, since they're filed by address.
    private func removePerAccountData(of removed: [ColdStorageAccount]) {
        guard !removed.isEmpty else { return }
        let defaults = UserDefaults.standard
        for account in removed {
            defaults.removeObject(forKey: addressLabelsKey(for: account.id))
            defaults.removeObject(forKey: hiddenIndicesKey(for: account.id))
            defaults.removeObject(forKey: addressBalancesKey(for: account.id))
        }
        let utxoPrefix = utxoLabelsKey(for: "")
        let stored = defaults.dictionaryRepresentation()
        var labelled = Set(stored.keys.filter { $0.hasPrefix(utxoPrefix) }.map { String($0.dropFirst(utxoPrefix.count)) })
        guard !labelled.isEmpty else { return }
        let keptAccounts = stored.flatMap { key, value -> [ColdStorageAccount] in
            guard key.hasPrefix(storageKeyPrefix), let data = value as? Data,
                  let others = try? JSONDecoder().decode([ColdStorageAccount].self, from: data) else { return [] }
            return others
        }
        let keptKpubs = Set(keptAccounts.map(\.kpubString))
        // A quantum address's coin labels go with the last account watching it.
        let keptQuantum = Set(keptAccounts.flatMap { $0.quantumAddresses.map(\.address) })
        for account in removed {
            for quantum in account.quantumAddresses where !keptQuantum.contains(quantum.address) {
                if labelled.remove(quantum.address) != nil {
                    defaults.removeObject(forKey: utxoLabelsKey(for: quantum.address))
                }
            }
        }
        for account in removed where !keptKpubs.contains(account.kpubString) {
            guard let extendedKey = KaspaExtendedPublicKey(kpubString: account.kpubString) else { continue }
            for network in NetworkType.allCases {
                for index in 0...max(account.maxAddressIndex, 0) {
                    guard !labelled.isEmpty else { return }
                    guard let address = try? extendedKey.receiveAddress(at: UInt32(index), network: network) else { break }
                    if labelled.remove(address) != nil {
                        defaults.removeObject(forKey: utxoLabelsKey(for: address))
                    }
                }
            }
        }
    }
}
