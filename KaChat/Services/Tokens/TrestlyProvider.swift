import Foundation
import UIKit
import WebKit

/// The wallet provider Trestly's site talks to inside K (kusdt-open SPEC §14, `window.kusdt`),
/// for the one address picked in Open Trestly. K's own code answers every request; the page
/// never sees a key.
///
/// - Injected at document start, main frame only, and only on the Trestly origin set in Settings
///   (`TrestlyBrowserView.siteURL`): the script checks the page's origin, and the bridge checks the
///   sending frame's origin and that it is the main frame, so another site or an iframe gets nothing.
/// - trestly.io (its 2026-11-20 build) finds it by `window.kusdt`, by `kusdt#initialized` and by
///   `kusdt:announceProvider`, which is dispatched again whenever the page dispatches
///   `kusdt:requestProvider`. It reads what K answers from `methods` (on the provider and on
///   `info`) and `kusdt_capabilities`, and names K from `info`.
/// - Answers: `kaspa_requestAccounts` (the picked address: opening Trestly with it was the approval),
///   `kaspa_getNetwork`, `kaspa_switchNetwork` (only to the network K is on; else 4200, since
///   K switches networks in its own settings), `kusdt_getBalances` (that address's plain KAS
///   from the node and its node-checked kUSDT), `kusdt_capabilities`, and the trades `kusdt_swap`,
///   `kusdt_addLiquidity`, `kusdt_removeLiquidity`: Trestly's own wallet logic (`KusdtCore.wallet`,
///   bundled by tools/kusdt-wallet) checks and quotes, K asks in `TrestlyApprovalSheet`, then the
///   same code builds, signs with this one address's key and sends. Everything else, including
///   `kusdt_send` and `kusdt_redeem`, is 4200, and the site says "K does not support …".
@MainActor
final class TrestlyProvider: NSObject, ObservableObject, WKScriptMessageHandlerWithReply {
    /// The bridge's name: `window.webkit.messageHandlers.kapay`.
    static let handlerName = "kapay"

    /// What K answers, as `methods` and `kusdt_capabilities` say. Send and redeem aren't in it:
    /// the site says K doesn't support them.
    static let methods = [
        "kaspa_requestAccounts", "kaspa_getNetwork", "kaspa_switchNetwork", "kusdt_getBalances",
        "kusdt_swap", "kusdt_addLiquidity", "kusdt_removeLiquidity",
    ]
    static let tradeMethods: Set<String> = ["kusdt_swap", "kusdt_addLiquidity", "kusdt_removeLiquidity"]

    /// The trade waiting for the user's answer, shown by `TrestlyBrowserView` as `TrestlyApprovalSheet`.
    @Published var approval: TrestlyApproval?
    /// One trade at a time, from its first check to the end of its send (audit, 2026-11-20): a second
    /// request while one is being prepared, shown or sent is answered -32002, so a sheet can never be
    /// swapped under the user's finger and two sends never run on one address's coins.
    private var tradeInFlight = false
    /// After Decline the page waits a moment before it can ask again, so sheets can't be popped up
    /// one after another.
    private var declinedAt: Date?
    /// The browser closed: nothing more is shown or signed for this page.
    private var closed = false
    /// "Swapped 10 KAS for 0.26 kUSDT" (or the other way round), shown over the page for a few seconds.
    @Published var banner: String?
    private var bannerToken = UUID()

    /// SPEC §14 error codes.
    enum Code {
        static let rejected = 4001
        static let unauthorized = 4100
        static let unsupported = 4200
        static let busy = -32002
        static let invalid = -32602
        static let failed = -32603
    }

    struct ProviderError: Error {
        let code: Int
        let message: String
        /// The trade may have gone out though no answer said so (`execute` timed out, its page
        /// died, or Trestly's code said `maybeSent`).
        var maybeSent = false
    }

    let target: TrestlyTarget
    /// The only origin answered, e.g. "https://trestly.io".
    let allowedOrigin: (host: String, port: Int)
    /// Set once the page asked for the account (SPEC §14: before that, reads are 4100).
    private var connected = false
    /// Requests running now: more than 8 at once is -32002, as kUSDT Wallet does.
    private var running = 0

    init(target: TrestlyTarget, siteURL: URL) {
        self.target = target
        self.allowedOrigin = (siteURL.host?.lowercased() ?? "", siteURL.port ?? 443)
    }

    /// K's network as the provider names it.
    static var networkName: String {
        AppSettings.load().networkType == .mainnet ? "mainnet" : "testnet-10"
    }

    // MARK: Installing

