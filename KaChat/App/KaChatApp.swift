import SwiftUI
import AVFoundation
import CoreData
import UserNotifications
import UIKit

@main
struct KaChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var walletManager = WalletManager.shared
    @StateObject private var contactsManager = ContactsManager.shared
    @StateObject private var chatService = ChatService.shared
    @StateObject private var settingsViewModel = SettingsViewModel()
    @StateObject private var pushManager = PushNotificationManager.shared
    @StateObject private var groupChatService = GroupChatService.shared
    @State private var isProcessingOutboundShare = false
    @State private var lastActiveResyncAt: Date?
    @State private var hasCompletedFirstActiveTransition = false
    @Environment(\.scenePhase) private var scenePhase

    /// Below this, becoming active again skips the heavier resync work (node pool reconnect
    /// sweep, catch-up sync) - only things that must run every single time
    /// regardless of how brief the background interval was (e.g. resuming a UTXO subscription
    /// that's unconditionally paused on every backgrounding) still do. Without this, quickly
    /// backgrounding and resuming (e.g. glancing at the app switcher for a second) re-fired this
    /// whole battery of MainActor-hopping tasks on every return, competing with the user's own
    /// taps for the MainActor's serial queue right as they started navigating - reading as
    /// laggy "surfing around" immediately after a quick resume.
    private let activeResyncDebounce: TimeInterval = 15

    init() {
        // A Testnet/Mainnet switch chosen in Settings takes effect here, before any service
        // reads the settings, so the whole app starts on one network (IOS-002).
        PendingNetworkSwitch.applyAtLaunch()
        // Warm up audio session and crypto on background thread to avoid first-interaction lag
        Task.detached(priority: .utility) {
            await Self.warmUp()
        }
        // Touch the (lazy) Nextcloud singleton so its lifecycle observers — the on-background
        // auto-backup and the launch catch-up — are registered from the very first launch
        // moment, not only after the user first visits a screen that references it.
        _ = NextcloudService.shared
        // People shown as their address are asked again for a .kachat name, once a minute.
        KachatNamesRegistry.shared.startUnnamedIdentitySweep()
        // The Appearance setting on every window from the first one on, not from the first
        // screen's onAppear (see `WindowAppearance`).
        WindowAppearance.install(AppSettings.load().appearance)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walletManager)
                .environmentObject(contactsManager)
                .environmentObject(chatService)
                .environmentObject(settingsViewModel)
                .environmentObject(pushManager)
                .environmentObject(groupChatService)
                .onAppear {
                    ChatService.shared.settingsViewModel = settingsViewModel
                    applyWindowAppearanceOverride()
                    if #available(iOS 16.0, macCatalyst 16.0, *) {
                        KaChatShortcutsProvider.updateAppShortcutParameters()
                    }
                }
                .onChange(of: walletManager.currentWallet?.publicAddress) { newValue in
                    guard newValue != nil else { return }
                    Task {
                        await processPendingOutboundShareIfNeeded()
                    }
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    // Universal links (https://kachat.app/u/<address>) - same router.
                    if let url = activity.webpageURL {
                        handleIncomingURL(url)
                    }
                }
                .preferredColorScheme(settingsViewModel.settings.appearance.colorScheme)
                .onChange(of: settingsViewModel.settings.appearance) { _ in
                    applyWindowAppearanceOverride()
                }
                .environment(\.locale, settingsViewModel.settings.language.locale ?? .autoupdatingCurrent)
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(to: newPhase)
        }
    }

    /// `.preferredColorScheme` only themes SwiftUI content — the UIKit layer underneath (the
    /// window background visible around sheet-presentation edges, the keyboard, share sheets,
    /// UIKit pickers) still follows the DEVICE appearance. With the app forced dark on a
    /// light-mode device, that mismatch showed as white edges peeking out around presented
    /// sheets. Overriding the windows' interface style makes the whole window chrome match.
    private func applyWindowAppearanceOverride() {
        WindowAppearance.set(settingsViewModel.settings.appearance)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                // The tab bar at the bottom kept the OLD theme's colours after a switch until
                // the app was relaunched: UIKit caches its resolved appearance and does not
                // re-resolve it for a window override change. Walking the bar and re-applying
                // the (dynamic-colour) appearance forces the repaint.
                Self.refreshTabBars(in: window.rootViewController)
            }
        }
    }

    private static func refreshTabBars(in root: UIViewController?) {
        guard let root else { return }
        var queue: [UIViewController] = [root]
        while let controller = queue.popLast() {
            if let tabs = controller as? UITabBarController {
                let appearance = UITabBarAppearance()
                appearance.configureWithDefaultBackground()
                tabs.tabBar.standardAppearance = appearance
                tabs.tabBar.scrollEdgeAppearance = appearance
                tabs.tabBar.setNeedsLayout()
                tabs.tabBar.layoutIfNeeded()
            }
            queue.append(contentsOf: controller.children)
            if let presented = controller.presentedViewController { queue.append(presented) }
        }
    }

    @MainActor
    private func handleScenePhaseChange(to newPhase: ScenePhase) {
        // No privacy cover in the App Switcher (owner's call, 2026-11-15): the app shows as it is.
        switch newPhase {
        case .background:
            // Persist any debounced message draft immediately so it survives termination.
            ChatService.shared.flushPendingDraftSave()
            // No indexer sweeping while backgrounded - the push / background fetch paths own that.
            ChatService.shared.stopForegroundContactSweep()
            ChatService.shared.stopActiveChatPollForBackground()
            GroupChatService.shared.stopLivePolling()
            ContactsManager.shared.stopProfileRescans()
            // KaPosts' in-app activity poller runs only while the app is active.
            KaPostsNotificationService.shared.stop()
            // Schedule background fetch when app goes to background
            if settingsViewModel.settings.backgroundFetchEnabled {
                BackgroundTaskManager.shared.scheduleBackgroundFetch()
            }
            // Sync contacts to shared container for notification extension
            SharedDataManager.syncContactsForExtension()
            SharedDataManager.syncWalletAddressForExtension()
            SharedDataManager.syncNotificationSettingsForExtension()
            if settingsViewModel.settings.notificationMode == .remotePush {
                ChatService.shared.pauseUtxoSubscriptionForRemotePush()
            }
            // Flush any pending read status updates to the store before backgrounding
            appDelegate.beginBackgroundFlushIfNeeded()
            ReadStatusSyncManager.shared.flushPendingUpdates()
            // And the messages themselves: a debounced save could otherwise die with the app.
            ChatService.shared.flushMessageStoreForBackground()
            // Flush the debounced chat-list snapshot write immediately too, rather than leaving
            // it in-flight for a 300ms timer that iOS could suspend the process before firing.
            ChatService.shared.chatListSnapshotPersistTask?.cancel()
            ChatService.shared.persistChatListSnapshotIfPossible()
            // Checkpoint WAL when going to background to reduce file size
            MessageStore.shared.checkpointWAL()
            // Give the async saves above a moment to actually land before releasing the
            // background task, since iOS can suspend the process as soon as it ends.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                appDelegate.endBackgroundFlushIfNeeded()
            }
        case .active:
            LaunchTrace.mark("scene active")
            // Cancel background fetch when app becomes active (we'll poll normally)
            BackgroundTaskManager.shared.cancelBackgroundFetch()
            // Foreground 1:1 indexer sweep (defense-in-depth next to the utxosChanged push and the
            // app-active catch-up sync below). No-op when no wallet is loaded yet - startPolling()
            // starts it once the wallet/store are ready.
            ChatService.shared.startForegroundContactSweep()
            // And the 2s open-chat poll, if a conversation was open when we went to background.
            ChatService.shared.resumeActiveChatPollIfNeeded()
            // The .kachat registry, for name lookups and the market.
            Task { @MainActor in await KachatNamesRegistry.shared.refreshIfStale() }
            // .kachat registrations in flight (testnet only; no-op on mainnet) resume after a
            // relaunch: commit -> wait -> register continues by itself, and a claim still in
            // progress brings its half sheet back up once (`KachatRegistrationPresenter`), as in KaPay.
            KachatNamesActions.shared.resume()
            // Group traffic from the indexer while the app is open (block stream as fallback).
            GroupChatService.shared.startLivePolling()
            ContactsManager.shared.startProfileRescans()
            // KaPosts activity (likes, replies, quotes on your posts), while the app is active.
            KaPostsNotificationService.shared.start()

            // Keep the Share Extension's data sources fresh on activation too - previously
            // contacts synced only on .background, so a fresh install that had never
            // backgrounded showed an empty contact list in the share sheet.
            SharedDataManager.syncContactsForExtension()
            SharedDataManager.syncWalletAddressForExtension()

            let isFirstActiveTransition = !hasCompletedFirstActiveTransition
            hasCompletedFirstActiveTransition = true
            // On cold launch specifically, every cache (KNS avatars, message-preview parsing,
            // image decoding) is empty, node pool/catch-up sync all kick off at once,
            // and the user is most likely to immediately start navigating around (e.g. opening a
            // chat and coming right back out) - all of that is MainActor-bound work (every
            // service here is @MainActor), so it directly competes with the user's own taps and
            // the chat list's own first-render work for the main thread's attention, which showed
            // up as a real freeze/black-screen specifically right after launch, getting harder to
            // reproduce once things warmed up. This grace period doesn't skip any of the sync
            // work below, just lets the very first render settle before it starts contending for
            // the main thread.
            let coldStartGraceNanos: UInt64 = isFirstActiveTransition ? 2_000_000_000 : 0

            let shouldRunHeavyResync = lastActiveResyncAt.map {
                Date().timeIntervalSince($0) > activeResyncDebounce
            } ?? true
            if shouldRunHeavyResync {
                lastActiveResyncAt = Date()
                // A batch of gRPC connections can die silently while backgrounded/asleep (the OS
                // tears down sockets, and the stream-completion callback that would normally
                // self-reconnect can be suspended along with the rest of the app) - reconnect any
                // that are dead right now instead of waiting for the next request to lazily discover
                // and fix just that one endpoint.
                Task {
                    if coldStartGraceNanos > 0 {
                        try? await Task.sleep(nanoseconds: coldStartGraceNanos)
                    }
                    await NodePoolService.shared.reconnectStaleConnections()
                }
            }
            // Process any messages decrypted by notification extension
            Task {
                await pushManager.processPendingMessages()
            }
            Task {
                await processPendingOutboundShareIfNeeded()
            }
            // Sync messages that may have arrived while backgrounded
            if shouldRunHeavyResync {
                Task {
                    if coldStartGraceNanos > 0 {
                        try? await Task.sleep(nanoseconds: coldStartGraceNanos)
                    }
                    // Run catch-up sync with push-reliability gating.
                    await ChatService.shared.maybeRunCatchUpSync(trigger: .appActive)

                    // One-time migration to per-device read markers (only when store is ready)
                    if MessageStore.shared.isStoreLoaded && MessageStore.shared.currentWalletAddress != nil {
                        ReadStatusSyncManager.shared.runMigrationIfNeeded()
                    }
                }
                // Own-address receive catch-up: diff spending balances against the
                // persisted baseline and notify for external receipts that landed while away
                // (internally debounced; first run only seeds the baseline).
                Task {
                    if coldStartGraceNanos > 0 {
                        try? await Task.sleep(nanoseconds: coldStartGraceNanos)
                    }
                    await AddressActivityNotifier.shared.runCatchUpIfNeeded()
                }
            }
            // Group catch-up (including "you were added to a group" control messages) runs on
            // EVERY foreground, NOT gated by the heavy-resync debounce above - otherwise a group
            // you were just added to on another device would not appear until the debounce window
            // elapsed and the app was re-activated. It is a cheap, cursor-based single round trip
            // that runs in its own task, so a newly-joined group appears within ~1 network hop.
            Task {
                await GroupChatService.shared.performCatchUpSync()
            }
            if settingsViewModel.settings.notificationMode == .remotePush {
                Task {
                    await ChatService.shared.resumeUtxoSubscriptionForRemotePush()
                }
                pushManager.refreshRegistrationIfNeeded()
            }
            SharedDataManager.syncWalletAddressForExtension()
            SharedDataManager.syncNotificationSettingsForExtension()
            SharedDataManager.syncGroupsForExtension()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func handleIncomingURL(_ url: URL) {
        // Every in-app target link - profiles and payment requests, in both their
        // `kachat://` and `https://kachat.app/...` forms - is parsed and validated in
        // ONE place (`KaChatInternalLink.parse`) and routed through ONE place
        // (`KaChatLinkRouter.open`), shared with the in-chat preview cards so a tapped card and
        // a tapped system link can never diverge.
        if let link = KaChatInternalLink.parse(url) {
            // KaPosts' Chat button: a profile link that asks for the chat (`?chat=1`) opens the
            // 1:1 chat itself rather than User Info. Older KaChat versions ignore the query and
            // show User Info, so KaPosts can send it to everyone.
            // Only for someone already known (a contact or a chat): `openChat` saves the contact
            // and the chat, and a saved contact skips Message Requests and Who Can Message You?
            // in the push extension, so a link from anywhere mustn't do that for a stranger.
            // A stranger's link opens User Info, where Open Chat is one tap (audit 2026-11-24 #20).
            if case .profile(let address) = link, KaChatLinkRouter.asksForChat(url),
               KaChatLinkRouter.isKnownChatPartner(address) {
                KaChatLinkRouter.openChat(address: address)
            } else {
                KaChatLinkRouter.open(link)
            }
            return
        }

        // KaPost's and KaPay's other links (their schemes are registered here since they retired,
        // 2026-11-21): a pre-written post opens the KaPosts composer, the market the .kachat tab's
        // Marketplace page.
        if let text = KaChatInternalLink.composeText(from: url) {
            KaPostsDeepLink.pendingComposeText = text
            NotificationCenter.default.post(name: .openKaPost, object: nil, userInfo: [:])
            return
        }
        if KaChatInternalLink.isMarketLink(url) {
            KachatDeepLink.pendingMarketplace = true
            NotificationCenter.default.post(name: .openKachatName, object: nil)
            return
        }

        // A KaPlay bot challenge (`kachatchess://bot/...`, registered here since KaPlay retired):
        // the game opens here, in the Games tab.
        if ChessBotLinks.challenge(from: url) != nil {
            ChessBotLinks.open(url)
            return
        }
        // An arcade score challenge (`kachatarcade://snake?score=...`, ARCADE.md): KaPlay opens the game.
        if ArcadeChallenge(url: url) != nil {
            ArcadeLinkRouter.open(url)
            return
        }

        guard url.scheme?.lowercased() == "kachat" else { return }

        guard url.host?.lowercased() == "share",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let shareId = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !shareId.isEmpty else {
            return
        }

        Task {
            await processPendingOutboundShareIfNeeded()
        }
    }

    /// Drains the Share Extension's outbound queue. Auto-send shares (composed and confirmed in
    /// the extension's quick-reply popup) are delivered on-chain IMMEDIATELY, with no user
    /// interaction - the extension's confirmation screen already promised "sends the moment
    /// KaChat opens". Pre-fill shares ("Edit in KaChat instead") stage the content in the chat
    /// composer. Runs on every activation and on the kachat://share deep link, so the queue is
    /// processed whether or not the extension's best-effort app-open worked.
    @MainActor
    private func processPendingOutboundShareIfNeeded() async {
        guard !isProcessingOutboundShare else { return }
        guard walletManager.currentWallet != nil else { return }

        isProcessingOutboundShare = true
        defer { isProcessingOutboundShare = false }

        SharedDataManager.pruneOutboundShares()
        // Oldest first so multiple queued messages to the same contact arrive in the order the
        // user shared them. The deep-linked share id (if any) is just one of these; processing
        // the whole queue also covers shares from earlier failed app-open attempts.
        let shares = SharedDataManager.getOutboundShares().sorted { $0.createdAtMs < $1.createdAtMs }
        guard !shares.isEmpty else { return }

        for share in shares {
            let cleanedText = share.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard share.hasSendableContent else {
                SharedDataManager.removeOutboundShare(id: share.id)
                continue
            }
            // Made while another account was signed in (or signed out): sending it from this one
            // would message that account's contact from this address. It's dropped, not sent.
            if let owner = share.walletAddress,
               let current = walletManager.currentWallet?.publicAddress,
               !WalletManager.isSameAccount(owner, current) {
                AppLog.log("[Share] Dropped a share made under another account")
                SharedDataManager.removeOutboundShare(id: share.id)
                continue
            }

            let contact = contactsManager.getContact(byAddress: share.contactAddress)
                ?? contactsManager.getOrCreateContact(address: share.contactAddress)

            chatService.pendingChatNavigation = share.contactAddress

            if share.autoSend {
                // Land in the chat so the user watches the queued message send for real -
                // pending bubble, delivery state, the works.
                NotificationCenter.default.post(
                    name: .openChat,
                    object: nil,
                    userInfo: ["contactAddress": share.contactAddress]
                )
                var textSent = false
                do {
                    if !cleanedText.isEmpty {
                        try await chatService.sendMessage(to: contact, content: cleanedText)
                        textSent = true
                    }
                    if let image = share.image {
                        try await sendSharedImage(image, to: contact)
                    }
                } catch {
                    AppLog.log("[Share] Auto-send failed for %@: %@",
                          String(share.contactAddress.suffix(10)),
                          error.localizedDescription)
                    // Don't lose what didn't go: fall back to staging it in the chat's composer
                    // so the user can retry with one tap. The image is the last send, so it's
                    // unsent whichever one threw. Text already sent isn't drafted again.
                    if !cleanedText.isEmpty && !textSent {
                        chatService.setDraft(cleanedText, for: share.contactAddress)
                    }
                    if let image = share.image,
                       let fileURL = SharedDataManager.outboundShareImageFileURL(for: image),
                       let imageData = try? Data(contentsOf: fileURL) {
                        chatService.stagePendingShareImage(imageData, for: share.contactAddress)
                    }
                    // The chat is already open from the post above, and only reads the composer
                    // pre-fill while handling this notification.
                    NotificationCenter.default.post(
                        name: .openChat,
                        object: nil,
                        userInfo: ["contactAddress": share.contactAddress]
                    )
                }
            } else {
                // Pre-fill path: land the user in the chat with the shared content staged in the
                // composer. Draft + image must be staged BEFORE posting .openChat - the notification
                // is delivered synchronously and ChatDetailView reads both while handling it.
                if !cleanedText.isEmpty {
                    chatService.setDraft(cleanedText, for: share.contactAddress)
                }
                if let image = share.image,
                   let fileURL = SharedDataManager.outboundShareImageFileURL(for: image),
                   let imageData = try? Data(contentsOf: fileURL) {
                    chatService.stagePendingShareImage(imageData, for: share.contactAddress)
                }
                NotificationCenter.default.post(
                    name: .openChat,
                    object: nil,
                    userInfo: ["contactAddress": share.contactAddress]
                )
            }

            SharedDataManager.removeOutboundShare(id: share.id)
        }
    }

    private func sendSharedImage(_ image: SharedOutboundShare.ImageAttachment, to contact: Contact) async throws {
        guard let fileURL = SharedDataManager.outboundShareImageFileURL(for: image) else {
            throw KasiaError.networkError("Could not locate shared image")
        }

        let imageData = try Data(contentsOf: fileURL)
        guard let uiImage = UIImage(data: imageData) else {
            throw KasiaError.networkError("Shared image could not be decoded")
        }

        // Sent straight from the share sheet, with no quality sheet to ask: Low (up to 0.1 KAS).
        let preparedImage = try await Task.detached(priority: .userInitiated) {
            try ImagePrep.prepareForTier(uiImage, tier: .low, forGroup: false)
        }.value
        try await chatService.sendImage(
            to: contact,
            imageData: preparedImage.data,
            fileName: preparedImage.fileName,
            mimeType: preparedImage.mimeType
        )
    }

    /// Pre-initialize heavy components to avoid lag on first user interaction
    private static func warmUp() async {
        // Warm up audio session
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])

        // Warm up crypto library with dummy operation
        let dummyKey = Data(repeating: 0x01, count: 32)
        _ = try? KasiaCipher.encrypt("warmup", recipientPublicKey: dummyKey)
    }
}

