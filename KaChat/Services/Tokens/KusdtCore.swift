import Foundation
import WebKit
import CryptoKit

/// Trestly's own kUSDT transaction builders (kusdt-open `bridge/packages/core/pkg-web`, the same
/// WebAssembly their wallet runs), run inside KaChat as in KaPay (owner's call, 2026-11-19): a KCC-20 input's
/// unlock script and compute budget come from running the token contract, which only their
/// runtime does exactly.
///
/// How it's kept safe:
/// - The three files ship in the app (`Resources/KusdtCore/`) and are checked against the SHA-256s
///   below before anything loads; the WebAssembly's is the one in kusdt-open's PROVENANCE.json.
/// - They're served only through a private scheme (`kusdt-core://`) to a hidden, non-persistent web
///   view that's never shown and navigates nowhere else.
/// - KaChat hands it one request at a time (`run`) and reads back the signed transaction. A key goes
///   in only for the address being spent from, and only for that call.
@MainActor
final class KusdtCore: NSObject {
    static let shared = KusdtCore()

    /// kusdt-open b70707c: `kusdt_wasm_bg.wasm` (PROVENANCE.json `wasm`), its loader, and the wallet's page,
    /// by the name the page asks for: the bundle file (the loader ships as `.js.txt`, so Xcode copies
    /// it rather than treating it as source) and its SHA-256.
    nonisolated private static let pinned: [String: (resource: String, ext: String, sha256: String)] = [
        "kusdt_wasm_bg.wasm": ("kusdt_wasm_bg", "wasm", "a7be48e962dab57902924ea71fbad31b073cd2ba2197ebcf0de83b0f2a54fd53"),
        "kusdt_wasm.js": ("kusdt_wasm.js", "txt", "be01841b7f2eb700acb38c7b36b9faef7d3deeefb7c86a233731afef0052dc78"),
        "kusdt-core.html": ("kusdt-core", "html", "05b1e41dc8508770b3583c8e74bc0c0ceecf7bca1e6b44e53c1deb750bbab1b4"),
    ]
    private static let scheme = "kusdt-core"