    /// Adds the script and the bridge to a web view's configuration (before the view is made).
    func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
    }

    /// The page side: `window.kusdt`, frozen, only on the allowed https origin.
    private var script: String {
        let methodsJSON = Self.jsonString(Self.methods) ?? "[]"
        let info = Self.jsonString([
            // what Trestly's site shows on Connect: the app's name and logo (K since 2026-11-21);
            // rdns is an id, not shown, so it stays as Trestly knows it
            "name": "K",
            "rdns": "com.kachat.wallet",
            "icon": Self.iconDataURL ?? "",
        ]) ?? "{}"
        let host = Self.jsonString(allowedOrigin.host) ?? "\"\""
        let port = allowedOrigin.port
        return """
        (() => {
          'use strict';
          try {
            const port = location.port === '' ? 443 : Number(location.port);
            if (location.protocol !== 'https:' || location.hostname.toLowerCase() !== \(host) || port !== \(port)) return;
            if (window.kusdt) return;
            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Self.handlerName);
            if (!bridge) return;
            const methods = Object.freeze(\(methodsJSON));
            const base = \(info);
            if (!base.icon) delete base.icon;
            const info = Object.freeze(Object.assign(base, { methods }));
            const listeners = Object.create(null);
            const fail = (code, message, data) => Object.assign(new Error(message), data === undefined ? { code } : { code, data });
            const provider = {
              isKaPay: true,
              info,
              methods,
              request(args) {
                if (!args || typeof args !== 'object' || typeof args.method !== 'string' || args.method.length > 64) {
                  return Promise.reject(fail(\(Code.invalid), 'Expected { method, params }.'));
                }
                let params = args.params === undefined ? null : args.params;
                let text;
                try { text = JSON.stringify(params); } catch (e) { return Promise.reject(fail(\(Code.invalid), 'Params must be JSON.')); }
                if (text !== undefined && text.length > 4096) return Promise.reject(fail(\(Code.invalid), 'Params are too long.'));
                return bridge.postMessage({ method: args.method, params: text === undefined ? null : JSON.parse(text) }).then((answer) => {
                  if (answer && answer.error) throw fail(answer.error.code, answer.error.message, answer.error.data);
                  return answer ? answer.result : null;
                }, (e) => { throw fail(\(Code.failed), String((e && e.message) || e)); });
              },
              on(event, listener) {
                if (typeof listener !== 'function') return provider;
                (listeners[event] = listeners[event] || []).push(listener);
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
            Object.defineProperty(window, 'kusdt', { value: provider, writable: false, configurable: false, enumerable: true });
            const announce = () => {
              try { window.dispatchEvent(new CustomEvent('kusdt:announceProvider', { detail: Object.freeze({ provider, info }) })); } catch (e) {}
            };
            window.addEventListener('kusdt:requestProvider', announce);
            announce();
            try { window.dispatchEvent(new Event('kusdt#initialized')); } catch (e) {}
          } catch (e) {}
        })();
        """
    }

    // MARK: Answering

    /// The bridge's reply form (WebKit resolves the page's promise with what this returns).
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        // Only the allowed site's own page, never a frame or another origin.
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        let port = origin.port == 0 ? 443 : origin.port
        guard frame.isMainFrame, origin.protocol == "https", origin.host.lowercased() == allowedOrigin.host, port == allowedOrigin.port else {
            return (Self.errorAnswer(ProviderError(code: Code.unauthorized, message: "This page can't use K.")), nil)
        }
        guard let request = message.body as? [String: Any], let method = request["method"] as? String, method.count <= 64 else {
            return (Self.errorAnswer(ProviderError(code: Code.invalid, message: "Expected { method, params }.")), nil)
        }
        // The page's own wrapper limits params, but a page can post to the bridge directly: the same
        // limits here, and only plain JSON (a Date or NaN would make JSONSerialization raise and
        // crash the app; audit, 2026-11-20).
        let rawParams = request["params"]
        if let rawParams, !(rawParams is NSNull) {
            guard JSONSerialization.isValidJSONObject([rawParams]),
                  let data = try? JSONSerialization.data(withJSONObject: [rawParams]), data.count <= 4096 + 2 else {
                return (Self.errorAnswer(ProviderError(code: Code.invalid, message: "Params must be JSON of at most 4096 characters.")), nil)
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
        case "kaspa_requestAccounts":
            connected = true
            return [target.address]
        case "kaspa_getNetwork":
            return Self.networkName
        case "kaspa_switchNetwork":
            guard connected else { throw ProviderError(code: Code.unauthorized, message: "Connect K to this site first.") }
            guard let network = (params as? [String: Any])?["network"] as? String,
                  ["mainnet", "testnet-10", "simnet"].contains(network) else {
                throw ProviderError(code: Code.invalid, message: "Expected { network }.")
            }
            guard network == Self.networkName else {
                throw ProviderError(code: Code.unsupported, message: "K changes networks only in its own Settings.")
            }
            return network
        case "kusdt_getBalances":
            guard connected else { throw ProviderError(code: Code.unauthorized, message: "Connect K to this site first.") }
            return try await balances()
        case "kusdt_capabilities":
            return Self.methods
        case _ where Self.tradeMethods.contains(method):
            guard connected else { throw ProviderError(code: Code.unauthorized, message: "Connect K to this site first.") }
            return try await trade(method, params: params)
        default:
            throw ProviderError(code: Code.unsupported, message: "K doesn't support \(method) here.")
        }
    }

    // MARK: Trades (Trestly's own wallet logic, `KusdtCore.wallet`)

    /// A swap, a deposit or a withdrawal from the page: `TrestlyTrade.run` (Trestly's code
    /// prepares, K asks in `TrestlyApprovalSheet`, then builds, signs and sends), one at a time, and
    /// not again for a moment after a Decline.
    private func trade(_ method: String, params: Any?) async throws -> Any? {
        guard !closed else { throw ProviderError(code: Code.unauthorized, message: "K closed this page.") }
        guard !tradeInFlight, approval == nil else {
            throw ProviderError(code: Code.busy, message: "K is already working on a request from this page.")
        }
        if let declinedAt, Date().timeIntervalSince(declinedAt) < 3 {
            throw ProviderError(code: Code.rejected, message: "You declined in K a moment ago.")
        }
        tradeInFlight = true
        defer { tradeInFlight = false }
        let done: TrestlyTrade.Done
        do {
            done = try await TrestlyTrade.run(method: method, params: params, target: target,
                                              ask: { await self.ask($0) }, isClosed: { self.closed })
        } catch let error as ProviderError where error.code == Code.rejected {
            declinedAt = Date()
            throw error
        }
        if method == "kusdt_swap", let text = TrestlyTrade.recordSwap(done, target: target) {
            showBanner(text)
        }
        return done.result
    }

    /// "Swapped 10 KAS for 0.26 kUSDT" over the page for a few seconds.
    private func showBanner(_ text: String) {
        Haptics.success()
        let token = UUID()
        bannerToken = token
        banner = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self.bannerToken == token { self.banner = nil }
        }
    }

    /// Shows the approval and waits for Approve or Decline (closing the sheet declines).
    private func ask(_ request: TrestlyApproval) async -> Bool {
        // a page that is gone gets no sheet (it would never be answered)
        guard !closed else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            request.answer = { approved in continuation.resume(returning: approved) }
            approval = request
        }
    }

    /// The browser closed (Done): a sheet still up is declined, and nothing later is shown or signed.
    func close() {
        closed = true
        let pending = approval
        approval = nil
        pending?.respond(false)
    }

    /// `{kas, kusdt}` for the connected address, as decimal strings (sompi and base units): the plain
    /// KAS coins the node shows at it, and its kUSDT as `TokenWallet` checked it on the node.
    private func balances() async throws -> [String: String] {
        let utxos: [UTXO]
        do {
            utxos = try await NodePoolService.shared.getUtxosByAddresses([target.address], allowRestFallback: false)
        } catch {
            throw ProviderError(code: Code.failed, message: "K couldn't read this address's KAS just now.")
        }
        let kas = utxos.filter { $0.covenantId == nil }.reduce(UInt64(0)) { $0 &+ $1.amount }

        let tokens = TokenWallet.shared
        await tokens.refreshIfStale()
        guard tokens.balance(of: .kusdt) != nil else {
            throw ProviderError(code: Code.failed, message: tokens.lastError ?? "K couldn't check this address's kUSDT just now.")
        }
        let kusdt = tokens.holdings(of: .kusdt).first(where: { $0.address == target.address })?.units ?? 0
        return ["kas": String(kas), "kusdt": String(kusdt)]
    }

    // MARK: Helpers

    private static func errorAnswer(_ error: ProviderError) -> [String: Any] {
        ["error": ["code": error.code, "message": error.message]]
    }

    private static func jsonString(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// K's globe logo as a small PNG data URL for `info.icon` (the site takes up to 256 KB). It
    /// named K's "KaChatWalletLogo", which K doesn't ship, so the site showed no logo. Also the
    /// Ethereum provider's EIP-6963 icon on the buy page (`CardBuyEthereumProvider`).
    static let iconDataURL: String? = {
        guard let image = UIImage(named: "KLogo") else { return nil }
        let size = CGSize(width: 96, height: 96)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard png.count < 200_000 else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }()
}
