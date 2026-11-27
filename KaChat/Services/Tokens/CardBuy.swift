import Foundation
import UIKit
import WebKit

// MARK: - The Ethereum wallet Trestly's buy page sees

/// Buy Kaspa with Debit Card (owner, 2026-11-26): the Ethereum wallet Trestly's buy page
/// (`trestly.io/buy`) connects to inside K, announced the standard way (EIP-6963) as "K".
///
/// The page sells USDC by card through Stripe into the buyer's own Ethereum address, and has that
/// address sign one EIP-2612 permit first, so Trestly's bridge can deposit it to Kaspa as kUSDT
/// (no ETH needed: Trestly's gas wallet sends the bridge transaction). K is that wallet:
/// `EthereumAccount`'s address, never shown as a wallet of its own.
///
/// - Injected at document start, main frame only, on the Trestly site set in Settings (the same
///   checks as `TrestlyProvider`, which the page gets beside it for the Kaspa side).
/// - Answers `eth_requestAccounts` / `eth_accounts` (the address: opening Buy Kaspa in K was the
///   approval), `eth_chainId` / `net_version` (Ethereum mainnet), `wallet_switchEthereumChain`
///   (to mainnet only) and `eth_signTypedData_v4` for **one thing only**: a USDC permit on Ethereum
///   mainnet from this address (`PermitRequest.parse` checks every field), shown in
///   `CardBuySignSheet` and signed only on Approve. Everything else is 4200: K sends no Ethereum
///   transaction and signs no other message.
/// - Tells `CardBuyTracker` the order's session as the page saves it, so K can follow the order
///   after the page closes.
@MainActor
final class CardBuyEthereumProvider: NSObject, ObservableObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "kachatEthereum"

    enum Code {
        static let rejected = 4001
        static let unauthorized = 4100
        static let unsupported = 4200
        static let unknownChain = 4902
        static let busy = -32002
        static let invalid = -32602
        static let failed = -32603
    }

    struct ProviderError: Error {
        let code: Int
        let message: String
    }

    /// The permit waiting for Approve or Decline, shown as `CardBuySignSheet`.
    @Published var pending: PermitRequest?

    /// Where the kUSDT lands (the address picked in Buy Kaspa).
    let target: TrestlyTarget
    let allowedOrigin: (host: String, port: Int)
    /// This account's Ethereum address, worked out when Buy Kaspa opened.
    let address: String
    private var closed = false
    private var declinedAt: Date?
    private var running = 0
    private let uuid = UUID().uuidString.lowercased()

    init(target: TrestlyTarget, siteURL: URL, address: String) {
        self.target = target
        self.allowedOrigin = (siteURL.host?.lowercased() ?? "", siteURL.port ?? 443)
        self.address = address
    }

    func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
    }

    /// The page closed: a sheet still up is declined, and nothing more is signed for it.
    func close() {
        closed = true
        let request = pending
        pending = nil
        request?.respond(false)
    }

    private var script: String {
        let info = Self.json([
            "uuid": uuid,
            "name": "K",
            "icon": TrestlyProvider.iconDataURL ?? "",
            "rdns": "com.kachat.wallet",
        ]) ?? "{}"
        let host = Self.json(allowedOrigin.host) ?? "\"\""
        let port = allowedOrigin.port
        return """
        (() => {
          'use strict';
          try {
            const port = location.port === '' ? 443 : Number(location.port);
            if (location.protocol !== 'https:' || location.hostname.toLowerCase() !== \(host) || port !== \(port)) return;
            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Self.handlerName);
            if (!bridge) return;
            const listeners = Object.create(null);
            const fail = (code, message) => Object.assign(new Error(message), { code });
            const send = (method, params) => bridge.postMessage({ method, params }).then((answer) => {
              if (answer && answer.error) throw fail(answer.error.code, answer.error.message);
              return answer ? answer.result : null;
            }, (e) => { throw fail(\(Code.failed), String((e && e.message) || e)); });
            const provider = {
              isKaChat: true,
              request(args) {
                if (!args || typeof args !== 'object' || typeof args.method !== 'string' || args.method.length > 64) {
                  return Promise.reject(fail(\(Code.invalid), 'Expected { method, params }.'));
                }
                let text;
                try { text = JSON.stringify(args.params === undefined ? null : args.params); } catch (e) { return Promise.reject(fail(\(Code.invalid), 'Params must be JSON.')); }
                if (text !== undefined && text.length > 16384) return Promise.reject(fail(\(Code.invalid), 'Params are too long.'));
                return send(args.method, text === undefined ? null : JSON.parse(text));
              },
              on(event, listener) {
                if (typeof listener === 'function') (listeners[event] = listeners[event] || []).push(listener);
                return provider;
              },
              removeListener(event, listener) {
                const list = listeners[event];
                if (list) listeners[event] = list.filter((l) => l !== listener);
                return provider;
              },
            };
            provider.off = provider.removeListener;
            Object.freeze(provider);
            const detail = Object.freeze({ info: Object.freeze(\(info)), provider });
            const announce = () => {
              try { window.dispatchEvent(new CustomEvent('eip6963:announceProvider', { detail })); } catch (e) {}
            };
            window.addEventListener('eip6963:requestProvider', announce);
            announce();

            // The order K follows after the page closes: the session the page saves when the order
            // is made (not paid yet), and the one it marks paid (`buy.paid:<session>`) and puts in
            // its address once Stripe says the payment went through.
            const report = (session, paid) => {
              if (typeof session === 'string' && /^[A-Za-z0-9_-]{6,200}$/.test(session)) {
                bridge.postMessage({ method: 'k_session', params: { session, paid: !!paid } }).catch(() => {});
              }
            };
            const fromURL = (url) => {
              try { report(new URL(url, location.href).searchParams.get('session'), true); } catch (e) {}
            };
            fromURL(location.href);
            for (const name of ['pushState', 'replaceState']) {
              const original = history[name];
              history[name] = function (state, title, url) {
                const result = original.apply(this, arguments);
                if (url != null) fromURL(String(url));
                return result;
              };
            }
            const setItem = Storage.prototype.setItem;
            Storage.prototype.setItem = function (key, value) {
              const result = setItem.apply(this, arguments);
              if (key === 'kusdt.web.buy.last') {
                try { report(JSON.parse(value).session, false); } catch (e) {}
              } else if (typeof key === 'string' && key.startsWith('kusdt.web.buy.paid:')) {
                report(key.slice('kusdt.web.buy.paid:'.length), true);
              }
              return result;
            };
          } catch (e) {}
        })();
        """
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        let port = origin.port == 0 ? 443 : origin.port
        guard frame.isMainFrame, origin.protocol == "https", origin.host.lowercased() == allowedOrigin.host, port == allowedOrigin.port else {
            return (Self.errorAnswer(ProviderError(code: Code.unauthorized, message: "This page can't use K.")), nil)
        }
        guard let body = message.body as? [String: Any], let method = body["method"] as? String, method.count <= 64 else {
            return (Self.errorAnswer(ProviderError(code: Code.invalid, message: "Expected { method, params }.")), nil)
        }
        let rawParams = body["params"]
        if let rawParams, !(rawParams is NSNull) {
            guard JSONSerialization.isValidJSONObject([rawParams]),
                  let data = try? JSONSerialization.data(withJSONObject: [rawParams]), data.count <= 16384 + 2 else {
                return (Self.errorAnswer(ProviderError(code: Code.invalid, message: "Params must be JSON of at most 16384 characters.")), nil)
            }
        }
        guard running < 8 else {
            return (Self.errorAnswer(ProviderError(code: Code.busy, message: "K is still answering this page's earlier requests.")), nil)
        }
        running += 1
        defer { running -= 1 }
        do {
            let result = try await answer(method, params: rawParams is NSNull ? nil : rawParams)
            return (["result": result ?? NSNull()], nil)
        } catch let error as ProviderError {
            return (Self.errorAnswer(error), nil)
        } catch {
            return (Self.errorAnswer(ProviderError(code: Code.failed, message: error.localizedDescription)), nil)
        }
    }

    private func answer(_ method: String, params: Any?) async throws -> Any? {
        switch method {
        case "eth_requestAccounts", "eth_accounts":
            return [address]
        case "eth_chainId":
            return "0x" + String(EthereumAccount.chainId, radix: 16)
        case "net_version":
            return String(EthereumAccount.chainId)
        case "wallet_switchEthereumChain":
            let asked = ((params as? [Any])?.first as? [String: Any])?["chainId"]
            guard let chain = EIP712.smallUInt(asked), chain == UInt64(EthereumAccount.chainId) else {
                throw ProviderError(code: Code.unknownChain, message: "K's Ethereum address is on Ethereum only.")
            }
            return nil
        case "eth_signTypedData_v4":
            return try await signPermit(params)
        case "k_session":
            if let report = params as? [String: Any], let session = report["session"] as? String {
                CardBuyTracker.shared.follow(session: session, target: target, paid: report["paid"] as? Bool == true)
            }
            return nil
        default:
            throw ProviderError(code: Code.unsupported, message: "K signs only the bridge's USDC permit here.")
        }
    }

    private func signPermit(_ params: Any?) async throws -> String {
        guard !closed else { throw ProviderError(code: Code.unauthorized, message: "K closed this page.") }
        guard pending == nil else { throw ProviderError(code: Code.busy, message: "A request from this page is already waiting in K.") }
        if let declinedAt, Date().timeIntervalSince(declinedAt) < 3 {
            throw ProviderError(code: Code.rejected, message: "You declined in K a moment ago.")
        }
        let request: PermitRequest
        do {
            request = try PermitRequest.parse(params, owner: address, target: target)
        } catch let failure as EIP712.Failure {
            throw ProviderError(code: Code.invalid, message: failure.message)
        }
        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            request.answer = { continuation.resume(returning: $0) }
            pending = request
        }
        guard approved, !closed else {
            declinedAt = Date()
            throw ProviderError(code: Code.rejected, message: "Declined in K.")
        }
        guard var key = EthereumAccount.privateKey() else {
            throw ProviderError(code: Code.failed, message: "K couldn't read this account's words.")
        }
        defer { key.zeroOut() }
        do {
            // the key must still make the address the page was given
            guard try EthereumAccount.address(privateKey: key).lowercased() == address.lowercased() else {
                throw ProviderError(code: Code.failed, message: "K's Ethereum address changed. Open Buy Kaspa again.")
            }
            let signature = try EthereumAccount.sign(digest: request.digest, privateKey: key)
            return "0x" + EthereumHex.string(signature)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError(code: Code.failed, message: "K couldn't sign: \(error.localizedDescription)")
        }
    }

    private static func errorAnswer(_ error: ProviderError) -> [String: Any] {
        ["error": ["code": error.code, "message": error.message]]
    }

    private static func json(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The one thing K signs on Ethereum: a USDC permit (EIP-2612) on mainnet from K's own address,
/// as Trestly's buy page asks for it. Anything else is refused before a sheet shows.
@MainActor
final class PermitRequest: Identifiable {
    let id = UUID()
    /// What the permit lets the bridge take, in USDC's 6-decimal units.
    let valueUnits: UInt64
    let spender: String
    let deadline: Date
    let target: TrestlyTarget
    let digest: Data
    var answer: ((Bool) -> Void)?

    private init(valueUnits: UInt64, spender: String, deadline: Date, target: TrestlyTarget, digest: Data) {
        self.valueUnits = valueUnits
        self.spender = spender
        self.deadline = deadline
        self.target = target
        self.digest = digest
    }

    /// Answers once; later calls do nothing.
    func respond(_ approved: Bool) {
        let answer = self.answer
        self.answer = nil
        answer?(approved)
    }

    /// "52.00 USDC".
    var amountText: String {
        String(format: "%.2f USDC", Double(valueUnits) / 1_000_000)
    }

    /// `[address, typedData]`, the typed data as JSON text (or an object), checked field by field.
    static func parse(_ params: Any?, owner: String, target: TrestlyTarget) throws -> PermitRequest {
        typealias Failure = EIP712.Failure
        guard let list = params as? [Any], list.count == 2, let signer = list[0] as? String else {
            throw Failure(message: "Expected [address, typedData].")
        }
        guard signer.lowercased() == owner.lowercased() else {
            throw Failure(message: "K signs only for its own address.")
        }
        let typed: [String: Any]
        if let text = list[1] as? String {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure(message: "The typed data isn't JSON.")
            }
            typed = object
        } else if let object = list[1] as? [String: Any] {
            typed = object
        } else {
            throw Failure(message: "The typed data is missing.")
        }

        // exactly an EIP-2612 permit: these types, nothing more
        guard typed["primaryType"] as? String == "Permit" else { throw Failure(message: "K signs only a USDC permit here.") }
        let types = try EIP712.parseTypes(typed["types"])
        guard Set(types.keys) == ["EIP712Domain", "Permit"] else { throw Failure(message: "K signs only a USDC permit here.") }
        let permitFields = types["Permit"]?.map { "\($0.type) \($0.name)" }
        guard permitFields == ["address owner", "address spender", "uint256 value", "uint256 nonce", "uint256 deadline"] else {
            throw Failure(message: "This isn't a standard permit.")
        }
        let allowedDomain: Set<String> = ["string name", "string version", "uint256 chainId", "address verifyingContract"]
        guard let domainFields = types["EIP712Domain"]?.map({ "\($0.type) \($0.name)" }),
              Set(domainFields).isSubset(of: allowedDomain), domainFields.contains("uint256 chainId"),
              domainFields.contains("address verifyingContract") else {
            throw Failure(message: "This permit's domain isn't USDC's.")
        }

        // USDC on Ethereum mainnet, from K's own address
        guard let domain = typed["domain"] as? [String: Any],
              EIP712.smallUInt(domain["chainId"]) == UInt64(EthereumAccount.chainId),
              (domain["verifyingContract"] as? String)?.lowercased() == EthereumAccount.usdcContract else {
            throw Failure(message: "K signs a permit only for USDC on Ethereum.")
        }
        guard let message = typed["message"] as? [String: Any],
              (message["owner"] as? String)?.lowercased() == owner.lowercased(),
              let spender = message["spender"] as? String, EthereumHex.isAddress(spender),
              let value = EIP712.smallUInt(message["value"]), value > 0, value <= 1_000_000_000_000,
              let deadline = EIP712.smallUInt(message["deadline"]), EIP712.smallUInt(message["nonce"]) != nil else {
            throw Failure(message: "This permit is malformed.")
        }
        let now = Date().timeIntervalSince1970
        guard Double(deadline) > now, Double(deadline) <= now + 86_400 else {
            throw Failure(message: "K signs only a permit that ends within a day.")
        }
        return PermitRequest(valueUnits: value, spender: spender, deadline: Date(timeIntervalSince1970: Double(deadline)),
                             target: target, digest: try EIP712.digest(typedData: typed))
    }
}