    enum CoreError: LocalizedError {
        case unavailable(String)
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let why): return why
            case .refused(let why): return why
            }
        }
    }

    private var webView: WKWebView?
    private var files: [String: Data] = [:]
    private var ready = false
    private var waiting: [CheckedContinuation<Void, Error>] = []
    /// Set only when a file isn't the pinned one: that never gets better, so it's refused for good.
    /// Any other failure (a slow start, a crashed web content process) is tried again next time.
    private var pinError: String?
    /// Bumped on every start and teardown, so a late timeout or teardown belongs to its own start.
    private var generation = 0
    private var starting = false

    /// Runs one builder command on a JSON request; answers the result as JSON, or throws the
    /// builder's own error (`{"error": …}`).
    func run(_ command: String, request: [String: Any]) async throws -> [String: Any] {
        try await load()
        guard let webView else { throw CoreError.unavailable(AppLocalization.string("kUSDT's transaction builder couldn't start.")) }
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let json = String(data: data, encoding: .utf8) else { throw CoreError.unavailable("bad request") }
        defer { scheduleTeardown() }
        let answer = try await webView.callAsyncJavaScript(
            "return window.kusdtCore.ready ? window.kusdtCore.run(command, request) : null",
            arguments: ["command": command, "request": json],
            in: nil,
            contentWorld: .page
        )
        guard let text = answer as? String,
              let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CoreError.unavailable(AppLocalization.string("kUSDT's transaction builder gave no answer."))
        }
        if let error = parsed["error"] as? String { throw CoreError.refused(error) }
        return parsed
    }

    // MARK: Loading

    private func load() async throws {
        if ready, webView != nil { return }
        if let pinError { throw CoreError.unavailable(pinError) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiting.append(continuation)
            guard !starting else { return }
            starting = true
            generation += 1
            let current = generation
            Task { @MainActor in await self.start(generation: current) }
        }
    }

    /// The pinned files are read and hashed off the main thread (the WebAssembly is ~8 MB), and the
    /// web view gets a content rule list that blocks every load but its own scheme: the page holds
    /// a spending key during a send, so it must not reach the network even if its code ever tried.
    private func start(generation current: Int) async {
        let checked: [String: Data]? = await Task.detached(priority: .userInitiated) { () -> [String: Data]? in
            var out: [String: Data] = [:]
            for (name, file) in Self.pinned {
                guard let url = Bundle.main.url(forResource: file.resource, withExtension: file.ext),
                      let data = try? Data(contentsOf: url),
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                    AppLog.log("[kUSDT] the builder file %@ is missing or not the pinned one: refused", name)
                    return nil
                }
                out[name] = data
            }
            return out
        }.value
        guard current == generation else { return }
        guard let checked else {
            pinError = AppLocalization.string("kUSDT's transaction builder isn't the pinned one, so it won't run.")
            finish(error: pinError)
            return
        }
        files = checked
        let rules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^\(Self.scheme):"},"action":{"type":"ignore-previous-rules"}}]
        """
        let ruleList: WKContentRuleList? = await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "kusdt-core-offline", encodedContentRuleList: rules) { list, error in
                if let error { AppLog.log("[kUSDT] the offline rule list didn't compile: %@", error.localizedDescription) }
                continuation.resume(returning: list)
            }
        }
        guard current == generation else { return }
        guard let ruleList else {
            finish(error: AppLocalization.string("kUSDT's transaction builder couldn't start."))
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        configuration.userContentController.add(WeakMessageHandler(self), name: "kusdtCore")
        configuration.userContentController.add(ruleList)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        guard let url = URL(string: "\(Self.scheme)://core/kusdt-core.html") else { return }
        view.load(URLRequest(url: url))
        // a start that never says ready doesn't leave every send waiting
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.generation == current, !self.ready else { return }
            AppLog.log("[kUSDT] the builder didn't start in time")
            self.finish(error: AppLocalization.string("kUSDT's transaction builder couldn't start."))
        }
    }

    private func finish(error: String?) {
        starting = false
        if error != nil {
            tearDown()
        } else {
            ready = true
            // the page has loaded all three: the copies here aren't needed until a restart
            files = [:]
        }
        let continuations = waiting
        waiting = []
        for c in continuations {
            if let error { c.resume(throwing: CoreError.unavailable(error)) } else { c.resume() }
        }
    }

    private func tearDown() {
        generation += 1
        ready = false
        starting = false
        files = [:]
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
    }

    /// A minute after the last run, the web view goes: the keys handed to it don't linger in its
    /// process, and the next send starts it again (a second or so).
    private func scheduleTeardown() {
        let current = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, self.generation == current, self.ready, self.waiting.isEmpty else { return }
            self.tearDown()
        }
    }

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any] else { return }
        if message["ready"] as? Bool == true {
            AppLog.log("[kUSDT] builder ready (%@)", (message["version"] as? String) ?? "?")
            finish(error: nil)
        } else if let error = message["error"] as? String {
            AppLog.log("[kUSDT] builder failed to start: %@", error)
            finish(error: AppLocalization.string("kUSDT's transaction builder couldn't start."))
        }
    }
}

// MARK: - Serving the pinned files

extension KusdtCore: WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let name = urlSchemeTask.request.url?.lastPathComponent ?? ""
        guard let data = files[name] else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = name.hasSuffix(".wasm") ? "application/wasm" : name.hasSuffix(".js") ? "text/javascript" : "text/html"
        let response = HTTPURLResponse(url: urlSchemeTask.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

extension KusdtCore: WKNavigationDelegate {
    /// The page goes nowhere but its own files.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == Self.scheme ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if !ready { finish(error: AppLocalization.string("kUSDT's transaction builder couldn't start.")) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !ready { finish(error: AppLocalization.string("kUSDT's transaction builder couldn't start.")) }
    }

    /// Its web content process died (memory pressure, a crash): started again on the next run,
    /// instead of every send failing until the app is relaunched.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        AppLog.log("[kUSDT] the builder's web process ended; it starts again on the next send")
        if ready { tearDown() } else { finish(error: AppLocalization.string("kUSDT's transaction builder couldn't start.")) }
    }
}

/// The content controller holds its handler strongly; this keeps the core from holding itself.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var core: KusdtCore?
    init(_ core: KusdtCore) { self.core = core }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        Task { @MainActor in self.core?.received(body) }
    }
}