// MARK: - App Delegate for Notification and Background Task Handling
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var backgroundFlushTaskId: UIBackgroundTaskIdentifier = .invalid

    /// Orientation policy per device: iPhone is hard-locked to portrait; iPad may rotate to any
    /// orientation. This is the authoritative runtime source for supported orientations (it
    /// overrides the Info.plist keys), so iPhone never rotates into landscape regardless of the
    /// device's rotation lock setting, while iPad follows the device as usual.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    /// Requests a few extra seconds of background execution time so the debounced read-marker
    /// and snapshot writes triggered on backgrounding (both `context.perform`, not
    /// `performAndWait`, so they return before the save actually lands) get a chance to complete
    /// before iOS can suspend the process. Without this, backgrounding right after reading a chat
    /// can lose that write, resurrecting a stale "unread" position and wrong scroll anchor the
    /// next time the chat is opened.
    func beginBackgroundFlushIfNeeded() {
        endBackgroundFlushIfNeeded()
        backgroundFlushTaskId = UIApplication.shared.beginBackgroundTask(withName: "ReadStatusFlush") { [weak self] in
            self?.endBackgroundFlushIfNeeded()
        }
    }

    func endBackgroundFlushIfNeeded() {
        guard backgroundFlushTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundFlushTaskId)
        backgroundFlushTaskId = .invalid
    }

    /// No third-party keyboards anywhere in the app, as in KaPost and KaPay: the 12 or 24 words,
    /// the passphrase and the NFC card PIN are typed on the system keyboard, so a keyboard with
    /// Full Access never sees them. They're offered the system's.
    func application(_ application: UIApplication, shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        extensionPointIdentifier != .keyboard
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Task.detached(priority: .utility) { CacheManager.sweepStaleTempFiles() }
        Task.detached(priority: .utility) { RetiredFeatureCleanup.runOnce() }
        Task { await RetiredFeatureCleanup.runOnceV2() }
        RetiredFeatureCleanup.runOnceV3()
        RetiredFeatureCleanup.runOnceV4()
        RetiredFeatureCleanup.runOnceV5()
        // Set notification delegate to handle foreground notifications
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()

        // Register background task handler
        BackgroundTaskManager.shared.registerBackgroundTasks()

        // The notification extension's copy of the notification switches is refreshed on every
        // launch, so an app update can never leave it stale or missing.
        SharedDataManager.syncNotificationSettingsForExtension()

        // Security hygiene: wipe the legacy plaintext shared-secret blob older releases left
        // in the App Group plist (see SharedDataManager.purgeLegacySharedSecretsIfPresent).
        SharedDataManager.purgeLegacySharedSecretsIfPresent()

        // Warm up keyboard in background to avoid first-tap delay
        // Delay slightly to ensure scene is ready (prevents "UIScene accessed before set" warning)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.warmUpKeyboard()
        }

        return true
    }

    // MARK: - APNs Token Handling

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushNotificationManager.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            PushNotificationManager.shared.didFailToRegisterForRemoteNotifications(error: error)
        }
    }

