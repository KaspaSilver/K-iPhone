import Foundation

// KNS left K on 2026-11-23 (.kachat only), but a KNS commit whose reveal failed before then still
// holds the user's coins at a script address that only the saved redeem script can spend. This is
// the part of the old KNSService that finishes those reveals, which returns the coins to the
// address that funded them (audit 2026-11-24 #4). It starts nothing new and runs only for accounts
// that still have a saved record (`kachat_spending_kns_reveals_<account>`); once every record is
// settled it does nothing. Remove it a few releases after no record is left in the field.

/// A KNS reveal saved before its commit was submitted (the only copy of the redeem script).
struct PendingKNSReveal: Codable {
    var commitTxId: String
    let ownerAddress: String
    /// The spending address whose key signs; nil = the chatting key.
    let spendingIndex: Int?
    let changeAddress: String
    /// The fresh slot `changeAddress` is, when it is one: listed again before a resume.
    let changeIndex: Int?
    let revealTargetAddress: String
    let revealPriorityFeeSompi: UInt64
    let redeemScript: Data
    let commitAddress: String
    let commitScriptPubKey: Data
    let commitAmountSompi: UInt64
    let revealAmountSompi: UInt64
    let commitOutputIndex: UInt32
    let createdAt: Date
    /// The commit's coin has been seen unspent at least once. Once seen, its disappearing means
    /// it was spent (the reveal, normally), and only then is this record safe to drop: it holds
    /// the only copy of the redeem script that unlocks the commit.
    var commitSeen: Bool? = nil
    /// Resumes that looked and found no commit coin, while it had never been seen.
    var emptyChecks: Int? = nil
    /// A domain transfer's details, for its chat notice; nil for a profile update.
    let domain: String?
    let assetId: String?
    let recipientAddress: String?

    var context: KasiaTransactionBuilder.KNSCommitContext {
        KasiaTransactionBuilder.KNSCommitContext(
            redeemScript: redeemScript,
            commitAddress: commitAddress,
            commitScriptPubKey: commitScriptPubKey,
            commitAmountSompi: commitAmountSompi,
            revealAmountSompi: revealAmountSompi,
            commitOutputIndex: commitOutputIndex
        )
    }
}


@MainActor
enum KNSRevealRecovery {
    /// A commit that was never seen is dropped only after this long and `missingCommitChecks`
    /// empty looks: the record is the only copy of its redeem script, so a slow commit or a node
    /// that missed it must not lose it. A commit seen once and then gone was spent: dropped then.
    private static let missingCommitLifetime: TimeInterval = 30 * 24 * 60 * 60
    private static let missingCommitChecks = 2
    private static let revealAttempts = 5

    /// Accounts already looked at this run, so returning to the app doesn't ask again.
    private static var checkedAccounts: Set<String> = []

    /// `kachat_spending_`, so removing the account removes it too (`removeSpendingData`).
    private static func defaultsKey(_ account: String) -> String {
        "kachat_spending_kns_reveals_\(account)"
    }

