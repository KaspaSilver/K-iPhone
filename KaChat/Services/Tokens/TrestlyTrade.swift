import Foundation

/// One trade on Trestly's pool, as K makes it (kusdt-open SPEC §14-15): Trestly's own pinned code
/// (`KusdtCore.wallet`) checks the pool and quotes (`prepare`), K asks the person
/// (`TrestlyApprovalSheet`), and only on Approve hands that code the address's key to build, sign and
/// send (`execute`). A pool that moved to a worse quote comes back as a requote and is asked again.
///
/// Shared by Trestly's site inside K (`TrestlyProvider`, any of its trades) and K's own Swap screen
/// (`SwapView` with kUSDT picked: a `kusdt_swap`), so both keep the same checks: one answer per
/// address at a time, the key wiped whatever happens, a trade that may have gone out holds its
/// address for 10 minutes, and spent coins are reserved like a send's.
@MainActor
enum TrestlyTrade {
    typealias ProviderError = TrestlyProvider.ProviderError
    typealias Code = TrestlyProvider.Code

    /// What a finished trade answered.
    struct Done {
        let result: [String: Any]
        /// The `prepare` the person approved (the last one, after any requote).
        let prepared: [String: Any]
        let fee: Any?
    }

    /// K's network as Trestly's code names it.
    static var networkName: String {
        AppSettings.load().networkType == .mainnet ? "mainnet" : "testnet-10"
    }

    /// The address's side of a request to Trestly's code (no key: that is added only on Approve).
    static func wallet(for target: TrestlyTarget) throws -> [String: Any] {
        guard let owner = Kusdt.schnorrOwner(of: target.address) else {
            throw ProviderError(code: Code.failed, message: "K can't trade from this kind of address.")
        }
        return [
            "network": networkName,
            "address": target.address,
            "ownerHex": Kusdt.hex(owner),
            "apiUrl": AppSettings.load().trestlyAPIURL,
        ]
    }

    /// Trestly's `prepare` alone: the quote and its checks, nothing signed or sent.
    static func prepare(method: String, params: Any?, target: TrestlyTarget) async throws -> [String: Any] {
        try await walletCall("prepare", ["method": method, "params": params ?? NSNull(), "wallet": try wallet(for: target)])
    }