#if targetEnvironment(macCatalyst)
    func applicationShouldTerminateAfterLastWindowClosed(_ application: UIApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        ensureMainWindow(application)
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }

        // Replace Close Window (Cmd+W) with Hide Window to keep the scene alive.
        // This avoids a full scene rebuild when the user clicks the dock icon.
        let hideCommand = UIKeyCommand(
            title: AppLocalization.string("Hide Window"),
            action: #selector(hideActiveWindow),
            input: "W",
            modifierFlags: .command
        )
        let menu = UIMenu(title: "", options: .displayInline, children: [hideCommand])
        builder.replace(menu: .close, with: menu)
    }

    @objc func hideActiveWindow() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.isHidden = true
            }
        }
    }

    private func ensureMainWindow(_ application: UIApplication) {
        // First: try to unhide any hidden windows in connected scenes (instant)
        for scene in application.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            let hiddenWindows = windowScene.windows.filter { $0.isHidden }
            if !hiddenWindows.isEmpty {
                for window in hiddenWindows {
                    window.isHidden = false
                    window.makeKeyAndVisible()
                }
                return
            }
            // Scene is connected and has visible windows — nothing to do
            if !windowScene.windows.isEmpty { return }
        }

        // No connected scene with windows — reactivate an existing session
        // (faster than creating a brand new one with nil)
        UIApplication.shared.requestSceneSessionActivation(
            application.openSessions.first,
            userActivity: nil,
            options: nil,
            errorHandler: nil
        )
    }
