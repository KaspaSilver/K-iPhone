import Foundation
import WebKit
import CryptoKit
import P256K

/// K as a wallet for a Kaspa website opened in K's own browser (`InAppBrowserScreen`): the same
/// `window.kachat` provider the K browser extension puts on pages (K-Browser-Extension
/// `public/inpage.js`), so a site that supports the extension works in the app unchanged.
/// Kasshi (kasshi.io) is the first and only site (owner, 2026-11-26; KASSHI_INTEGRATION.md).
///
/// - Injected at document start, main frame only, on an allowed https origin; the bridge checks
///   the sending frame again (main frame, same origin), so an iframe or another site gets nothing.
/// - `requestAccounts` opens K's Connect sheet, where the person picks the address: the Chatting
///   Address or another regular address of the account (never a quantum one: Kasshi checks the
///   signature against the address the key makes). Everything after uses that address. The pick
///   is remembered per K account and site and suggested next time.
/// - `signMessage` opens the Sign sheet (the full text); the signature is KasWare's personal
///   message scheme, hex: schnorr(blake2b-256(key "PersonalMessageSigningHash", utf8(text))).
/// - `sendKaspa` opens K's own Send Kaspa review (`WithdrawKaspaView` with the address and amount
///   fixed and From locked to the connected address), swipe up to send; the txid comes back.
/// - One sheet at a time (-32002); a decline makes the site wait 3 s before it can ask again.
/// - Nothing persists but the remembered pick: the browser's storage is gone when it closes, and
///   the connection with it.
@MainActor
final class KaChatSiteWallet: NSObject, ObservableObject, WKScriptMessageHandlerWithReply {
    /// `window.webkit.messageHandlers.kachatSite`.
    static let handlerName = "kachatSite"

    /// Sites that get the provider: the host itself and its subdomains, https only.
    static let allowedHosts: Set<String> = ["kasshi.io"]