// MARK: - Following the order

/// One card purchase, from the page's order to the kUSDT on the picked address.
struct CardBuy: Codable, Equatable, Identifiable {
    enum Stage: String, Codable {
        /// Created on Trestly; Stripe hasn't been paid.
        case waitingPayment
        /// Paid; Stripe is delivering the USDC.
        case paid
        /// The bridge transaction is out; kUSDT is being minted on Kaspa.
        case bridging
        /// The kUSDT is on the address.
        case arrived
        /// The permit ran out before the bridge used it: the page asks for a new one.
        case signAgain
        /// Stripe refused the purchase.
        case rejected
        /// The bridge couldn't run, and the USDC went back to K's Ethereum address.
        case refunded
        /// Never paid, and the order is over.
        case expired
    }

    let session: String
    let address: String
    let label: String
    let spendingIndex: Int?
    let startedAt: Date
    var stage: Stage = .waitingPayment
    /// What was paid for, "50.00" (Stripe's amount).
    var dollars: String?
    /// kUSDT minted to the address, in units.
    var mintedUnits: UInt64?
    /// USDC sent back, in units.
    var refundUnits: UInt64?
    /// The page said Stripe took the payment. Until then (or Trestly says so) the order is dropped
    /// once Buy Kaspa closes: an order never paid isn't followed.
    var paidSeen: Bool?