#endif

    /// Pre-load keyboard to avoid first-use delay
    private static func warmUpKeyboard() {
        // Guard against accessing scene before it's ready
        guard !UIApplication.shared.connectedScenes.isEmpty else {
            return
        }

        let textField = UITextField()
        textField.autocorrectionType = .no
        textField.inputAssistantItem.leadingBarButtonGroups = []
        textField.inputAssistantItem.trailingBarButtonGroups = []

        // Add to window hierarchy temporarily
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            textField.frame = CGRect(x: -100, y: -100, width: 10, height: 10)
            window.addSubview(textField)
            textField.becomeFirstResponder()

            // Remove after brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                textField.resignFirstResponder()
                textField.removeFromSuperview()
            }
        }
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        Task { @MainActor in
            let sender = userInfo["sender"] as? String
            let ourAddress = WalletManager.shared.currentWallet?.publicAddress
            let activeAddress = ChatService.shared.activeConversationAddress
            let threadId = notification.request.content.threadIdentifier
            let settings = AppSettings.load()
            // A Received KAS push the app sees is remembered, so the catch-up never posts a second
            // "Received" for its tx once it has left Notification Center (the extension doesn't
            // run for it: no mutable-content) (audit 2026-11-24 notifications).
            let isAddressActivityPush = (userInfo["type"] as? String) == "address_activity"
            if isAddressActivityPush, let txId = userInfo["tx_id"] as? String {
                InAppBanner.notePushArrived(txId)
            }
            // Notifications off in K: nothing shows, whatever the kind. Rooms and KaPost didn't
            // check it at all, and the server can still send until the registration update lands.
            // The app's own banners already checked their settings before posting (audit
            // 2026-11-24 notifications).
            guard settings.notificationsEnabled else {
                completionHandler([])
                return
            }
            // A Received KAS push for an address that no longer notifies (its switch, its Cold
            // Storage account's, or Address Activity turned off since the registration): the
            // push service can still send until the update lands (audit 2026-11-24 notifications).
            if isAddressActivityPush {
                let address = (userInfo["address"] as? String)?.lowercased() ?? ""
                let watched = Set(AddressActivityNotifier.shared.pushWatchOnlyAddresses().map { $0.lowercased() })
                guard watched.contains(address) else {
                    completionHandler([])
                    return
                }
            }
            // KaPosts and Public Chats (back since 2026-11-21, as in KaPost).
            if threadId.hasPrefix("kaposts") || threadId.hasPrefix("broadcast:") {
                completionHandler(Self.kaPostsOrRoomPresentation(notification, settings: settings))
                return
            }
            let contactAddress = sender ?? (!threadId.isEmpty ? threadId : nil)
            let contact = contactAddress.flatMap { ContactsManager.shared.getContact(byAddress: $0) }
            let isActiveConversation = activeAddress != nil &&
                (activeAddress == sender || (!threadId.isEmpty && activeAddress == threadId))
            // Group push's threadIdentifier is "group:<groupId>" (see NotificationService.swift's
            // handleGroupPush) - mirrors the 1:1 check above using GroupChatService's own
            // currently-open-group tracking (GroupChatDetailView's .task/.onDisappear), which
            // already existed for the read-state auto-mark but was never consulted here.
            let isActiveGroup = threadId.hasPrefix("group:") &&
                GroupChatService.shared.activeGroupId == String(threadId.dropFirst("group:".count))
            // The remote push is the only banner source: the app posts none of its own for the
            // messages, group traffic, rooms and KaPost activity it discovers itself (the same
            // message used to arrive as two differently-worded banners). Discovery still runs;
            // rooms the push server does not index, and anything the push service misses,
            // notify nothing - on purpose. The one rule here is about the reader: no banner for
            // the chat they are looking at.

            // Message Requests: the extension already decided (one "New message request", then
            // silence; nothing from a blocked address) - a push it emptied must not surface as a
            // blank banner, and a pending request's or blocked sender's message never rings.
            let content = notification.request.content
            let emptiedByExtension = content.title.isEmpty && content.body.isEmpty
            // A group push the notification extension never reworded (it timed out, or didn't
            // run) still has the server's raw text: the sender's address and "New group message",
            // even for a member accepting an invite, which isn't a message at all. While K is
            // open it banners the group messages it reads itself (`postInAppBanner`), so the raw
            // push is never shown (2026-11-24).
            let pushType = userInfo["type"] as? String
            let rawGroupPush = (pushType == "group_message" || pushType == "group_control")
                && !content.threadIdentifier.hasPrefix("group:")
                && content.threadIdentifier != "message_requests"
                && UIApplication.shared.applicationState == .active
            if rawGroupPush {
                completionHandler([])
                return
            }
            let fromRequestOrBlocked = contactAddress.map { address in
                ChatService.shared.isChatBlocked(address)
                    || ChatService.shared.conversations.contains { $0.contact.address == address && ChatService.shared.isMessageRequest($0) }
            } ?? false
            if emptiedByExtension || (fromRequestOrBlocked && content.threadIdentifier != "message_requests") {
                completionHandler([])
            } else if sender == ourAddress || ((isActiveConversation || isActiveGroup) && UIApplication.shared.applicationState == .active) {
                completionHandler([])
            } else if !settings.shouldDeliverIncomingNotification(for: contact) {
                completionHandler([])
            } else if (userInfo["kachat_quiet_voice_part"] as? Bool) == true {
                // A later part of a long voice note: its first part already announced it.
                completionHandler([.list])
            } else if !InAppBanner.isOwn(notification), !InAppBanner.claim(InAppBanner.txId(of: notification)) {
                // The app already bannered this message while open (`InAppBanner`).
                completionHandler([.list])
            } else {
                var options: UNNotificationPresentationOptions = [.banner, .badge]
                if settings.shouldPlayIncomingNotificationSound(for: contact) {
                    options.insert(.sound)
                } else if settings.incomingNotificationVibrationEnabled {
                    Haptics.impact(.light)
                }
                completionHandler(options)
            }
        }

        Task {
            _ = await PushNotificationManager.shared.handleRemoteNotification(userInfo)
        }
    }

    // MARK: KaPosts and Public Chats pushes (from KaPost, 2026-11-21)

    /// How a KaPosts or room push shows while the app is open: the per-kind switches, nothing
    /// while KaPosts' Notifications screen or that room is on screen, nothing from someone
    /// muted or blocked, and a long voice note's later parts listed quietly.
    @MainActor
    private static func kaPostsOrRoomPresentation(_ notification: UNNotification, settings: AppSettings) -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        let threadId = notification.request.content.threadIdentifier
        let body = notification.request.content.body
        var options: UNNotificationPresentationOptions = [.banner, .badge]
        if settings.incomingNotificationSoundEnabled {
            options.insert(.sound)
        }
        if threadId == "kaposts" {
            // The bell's count comes from the poll, which runs every 5 minutes with push on.
            KaPostsNotificationService.shared.pollSoon()
            // Nothing from someone you blocked or muted, as in the in-app count, when the push
            // names who acted (`actor_pubkey`).
            let actorHidden = (userInfo["actor_pubkey"] as? String)
                .flatMap { KaPostsAPIClient.kaspaAddress(fromPubkey: $0) }
                .map { KaPostsModerationStore.shared.isHidden($0) } ?? false
            if actorHidden
                || !kaPostsPushAllowed(userInfo: userInfo, body: body, settings: settings)
                || (UIApplication.shared.applicationState == .active
                    && KaPostsNotificationService.shared.isNotificationsScreenVisible) {
                return []
            }
            // One banner per action: a push whose action the in-app banner already showed is
            // held back (and claims it when it comes first). The app's own banners pass.
            if !notification.request.identifier.hasPrefix(KaPostsBannerLedger.localIdentifierPrefix) {
                let key = KaPostsBannerLedger.key(
                    actorPubkey: userInfo["actor_pubkey"] as? String,
                    postId: userInfo["postId"] as? String,
                    kind: KaPostsBannerLedger.kind(pushKind: userInfo["kaposts_kind"] as? String, body: body)
                )
                if !KaPostsBannerLedger.claim(key) { return [] }
            }
        } else if threadId.hasPrefix("broadcast:") {
            // No banner for the room you are reading.
            let channel = String(threadId.dropFirst("broadcast:".count))
            if UIApplication.shared.applicationState == .active,
               PublicChatService.shared.isViewing(channel: channel) {
                return []
            }
            // Nothing for a room that was deleted, muted or switched off: the push service
            // can still send for it until the registration update lands. Except a push that @'s
            // you (`mention: true`, INDEXER_HANDOFF.md 2026-11-24): the indexer sends those
            // whatever the bell, as the extension shows them (audit 2026-11-24 notifications).
            guard let room = KaChatInternalLink.normalizeAndValidateChannel(channel),
                  PublicChatService.shared.wantsRoomPush(channel: room)
                    || (isTrue(userInfo["mention"])
                        && !PublicChatService.serviceChannels.contains(PublicChatChannelName.normalize(room))) else {
                return []
            }
            // The app already bannered this message while open (`InAppBanner`).
            if !InAppBanner.isOwn(notification), !InAppBanner.claim(InAppBanner.txId(of: notification)) {
                return [.list]
            }
            // A long voice note's later parts: listed, no banner or sound.
            if RoomVoicePushBursts.isLaterPart(
                threadId: threadId,
                sender: notification.request.content.subtitle,
                body: body,
                identifier: notification.request.identifier
            ) {
                return [.list]
            }
        }
        if !options.contains(.sound), settings.incomingNotificationVibrationEnabled {
            Haptics.impact(.light)
        }
        return options
    }

    /// A push flag as the server may send it: a bool, a number or "true" / "1" (the extension's
    /// `isTrue`).
    private static func isTrue(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.intValue != 0 }
        if let text = value as? String { return text.lowercased() == "true" || text == "1" }
        return false
    }

    /// Which KaPosts pushes the reader still wants shown, by the Settings switches.
    ///
    /// `kaposts_kind` is the field the server should send; failing that the body is matched
    /// against the exact English phrases PUSH_EXTENSIONS.md §3 specifies - server-generated and
    /// unlocalized, so a fixed set. An unrecognised push is shown rather than swallowed.
    static func kaPostsPushAllowed(userInfo: [AnyHashable: Any], body: String, settings: AppSettings) -> Bool {
        let key: String
        if let explicit = userInfo["kaposts_kind"] as? String {
            switch explicit {
            case "vote_up": key = "likes"
            case "vote_down": key = "dislikes"
            case "reply": key = "comments"
            case "quote", "repost": key = "reposts"
            case "follow": key = "follows"
            case "mention": key = "mentions"
            default: return true
            }
        } else {
            let lowered = body.lowercased()
            if lowered.contains("disliked your") { key = "dislikes" }
            else if lowered.contains("liked your") { key = "likes" }
            else if lowered.contains("replied to your") { key = "comments" }
            else if lowered.contains("quoted your") || lowered.contains("reposted your") { key = "reposts" }
            else if lowered.contains("followed you") { key = "follows" }
            else if lowered.contains("mentioned you") { key = "mentions" }
            else { return true }
        }
        switch key {
        case "likes": return settings.kaPostsNotifyLikes
        case "dislikes": return settings.kaPostsNotifyDislikes
        case "comments": return settings.kaPostsNotifyComments
        case "reposts": return settings.kaPostsNotifyReposts
        case "follows": return settings.kaPostsNotifyFollows
        case "mentions": return settings.kaPostsNotifyMentions
        default: return true
        }
    }

    /// A reply or quote push opens the reply or quote itself - the same target the in-app banners
    /// use. The push's `postId` is the post it was made ON (PUSH_EXTENSIONS.md), and opening that
    /// left you on your own post waiting for the indexer to list the new reply. The action's txid
    /// is the push's `apns-collapse-id`, which iOS gives us as the request identifier; the thread
    /// opens on its parent with the reply already in it (`openResolvedPost`).
    static func kaPostsPushOpensAction(userInfo: [AnyHashable: Any], body: String) -> Bool {
        if let explicit = userInfo["kaposts_kind"] as? String {
            return explicit == "reply" || explicit == "quote"
        }
        let lowered = body.lowercased()
        return lowered.contains("replied to your") || lowered.contains("quoted your")
    }

    private static func isTxId(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    /// A tapped room push opens the room only while it is in the list: a room deleted since (or
    /// never joined here) is not joined back by a tap. On a cold start the account's rooms are
    /// still loading, so this waits for them (up to 10 s) before deciding.
    @MainActor
    private static func openRoomFromPush(_ channel: String, attemptsLeft: Int = 20) {
        let service = PublicChatService.shared
        guard service.isStoreReady else {
            guard attemptsLeft > 0 else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                openRoomFromPush(channel, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        guard service.channels.contains(where: { $0.channelName == channel }) else {
            AppLog.log("%@", "[Push] Ignored a tap on a push for a room that isn't joined")
            return
        }
        // Pending for a cold start, and the room's newest rows asked for right away: the
        // announced message is not in the store yet.
        service.pendingPublicChatNavigation = channel
        NotificationCenter.default.post(name: .openPublicChat, object: nil, userInfo: ["channel": channel])
        Task { @MainActor in
            await service.refreshFromIndexerNow(channel: channel)
        }
    }

    // MARK: Quick reply (iPhone notification actions + Apple Watch)

    /// Category attached to every actionable message notification (1:1 and group, local and
    /// push). The text-input action gives iPhone its inline quick-reply field and Apple Watch
    /// its Reply button with dictation/scribble - no watch app needed, mirrored notifications
    /// inherit the actions automatically.
    static let messageCategoryId = "KACHAT_MESSAGE"
    static let replyActionId = "KACHAT_REPLY"

    private func registerNotificationCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionId,
            title: AppLocalization.string("Reply"),
            // A reply sends from the owner's address and pays its fee: the phone must be
            // unlocked first. An unlocked Apple Watch on the wrist still replies directly.
            options: [.authenticationRequired],
            textInputButtonTitle: AppLocalization.string("Send"),
            textInputPlaceholder: AppLocalization.string("Message")
        )
        let category = UNNotificationCategory(
            identifier: Self.messageCategoryId,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private enum QuickReplyError: Error {
        case noWallet
        case unknownTarget
    }

    /// Sends a quick-reply without any UI: iOS launches the app into the background for the
    /// action, so grab background time, make sure the wallet is loaded (keychain material is
    /// AfterFirstUnlock, so this works from the lock screen), and route by thread id. On any
    /// failure, post a notification so the reply isn't silently lost.
    private func handleQuickReply(
        text: String,
        threadIdentifier: String,
        completionHandler: @escaping () -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completionHandler()
            return
        }
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "kachat.quickreply") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        Task { @MainActor in
            defer {
                completionHandler()
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
            do {
                if WalletManager.shared.currentWallet == nil {
                    await WalletManager.shared.loadWallet()
                }
                guard WalletManager.shared.currentWallet != nil else { throw QuickReplyError.noWallet }
                if threadIdentifier.hasPrefix("group:") {
                    let groupId = String(threadIdentifier.dropFirst("group:".count))
                    guard !groupId.isEmpty else { throw QuickReplyError.unknownTarget }
                    try await GroupChatService.shared.sendGroupMessage(trimmed, to: groupId)
                } else if !threadIdentifier.isEmpty,
                          let contact = ContactsManager.shared.getContact(byAddress: threadIdentifier) {
                    _ = ChatService.shared.getOrCreateConversation(for: contact)
                    try await ChatService.shared.sendMessage(to: contact, content: trimmed)
                } else {
                    throw QuickReplyError.unknownTarget
                }
            } catch {
                AppLog.log("%@", "[QuickReply] Send failed: \(error.localizedDescription)")
                postQuickReplyFailureNotification(threadIdentifier: threadIdentifier)
            }
        }
    }

    private func postQuickReplyFailureNotification(threadIdentifier: String) {
        let content = UNMutableNotificationContent()
        content.title = AppLocalization.string("Reply not sent")
        content.body = AppLocalization.string("Your reply couldn't be sent. Open K to try again.")
        content.sound = .default
        content.threadIdentifier = threadIdentifier
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "quickreply-fail-\(UUID().uuidString)", content: content, trigger: nil)
        )
    }

    // Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task {
            _ = await PushNotificationManager.shared.handleRemoteNotification(
                response.notification.request.content.userInfo
            )
        }
        // The threadIdentifier contains the contact address, or "group:<groupId>" for a group
        // chat notification.
        let threadIdentifier = response.notification.request.content.threadIdentifier

        // The scheduled-post reminder (local fallback): into KaPosts, which sends what is due
        // and shows the Scheduled screen.
        if threadIdentifier == "kaposts-scheduled" {
            KaPostsDeepLink.pendingOpenScheduled = true
            NotificationCenter.default.post(name: .openKaPost, object: nil, userInfo: [:])
            completionHandler()
            return
        }

        // KaPosts push (thread-id "kaposts"): straight to the post when the payload names one,
        // else the Notifications screen (from KaPost).
        if threadIdentifier == "kaposts" {
            let userInfo = response.notification.request.content.userInfo
            let body = response.notification.request.content.body
            let actionId = response.notification.request.identifier
            if Self.kaPostsPushOpensAction(userInfo: userInfo, body: body), Self.isTxId(actionId) {
                // A reply or a quote: open it, not the post it was made on.
                KaPostsDeepLink.pendingPostTxId = actionId.lowercased()
            } else if let postId = userInfo["postId"] as? String, Self.isTxId(postId) {
                // Only a transaction id: the payload is the push service's word, not ours.
                KaPostsDeepLink.pendingPostTxId = postId.lowercased()
            } else {
                // naming no post: the Notifications screen, behind Profile's bell
                NotificationsRoute.pending = true
                NotificationCenter.default.post(name: .openAllNotifications, object: nil)
                completionHandler()
                return
            }
            NotificationCenter.default.post(name: .openKaPost, object: nil, userInfo: [:])
            completionHandler()
            return
        }

        // A room push: the room, while it is in the list.
        if threadIdentifier.hasPrefix("broadcast:") {
            // Through the same gate as a room link's name, before it can open anything.
            if let channel = KaChatInternalLink.normalizeAndValidateChannel(
                String(threadIdentifier.dropFirst("broadcast:".count))
            ) {
                Task { @MainActor in Self.openRoomFromPush(channel) }
            }
            completionHandler()
            return
        }

        // A .kachat name event (an offer, a sale, a renewal reminder: the push's `name_event` or
        // a local reminder on thread "kachat-names"): the .kachat section, wherever it lives.
        // `PendingTabRoute` covers the cold start.
        if threadIdentifier == "kachat-names"
            || (response.notification.request.content.userInfo["type"] as? String) == "name_event" {
            PendingTabRoute.pending = .kachatNames
            NotificationCenter.default.post(name: .openKachatName, object: nil)
            completionHandler()
            return
        }

        // A Received KAS push (`address_activity`, thread "funds:<address>"): that address's
        // history, as the app's own notice opens it; a Cold Storage address opens Wallet.
        if threadIdentifier.hasPrefix("funds:")
            || (response.notification.request.content.userInfo["type"] as? String) == "address_activity" {
            let address = (response.notification.request.content.userInfo["address"] as? String)
                ?? String(threadIdentifier.dropFirst("funds:".count))
            // The tapped push leaves Notification Center: remembered, so the catch-up that runs
            // as K opens doesn't announce the same tx again (audit 2026-11-24 notifications).
            if let txId = response.notification.request.content.userInfo["tx_id"] as? String {
                InAppBanner.notePushArrived(txId)
            }
            Task { @MainActor in
                if AddressActivityNotifier.shared.opensHistory(for: address) {
                    OwnAddressRoute.pending = address
                    NotificationCenter.default.post(name: .openOwnAddress, object: nil)
                } else {
                    PendingTabRoute.pending = .wallet
                    NotificationCenter.default.post(name: .openProfile, object: nil)
                }
            }
            completionHandler()
            return
        }

        // Own-address activity (a spending address received Kaspa) notification tapped: these
        // are wallet events, not chats - the thread id must never fall through to the
        // contact-address branch below (it would stage a bogus pendingChatNavigation). A receipt
        // lands on Wallet, which shows the addresses and balances. `PendingTabRoute`
        // covers the cold start, where the post below has no observer yet.
        // A "Received kUSDT" notification: that token's Manage screen, on the Wallet tab.
        // `TokenRoute` and `PendingTabRoute` cover the cold start, where the posts have no
        // observer yet.
        if threadIdentifier == TokenWallet.notificationThread {
            let token = response.notification.request.content.userInfo["token"] as? String
            Task { @MainActor in
                TokenRoute.pending = token ?? WalletToken.kusdt.id
                PendingTabRoute.pending = .wallet
                NotificationCenter.default.post(name: .openProfile, object: nil)
                NotificationCenter.default.post(name: .openToken, object: nil)
            }
            completionHandler()
            return
        }

        if threadIdentifier == AddressActivityNotifier.notificationThreadIdentifier {
            if let address = response.notification.request.content.userInfo["address"] as? String, !address.isEmpty {
                // One address got the Kaspa: open that address's history (chatting or spending -
                // MainTabView works out which).
                OwnAddressRoute.pending = address
                NotificationCenter.default.post(name: .openOwnAddress, object: nil)
            } else {
                PendingTabRoute.pending = .wallet
                NotificationCenter.default.post(name: .openProfile, object: nil)
            }
            completionHandler()
            return
        }

        // Quick reply: send straight from the notification (long-press on iPhone, Reply on
        // Apple Watch) without opening the app UI.
        if response.actionIdentifier == Self.replyActionId,
           let textResponse = response as? UNTextInputNotificationResponse {
            handleQuickReply(
                text: textResponse.userText,
                threadIdentifier: threadIdentifier,
                completionHandler: completionHandler
            )
            return
        }
        if threadIdentifier.hasPrefix("group:") {
            let groupId = String(threadIdentifier.dropFirst("group:".count))
            if !groupId.isEmpty {
                // Store pending navigation for cold start scenario
                Task { @MainActor in
                    GroupChatService.shared.pendingGroupNavigation = groupId
                }

                // Also post notification for already-running views
                NotificationCenter.default.post(
                    name: .openGroup,
                    object: nil,
                    userInfo: ["groupId": groupId]
                )
            }
        } else if threadIdentifier == "group_requests" || threadIdentifier == "message_requests" {
            // An invite, or a first message from someone new: both are answered in Message
            // Requests, on Chats. Neither is a contact address, so the last branch can't take them.
            Task { @MainActor in
                GroupChatService.shared.pendingGroupListNavigation = true
                GroupChatService.shared.pendingMessageRequestsOpen = true
            }
            NotificationCenter.default.post(name: .openGroup, object: nil, userInfo: [:])
        } else if threadIdentifier == "group" {
            // Undecryptable group push: NotificationService's `deliverGroupFallback` can only
            // tag it with the bare "group" thread id (it never learned WHICH group), so there's
            // no room to open. Land on the chat list - the branch below would otherwise treat
            // "group" as a contact address and go nowhere at all.
            Task { @MainActor in
                GroupChatService.shared.pendingGroupListNavigation = true
            }
            NotificationCenter.default.post(name: .openGroup, object: nil, userInfo: [:])
        } else if !threadIdentifier.isEmpty {
            let contactAddress = threadIdentifier
            // Store pending navigation for cold start scenario
            Task { @MainActor in
                ChatService.shared.pendingChatNavigation = contactAddress
            }

            // Also post notification for already-running views
            NotificationCenter.default.post(
                name: .openChat,
                object: nil,
                userInfo: ["contactAddress": contactAddress]
            )
        } else {
            // No thread id at all - a server push that predates (or drops) the thread-id
            // contract. Nothing to route by, so land on the main Chats screen rather than
            // leaving the user wherever the app happened to be.
            NotificationCenter.default.post(name: .openChat, object: nil, userInfo: [:])
        }
        completionHandler()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let handled = await PushNotificationManager.shared.handleRemoteNotification(userInfo)
            completionHandler(handled ? .newData : .noData)
        }
    }
}