    static func isAllowed(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    enum Code {
        static let rejected = 4001
        static let maybeSent = 4002
        static let unauthorized = 4100
        static let unsupported = 4200
        static let unavailable = 4900
        static let busy = -32002
        static let invalid = -32602
    }

    struct SiteError: Error {
        let code: Int
        let message: String
        /// With 4002 ("may have been sent"): the transaction that may land.
        var txid: String? = nil
    }

    /// What the page is waiting on the person for, shown by `InAppBrowserScreen` as a sheet.
    struct Request: Identifiable {
        enum Kind {
            case connect
            case sign(message: String)
            case send(to: String, sompi: UInt64)
        }
        let id = UUID()
        let host: String
        let kind: Kind
    }

    /// The address the page is connected to.
    struct Connection: Equatable {
        let source: SendSource
        let address: String
        /// 33-byte compressed key, hex ("02..."), as the extension and KasWare return it.
        let publicKey: String
    }

    @Published var pending: Request?
    @Published private(set) var connection: Connection?
    /// A sheet is on screen (a send's Sent screen stays up after its answer): no new request
    /// until it's closed, so one sheet never replaces another.
    var sheetOpen = false

    private var answer: ((Result<Any?, SiteError>) -> Void)?
    /// Signed in from K's own "Sign in to Kasshi" sheet (`preConnect`): the site's first
    /// `signMessage` on this host before this time is its sign-in, signed with no second sheet
    /// (owner, 2026-11-27: pick the address, then straight in).
    private var signInApproved: (host: String, until: Date)?
    /// Page loads the approval may still see: one for the page still loading when the person
    /// picked the address, none after that. A later navigation ends it (audit 2026-11-27 M2).
    private var approvalLoadBudget = 0
    /// The page K opened on has finished loading once.
    private var initialLoadDone = false
    /// A site send whose answer was lost may still land: no new send from this site for ten
    /// minutes (audit 2026-11-27 M3), as `TrestlyTrade` holds a "maybe sent" trade. Kept by K
    /// account and site, outside the browser, so closing Kasshi and opening it again doesn't
    /// lift it (release audit 2026-11-27, Low).
    private static var sendHolds: [String: Date] = [:]

    private static func sendHoldKey(host: String) -> String {
        let account = WalletManager.shared.currentWallet?.publicAddress.lowercased() ?? ""
        return account + "|" + siteKey(host.lowercased())
    }
    private var declinedAt: Date?
    private var running = 0
    private var closed = false
    private weak var webView: WKWebView?

    // MARK: Installing

    /// Adds the provider to a web view's configuration (before the view is made).
    func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    /// The browser is on screen again. A browser hidden behind another tab and brought back keeps
    /// its page; before, it stayed "closed" and answered the site's next request with "K closed
    /// this page." until something reloaded it (2026-11-27).
    func reopen() {
        closed = false
    }

    /// The browser closed: a sheet still up is declined, and nothing more is answered.
    func close() {
        closed = true
        signInApproved = nil
        finish(.failure(SiteError(code: Code.rejected, message: "K closed this page.")))
        pending = nil
        connection = nil
    }

    /// The page side: `window.kachat`, frozen, only on an allowed https origin. The same calls
    /// and shapes as the extension's inpage.js, plus `platform: "ios"`.
    private static var script: String {
        let hosts = (try? JSONSerialization.data(withJSONObject: Array(allowedHosts).sorted()))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (() => {
          'use strict';
          try {
            if (location.protocol !== 'https:') return;
            const host = location.hostname.toLowerCase();
            const allowed = \(hosts);
            if (!allowed.some((h) => host === h || host.endsWith('.' + h))) return;
            if (window.kachat) return;
            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
            if (!bridge) return;
            const listeners = { accountsChanged: new Set(), disconnect: new Set(), networkChanged: new Set() };
            class KaChatWalletError extends Error {
              constructor(message, code, txid) {
                super(message);
                this.name = 'KaChatWalletError';
                this.code = code;
                if (typeof txid === 'string' && /^[0-9a-f]{64}$/.test(txid)) this.txid = txid;
              }
            }
            const call = (method, params) => {
              let text;
              try { text = JSON.stringify(params || []); } catch (e) { return Promise.reject(new KaChatWalletError('Params must be JSON.', -32602)); }
              if (text.length > 8192) return Promise.reject(new KaChatWalletError('Params are too long.', -32602));
              return bridge.postMessage({ method, params: JSON.parse(text) }).then((answer) => {
                if (answer && answer.error) throw new KaChatWalletError(answer.error.message || 'Request failed.', answer.error.code, answer.error.txid);
                return answer ? answer.result : null;
              }, (e) => { throw new KaChatWalletError(String((e && e.message) || e), 4900); });
            };
            const provider = Object.freeze({
              isKaChat: true,
              version: '1',
              platform: 'ios',
              requestAccounts: () => call('requestAccounts'),
              getAccounts: () => call('getAccounts'),
              getNetwork: () => call('getNetwork'),
              getPublicKey: () => call('getPublicKey'),
              getBalance: () => call('getBalance'),
              sendKaspa: (toAddress, sompi, options = {}) => call('sendKaspa', [String(toAddress), String(sompi), { priorityFee: options && options.priorityFee != null ? String(options.priorityFee) : '0' }]),
              signMessage: (message) => call('signMessage', [String(message)]),
              disconnect: () => call('disconnect'),
              on(event, handler) { if (listeners[event] && typeof handler === 'function') listeners[event].add(handler); return provider; },
              removeListener(event, handler) { if (listeners[event]) listeners[event].delete(handler); return provider; },
            });
            window.addEventListener('kachat:native-event', (e) => {
              const d = e && e.detail;
              if (!d || !listeners[d.event]) return;
              for (const handler of listeners[d.event]) { try { handler(d.payload); } catch (err) { console.error(err); } }
            });
            Object.defineProperty(window, 'kachat', { value: provider, writable: false, configurable: false, enumerable: true });
            window.dispatchEvent(new Event('kachat#initialized'));
          } catch (e) {}
        })();
        """
    }

    // MARK: Answering

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        guard frame.isMainFrame, origin.protocol == "https", Self.isAllowed(host: origin.host) else {
            return (Self.errorAnswer(SiteError(code: Code.unauthorized, message: "This page can't use K.")), nil)
        }
        guard let body = message.body as? [String: Any], let method = body["method"] as? String, method.count <= 64 else {
            return (Self.errorAnswer(SiteError(code: Code.invalid, message: "Expected { method, params }.")), nil)
        }
        let params = body["params"] as? [Any] ?? []
        guard running < 8 else {
            return (Self.errorAnswer(SiteError(code: Code.busy, message: "K is still answering this page's earlier requests.")), nil)
        }
        running += 1
        defer { running -= 1 }
        do {
            let result = try await answer(method, params: params, host: origin.host.lowercased())
            return (["result": result ?? NSNull()], nil)
        } catch let error as SiteError {
            return (Self.errorAnswer(error), nil)
        } catch {
            return (Self.errorAnswer(SiteError(code: Code.unavailable, message: error.localizedDescription)), nil)
        }
    }

    private func answer(_ method: String, params: [Any], host: String) async throws -> Any? {
        guard !closed else { throw SiteError(code: Code.unauthorized, message: "K closed this page.") }
        switch method {
        case "getNetwork":
            // only a connected site learns the network, as in the extension
            return connection == nil ? nil : Self.networkName
        case "getAccounts":
            return connection.map { [$0.address] } ?? []
        case "requestAccounts":
            if let connection { return [connection.address] }
            _ = try await ask(.connect, host: host)
            guard let connection else { throw SiteError(code: Code.rejected, message: "Request rejected in K.") }
            return [connection.address]
        case "getPublicKey":
            guard let connection else { throw Self.notConnected }
            return connection.publicKey
        case "getBalance":
            guard let connection else { throw Self.notConnected }
            return try await balance(of: connection.address)
        case "disconnect":
            signInApproved = nil
            if connection != nil {
                connection = nil
                emit("accountsChanged", payload: [String]())
                emit("disconnect", payload: nil)
            }
            return true
        case "signMessage":
            guard connection != nil else { throw Self.notConnected }
            guard let text = params.first as? String, !text.isEmpty else {
                throw SiteError(code: Code.invalid, message: "signMessage: the message is required.")
            }
            guard text.count <= 4096 else {
                throw SiteError(code: Code.invalid, message: "signMessage: messages are limited to 4096 characters.")
            }
            // KaPost actions are signed with this same scheme and key, and the indexer takes any
            // signature that matches: a signed "delete:<post>" or "<base64>:[]" could be posted as
            // you. Those shapes are never signed for a site (release audit 2026-11-27 R3).
            if Self.looksLikeKaPostAction(text) {
                throw SiteError(code: Code.rejected, message: "K doesn't sign this message: it has the form of a K post or action.")
            }
            // The sign-in the person already agreed to in K's own sheet: once, only kasshi.io
            // itself, and only Kasshi's own sign-in challenge for the connected address with a
            // fresh timestamp. Anything else gets the Sign sheet (audit 2026-11-27 M2).
            if let approved = signInApproved, approved.host == Self.siteKey(host), Date() < approved.until,
               Self.signInHosts.contains(host.lowercased()),
               pending == nil, answer == nil, !sheetOpen, let connection,
               Self.isKasshiSignInChallenge(text, address: connection.address) {
                signInApproved = nil
                do {
                    return try Self.sign(text, source: connection.source, expecting: connection.address)
                } catch {
                    throw SiteError(code: Code.unavailable, message: "K couldn't sign this message.")
                }
            }
            return try await ask(.sign(message: text), host: host)
        case "sendKaspa":
            guard connection != nil else { throw Self.notConnected }
            if let until = Self.sendHolds[Self.sendHoldKey(host: host)], Date() < until {
                throw SiteError(code: Code.busy, message: "Your last payment from this page may still go through. Check it before paying again; K takes payments from this page again in a few minutes.")
            }
            let to = (params.first as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard KaspaAddress.isValidOnActiveNetwork(to) else {
                let prefix = Self.networkName == "mainnet" ? "kaspa:" : "kaspatest:"
                throw SiteError(code: Code.invalid, message: "sendKaspa: a \(prefix) address is required.")
            }
            let amountText = params.count > 1 ? String(describing: params[1]) : ""
            guard amountText.range(of: #"^\d{1,19}$"#, options: .regularExpression) != nil,
                  let sompi = UInt64(amountText), sompi > 0 else {
                throw SiteError(code: Code.invalid, message: "sendKaspa: the amount is a whole number of sompi above zero.")
            }
            return try await ask(.send(to: to, sompi: sompi), host: host)
        default:
            throw SiteError(code: Code.unsupported, message: "K does not support \(method.prefix(40)).")
        }
    }

    private static let notConnected = SiteError(code: Code.unauthorized, message: "Connect first: call kachat.requestAccounts().")

    /// The hosts K's own sign-in sheet signs in to without a second sheet: the site itself, never
    /// a subdomain (audit 2026-11-27 M2).
    static let signInHosts: Set<String> = ["kasshi.io", "www.kasshi.io"]

    /// Kasshi's sign-in challenge (`/api/wallet-auth/challenge`, checked 2026-11-27):
    /// "Sign this message to authenticate with KasShi.\n\nAddress: <address>\nTimestamp: <ms>\nNonce: <hex>",
    /// for the connected address, made within the last ten minutes.
    static func isKasshiSignInChallenge(_ text: String, address: String) -> Bool {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.count == 5,
              lines[0] == "Sign this message to authenticate with KasShi.", lines[1].isEmpty,
              lines[2].hasPrefix("Address: "), lines[3].hasPrefix("Timestamp: "), lines[4].hasPrefix("Nonce: ") else { return false }
        let shown = String(lines[2].dropFirst("Address: ".count)).lowercased()
        guard shown == address.lowercased() else { return false }
        // range-checked first: the page picks this number, and abs(now - Int64.min) traps
        guard let ms = Int64(lines[3].dropFirst("Timestamp: ".count)),
              ms > 0, ms < 100_000_000_000_000 else { return false }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard abs(now - ms) < 600_000 else { return false }
        let nonce = lines[4].dropFirst("Nonce: ".count)
        return (8...128).contains(nonce.count) && nonce.allSatisfy { $0.isHexDigit }
    }

    /// The strings K signs for KaPost (`KaPostsProtocol`'s signing strings, KaPostsAPIClient.swift):
    /// the action prefixes; a post, `<base64>:<mentions JSON>`; a reply, vote or quote,
    /// `<64-hex id>:...`; an unquote, a bare 64-hex id. Checked as sent and trimmed, any case.
    static func looksLikeKaPostAction(_ text: String) -> Bool {
        for candidate in Set([text, text.trimmingCharacters(in: .whitespacesAndNewlines)]) {
            let lower = candidate.lowercased()
            if kaPostActionPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
            let head = lower.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? lower
            // a post id (a txid) alone or first
            if head.count == 64, head.allSatisfy({ $0.isHexDigit }) { return true }
            // a post: base64 text, then the mentions array
            if let colon = candidate.firstIndex(of: ":") {
                let b64 = candidate[..<colon]
                let rest = candidate[candidate.index(after: colon)...]
                if b64.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }),
                   rest.trimmingCharacters(in: .whitespacesAndNewlines).first.map({ $0 == "[" || $0 == "{" }) == true {
                    return true
                }
            }
        }
        return false
    }

    private static let kaPostActionPrefixes = ["edit:", "delete:", "poll:", "pollvote:", "tip:", "schedule:",
                                               "cancel-schedule:", "follow:", "unfollow:"]

    static var networkName: String {
        AppSettings.load().networkType == .mainnet ? "mainnet" : "testnet-10"
    }

    // MARK: The person's answer

    /// Shows the sheet and waits for it. One at a time; a decline holds the site off for 3 s.
    private func ask(_ kind: Request.Kind, host: String) async throws -> Any? {
        guard pending == nil, answer == nil, !sheetOpen else {
            throw SiteError(code: Code.busy, message: "A request from this site is already waiting in K.")
        }
        if let declinedAt, Date().timeIntervalSince(declinedAt) < 3 {
            throw SiteError(code: Code.rejected, message: "The last request from this site was just rejected in K. Wait a few seconds before asking again.")
        }
        let result: Result<Any?, SiteError> = await withCheckedContinuation { continuation in
            answer = { continuation.resume(returning: $0) }
            pending = Request(host: host, kind: kind)
        }
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            if error.code == Code.rejected { declinedAt = Date() }
            throw error
        }
    }

    private func finish(_ result: Result<Any?, SiteError>) {
        guard let answer else { return }
        self.answer = nil
        answer(result)
    }

    /// The sheet went away without an answer (Cancel, a swipe down, Decline).
    func decline() {
        pending = nil
        finish(.failure(SiteError(code: Code.rejected, message: "Request rejected in K.")))
    }

    /// Connect approved with the address picked in the sheet.
    func approveConnect(source: SendSource, host: String) {
        do {
            let connected = try Self.connection(for: source)
            connection = connected
            Self.rememberPick(source, host: host)
            pending = nil
            finish(.success([connected.address]))
            emit("accountsChanged", payload: [connected.address])
        } catch let error as SiteError {
            pending = nil
            finish(.failure(error))
        } catch {
            pending = nil
            finish(.failure(SiteError(code: Code.unavailable, message: error.localizedDescription)))
        }
    }

    /// K's own "Sign in" sheet, before the site asks (Kasshi from Kaspa Hub, owner 2026-11-27): the
    /// picked address connects at once, so the site's `requestAccounts` answers with no sheet, and
    /// its sign-in message that follows within two minutes is signed with no sheet either.
    func preConnect(source: SendSource, host: String) throws {
        let connected = try Self.connection(for: source)
        connection = connected
        Self.rememberPick(source, host: host)
        signInApproved = (Self.siteKey(host), Date().addingTimeInterval(120))
        approvalLoadBudget = initialLoadDone ? 0 : 1
        // The page asked to connect while K's own sheet was up: it gets the picked address now.
        // Left waiting, every later request answered "busy" (audit 2026-11-27 L1).
        if case .connect? = pending?.kind {
            pending = nil
            finish(.success([connected.address]))
        }
        emit("accountsChanged", payload: [connected.address])
    }

    /// A page finished loading while connected (`preConnect` ran before it was there, or a link
    /// within the site): `accountsChanged` with the address, so a site that listens can start its
    /// sign-in by itself.
    func pageLoaded() {
        // the sign-in approval lasts through the page it was given for, not a later navigation
        if signInApproved != nil {
            if approvalLoadBudget > 0 { approvalLoadBudget -= 1 } else { signInApproved = nil }
        }
        initialLoadDone = true
        guard !closed, let connection else { return }
        emit("accountsChanged", payload: [connection.address])
    }

    /// The site's send went out but its answer was lost: the page hears "may have been sent"
    /// (4002) with the txid, never "rejected", and can't ask for another payment for ten minutes
    /// (audit 2026-11-27 M3).
    func maybeSent(txId: String, host: String) {
        let now = Date()
        Self.sendHolds = Self.sendHolds.filter { $0.value > now }
        Self.sendHolds[Self.sendHoldKey(host: host)] = now.addingTimeInterval(600)
        pending = nil
        finish(.failure(SiteError(code: Code.maybeSent,
                                  message: "This payment may have gone through. Check it before paying again.",
                                  txid: txId)))
    }

    /// Sign approved: the connected address's key signs the text.
    func approveSign(_ text: String) {
        guard let connection else { decline(); return }
        do {
            let signature = try Self.sign(text, source: connection.source, expecting: connection.address)
            pending = nil
            finish(.success(signature))
        } catch {
            pending = nil
            finish(.failure(SiteError(code: Code.unavailable, message: "K couldn't sign this message.")))
        }
    }

    /// The send went out (K's own Send review).
    func sent(txId: String) {
        pending = nil
        finish(.success(txId))
    }

    // MARK: Keys

    private static func privateKey(for source: SendSource) -> Data? {
        switch source {
        case .chatting: return WalletManager.shared.getPrivateKey()
        case .spending(let index, _, _):
            guard !WalletManager.isQuantumIndex(index) else { return nil }
            return WalletManager.shared.spendingPrivateKey(at: index)
        }
    }

    /// The picked address with its public key, checked: the key must make that address.
    private static func connection(for source: SendSource) throws -> Connection {
        guard let address = source.address?.lowercased(),
              var key = privateKey(for: source) else {
            throw SiteError(code: Code.unavailable, message: "K couldn't open this address's key.")
        }
        defer { key.zeroOut() }
        let signing = try P256K.Signing.PrivateKey(dataRepresentation: key)
        let schnorr = try P256K.Schnorr.PrivateKey(dataRepresentation: key)
        let made = KaspaAddress.fromPublicKey(Data(schnorr.xonly.bytes), network: AppSettings.load().networkType).address
        guard made.lowercased() == address else {
            throw SiteError(code: Code.unavailable, message: "This address can't connect to a website.")
        }
        return Connection(source: source, address: address, publicKey: signing.publicKey.dataRepresentation.hexString)
    }

    /// KasWare's personal message signature, hex.
    private static func sign(_ text: String, source: SendSource, expecting address: String) throws -> String {
        guard var key = privateKey(for: source) else { throw SiteError(code: Code.unavailable, message: "No key") }
        defer { key.zeroOut() }
        let schnorr = try P256K.Schnorr.PrivateKey(dataRepresentation: key)
        let made = KaspaAddress.fromPublicKey(Data(schnorr.xonly.bytes), network: AppSettings.load().networkType).address
        guard made.lowercased() == address.lowercased() else { throw SiteError(code: Code.unavailable, message: "Key mismatch") }
        var digest = Array(Blake2b.hash(Data(text.utf8), digestLength: 32, key: "PersonalMessageSigningHash"))
        let signature = try schnorr.signature(message: &digest, auxiliaryRand: nil)
        return Data(signature.bytes).hexString
    }

    // MARK: Balance

    /// `{confirmed, unconfirmed, total}` in sompi: the plain KAS coins the node holds at it.
    private func balance(of address: String) async throws -> [String: UInt64] {
        do {
            let utxos = try await NodePoolService.shared.getUtxosByAddresses([address])
            let total = utxos.filter { $0.covenantId == nil }.reduce(UInt64(0)) { $0 &+ $1.amount }
            return ["confirmed": total, "unconfirmed": 0, "total": total]
        } catch {
            throw SiteError(code: Code.unavailable, message: "K couldn't read this address's balance just now.")
        }
    }

    // MARK: Events

    private func emit(_ event: String, payload: Any?) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: ["event": event, "payload": payload ?? NSNull()]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('kachat:native-event', { detail: \(json) }));",
                                   in: nil, in: .page, completionHandler: nil)
    }

    // MARK: The remembered pick

    /// The address last connected to each site, per K account: suggested next time.
    private static var pickKey: String? {
        WalletManager.shared.currentWallet.map { "kachat_site_connections_\($0.publicAddress.lowercased())" }
    }

    private static func rememberPick(_ source: SendSource, host: String) {
        guard let key = pickKey else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        all[siteKey(host)] = source.spendingIndex ?? -1
        UserDefaults.standard.set(all, forKey: key)
    }

    /// The spending address index picked last time on this site (nil: the Chatting Address),
    /// if it's still one this account can connect.
    static func rememberedSpendingIndex(host: String) -> Int? {
        guard let key = pickKey,
              let index = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int])?[siteKey(host)],
              index >= 0, !WalletManager.isQuantumIndex(index),
              index <= WalletManager.shared.maxSpendingAddressIndex else { return nil }
        return index
    }

    /// kasshi.io and www.kasshi.io are one site.
    static func siteKey(_ host: String) -> String {
        allowedHosts.first { host == $0 || host.hasSuffix("." + $0) } ?? host
    }

    private static func errorAnswer(_ error: SiteError) -> [String: Any] {
        var body: [String: Any] = ["code": error.code, "message": error.message]
        if let txid = error.txid { body["txid"] = txid }
        return ["error": body]
    }
}