    var id: String { session }

    var isFinished: Bool { [.arrived, .rejected, .refunded, .expired].contains(stage) }

    var target: TrestlyTarget {
        TrestlyTarget(label: label, address: address, spendingIndex: spendingIndex)
    }
}

/// Follows the account's card purchase (one at a time) after Trestly's page closes, so the Wallet
/// tab's Buy Kaspa card shows where it is and offers Swap to Kaspa once the kUSDT lands.
///
/// Reads Trestly's own endpoints, as the buy page does: `/buy-api/order?session=` on the Trestly
/// site (Stripe's payment, the bridge transaction, a refund) and the Trestly API's
/// `/deposits/1/<nonce>` (chain 1 is Ethereum) for the minted kUSDT. Polls every 8 s while Buy
/// Kaspa is open, else on the foreground beat (started by the Wallet tab's card or Buy Kaspa),
/// and stops once the purchase is over. Kept per account (`kachat_card_buy_v1_<account>`), removed with it.
@MainActor
final class CardBuyTracker: ObservableObject {
    static let shared = CardBuyTracker()

    @Published private(set) var buy: CardBuy?
    /// Buy Kaspa is on screen: poll faster. When it closes, an order that wasn't paid is dropped
    /// (one last look first, in case the payment went through as it closed).
    var screenOpen = false {
        didSet {
            if screenOpen { pollSoon() } else if oldValue { ensurePolling() }
        }
    }