/// Cold-start handoff for a notification tap whose whole destination IS a dock tab (wallet
/// receipts). The `.openProfile` post those taps make is delivered synchronously to whoever is
/// listening RIGHT THEN - on a cold start that is nobody, since the app is still on the
/// loading/onboarding route and `MainTabView` hasn't mounted. It consumes this on mount instead
/// (`consumePendingNotificationRoute`); the destinations that carry their own pending state
/// (chat, group) don't need it.
enum PendingTabRoute {
    static var pending: AppTab?
}

/// The token a tapped "Received" token notification opens (`TokenManageView`), for the Wallet tab
/// to take. Survives a cold start, where the post has no observer yet.
enum TokenRoute {
    static var pending: String?
}

/// Public Chats and KaPosts left the app on 2026-10-24 (`runOnce`), then the wallet features
/// (`runOnceV2`). What Public Chats and KaPosts kept on this phone - each
/// account's public room history (its own SQLite file) and the KaPosts drafts, follows, mutes and
/// read markers in UserDefaults - is deleted once, so nothing of them lingers on disk.
enum RetiredFeatureCleanup {
    private static let doneKey = "kachat_retired_features_cleaned_v1"

    /// Once deleted what Public Chats and KaPosts kept on the phone (they left on 2026-10-24).
    /// Since 2026-11-21 KaChat is the all-in-one app again and both are coming back, so it deletes
    /// nothing: their settings and each account's public room store (`KaChatBroadcasts-*.sqlite`,
    /// possibly already open by then) are theirs to use. It only marks itself done.
    static func runOnce() {
        UserDefaults.standard.set(true, forKey: doneKey)
    }