    /// The whole trade. `ask` shows the approval and answers Approve (true) or Decline; `isClosed`
    /// stops it when the screen that asked has gone away.
    static func run(method: String, params: Any?, target: TrestlyTarget,
                    native: Bool = false,
                    ask: (TrestlyApproval) async -> Bool,
                    isClosed: () -> Bool = { false }) async throws -> Done {
        if let minutes = await heldMinutes(for: target.address) {
            throw ProviderError(code: Code.busy, message: "Your last trade from this address gave no answer and may still go through. Check the address's history. K takes trades from it again once that one shows on the network, or in about \(minutes) min.")
        }
        let paramsJSON: Any = params ?? NSNull()
        var wallet = try wallet(for: target)
        var prepared = try await walletCall("prepare", ["method": method, "params": paramsJSON, "wallet": wallet])
        var seen: [String: Any]? = nil

        while true {
            let approved = await ask(TrestlyApproval(method: method, prepared: prepared, seen: seen, from: target.label, native: native))
            guard approved, !isClosed() else {
                throw ProviderError(code: Code.rejected, message: "You declined in K. Nothing was sent.")
            }

            // the address's coins as they were before the trade: if it gives no answer, these are
            // held, and the hold ends early once one of them is spent (the trade landed)
            let coinsBefore = (try? await NodePoolService.shared.getUtxosByAddresses([target.address]))?.map(\.id) ?? []

            guard var secret = target.spendingIndex.map({ WalletManager.shared.spendingPrivateKey(at: $0) }) ?? WalletManager.shared.getPrivateKey() else {
                throw ProviderError(code: Code.failed, message: "K couldn't unlock this address's key.")
            }
            // The key must be this address's own: a target picked on another account (the
            // account switched while Swap kept it) would pair this account's key with the other
            // account's address (audit 2026-11-24 #5).
            guard let owner = Kusdt.schnorrOwner(of: target.address),
                  let signer = try? KachatNamesService.xonlyKey(privateKey: secret),
                  signer == owner else {
                secret.resetBytes(in: secret.startIndex..<secret.endIndex)
                throw ProviderError(code: Code.failed, message: AppLocalization.string("This address doesn't belong to the account that's open now. Nothing was sent."))
            }
            wallet["secret"] = Kusdt.hex(secret)
            var request: [String: Any] = ["method": method, "params": paramsJSON, "wallet": wallet,
                                          "shownFeerate": prepared["feerate"] ?? NSNull(),
                                          "acceptedFee": prepared["acceptedFee"] ?? NSNull()]
            // the key leaves this function's hands whether execute answers, throws or times out
            // (audit 2026-11-21, #7)
            defer {
                wallet["secret"] = nil
                request["wallet"] = nil
                secret.resetBytes(in: secret.startIndex..<secret.endIndex)
            }
            if method == "kusdt_removeLiquidity" {
                request["quoted"] = ["kasOut": prepared["kasOut"] ?? NSNull(), "tokensOut": prepared["tokensOut"] ?? NSNull()] as [String: Any]
            } else {
                request["quoted"] = prepared["quote"] ?? NSNull()
            }
            let done: [String: Any]
            do {
                done = try await walletCall("execute", request)
            } catch let error as ProviderError where error.maybeSent {
                // it may have gone out: hold this address's coins and its trades (audit 2026-11-21, #1)
                hold(address: target.address, outpoints: coinsBefore)
                if !coinsBefore.isEmpty { ChatService.shared.reserveOutpoints(coinsBefore) }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    await TokenWallet.shared.refresh()
                }
                throw error
            }
            wallet["secret"] = nil

            for step in (done["steps"] as? [String]) ?? [] { AddressActivityNotifier.shared.markOwnTransaction(step) }
            // the coins it spent are held like a send's own (10 minutes), so a send from this
            // address right after can't pick them (audit, 2026-11-20)
            let spent = ((done["inputs"] as? [String]) ?? []).filter { $0.count > 65 && $0.count < 80 }
            if !spent.isEmpty { ChatService.shared.reserveOutpoints(spent) }
            if done["requote"] != nil {
                // The pool moved and pays less than approved: nothing was sent. Trestly's code
                // prepares it again from scratch, so the sheet shows the new quote with its own
                // warnings, fee and minimum check, not the first one's (audit, 2026-11-20).
                if method == "kusdt_removeLiquidity" {
                    seen = ["kasOut": prepared["kasOut"] ?? "0", "tokensOut": prepared["tokensOut"] ?? "0"]
                } else {
                    seen = ["quote": prepared["quote"] ?? "0"]
                }
                prepared = try await walletCall("prepare", ["method": method, "params": paramsJSON, "wallet": wallet])
                continue
            }
            guard let result = done["result"] as? [String: Any] else {
                throw ProviderError(code: Code.failed, message: "Trestly's pool code gave no result.")
            }
            if let txid = result["txid"] as? String {
                AddressActivityNotifier.shared.markOwnTransaction(txid)
                // looked up again until the swap's coins show (`TokenWallet.followTrade`)
                TokenWallet.shared.followTrade(txid: txid, address: target.address)
            } else {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    await TokenWallet.shared.refresh()
                }
            }
            return Done(result: result, prepared: prepared, fee: done["fee"])
        }
    }

    /// A swap that went through: a line in Notifications (the bell) and the kUSDT side in that
    /// address's history. Returns the text ("Swapped 10 KAS for 0.26 kUSDT"), for a banner;
    /// "Swap sent" when it went out and wasn't seen accepted in time (it may still be).
    @discardableResult
    static func recordSwap(_ done: Done, target: TrestlyTarget) -> String? {
        guard let txid = done.result["txid"] as? String,
              let amountIn = TrestlyApproval.number(done.prepared["amountIn"]),
              let amountOut = TrestlyApproval.number(done.result["amountOut"]) else { return nil }
        let bought = done.prepared["side"] as? String == "buy"
        let kas = KaspaUnit.amount(bought ? amountIn : amountOut)
        let kusdt = TokenAmount.amount(bought ? amountOut : amountIn, token: .kusdt)
        let confirmed = done.result["confirmed"] as? Bool != false
        let text = String(format: AppLocalization.string(confirmed ? "Swapped %@ for %@" : "Swap sent: %@ for %@"),
                          bought ? kas : kusdt, bought ? kusdt : kas)
        GlobalNotificationCenter.shared.record(id: "trestly-swap-\(txid)", source: .token,
                                               title: AppLocalization.string(confirmed ? "Swap Complete" : "Swap Sent"),
                                               body: text, timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                                               targetId: WalletToken.kusdt.id)
        TokenWallet.shared.noteSwap(token: .kusdt, spendingIndex: target.spendingIndex, txid: txid,
                                    units: bought ? amountOut : amountIn, sold: !bought,
                                    fee: TrestlyApproval.number(done.fee))
        return text
    }

    /// One call into Trestly's code; its refusal becomes the provider's error (their message, their code).
    static func walletCall(_ function: String, _ request: [String: Any]) async throws -> [String: Any] {
        let answer: [String: Any]
        do {
            answer = try await KusdtCore.shared.wallet(function, request: request)
        } catch KusdtCore.CoreError.maybeSent(let why) {
            throw ProviderError(code: Code.failed, message: maybeSentMessage(why), maybeSent: true)
        } catch {
            throw ProviderError(code: Code.failed, message: error.localizedDescription)
        }
        if let message = answer["error"] as? String {
            let code = (answer["code"] as? NSNumber)?.intValue ?? Code.failed
            if answer["maybeSent"] as? Bool == true {
                throw ProviderError(code: code, message: maybeSentMessage(message), maybeSent: true)
            }
            throw ProviderError(code: code, message: message)
        }
        return answer
    }

    private static func maybeSentMessage(_ why: String) -> String {
        why + " " + AppLocalization.string("The trade may have gone through.") + " "
            + AppLocalization.string("Check the address's history before trying again.")
    }

    // MARK: Trades that may have gone out

    /// A trade whose `execute` gave no answer may still land (audit 2026-11-21, #1): its address
    /// takes no new trade until one of the coins it held before is spent (the trade shows on the
    /// network) or `holdSeconds` pass. Kept on the phone, so a relaunch doesn't drop it.
    private struct MaybeSentHold: Codable {
        let until: Date
        let outpoints: [String]
    }

    private static let holdsKey = "kachat_trestly_maybe_sent_holds"
    private static let holdSeconds: TimeInterval = 600

    private static var holds: [String: MaybeSentHold] {
        get {
            guard let data = UserDefaults.standard.data(forKey: holdsKey),
                  let decoded = try? JSONDecoder().decode([String: MaybeSentHold].self, from: data) else { return [:] }
            return decoded
        }
        set {
            let now = Date()
            let live = newValue.filter { $0.value.until > now }
            if live.isEmpty {
                UserDefaults.standard.removeObject(forKey: holdsKey)
            } else if let data = try? JSONEncoder().encode(live) {
                UserDefaults.standard.set(data, forKey: holdsKey)
            }
        }
    }

    private static func hold(address: String, outpoints: [String]) {
        var all = holds
        all[address] = MaybeSentHold(until: Date().addingTimeInterval(holdSeconds), outpoints: outpoints)
        holds = all
    }

    /// Minutes left on this address's hold, or nil when it may trade: no hold, the hold ran out,
    /// or a coin it had before is gone from the node (the earlier trade landed).
    static func heldMinutes(for address: String) async -> Int? {
        guard let held = holds[address] else { return nil }
        let left = held.until.timeIntervalSinceNow
        guard left > 0 else {
            var all = holds
            all[address] = nil
            holds = all
            return nil
        }
        if !held.outpoints.isEmpty,
           let now = try? await NodePoolService.shared.getUtxosByAddresses([address]) {
            let present = Set(now.map(\.id))
            if held.outpoints.contains(where: { !present.contains($0) }) {
                var all = holds
                all[address] = nil
                holds = all
                return nil
            }
        }
        return max(1, Int((left / 60).rounded(.up)))
    }
}