    private var account: String?
    private var loop: Task<Void, Never>?
    private var pollNow: CheckedContinuation<Void, Never>?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static let storagePrefix = "kachat_card_buy_v1_"

    private init() {
        account = Self.currentAccount
        buy = Self.load(account: account)
    }

    private static var currentAccount: String? {
        WalletManager.shared.currentWallet?.publicAddress.lowercased()
    }

    /// The page saved an order (or marked it paid): follow it.
    func follow(session: String, target: TrestlyTarget, paid: Bool) {
        syncAccount()
        if var current = buy, current.session == session {
            if paid, current.paidSeen != true {
                current.paidSeen = true
                buy = current
                save()
                revealAddress(of: current)
            }
            return
        }
        buy = CardBuy(session: session, address: target.address, label: target.label,
                      spendingIndex: target.spendingIndex, startedAt: Date(), paidSeen: paid ? true : nil)
        save()
        if paid, let buy { revealAddress(of: buy) }
        // the regular kUSDT look covers this address from now on
        TokenWallet.shared.noteReceiveAddressShown(target.address)
        ensurePolling()
    }

    /// A paid order's fresh address goes on Manage Addresses' list (Buy Kaspa only derives it, so
    /// leaving without paying uses nothing up). Nothing for the Chatting Address or one already listed.
    private func revealAddress(of buy: CardBuy) {
        guard let index = buy.spendingIndex else { return }
        Task { await TokenWallet.shared.revealFreshReceiveAddress(index) }
    }