    private static let doneKeyV2 = "kachat_retired_features_cleaned_v2"
    /// Once deleted the data of Portfolio, Cold Storage, Swap, the .kachat market and the old
    /// customizable dock (they left on 2026-10-24). Since 2026-11-21 KaChat is the all-in-one app
    /// again and those features are back, so it deletes only what stays retired: the old Home
    /// Screen widget's snapshot. Swap is back too (2026-11-23), so its `kachat_swap_*` history and
    /// agreements are kept (audit 2026-11-24). (The old dock keys were `kachat_dock_*`, which the
    /// new `DockLayout` keys would also match, so they're left alone too.)
    private static let defaultsPrefixesV2: [String] = []

    static func runOnceV2() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKeyV2) else { return }
        for key in defaults.dictionaryRepresentation().keys where defaultsPrefixesV2.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
        UserDefaults(suiteName: SharedDataManager.appGroupIdentifier)?.removeObject(forKey: "kachat_portfolio_widget_store")
        defaults.set(true, forKey: doneKeyV2)
    }

    private static let doneKeyV3 = "kachat_retired_features_cleaned_v3"

    /// Simple Mode left on 2026-10-24: its Keychain password record, its attempt counters and the
    /// onboarding's "Who will use KaChat?" marker go once.
    static func runOnceV3() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKeyV3) else { return }
        try? KeychainService.shared.deleteChildModePasswordRecord()
        for key in ["kachat_simple_mode_failed_attempts", "kachat_simple_mode_locked_until", "kachat_user_type_choice_state"] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: doneKeyV3)
    }

    private static let doneKeyV4 = "kachat_retired_features_cleaned_v4"

    /// Voice and video calls left on 2026-11-11: the per-contact list of who could call, shared
    /// with the extensions, the handled call ids and each account's Nextcloud Talk check go once.
    /// The call-ringing push token is dropped by `PushNotificationManager` on load.
    static func runOnceV4() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKeyV4) else { return }
        UserDefaults(suiteName: SharedDataManager.appGroupIdentifier)?.removeObject(forKey: "call_contacts")
        for key in defaults.dictionaryRepresentation().keys
        where key == "kachat_calls_handled_ids" || key.hasPrefix("kachat_nextcloud_talk_calls") {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: doneKeyV4)
    }

    private static let doneKeyV5 = "kachat_retired_features_cleaned_v5"

    /// Coin labels Cold Storage kept (`kachat_cold_storage_utxo_labels_`) move once into the store
    /// Rename UTXO writes and Coin Control reads (`WalletManager.spendingUtxoLabelsKey`). Same
    /// format, a JSON `"txId:index"` -> name map per address; a name given since wins.
    static func runOnceV5() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKeyV5) else { return }
        let prefix = "kachat_cold_storage_utxo_labels_"
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            let target = WalletManager.spendingUtxoLabelsKey(for: String(key.dropFirst(prefix.count)))
            if let data = value as? Data,
               let old = try? JSONDecoder().decode([String: String].self, from: data) {
                var merged = defaults.data(forKey: target)
                    .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
                merged.merge(old.filter { !$0.value.isEmpty }) { current, _ in current }
                guard let encoded = try? JSONEncoder().encode(merged) else { continue }
                defaults.set(encoded, forKey: target)
            }
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: doneKeyV5)
    }
}

/// The own address a tapped "Received" notification points at, for MainTabView to open (its
/// History tab). Survives a cold start, where the post below has no observer yet.
enum OwnAddressRoute {
    static var pending: String?
}

/// The single place an already-validated `KaChatInternalLink` becomes navigation. Used by the
/// system URL router (`KaChatApp.handleIncomingURL`, for links tapped outside the app) AND by
/// the in-chat preview cards (`KaChatInternalLinkCardView`), so a link opens the same screen
/// whichever way the user reached it - and never bounces out to Safari for an in-app target.
enum KaChatLinkRouter {
    /// Any URL a user taps inside the app: a KaChat link (kachat.app or the kachat:// scheme) goes straight to its profile or payment request; everything else leaves the
    /// app as usual. The one call every "Open" button should make.
    @MainActor
    static func openAnywhere(_ url: URL, fromChat: Bool = false) {
        if let link = KaChatInternalLink.parse(url) {
            open(link, fromChat: fromChat)
            return
        }
        guard isSafeExternalLink(url) else {
            AppLog.log("[Links] refused to open a %@ link from content", url.scheme ?? "schemeless")
            return
        }
        UIApplication.shared.open(url)
    }