    private static func load(account: String) -> [PendingKNSReveal] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(account)),
              let decoded = try? JSONDecoder().decode([PendingKNSReveal].self, from: data) else { return [] }
        return decoded
    }

    private static func store(_ reveals: [PendingKNSReveal], account: String) {
        if reveals.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey(account))
        } else if let data = try? JSONEncoder().encode(reveals) {
            UserDefaults.standard.set(data, forKey: defaultsKey(account))
        }
    }

    /// Rewrites a stored record in place (a resume's bookkeeping), without marking it as this run's.
    private static func update(_ reveal: PendingKNSReveal, account: String) {
        store(load(account: account).map { $0.commitTxId == reveal.commitTxId ? reveal : $0 }, account: account)
    }

    private static func clear(commitTxId: String, account: String) {
        store(load(account: account).filter { $0.commitTxId != commitTxId }, account: account)
    }

    private static func submitRetrying(_ revealTx: KaspaRpcTransaction) async throws -> String {
        var lastError: Error = KasiaError.networkError("KNS reveal was not submitted")
        for attempt in 0..<revealAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(attempt * 2, 8)) * 1_000_000_000)
            }
            do {
                return try await submitAllowingOrphan(revealTx)
            } catch let unknown as SendOutcomeUnknownError {
                throw unknown
            } catch {
                if let acceptedTxId = ChatService.shared.acceptedTransactionId(from: error) { return acceptedTxId }
                AppLog.log("[KNS_REVEAL] attempt %d failed: %@", attempt + 1, error.localizedDescription)
                lastError = error
            }
        }
        throw lastError
    }

    private static func submitAllowingOrphan(_ revealTx: KaspaRpcTransaction) async throws -> String {
        do {
            return try await NodePoolService.shared.submitTransaction(revealTx, allowOrphan: false).txId
        } catch {
            guard error.localizedDescription.lowercased().contains("orphan") else { throw error }
            AppLog.log("[KNS_REVEAL] retry allowOrphan=true reason=%@", error.localizedDescription)
            return try await NodePoolService.shared.submitTransaction(revealTx, allowOrphan: true).txId
        }
    }

    /// Finishes this account's reveals left by an earlier run. Called when the app comes up and
    /// when an account is loaded; once per account while it all goes through, again on the next
    /// return to the app when something could not be settled.
    static func resumeIfNeeded() async {
        let wallets = WalletManager.shared
        guard let account = wallets.currentWallet?.publicAddress,
              checkedAccounts.insert(account).inserted else { return }
        let waiting = load(account: account)
        guard !waiting.isEmpty else { return }
        var unsettled = false
        defer { if unsettled { checkedAccounts.remove(account) } }
        do {
            try await ChatService.shared.connectRpcIfNeeded()
        } catch {
            unsettled = true
            return
        }
        for reveal in waiting {
            guard wallets.currentWallet?.publicAddress == account else {
                unsettled = true
                return
            }
            if await !resume(reveal, account: account) { unsettled = true }
        }
    }

    /// True when this reveal needs no further look: finished, or dropped as gone.
    private static func resume(_ reveal: PendingKNSReveal, account: String) async -> Bool {
        let wallets = WalletManager.shared
        let label = String(reveal.commitTxId.prefix(12))
        let ownerKey: Data?
        if let index = reveal.spendingIndex {
            ownerKey = wallets.spendingPrivateKey(at: index)
        } else {
            ownerKey = wallets.getPrivateKey()
        }
        guard let ownerKey else { return false }
        do {
            let utxos = try await NodePoolService.shared.getUtxosByAddresses([reveal.commitAddress])
            guard utxos.contains(where: {
                $0.outpoint.transactionId == reveal.commitTxId && $0.outpoint.index == reveal.commitOutputIndex
            }) else {
                var counted = reveal
                counted.emptyChecks = (reveal.emptyChecks ?? 0) + 1
                if reveal.commitSeen == true {
                    // Seen unspent before, gone now: spent, the reveal went through. The record
                    // is the only copy of the redeem script, so one lagging node's empty answer
                    // isn't enough: it takes two in a row.
                    guard (counted.emptyChecks ?? 0) >= 2 else {
                        update(counted, account: account)
                        return false
                    }
                    AppLog.log("[KNS_REVEAL] commit %@ was spent: nothing to finish", label)
                    clear(commitTxId: reveal.commitTxId, account: account)
                    return true
                }
                guard Date().timeIntervalSince(reveal.createdAt) > missingCommitLifetime,
                      (counted.emptyChecks ?? 0) >= missingCommitChecks else {
                    update(counted, account: account)
                    return false
                }
                AppLog.log("[KNS_REVEAL] commit %@ never appeared: dropped", label)
                clear(commitTxId: reveal.commitTxId, account: account)
                return true
            }
            if reveal.commitSeen != true || (reveal.emptyChecks ?? 0) > 0 {
                // seen unspent: any earlier empty answers were a lagging node
                var seen = reveal
                seen.commitSeen = true
                seen.emptyChecks = 0
                update(seen, account: account)
            }
            // the reveal's change lands here, so it has to be on the list first
            if let changeIndex = reveal.changeIndex {
                await wallets.revealSpendingAddress(at: changeIndex, owner: account)
            }
            let revealTx = try KasiaTransactionBuilder.buildKNSAddProfileRevealTx(
                ownerAddress: reveal.ownerAddress,
                ownerPrivateKey: ownerKey,
                changeAddress: reveal.changeAddress,
                commitTxId: reveal.commitTxId,
                commitContext: reveal.context,
                revealTargetAddress: reveal.revealTargetAddress,
                revealPriorityFeeSompi: reveal.revealPriorityFeeSompi
            )
            let revealTxId = try await submitRetrying(revealTx)
            AppLog.log("[KNS_REVEAL] finished commit %@ with reveal %@", label, String(revealTxId.prefix(12)))
            clear(commitTxId: reveal.commitTxId, account: account)
            ChatService.shared.registerSuppressedPaymentTxIds([reveal.commitTxId, revealTxId], reason: "kns-reveal-resumed")
            return true
        } catch {
            AppLog.log("[KNS_REVEAL] could not finish commit %@: %@", label, error.localizedDescription)
            return false
        }
    }
}