    /// The card's X, or Swap to Kaspa: the purchase is no longer shown.
    func clear() {
        syncAccount()
        buy = nil
        save()
        loop?.cancel()
        loop = nil
    }

    /// Starts following again (the Wallet tab shows, Buy Kaspa opened), if there's anything to follow.
    func ensurePolling() {
        syncAccount()
        guard let buy, !buy.isFinished else { return }
        if loop == nil {
            loop = Task { @MainActor [weak self] in
                await self?.run()
            }
        } else {
            pollSoon()
        }
    }

    private func pollSoon() {
        let waiting = pollNow
        pollNow = nil
        waiting?.resume()
    }

    private func run() async {
        defer { loop = nil }
        while !Task.isCancelled {
            guard let current = buy, !current.isFinished else { return }
            await poll(current)
            guard let after = buy, !after.isFinished else { return }
            await wait()
        }
    }

    /// 8 s while Buy Kaspa is open, else to the next foreground beat; `pollSoon` cuts it short.
    private func wait() async {
        let open = screenOpen
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // an earlier loop's waiter (cleared, then started again) is let go, never dropped
            pollSoon()
            pollNow = continuation
            Task { @MainActor [weak self] in
                if open {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                } else {
                    await ForegroundBeat.sleepUntilNextBeat(offset: 1.5)
                }
                self?.pollSoon()
            }
        }
    }

    private func poll(_ current: CardBuy) async {
        guard let order = await fetchOrder(current.session) else { return }
        // a switch of account while the request ran: not this account's purchase any more
        guard buy?.session == current.session else { return }
        var next = current
        let orderObject = order["order"] as? [String: Any]
        let purchase = order["purchase"] as? [String: Any]

        if orderObject == nil, purchase == nil {
            // Trestly doesn't know it (yet): nothing was paid, so with Buy Kaspa closed it's dropped
            if !screenOpen, current.paidSeen != true { clear(); return }
            if Date().timeIntervalSince(current.startedAt) > 86_400 { next.stage = .expired }
            update(next)
            return
        }
        // the kUSDT goes where the order says; if that isn't the address picked here, K has
        // nothing to swap, and stops following it (the page shows its own progress)
        if let kaspa = orderObject?["kaspaAddress"] as? String, kaspa.lowercased() != current.address.lowercased() {
            clear()
            return
        }
        if let amount = purchase?["amount"] { next.dollars = Self.dollarsText(amount) }

        let state = orderObject?["state"] as? String
        let stripe = purchase?["stripe"] as? String
        let refund = orderObject?["refund"] as? [String: Any]

        if stripe == "rejected" {
            next.stage = .rejected
        } else if let refund, refund["state"] as? String == "returned" {
            next.stage = .refunded
            next.refundUnits = EIP712.smallUInt(refund["amount"])
        } else if let state, ["needs-sign", "expired", "replaced"].contains(state) {
            next.stage = .signAgain
        } else if state == "unpaid", let deadline = EIP712.smallUInt(orderObject?["deadline"]),
                  Double(deadline) < Date().timeIntervalSince1970 {
            next.stage = .expired
        } else if state == "bridged", let nonce = EIP712.smallUInt(orderObject?["nonce"]) {
            next.stage = .bridging
            if let minted = await fetchMinted(nonce: nonce) {
                next.stage = .arrived
                next.mintedUnits = minted
            }
        } else if orderObject?["tx"] as? String != nil {
            next.stage = .bridging
        } else if stripe == "fulfillment_complete" || stripe == "fulfillment_processing" || Self.hasValue(purchase?["delivered"]) {
            next.stage = .paid
        } else {
            next.stage = .waitingPayment
        }
        guard buy?.session == current.session else { return }
        // only a real payment counts: Stripe's status, the USDC delivered, the bridge, a refund
        if [.paid, .bridging, .arrived, .refunded].contains(next.stage), next.paidSeen != true {
            next.paidSeen = true
            revealAddress(of: next)
        }
        // never paid and Buy Kaspa closed: not followed any more, and nothing shows on the card
        if next.paidSeen != true, !screenOpen, [.waitingPayment, .signAgain, .expired].contains(next.stage) {
            clear()
            return
        }
        let arrivedNow = next.stage == .arrived && current.stage != .arrived
        update(next)
        if arrivedNow {
            Haptics.success()
            Task { await TokenWallet.shared.refresh() }
        }
    }

    private func update(_ next: CardBuy) {
        guard next != buy else { return }
        buy = next
        save()
    }

    /// A field that's really there: JSON's null comes back as NSNull, which isn't nil (an order
    /// nobody paid has `"delivered": null`, which read as delivered and showed "Paid").
    private static func hasValue(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let text = value as? String { return !text.isEmpty }
        return true
    }

    /// "50.00" from Stripe's amount (a string or a number).
    private static func dollarsText(_ value: Any) -> String? {
        let number: Double?
        if let text = value as? String { number = Double(text) } else { number = (value as? NSNumber)?.doubleValue }
        return number.map { String(format: "%.2f", $0) }
    }

    private func fetchOrder(_ id: String) async -> [String: Any]? {
        var components = URLComponents(url: TrestlyBrowserView.siteURL.appendingPathComponent("buy-api/order"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "session", value: id)]
        guard let url = components?.url, url.scheme == "https" else { return nil }
        return await fetchJSON(url)
    }

    /// The kUSDT the bridge minted for deposit `nonce`, once Trestly says it's minted.
    private func fetchMinted(nonce: UInt64) async -> UInt64? {
        var base = AppSettings.load().trestlyAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/deposits/1/\(nonce)"), url.scheme == "https",
              let deposit = await fetchJSON(url), deposit["status"] as? String == "minted" else { return nil }
        return EIP712.smallUInt(deposit["minted"])
    }

    private func fetchJSON(_ url: URL) async -> [String: Any]? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 256_000 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Storage, per account

    private func syncAccount() {
        let now = Self.currentAccount
        guard now != account else { return }
        account = now
        loop?.cancel()
        loop = nil
        buy = Self.load(account: now)
    }

    private static func key(_ account: String) -> String { storagePrefix + account }

    private static func load(account: String?) -> CardBuy? {
        guard let account, let data = UserDefaults.standard.data(forKey: key(account)) else { return nil }
        return try? JSONDecoder().decode(CardBuy.self, from: data)
    }

    private func save() {
        guard let account else { return }
        if let buy, let data = try? JSONEncoder().encode(buy) {
            UserDefaults.standard.set(data, forKey: Self.key(account))
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key(account))
        }
    }
}