    /// Links that other people's content (messages, posts, KNS profiles) may open outside the
    /// app: the web and email. Anything else - `shortcuts://run-shortcut`, another wallet's
    /// deep link, `itms-services://`, `tel:` - stays inert, since the text detectors happily
    /// link every scheme and one tap would run it.
    static func isSafeExternalLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "mailto"
    }

    @MainActor
    static func open(_ link: KaChatInternalLink, fromChat: Bool = false) {
        switch link {
        case .profile(let address):
            openProfile(address: address)
        case .paymentRequest(let request):
            openPaymentRequest(request, fromChat: fromChat)
        case .kaPost(let txId):
            // KaPosts is back in KaChat (2026-11-21): the post opens in the feed.
            guard !txId.isEmpty else { return }
            KaPostsDeepLink.pendingPostTxId = txId
            NotificationCenter.default.post(name: .openKaPost, object: nil, userInfo: ["txId": txId])
        case .publicChatRoom(let channel):
            openPublicChatRoom(channel: channel)
        }
    }

    /// A payment request, from a chat or anywhere else, is paid right here (since 2026-11-21: KaPay
    /// is retired): Send Kaspa with it filled in. Your own shows it (amount, memo, the address it
    /// pays into) with its link to copy or share again (`PaymentRequestSheetPresenter`, in
    /// `MainTabView`).
    @MainActor
    static func openPaymentRequest(_ request: PaymentRequest, fromChat: Bool = false) {
        PaymentRequestRouter.shared.pending = request
    }

    /// A profile link carrying `chat=1` (KaPosts' Chat button).
    static func asksForChat(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name.lowercased() == "chat" && $0.value == "1" } ?? false
    }

    /// A saved contact or someone with a conversation here: a `?chat=1` link may open their chat
    /// straight away (audit 2026-11-24 #20).
    @MainActor
    static func isKnownChatPartner(_ address: String) -> Bool {
        let normalized = address.lowercased()
        if ContactsManager.shared.contacts.contains(where: { $0.address.lowercased() == normalized }) { return true }
        return ChatService.shared.conversations.contains { $0.contact.address.lowercased() == normalized }
    }

    /// Opens (or starts) the 1:1 chat with `address` - the route the Addresses screen's Chat
    /// takes. Your own address has no chat with itself, so it shows your User Info instead.
    @MainActor
    static func openChat(address: String) {
        let normalized = address.lowercased()
        guard KaspaAddress.isValidOnActiveNetwork(normalized) else { return }
        guard normalized != WalletManager.shared.currentWallet?.publicAddress.lowercased() else {
            openProfile(address: normalized)
            return
        }
        let contact = ContactsManager.shared.getOrCreateContact(address: normalized)
        _ = ChatService.shared.getOrCreateConversation(for: contact)
        // Pending first, for a cold start where the chat list isn't up to hear the post yet.
        ChatService.shared.pendingChatNavigation = contact.address
        NotificationCenter.default.post(name: .openChat, object: nil, userInfo: ["contactAddress": contact.address])
    }

    /// Someone's profile link - yours included - opens their User Info, from which Open Chat is
    /// one tap (see `ChatListView.openPendingProfile`).
    @MainActor
    private static func openProfile(address: String) {
        let normalized = address.lowercased()
        guard KaspaAddress.isValid(normalized) else { return }
        // User Info, for anyone - yourself included (your own link shows your own card: name,
        // avatar, KNS profile, address, Share). The same screen a chat header or a group roster
        // opens, with Open Chat on it for anyone else, and their name and
        // avatar to check who the link is for before writing to them.
        let chatService = ChatService.shared
        let known = ContactsManager.shared.contacts.first { $0.address.lowercased() == normalized }?.address
            ?? chatService.conversations.first { $0.contact.address.lowercased() == normalized }?.contact.address
        chatService.pendingProfileAddress = known ?? normalized
        NotificationCenter.default.post(name: .openChat, object: nil, userInfo: [:])
    }

    // MARK: Public Chats rooms (from KaPost, 2026-11-21)

    @MainActor
    private static func openPublicChatRoom(channel: String, attemptsLeft: Int = 20) {
        // Re-validated here, the last gate before a name from a pasted link can create a row.
        guard let normalized = KaChatInternalLink.normalizeAndValidateChannel(channel) else { return }
        let service = PublicChatService.shared
        // Curated rooms always exist, and one already on the list needs nothing. Anything else
        // joins the user's own list first, as if typed into "Join or Create a Channel", once
        // they say so: any app or post can hand over a link, and the name is whatever it likes.
        let curated = PublicChatService.curatedChannels.contains(normalized)
        // On a cold start `channels` is empty until the account's store opens, so a room already
        // joined would be offered again: wait for the store (up to 10 s, as `openRoomFromPush`).
        if !curated, !service.isStoreReady, attemptsLeft > 0 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                openPublicChatRoom(channel: normalized, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        let listed = curated || service.channels.contains { $0.channelName == normalized }
        guard listed else {
            confirmJoin(normalized) {
                // The store may have opened while the alert was up.
                if !PublicChatService.shared.channels.contains(where: { $0.channelName == normalized }) {
                    PublicChatService.shared.joinChannel(normalized)
                }
                navigateToPublicChatRoom(normalized)
            }
            return
        }
        navigateToPublicChatRoom(normalized)
    }

    @MainActor
    private static func navigateToPublicChatRoom(_ normalized: String) {
        PublicChatService.shared.pendingPublicChatNavigation = normalized
        NotificationCenter.default.post(name: .openPublicChat, object: nil, userInfo: ["channel": normalized])
    }

    /// Asks before a link adds a room. Waits a few seconds for a window on a cold start.
    @MainActor
    private static func confirmJoin(_ normalized: String, attemptsLeft: Int = 10, onJoin: @escaping @MainActor () -> Void) {
        guard let presenter = topViewController() else {
            guard attemptsLeft > 0 else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                confirmJoin(normalized, attemptsLeft: attemptsLeft - 1, onJoin: onJoin)
            }
            return
        }
        let title = String(format: AppLocalization.string("Join #%@?"), normalized)
        var message = AppLocalization.string("A link wants to add this room to your Public Chats.")
        if hasMixedScripts(normalized) {
            message += "\n\n" + AppLocalization.string("This name mixes letters from different alphabets, so it may be imitating another room.")
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: AppLocalization.string("Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: AppLocalization.string("Join"), style: .default) { _ in
            Task { @MainActor in onJoin() }
        })
        presenter.present(alert, animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        let window = scene?.windows.first(where: \.isKeyWindow)
            ?? scene?.windows.first { !$0.isHidden && $0.windowLevel == .normal }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// Letters from more than one of the alphabets that share look-alike shapes, the way a
    /// Cyrillic "а" passes for a Latin "a" in a well-known room's name.
    private static func hasMixedScripts(_ name: String) -> Bool {
        var seen = Set<String>()
        for scalar in name.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: seen.insert("latin")
            case 0x370...0x3FF, 0x1F00...0x1FFF: seen.insert("greek")
            case 0x400...0x52F, 0x2DE0...0x2DFF, 0xA640...0xA69F: seen.insert("cyrillic")
            case 0x530...0x58F: seen.insert("armenian")
            case 0x13A0...0x13FF, 0xAB70...0xABBF: seen.insert("cherokee")
            default: break
            }
        }
        return seen.count > 1
    }
}

/// Cold-start handoff for KaPosts links and notification taps - the notification alone is lost
/// if KaPostsView isn't mounted yet.
enum KaPostsDeepLink {
    static var pendingPostTxId: String?
    /// The scheduled-post reminder tapped - open the Scheduled screen on mount.
    static var pendingOpenScheduled = false
    /// Someone's KaPosts profile, asked for from another tab (a Public Chats member, a link).
    static var pendingProfileAddress: String?
    /// A pre-written post from another app, for the new-post composer.
    static var pendingComposeText: String?
}

extension Notification.Name {
    static let openChat = Notification.Name("openChat")
    /// A wallet receipt was tapped: the Wallet tab.
    static let openProfile = Notification.Name("openProfile")
    /// A "Received" notification for one of your addresses was tapped: `OwnAddressRoute.pending`.
    static let openOwnAddress = Notification.Name("openOwnAddress")
    /// A token's Manage screen (a "Received kUSDT" notification): `TokenRoute.pending` names it.
    static let openToken = Notification.Name("openToken")
    static let openGroup = Notification.Name("openGroup")
    /// A KaPosts post or notification: the KaPosts tab (`KaPostsDeepLink` says what to open).
    static let openKaPost = Notification.Name("openKaPost")
    /// Someone's KaPosts profile: `KaPostsDeepLink.pendingProfileAddress`.
    static let openKaPostsProfile = Notification.Name("openKaPostsProfile")
    /// A Public Chats room: `PublicChatService.pendingPublicChatNavigation`.
    static let openPublicChat = Notification.Name("openBroadcast")
}

/// KaChat's burst rule for parts of a long voice note or a multi-part photo, for room pushes (KaChat CLAUDE.md, "Parts
/// arrive as bare txIds"). The indexer pushes every part of a long voice note as its own
/// "Voice message", and the extension can't read a room push's part tag. So a voice
/// push from the same sender in the same room within 60 seconds of the last one is a later part:
/// it is listed without a banner, sound or badge, and the quiet entry before it is removed,
/// leaving the first banner and one quiet entry per note. Two separate voice messages from one
/// sender within a minute ring once; the room still shows both.
///
/// Banners the app posts itself while it is open (owner, 2026-11-22, after a TestFlight build
/// showed none in the app: "same should happen for messages I get in one-on-one chats, public
/// chats or group chats"). The app finds a new 1:1, group or room message on its own, through its
/// subscription, sweeps and polls, and banners it at once, so nothing waits on the push service.
/// One banner per message: the app's banner is skipped when that message's push is already in
/// Notification Center, and a push arriving after the app's banner is held back in `willPresent`
/// (`claim`). Only while the app is active; in the background and when closed, pushes alone.
@MainActor
enum InAppBanner {
    /// Marks the app's own banners, so `willPresent` lets them through.
    static let userInfoKey = "kachat_in_app_banner"
    /// A message older than this when the app finds it gets no banner: it's catch-up, not news.
    static let maxAgeMs: Int64 = 3 * 60 * 1000
    private static let window: TimeInterval = 15 * 60
    private static var claimed: [String: Date] = [:]

    /// True the first time a message (its txid) is claimed in the window.
    static func claim(_ txId: String) -> Bool {
        let key = txId.lowercased()
        guard !key.isEmpty else { return true }
        let now = Date()
        claimed = claimed.filter { now.timeIntervalSince($0.value) < window }
        guard claimed[key] == nil else { return false }
        claimed[key] = now
        return true
    }

    /// Whether a message with this block time (ms; 0 = not in a block yet) is recent enough.
    static func isRecent(blockTimeMs: Int64) -> Bool {
        guard blockTimeMs > 0 else { return true }
        return Int64(Date().timeIntervalSince1970 * 1000) - blockTimeMs <= maxAgeMs
    }

    /// Whether a push for this key already reached the phone (the notification extension's
    /// `recordPushArrival` ledger in the App Group): its txid, a room push's collapse id, or
    /// `kaposts:` + `KaPostsBannerLedger.key`. Covers the push you tapped to open the app, which
    /// is gone from Notification Center by the time the app looks there.
    nonisolated static func pushArrived(_ key: String) -> Bool {
        let lowered = key.lowercased()
        guard !lowered.isEmpty,
              let ledger = UserDefaults(suiteName: SharedDataManager.appGroupIdentifier)?
                .dictionary(forKey: "push_arrivals_v1") as? [String: Double],
              let at = ledger[lowered] else { return false }
        return Date().timeIntervalSince1970 - at < 30 * 60
    }

    /// Records a push the app itself saw (`willPresent`, or a tap) in the same ledger, for the
    /// pushes the extension never sees: `address_activity` comes without mutable-content, so
    /// nothing recorded it, and once it left Notification Center the catch-up posted a second
    /// "Received" for the same tx (audit 2026-11-24 notifications). Same window and cap as the
    /// extension's `recordPushArrival`.
    nonisolated static func notePushArrived(_ key: String) {
        let lowered = key.lowercased()
        guard !lowered.isEmpty,
              let defaults = UserDefaults(suiteName: SharedDataManager.appGroupIdentifier) else { return }
        let now = Date().timeIntervalSince1970
        var ledger = (defaults.dictionary(forKey: "push_arrivals_v1") as? [String: Double]) ?? [:]
        ledger = ledger.filter { now - $0.value < 30 * 60 }
        ledger[lowered] = now
        if ledger.count > 500 {
            let keep = ledger.sorted { $0.value > $1.value }.prefix(500)
            ledger = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        defaults.set(ledger, forKey: "push_arrivals_v1")
    }

    /// Whether a local push banner is a message's own.
    static func isOwn(_ notification: UNNotification) -> Bool {
        (notification.request.content.userInfo[userInfoKey] as? Bool) == true
    }

    /// The txid a push names: `tx_id` for chats and groups, else the request's id (a room push's
    /// `apns-collapse-id` is the message's txid).
    static func txId(of notification: UNNotification) -> String {
        (notification.request.content.userInfo["tx_id"] as? String) ?? notification.request.identifier
    }

    /// Posts the banner now, once per txid, only while the app is active, and not when the
    /// message's push is already showing.
    static func post(
        txId: String,
        title: String,
        subtitle: String? = nil,
        body: String,
        threadIdentifier: String,
        categoryIdentifier: String? = nil,
        sound: Bool
    ) {
        guard UIApplication.shared.applicationState == .active, !txId.isEmpty else { return }
        guard !pushArrived(txId), claim(txId) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.threadIdentifier = threadIdentifier
        if let categoryIdentifier { content.categoryIdentifier = categoryIdentifier }
        content.sound = sound ? .default : nil
        content.userInfo = [userInfoKey: true, "tx_id": txId]
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let lowered = txId.lowercased()
            let alreadyShown = delivered.contains { note in
                note.request.identifier.lowercased() == lowered
                    || (note.request.content.userInfo["tx_id"] as? String)?.lowercased() == lowered
            }
            guard !alreadyShown else { return }
            center.add(UNNotificationRequest(identifier: txId, content: content, trigger: nil)) { error in
                if let error {
                    AppLog.log("[InAppBanner] Failed: %@", error.localizedDescription)
                }
            }
        }
    }
}

/// This only runs while KaChat is open (`willPresent`). With the app in the background or
/// closed, iOS shows every part's push as it arrives.
@MainActor
enum RoomVoicePushBursts {
    /// Parts go out one after another, a few seconds apart.
    private static let window: TimeInterval = 60
    /// The indexer's previews for a media envelope: "Voice message" for any file or audio today
    /// (a photo too), "Photo" once it tells photos apart (kachat-indexer
    /// docs/ROOM_VOICE_PART_PUSHES.md). Multi-part photos (`mediaPart`) burst the same way.
    private static let mediaPreviews: Set<String> = ["Voice message", "Photo"]

    private struct Burst {
        var lastPush: Date
        /// The quiet notification the last later part left, to remove when the next arrives.
        var quietId: String?
    }

    private static var bursts: [String: Burst] = [:]

    /// True when this room push is a later part of a voice burst that already rang. Records
    /// the push either way.
    static func isLaterPart(threadId: String, sender: String, body: String, identifier: String) -> Bool {
        guard threadId.hasPrefix("broadcast:"),
              mediaPreviews.contains(body.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let now = Date()
        bursts = bursts.filter { now.timeIntervalSince($0.value.lastPush) < window }
        let owner = "\(threadId)|\(sender.lowercased())"
        guard let earlier = bursts[owner] else {
            bursts[owner] = Burst(lastPush: now, quietId: nil)
            return false
        }
        if let quietId = earlier.quietId {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [quietId])
        }
        bursts[owner] = Burst(lastPush: now, quietId: identifier)
        return true
    }
}

/// The Appearance setting (System / Light / Dark) on every UIKit window, all the time.
///
/// It used to reach the windows only from the first screen's onAppear and on a change. iOS
/// draws the App Switcher card from a snapshot it takes when K leaves the screen, and again
/// whenever it wakes K in the background (a push, a fetch) or the phone's own Light/Dark Mode
/// flips. When that drawing happened while a window had no override, SwiftUI's
/// `.preferredColorScheme` and UIKit disagreed and the card came out half Light, half Dark:
/// black text on the black background, so names and titles vanished (2026-11-23). Now the
/// override is set as each window shows, and again on every scene change, so the snapshot
/// always matches the app.
@MainActor
enum WindowAppearance {
    private static var style: UIUserInterfaceStyle = .unspecified
    private static var observers: [NSObjectProtocol] = []

    /// Called once at launch with the saved setting.
    static func install(_ appearance: AppAppearance) {
        style = uiStyle(for: appearance)
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [
            UIWindow.didBecomeVisibleNotification,
            UIWindow.didBecomeKeyNotification,
            UIScene.willEnterForegroundNotification,
            UIScene.didActivateNotification,
            UIScene.willDeactivateNotification,
            UIScene.didEnterBackgroundNotification,
        ]
        observers = names.map { name in
            // Delivered on the main queue, and applied right away (not in a Task), so the
            // override is in place before iOS takes the snapshot that follows going to the
            // background.
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { applyToAllWindows() }
            }
        }
        applyToAllWindows()
    }

    /// A change in Settings > Customization.
    static func set(_ appearance: AppAppearance) {
        style = uiStyle(for: appearance)
        applyToAllWindows()
    }

    private static func applyToAllWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.overrideUserInterfaceStyle != style {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    private static func uiStyle(for appearance: AppAppearance) -> UIUserInterfaceStyle {
        switch appearance {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}
