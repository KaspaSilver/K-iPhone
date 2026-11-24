# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

KaChat is a native iOS messaging and payment application built on the Kaspa blockchain. It enables encrypted peer-to-peer messaging with on-chain payments using SwiftUI.

**Scope (since 2026-11-20): the all-in-one app again.** The owner reversed the 2026-10-24 split:
KaChat gets back everything KaPay, KaPost and KaPlay do (trading through Trestly, .kachat
management, Portfolio, Cold Storage, KaPosts, Public Chats, Chess Online) and what was removed
from KaChat itself (Stats, Kaspa Websites, the widget, Simple Mode, calls), in phases; the other
apps get retired. Port from their current code; the "Removed from the app" list below shrinks as
each phase lands.

**Name: "K" (owner, 2026-11-21).** The app is called K: the home-screen name
(`INFOPLIST_KEY_CFBundleDisplayName`, app and share extension), the permission prompts and every
sentence that means the app say "K", in all 19 languages. "KaChat" stays where it names something
real: the chats tab (`AppTab.chats`) and its list (the wallet tab stays "Wallet": it was "KaPay"
briefly on 2026-11-21 and the owner changed it back; Settings keeps its "Chats" category), .kachat names and profiles ("KaChat Profile",
"KaChat Link", "Shared a KaChat profile"), KaChat Stats (the protocol's transactions), the Siri
shortcuts, the KaChat-NFC applet, and the "KaChat" Nextcloud folder and archive. The
Trestly provider announces itself as "K" with the `KLogo` globe (its rdns stays `com.kachat.wallet`). The project file and main scheme are `K` (`K.xcodeproj`, owner, 2026-11-23; Xcode Cloud's workflow points at them); the targets (and so the `KaChat` module name, which saved data can carry), bundle id and URL schemes are unchanged. The sign-in
screen (`OnboardingView`) shows the K globe (`KLogo`, cut from the app icon) with a teal glow over
"Digital Freedom on the Kaspa Network"; the old `KaChatLogo` and `KaChatAppIcon` images are deleted (2026-11-22).
The app icon is dark only (owner, 2026-11-22): `AppIcon` has the dark globe (`dark.png`) for every
appearance plus the tinted one; the teal light-mode icon is gone, so don't add one back.

**Dock and Kaspa Hub (phase 1, 2026-11-20):** the dock is fixed (owner's call, 2026-11-23: no
Customize Dock): Kaspa Hub, Wallet, KaChat (the `.chats` tab, labeled "KaChat" since 2026-11-21 for
the rebrand of the app as "K"), Profile, Settings (`AppTab.defaultDock`, `DockLayout`). The
connection dot is only at the top of Settings and on the dock's Settings icon (`ConnectionHealth`,
`SettingsDockIcon`: green connected, orange connecting, red after 8 s disconnected), on no other
screen. Every other tab is a tile in Kaspa Hub's grid (`KaspaHubView`,
`Views/Ecosystem/KaspaHubView.swift`), where it opens full screen; tapping Kaspa Hub again goes back
to the grid (`HubRouter`). A section opened from the Hub stays alive, hidden, when you leave it
(audit 2026-11-21 #28): KaPost, Portfolio, KaPlay, .kachat, Stats and Cold Storage come back exactly
as left (Chats, Wallet, Contacts, Settings and Websites still close). Hidden sections pause their
polling through the `hubSectionHidden` environment value and `onScreenPresence(appear:disappear:)`,
which counts a hidden section as gone; use it, not onAppear/onDisappear, for any new timer or poll in
a Hub section. A tab's screen is the same in either place (`AppTabContent`);
routes open a tab wherever it lives (`MainTabView.show`), and the Hub's dock badge adds up the
tabs inside it. A new feature is a new `AppTab` case; it lands in the Hub. Chats shows the unread count of its chats and groups on the dock, Wallet a dot
for the notification center (`AppTabBadge`, synced from `ChatService.updateAppBadge`). Group chats
share the chat list with 1:1 chats, by latest activity (`ChatListView`, since 2026-11-04; group
notification taps land there). The KaChat bots are always circles in the row above the chats. **Pin** (a chat's or
group's swipe, or Pin to Top Row in a circle's half sheet) moves it out of the list into that circle row (pins
"c:<address>" beside the bots' "b:" in `kachat_chat_circle_pins_<wallet>`; groups in
`kachat_group_pins_<wallet>`; public rooms, since 2026-11-23, in `kachat_room_pins_<wallet>`, held for
Mark as Read, Unpin, Mute and Delete); while searching, pinned ones show in the results instead. Settings > Chats > Who Can Message You?
(`WhoCanMessage`, 2026-11-23): Anyone, or Only Users with a Username, which hides 1:1 Message
Requests from senders with no .kachat name (`isHiddenRequest`; not deleted) and keeps the push
extension silent for them (`chat_who_can_message` in the App Group, checked against
`shared_identity_names`). The extension files the senders it silenced for want of a known name
(`chat_hidden_request_addresses`); once the app knows their name the request rings once from the
app (`ChatService.announceNamedHiddenRequests`, audit 2026-11-24 #13). Accepted chats and group
invites aren't affected. Being added to a group
is only a request: it waits in Message Requests (`GroupChatService.groupInvites`, its keys in the
Keychain) and you aren't in the group until you accept. Your answer goes on chain, encrypted, so
your other devices, a restore of your words and the group all know (MESSAGING.md, "Group invites");
member rows show Invited or Declined. Chats'
floating + opens a half sheet: New Chat or New Group Chat. Wallet (`WalletView`, since 2026-11-04)
holds the account's money, laid out as KaPay's Wallet tab (2026-11-19): the balance card (swipes
Kaspa ⇄ kUSDT; Tap to Manage opens Manage Addresses or Manage kUSDT), then Send, Receive,
Request and Swap (see "Swap"), Backup Hygiene when due, and the Chatting Address and Your Usernames
(`YourDomainsCard`, labeled Your Usernames since 2026-11-23: the account's .kachat names, opening
`KachatLiveDomainsTab`, whose empty state says No usernames yet and Claim a Username) cards.
Pulling Wallet down always scans every address for balances (2026-11-20, `scanAndRefresh`): Kaspa's
`discoverSpendingAddresses` and kUSDT's `discoverHoldings` side by side, then the balances. Profile
(since 2026-11-21) is your KaPosts profile (`KaPostsView(rootMode: .myProfile)`): banner, avatar,
name, follows and bio, then your posts and replies; under the header Edit Profile, Share Profile
(`ShareProfileSheet`: your Chatting Address's QR and Copy Share Link) and Log Out. Help moved to
Settings. The old `ProfileView` screen is no longer a tab. **Every notification is behind Profile's
bell** (top right, `AllNotificationsBell` → `AllNotificationsView`, since 2026-11-21): one list,
newest first, of KaPosts activity and the wallet's (Kaspa and kUSDT received)
(`KaPostsNotificationsView(allInOne: true)`), in a sheet with Done: no tabs, no settings gear, no
back arrow (owner's calls). The dock badge on Profile adds both unseen counts up. Beside the avatar
is See All Posts (opens the KaPosts tab), and Profile has KaPosts' compose button. Neither the Wallet tab nor the KaPosts menu
lists notifications any more; a push naming no post opens the bell (`NotificationsRoute`). Posts
and Replies on a profile change only with the cycle button, fading as KaPost's feeds do (owner,
2026-11-24: no sideways swipe). KaPost's three feeds
(Following, Feed, Popular) are one see-through button beside the title (`feedCycleButton`, owner,
2026-11-23): each tap fades to the next; no tabs and no sideways swipe. On someone else's profile
Follow and Chat sit under the follow counts.
**Rules from the 2026-11-21 audit (fixed 2026-11-22, AUDIT_2026-11-21.md):**
- Public rooms: the block stream only covers rooms with no working indexer and the room open on
  Wi-Fi; other bell-on rooms come from the 20 s sweep and push. With no such room the block handler
  is removed. The Chats list watches `PublicChatRoomSummaries` (publishes only on a real change), not
  the service. Room reply quotes come from the stored original (`replyToId`), never the envelope.
- Trestly: a trade whose `execute` gives no answer is "maybe sent": its coins are reserved and the
  address refuses new trades for 10 minutes or until the earlier trade shows on chain.
- The in-app browser (Websites, explorer, faucet) keeps to its starting site, sends other sites to
  Safari, shows the live host, and uses a non-persistent data store.
- `.kachat` social avatars resolve only for you, your contacts and chats, and profiles you opened
  (`KachatSocialImageResolver.mayLookUp`); identity lookups are batched (`/identity/batch`).
- Delete Account removes every ported store (`WalletManager.removeLocalData`); Log Out keeps the
  `.kachat` reminders (`kachat-reminder-` ids). The Profile bell reloads per account.
- Banners while the app is open (owner, 2026-11-22): the app banners new 1:1, group and room
  messages itself (`InAppBanner` in KaChatApp.swift) and new KaPost activity on your posts (the
  20 s `KaPostsNotificationService` poll, `KaPostsBannerLedger`), one banner per message or action:
  skipped when its push is already showing, and a later push is listed without a banner
  (`willPresent`). In the background and when closed, pushes alone. Never a second banner for
  a push that already came (owner, 2026-11-22): the notification extension records every push
  in the App Group (`recordPushArrival`, `push_arrivals_v1`: txid, request id, `kaposts:` key,
  30 min), and every app banner (chats, groups, rooms, KaPost, Received KAS) first checks
  `InAppBanner.pushArrived`. That covers the push you tapped to open K, which has left
  Notification Center.
- KaPost pushes (owner, 2026-11-22): the extension titles them "KaPost" (the server sends
  "KaPosts") and names the actor from `actor_pubkey` as K does: a contact's name, else their
  .kachat name from `shared_identity_names` (the registry's cached names, newest 500, written
  with the contacts sync; nothing looked up), else the server's subtitle.
- KaPost tips in chats (owner, 2026-11-22): a tip (`kchat:1:tip:`) is a payment in the tipper's
  1:1 chat. `KaPostTipLedger` (App Group `kapost_tips_v1`: tip txid -> post txid) is filled when
  K sends a tip, by the notification extension, or by reading the payment's transaction once;
  the card then says "Received tip" / "Sent tip" (`PaymentCardHeading`) and a tap opens the
  tipped post instead of the payment sheet. One notice per tip, opening the chat: the indexer
  sends a payment push and a KaPost "tipped your post" push with the same collapse id (the tip's
  txid); the extension words both "Received a tip: X KAS" in the tipper's chat thread (the KaPost
  one rewritten as a `payment` push) and makes whichever comes second quiet (`pushSeenBefore`).
  In the app, the chat banner says the same and the KaPost poll posts no tip banner.
- Dollars in a chat (owner, 2026-11-22): a contact's Send Dollars pings under their name like a
  Kaspa payment: the push reads "Sent you kUSDT" (no amount: only the sender's claim), the app's
  banner "Sent you 1.00 kUSDT" once the coin checks out (`postTokenPaymentBanner`, keyed by the
  notice message's txid like its push). The wallet's own "Received kUSDT" skips any coin a chat
  notice filed, and holds a new coin on the Chatting Address up to 2 minutes
  (`TokenWallet.noticeWait`) waiting for that notice, so there's one ping, not two.
- A payment notice that couldn't go out (`keepUnsentNotice`: usually the payment's own change
  isn't spendable yet) is retried every 20 s while open, for 15 minutes
  (`scheduleUnsentNoticeRetry`), not only when the chatting balance changes: a balance-only retry
  held Android's kUSDT notice until an unrelated 10 KAS payment arrived (2026-11-22).
- Cold Storage never shows a kpub as text (owner, 2026-11-22): not on the account list, not on
  the account screen, not under the kpub QR. It is copied from the account's Address Actions
  (Copy kpub) or the list's ⋮. The account screen has Manage Addresses' floating Address Actions
  button and its full-width Total Balance card. Fiat amounts are grouped ("$1,234.56",
  `formatFiatAmount`).
- Push registration sends `"app": "k"` (K takes every push kind: chats, groups, KaPost, rooms,
  Received KAS, .kachat) and `watch_only_addresses` (spending and notifying Cold Storage
  addresses; empty with Address Activity off), both in the change signature. The server side is
  kachat-indexer `docs/K_ALL_IN_ONE_PUSH.md`. The extension shows `name_event` pushes; a tapped one
  opens .kachat, a tapped `address_activity` push the address's history.
- Unfinished `.kachat` claims resume on every activation and reopen their sheet
  (`KachatRegistrationPresenter` on MainTabView); the expired-names banner is on the Wallet tab.
- KaPost indexer answers are size-capped and sanity-checked; KaPost notifications poll every 5 min
  when push is registered. Markdown links are parsed in linear time.
**Back from KaPay (phase 2, 2026-11-21):** Portfolio (`Views/Portfolio/`, kept on the phone: KaChat's
Nextcloud backs up contacts only), Cold Storage (`Views/ColdStorage/`, KasSigner; Coin Control is KaPay's
`CoinControlView` there, showing spending and KasSigner coin labels), the full `.kachat` market (claim,
renew, list, buy, offers, reminders: `Views/Ecosystem/KachatMarketView.swift`,
`KachatNamesLiveViews.swift`, the `.kachat` tab, labeled Usernames with the ".kachat" wordmark for its icon (`KachatTabIcon`, owner, 2026-11-23); Your Domains' .kachat card is KaPay's
`KachatLiveDomainsTab`; the .kachat tab's Your Names row, like For sale, shows only once the account owns a name), and Trestly trading (`TrestlyProvider` for Trestly's site inside K, `TrestlyConnectSheet` →
`TrestlyBrowserView`; since 2026-11-23 nothing opens the site: Wallet's Swap trades kUSDT itself, see "Swap"). Each is a tab that starts in
Kaspa Hub. The `.kachat` registry is KaPay's with KaChat's own parts merged back in (contact identity
lookups and the unnamed sweep, the chain copy walked off the main thread, the profile resolver's
cache, the names indexer setting); Edit KaChat Profile is KaChat's own
(`KachatProfileEditorView.swift`). The ported code's `WalletService` is `ChatService` here.
**Back from KaPost (phase 3, 2026-11-21):** KaPosts (`Views/KaPosts/`, the `.kaposts` tab:
`KaPostsPageView`; KaPost's settings are Settings > KaPosts, its notifications are behind Profile's
bell, and your profile is the dock's Profile tab; Edit Profile's Username section (first, since 2026-11-23) has "Get a username", which opens the
.kachat tab;
tips go through `ChatService.sendPayment(tip:)`) and Public Chats (`Views/Chat/PublicChat*`,
`PublicChatService`, `PublicChatStore` in `KaChatBroadcasts-<hash>.sqlite`). Public rooms are rows in
the Chats list with the chats and groups, by latest activity (`ChatListView`: Delete switches a
default room off or leaves your own (either drops its pin), Mute, Pin, Mark as Read), and the Chats +'s New sheet has New Public
Chat (join or create a room) and Edit Default Public Chats (`PublicChatsSettingsView` in
`Views/Chat/PublicChatRoomViews.swift`: each default
room and the language rooms on or off). Rooms with their bell on add to the Chats badge. KaPosts
starts in Kaspa Hub with its own badge (`AppTabBadge`); both open from links and pushes
(`KaPostsRoutes` in MainTabView; `.kaPost` and `.publicChatRoom` links open in the app), and the push
registration sends their real fields again (PUSH_EXTENSIONS.md). The ported code calls the app
"KaChat" and the feed "KaPosts". Posts and room messages have Report (`ContentReport`, an email to
support).
**Back from KaPlay (phase 4, 2026-11-21):** Chess (`Views/Chess/`, `Views/Games/GamesView.swift`,
`ChessTournamentService`, `ChessTournamentEngine`, `ChessBotGame`, `ChessBotLeaderboardService`,
`ChessBotLinks`, `Utilities/ChessBotEngine.swift`): the `.games` tab, called KaPlay (owner's call, 2026-11-21; a card per game; Chess is online
1v1 and 8-player tournaments in the hidden `chess-arena` room, and five bots whose results are
stamped on chain in `chess-bots`), starting in Kaspa Hub. The leaderboards are on KaPlay >
Chess's own screen (`ChessHomeView`'s 14-stop cycle button; owner's call, 2026-11-22: no longer a
Hub tile; the separate leaderboard screens were deleted 2026-11-24). KaPlay also has an arcade (owner, 2026-11-23, ARCADE.md): Snake and 2048,
native and seeded, so every game replays to its score (`ArcadeEngines.swift`); a finished game is
stamped in the hidden `#kplay-arcade` room (`ArcadeStampJob`), the boards come from the indexer's
`/arcade/leaderboard` (INDEXER_HANDOFF.md, open) with your own stamped best merged in
(`ArcadeLeaderboardService`), and Share to KaPost writes a `kachatarcade://` challenge, drawn as
`KaPostArcadeChallengeCard`, whose Play opens the game with the score to beat. Chess's screen is laid out like the arcade games' (2026-11-24, `ChessHomeView`): a Play card whose
Play opens a half sheet (1v1, Tournament, Bots), then the leaderboard, whose cycle button steps
through every board (1v1, Tournaments, each bot; each this month and all time). Every This Month /
All Time switch is KaPost's cycle button (`CycleCapsuleButton`; past six stops it shows "3/14", not
dots). 2048's icon is the number (`ArcadeGameIcon`). Every page switch inside a screen is that button too
(`PageCycleBar`, which replaced `UnderlineTabBar`: an address's History / UTXOs / Domains, Cold
Storage accounts, Stats, Swap; also 1v1 / Tournaments' pages and a profile's Posts / Replies). No
underline tabs. A score shows
"stamped" once the node takes the stamp (then checked on chain for 90 s, taken back if it never
lands). Share to KaPost stays in KaPlay (owner, 2026-11-24): KaPost's composer slides up over the
game (`KaPostQuickComposer`, posting at once, no undo window), Post sends it and the X closes it,
back to the game. The composer shows a challenge link (arcade or bot) as the card the feed will
draw, putting the link back on the end when posted. KaPlay's arena side is merged into `PublicChatService`: chess sends tied to
their account (`sendPublicChat(deferNoInputRetry:expectedSender:)`), own arena rows waiting for
the chain's time (`localStampSentAt`, dropped by `checkUnconfirmedServiceRows` at about 75 s), the
arena indexer's own health (`PublicChatIndexerClient.arenaHealth`, `ArenaIndexerHealth`,
`.arenaIndexerAvailabilityChanged`, never the message indexer's `.indexerAvailabilityChanged`),
repaging after a lapse or an outage, and `readArenaFromChain` while it's down. The arena follows the
message indexer (`AppSettings.publicChatIndexerURL`), so there is no Chess card in Connection
Settings. A KaPosts bot challenge card (`KaPostBotChallengeCard`) opens the bot in KaPlay
(`ChessBotLinks.open`, `.openGames`), and Share to KaPosts opens the KaPosts composer. The 1:1 chat's
Play Chess is unchanged; the arena shares its board pieces. Account removal clears bot records and
the arena's pending stamps. KaPlay's `kachatchess://` scheme is registered here too (owner's call, 2026-11-21: KaPlay is retired), so a challenge link tapped anywhere opens the bot in KaPlay (`ChessBotLinks.open`); while KaPlay is still installed, iOS picks either app.
**Leftovers from the retired apps (2026-11-21):** KaPost's Terms of Use (`Views/Onboarding/TermsOfUseView.swift`,
`KaChatTerms`): the first screen until agreed (`ContentView`, `kachat_terms_accepted_version`),
readable in Settings > About; bump `currentVersion` when the text changes. Their URL schemes are
registered here (`kaposts`, `kapay`, `kachatwallet`, `kachatchess`): posts, rooms, profiles,
payment requests, `kaposts://compose?text=` (the KaPosts composer) and `kapay://market` (the
.kachat Marketplace) open in KaChat (`KaChatInternalLink`, `KaChatApp.handleIncomingURL`). The app
icon's badge is the Chats tab's count plus KaPosts' unseen activity (`ChatService.updateAppBadge`,
also run by `DockBadgeSync`). Settings > Help has KaPay's .kachat Names Guide
(`KachatSetupGuideView`) and kUSDT Guide beside the Welcome Guide. The product is called KaPost
(singular; owner, 2026-11-21): every label people read says KaPost (the Hub tile, Settings > KaPost,
Share to KaPost, Search KaPost), while code names (`.kaposts`, `KaPostsView`, `[KaPosts]` log
tags, the `kaposts` push thread) stay as they are.
**Back from before the split (phase 5, 2026-11-21):** KaChat Stats (`.kachatStats`,
`Views/Ecosystem/KaChatStatsView.swift`: `GET /stats` from the indexers, STATS_INDEXER.md, plus the
.kachat registry's `activityTotals`) and Kaspa Websites (`.apps`, `ProfileAppsView` in
`Views/Ecosystem/KaspaWebsitesView.swift`, each site in `InAppBrowserScreen`), both tiles in Kaspa
Hub, restored from git as they were when they left on 2026-10-24.
Staying out (owner's call, 2026-11-21: not now): the home-screen widget, Simple Mode and calls
(calls left on 2026-11-11: no CallKit, PushKit, WebRTC or Nextcloud Talk, other clients' `call_*`
messages are dropped, `CallSignal` in Models.swift). Don't restore them unless the owner asks.

## Build Commands

Important, never build yourself, always ask user to build.

```bash
# Open project in Xcode
open K.xcodeproj

# Build from command line
xcodebuild -project K.xcodeproj -scheme K -destination 'platform=iOS Simulator,name=iPhone 17' build

# Tests: no command runs them. KaChatTests/ isn't in any target and the scheme's TestAction is
# empty, so `xcodebuild ... test` has nothing to run.

# Clean build
xcodebuild -project K.xcodeproj -scheme K clean
```

## Architecture

### MVVM Pattern with Singleton Services

The app uses MVVM architecture with global singleton services injected via SwiftUI's `@EnvironmentObject`:

- **Entry Point**: `KaChatApp.swift` initializes all services as `@StateObject` and injects them into the view hierarchy
- **Services**: Singleton pattern (`*.shared`) for core business logic, all marked `@MainActor` for thread safety
- **ViewModels**: `@ObservableObject` classes that bridge services and views
- **Views**: Pure SwiftUI views organized by feature (Chat, Contacts, Onboarding, Settings)

### Key Services

| Service | Purpose |
|---------|---------|
| `WalletManager` | Wallet lifecycle, key derivation, balance tracking |
| `ChatService` | Message polling, conversation state, sync with indexer |
| `NodePoolService` | Main entry point for gRPC node pool (POOLS_v2 architecture) |
| `NodeRegistry` | Persistent node storage with health/profile tracking |
| `NodeSelector` | Capability-aware node selection with scoring |
| `NodeProfiler` | Node discovery, DNS resolution, health probing |
| `GRPCConnectionPool` | Manages gRPC connections with circuit breakers |
| `UtxoSubscriptionManager` | UTXO subscriptions with failover and keepalive |
| `KasiaAPIClient` | REST HTTP client for Kasia Indexer |
| `KeychainService` | Device-specific Secure Enclave credential storage |
| `MessageStore` | Core Data message persistence, device-local, one SQLite store per wallet |
| `ContactsManager` | Chat contacts (per wallet): names, deletion tombstones. KaChat no longer reads or writes the phone's Contacts (removed 2026-10-08; no `NSContactsUsageDescription`) |
| `AddressBookManager` | Contacts, called the Address Book in code (its own dock tab, `AddressBookView.swift`; shown as "Contacts" since 2026-10-28, "Addresses" before): saved Kaspa addresses with a name and note, per wallet, on device and in the encrypted `kachat-contacts.json` on Nextcloud (NEXTCLOUD_SYNC.md, "Contacts only"), which KaPay uses directly (§9). A saved name is the display-name fallback after a name you gave the chat. An entry's picture is a photo you assign (files in Application Support/AddressBookPhotos/<wallet hash>/, `photo` in the backup, size and removal in Settings > Storage) or else exactly the avatar the address set on its own profile (`AddressBookAvatar`, never the chat contact's backup photo); an assigned photo also wins everywhere else that address's avatar shows, chats included (`KNSAvatarView`). Import / export (the button next to +): a JSON file via Files or the KaChat folder in Nextcloud (NEXTCLOUD_SYNC.md §1). It replaced phone-Contacts sync, which wrote Kaspa addresses into people's iCloud/Google contacts |
| `KasiaTransactionBuilder` | Constructs signed Kaspa transactions |
| `KachatNamesService` | `.kachat` names. **Live on both networks**: testnet-10, and **mainnet since 2026-10-09** ("mainnet v1", kachat-domains docs/MAINNET.md: registry `348bd2c8…75a4`, the audited v4 contracts with yearly periods, 90-day grace, 30-day renewal window, register 4000/2000/1000/250/35 KAS). `isLaunched` is true on both; `networkName` / `addressPrefix` pick the network's bundled manifest (`Resources/kachat-names-<network>.json`), pins and price tables (per network in `KachatNames.Manifest`), address prefix and cache folder, and a network switch resets the manifest and registry. Mainnet opened to everyone in the app on Friday 2026-10-16 8:00 AM Eastern; the countdown that gated it until then was removed (audit XP-028). **Before any registry switch on mainnet**, build the old-registry offer clean-up first: the app only reads its manifest's registry, so offers on the old one vanish and stay locked (audit IOS-066, left as is; KACHAT_NAMES.md warning at the top). **Address profiles are not registry data** (`profilesEnabled`, every network since 2026-10-05): a `kchat:1:profile:` self-send from the chatting address (`KachatNamesActions.profileSigner()`), so "Edit KaChat Profile" saves on mainnet too (primary name greyed out there), and mainnet identities are profile-only (`GET /profiles/{address}`; the indexer side is kachat-indexer `docs/KACHAT_PROFILES.md`). Any UI change must work on both networks. It loads and verifies the registry manifest (registry v4 or v5, `registryVersion`: fixed price tables baked into the gap and name, one genesis whose covenant-id binding is verified; v5 adds `import` from a migration snapshot of the previous registry). The name template hash and the price tables are pinned in the app (`Manifest.pinnedTemplateHashes` by version, `pinnedRegisterPrices` / `pinnedRenewPrices`), the v4 gap too; the offer and the v5 gap per deployment in `Manifest.deployedTemplateHashes`; an indexer-served manifest is accepted only when every template hash is pinned. The bundled `Resources/kachat-names-testnet-10.json` is the live testnet-10 v5 registry on the audited contracts since 2026-10-09 (audit C2): genesis `b6223f0f…e24f`, registry `1283f749…bfa2`, imported from the drill registry `fdc403f5…571d` (6 names; 24-hour periods, 6-hour grace, 2-hour renewal window). Register, renew, list, buy and offers are back in KaChat since 2026-11-21 (from KaPay: `KachatNamesActions`, `KachatNamesBuilder`); name transactions ask Face ID (`SwipeUpToSendScrollView.authReason`) |
| `KachatNamesRegistry` | `.kachat` reads (lookup, by owner, a buyer's offers, identity) from the names indexer when `GET /names/status` matches the manifest's registry covenant id and the indexer is at most ~1 minute (600 DAA) behind the network - re-checked on every refresh - else from its own chain walker: the registry's live UTXOs kept from genesis, spends found via the REST API's `/addresses/{p2sh}/full-transactions`, decoded and verified against output scripts (`KachatNamesRegistryState.swift`, pure, tested by `scripts/test_kachat_names_registry.swift`) |
| `KachatNamesActions` | What is left of the `.kachat` actions since the market moved to the KaChat wallet app: `saveProfile` and `profileFee` (the `kchat:1:profile:` record), `ownNamesAndOffers` (this wallet's names across its keys), `marketAddresses` (read-only, for names an older build's Buy From address holds) and `follow(txId:)`, which watches the mempool, then the REST API, so the receipt shows Sent / In a block / Updated in KaChat. Screens in `KaChat/Views/Ecosystem/KachatNamesLiveViews.swift` |

### Messaging Protocol

1. **Handshake**: Initial key exchange, stored in sender's self-stash on-chain
2. **Contextual Messages**: Encrypted messages using shared secret derived from handshake
3. **Payments**: On-chain KAS transfers with optional encrypted metadata
4. **Audio**: Voice messages encoded with the Opus codec (vendored `Opus.xcframework` via `OpusBridge`). On chain, 16 kbps CBR in 60 ms frames (`VoiceNotePolicy`): 1:1 up to 2:50 as tagged parts of at most 14.5 s, groups up to 1:50 as tagged parts of at most 9.8 s, each limit set by 1 KAS of total fees; shown as one bubble. Group voice is sealed as the binary media frame inside the unchanged `gcomm` payload (older and other clients can't read group voice notes until updated). See MESSAGING.md "Long voice notes (multi-part)"

### Network Communication

- **Kaspa Node (gRPC)**: Managed by `NodePoolService` (`NodePool/*`) for UTXO subscriptions, transaction submission, and peer discovery
- **Kaspa REST API**: Configurable via Settings (default: `api.kaspa.org` mainnet / `api-tn10.kaspa.org` testnet - testnet means testnet-10, where the covenants and the node pool's testnet seeds are; the retired TN11 default migrates forward) for fetching transaction history, payments, and UTXO fallback
- **Kasia Indexer (REST)**: Configurable via Settings (default: `indexer.kachat.app`; testnet has no default) for message indexing and retrieval

### Connection Settings

Network endpoints are in Settings > Connection Settings: a card per connection (Indexer, Node, Domains, Explorer, Trestly), each opening its own screen with Save (Node saves as you pick), as KaPay has it. All configurable:
- **Network**: mainnet / testnet toggle
- **Node**: pinned out of the box to `grpcs://node.kaspium.io`, Kaspium's own default (`AppSettings.defaultTrustedNodeAddress`, since 2026-11-21; settings still on the retired `toccata.kaspium.io` move to it as they decode). Use Default resets to it
- **Indexer URL**: Kasia message indexer endpoint
- **KaChat Names Indexer URL** (Domains tab, `AppSettings.kachatNamesIndexerURL`): where `.kachat` names and profiles are read. Separate from the message indexer so a user can run their own names indexer; same KaChat indexer by default (`indexer.kachat.app`, `AppSettings.defaultIndexerURL`; saved `kachat.duckdns.org` defaults migrate forward as settings decode; testnet has no default indexer, so its chat, push and names fields start blank and the retired `tnkachat.duckdns.org` is cleared), and settings saved before it existed copy the message indexer. Falls back to the chain walker when it can't serve the registry.
- **Kaspa REST API URL**: Block explorer API for transaction lookups
- **Trestly API URL** (Trestly card, `AppSettings.trestlyAPIURL`, kept per network in `ConnectionProfile`): where kUSDT balances are looked up (`GET /tokens?owner=`). Blank means the network's default (api.trestly.io / testnet.trestly.io). **Trestly Site URL** on the same card (`AppSettings.trestlySiteURL`): Trestly's site (its `/terms` is the Swap agreement's link).

Settings are stored in `AppSettings` struct with network-specific defaults and loaded via `AppSettings.load()` static method (safe to call from any context).

### Name services: .kachat only

Since 2026-11-23 (owner's call) K reads no other Kaspa name service: KNS (.kas), dotk (.k) and
Kaspa Names (.kaspa) are gone, `KNSService` with them. Typed names resolve as `.kachat` only
(`NameServicesClient.resolveEverywhere`, one answer; no "Other domains"); Your Domains, Manage
Addresses, Cold Storage, the chatting-address picker and an address's Domains tab show `.kachat`
names only; Connection Settings > Domains has only the KaChat Names Indexer URL. A contact named
after a `.kas` domain is still un-named on load (`ContactsManager.clearKasDomainAliases`), KNS
commit/reveal transactions are still kept out of chats as payments
(`handleKNSOperationTransactionIfNeeded`, no "domain transferred" message), and old "Sent/Received
.kas domain" chat lines still draw. A KNS commit whose reveal failed before then still holds coins
only its saved redeem script can spend: `KNSRevealRecovery` (`Services/KNSRevealRecovery.swift`,
with the reveal builder in KaChatTransactionBuilder) finishes those reveals on app-active and
wallet load, returning the coins; it starts nothing new (audit 2026-11-24 #4). Remove it a few
releases after no `kachat_spending_kns_reveals_` record is left. `KNSAvatarView.swift` is the app's shared picture code
(avatars, banners, the image cache), not KNS. Show .kachat Endings is off by default
(`KachatNameLabel.showsEnding`), the marketplace included: its tiles and search field show bare
names unless it's on; text other people read (a KaPost @mention, a copied name, the Address
Book) keeps the ending.

### Data Sync Strategy

The app uses a subscription-based approach to minimize polling:

1. **Initial Sync**: Full fetch of historical data on startup/wallet import
2. **gRPC Subscriptions**: Subscribe to `utxosChanged` for real-time payment notifications
3. **Fallback Polling**: If subscription fails, fall back to periodic polling until reconnected
4. **Adaptive per-object cursors** for handshakes/contextual messages:
   - Store `lastFetchedBlockTime` per sync object (handshake in/out, contextual alias in/out)
   - If last fetched block is within 10 minutes of current sync: rewind cursor by 10 minutes for reorg safety
   - If last fetched block is older than 10 minutes: use `lastFetchedBlockTime + 1` to avoid repeatedly downloading the same old window
   - Keep `lastPollTime` as a global fallback for first-time objects and migration safety

5. **A failed read never counts as read.** When a read keeps failing, even with its page size stepped down to 1, its phase is skipped: the cursors stay put and `lastPollTime` doesn't advance, so a later sync re-reads the window. A full sync that fails retries itself while the app is open (`noteFullSyncFinished`: 30s doubling to 10 minutes). `MessageStore.markSyncTrouble` only adds a note to the wipe-and-resync sheet, and the next complete sync clears it. Nobody should need to wipe to repair sync

Payment detection logic:
- **Incoming**: Our address appears in outputs but NOT in inputs
- **Outgoing**: Our address appears in inputs (we're the sender)
- Amount for incoming = sum of outputs to our address
- Amount for outgoing = output amount to recipient (non-change output)

### Live Message Delivery (1:1 chats)

Four independent, idempotent paths surface an incoming 1:1 message; all insert through
`ChatService.addMessageToConversation`, which dedupes by `txId` at both the fetch and the
conversation level, so overlap is harmless:

1. **gRPC `utxosChanged` subscription** (`UtxoSubscriptionManager`) on own + contacts' addresses.
   This is server-side state on the gRPC stream and dies with it. `GRPCStreamConnection` bumps
   `connectionGeneration` on every connect; the manager records the generation at subscribe time
   and re-sends `notifyUtxosChangedRequest` when it moved (15s health check +
   `verifyPrimarySubscription()` right after foreground reconnect), then posts
   `.rpcSubscriptionsRestored` so `ChatService` runs a catch-up sync for the dead window.
2. **Open-chat poll** (`startActiveChatPoll`, ~2s) for the conversation on screen only.
3. **Foreground contact sweep** (`startForegroundContactSweep`): runs only while the UTXO
   subscription is down or not verified alive within 45s (`isUtxoSubscriptionHealthy`), 30s
   between sequential sweeps (60s on cellular, backs off to 120s on indexer errors), 120ms
   between contacts, a window of 12 per pass: the 4 most recent contacts every pass plus a
   rotating slice of the rest. Starts on app-active / wallet load, stops on background /
   wallet switch / logout. Its loop also carries the group catch-up ride-along.
4. **Remote push** (`PushNotificationManager`) and the **60s fallback poll**
   (`startFallbackPolling`), which runs only when the subscription is down and push is off.

**With the indexer down** (`KasiaAPIClient.isIndexerDown`: three failures in a row at least five seconds apart, so one timeout or network handoff changes nothing; one cheap request a minute checks whether it's back, and on recovery the sync cursors rewind to the outage so the indexer serves that window again): path 1 needs no indexer, since the payload comes from the node's mempool or the Kaspa REST API. History reads (handshakes, messages by sender and alias, payments, self-stash) answer from the address's history on the Kaspa REST API in the indexer's own shapes (`fromIndexerOrChain`), because a node keeps no history by address. Groups go to the block stream, on cellular too, and catch up from each member's history (`catchUpGroupsFromChain`). First-contact messages come from the block stream (`refreshInboxBlockScan`), since only the indexer can look an inbox tag up. Push can't work without it: that's server-side, so nothing arrives while the app is closed.

There is NO per-contact "realtime disabled" flag, spam detector, or per-contact 60s poll in the
code (`realtimeUpdatesDisabled`, `noisyContactWarning`, `recordIrrelevantTxNotification` do not
exist on any platform). Earlier docs described that feature; it was never built.

### gRPC Node Pool (POOLS_v2)

The app uses a sophisticated gRPC-based node pool architecture (see `POOLS_v2.md` for full design):

**Node Discovery (`NodeProfiler`):**
- Resolves DNS seeds using `getaddrinfo()` for all A records
- Discovers peers via `getPeerAddresses` from active nodes
- Filters by an allowlist of gRPC ports (15110/15111/16110/16111 mainnet family, 15210/15211/16210/16211 testnet family; see `NodeProfiler.allowedGrpcPorts`)

**Dynamic Probe Modes:**
- **Aggressive mode**: Fast probing (10s loop, 4min candidate interval) when pool is building
- **Conservative mode**: Slow probing (60s loop, 60min candidate interval) when pool is healthy
- Triggers conservative when: 5+ active nodes AND at least one with latency <200ms

**Discovery Pause:**
- Pauses discovery and candidate probing when pool is healthy enough:
  - 5+ nodes with latency ≤200ms, OR
  - 15+ total active nodes
- Resumes automatically when criteria no longer met

**UTXO Subscriptions (`UtxoSubscriptionManager`):**
- Sticky primary + warm standby pattern
- 30-second keepalive ping (`getInfoRequest`) on subscription channel
- Automatic failover with state resync via `GetUtxosByAddresses`
- Triggers catch-up sync on restart/reconnect unless remote push channel is currently marked reliable (then debounced)

**Robustness:**
- **Network Epochs**: Health stats reset on network path changes (WiFi↔cellular, VPN)
- **Circuit Breakers**: Per-connection failure tracking with automatic recovery
- **Hedged Requests**: Race primary + backup for user-facing operations
- **REST Fallback**: `getUtxosByAddresses()` falls back to REST API when gRPC unavailable

### Push Notifications (Implemented)

Remote push notifications are implemented for background/terminated delivery. `PushNotificationManager` manages token lifecycle and indexer registration; `KaChatNotificationService` decrypts notification payloads when available.

**Key Points:**
- Requires fork of `kasia-indexer` with `PushNotificationActor`
- Devices register watched addresses (contacts) with indexer
- Push includes encrypted payload (≤3.5KB) for immediate decryption, or txId-only for large messages
- iOS Notification Service Extension (`KaChatNotificationService`) decrypts and displays actual message content
- App Group (`group.com.kachat.app`) shares keys/contacts between main app and extension
- Push reliability is scored by txId correlation between UTXO-notified incoming messages and APNs receipt:
  - 3 consecutive misses (after 60s grace each) -> `unreliable`, force re-register + immediate catch-up sync
  - First matched hit -> `reliable` again
  - When `reliable`, app-active/restart catch-up syncs are debounced (10 minutes)

### Data Storage

- **Keychain + Secure Enclave**: Seed phrases and private keys wrapped with device-specific SE keys (see Multi-Device section)
- **Core Data (local only)**: Messages in a plain `NSPersistentContainer`, one SQLite store per wallet. No iCloud/CloudKit anywhere in the app. Messages and groups come back to any device from the chain with the seed; Nextcloud (`NextcloudService`) backs up contacts only
- **UserDefaults**: Settings, contact aliases (fallback for wallet)

### Multi-Device Architecture

A seed can be entered on several devices; each keeps its own local message store and gets messages and groups back from the chain with the seed. Nextcloud (Settings > Storage > Nextcloud, Automatic Sync) backs up contacts only, in an encrypted `kachat-contacts.json`; the old `kachat-backup.json` is never read or written. The app never uses iCloud or CloudKit - removed in 4.1 - so there is no iCloud container entitlement and nothing about a wallet reaches Apple.

**Bundle Identifiers:**
- Bundle ID: `com.kachat.app`
- App Group: `group.com.kachat.app`
- Keychain Access Group: `$(AppIdentifierPrefix)com.kachat.app`

**Device-Specific Secure Enclave Storage (`KeychainService`):**

Seed phrases and private keys are encrypted using the device's Secure Enclave, making them non-transferable between devices:

```swift
// Device ID derived from SE public key hash (first 8 bytes)
let seKey = try secureEnclavePrivateKey()
let publicKeyData = SecKeyCopyExternalRepresentation(publicKey)
let deviceId = SHA256.hash(data: publicKeyData).prefix(8).hexString  // e.g., "a1b2c3d4e5f6g7h8"

// Keychain keys are device-specific
"kachat_seed_phrase.a1b2c3d4e5f60718"  // Device 1
"kachat_seed_phrase.29e8f7a6b5c4d3e2"  // Device 2
```

- Each device must enter the seed phrase separately during setup
- SE-wrapped data cannot be decrypted on other devices

**Per-Wallet Stores (`MessageStore`):**

Messages are partitioned by wallet address using separate SQLite files:

```swift
// SQLite file per wallet, suffix = SHA256(walletAddress).prefix(8) hex
"KasiaMessages-a1b2c3d4.sqlite"  // Wallet 1
"KasiaMessages-e5f6g7h8.sqlite"  // Wallet 2
```

- Switching wallets reloads the appropriate message store
- All Core Data queries filter by `walletAddress` field
- Persistent history tracking stays enabled on the store (Core Data refuses to open a store that had it and lost it); `purgeOldHistory()` trims it on every load

## Code Organization

```
KaChat/
├── App/              # KaChatApp, ContentView (router), LaunchRouter, MainTabView
├── Models/           # Models.swift (core)
├── ViewModels/       # SettingsViewModel
├── Views/            # SwiftUI views by feature: Chat/, Contacts/, Onboarding/, Settings/,
│                     # Ecosystem/ (bots, Edit KaChat Profile), Shared/
├── Services/         # Core business logic, API clients, crypto utilities (+ NodePool/)
├── Shortcuts/        # App Intents / Shortcuts integration
├── Generated/        # Generated protobuf/gRPC sources
└── Utilities/        # CryptoUtils, KasiaCipher (ECIES, in KaChatCipher.swift), Bech32, ...
```

Companion targets at the repo root: `KaChatNotificationService/` (push decryption extension) and `KaChatShareExtension/` (share sheet).

## Key Dependencies

- **P256K** (swift-secp256k1, SPM): secp256k1 elliptic curve library for key derivation and signing
- **grpc-swift + SwiftProtobuf** (SPM): gRPC stack for the node pool (`KaChat/Generated/*` holds the generated protobuf/gRPC sources, regenerated from rusty-kaspa's protos by `scripts/regenerate_protowire.sh`)
- **Opus** (`external/opus/Opus.xcframework`, vendored): audio codec for voice messages, linked through the Objective-C bridge `OpusBridge.h/m`

## Patterns to Follow

- Mark all service classes and view models with `@MainActor` for UI thread safety
- Use async/await for all asynchronous operations
- Error handling via `KasiaError` enum with `LocalizedError` conformance
- Kaspa addresses use Bech32 encoding with `kaspa:` or `kaspatest:` prefix
- Amounts are in sompi (1 KAS = 100,000,000 sompi)

## UI Patterns

### Chat Composer (ChatDetailView / GroupChatDetailView)

The input bubble is the text field only. Everything else is in the "+" sheet:

- **1:1 order:** Send Kaspa, Send Dollars, Tip (not in your own chat), Camera, Photo, GIF, Voice Message, File (Nextcloud only), Request
  Payment, Play Chess, and Send Handshake where needed (only where first contact still needs one).
- **Tip** (2026-11-23): the same as a KaPost's Tip, set in Settings > Customization > Tipping
  (`KaPostsSettingsView(part: .tipping)`, moved there from Settings > KaPost, which keeps the cool
  down): Tip In picks Kaspa, kUSDT (the chat's Send Dollars) or asking (`KaPostTipFlow`); a Kaspa
  tip with a default amount (`KaPostsSettingsView.instantTip`, at most 10 KAS) waits in the
  composer as a Tip card until the send button (owner, 2026-11-23: never straight from the +; the
  trash takes it back), then goes from Tips From; with no default, `KaPostTipSheet` asks the amount. It is an ordinary payment in the chat: no post,
  nothing counted.
- **Send Dollars** (2026-11-20): a step of the + sheet asks "Which stablecoin are you sending?" (`DollarTokenChooser`, every
  `isDollarStable` token: kUSDT today, so other stablecoins join the list later), then `TokenSendView`
  with the chat as the recipient (`init(token:chatRecipient:name:)`): no To step, From with a "To
  <name>" chip, How much, the review and swipe up, like the chat's Send KAS sheet. It sends to the
  contact's chatting address; then `ChatService.recordTokenPayment` adds the "Sent 12.50 kUSDT" bubble
  and sends a `token_payment_notice`, which the contact's app checks on chain before showing
  "Received" (MESSAGING.md, "Token Payments in a Chat"). No memo.
- **Groups:** Camera, Photo, GIF, Voice Message, File. A group has no single recipient for pay or chess.
- **GIF** (since 2026-11-18) opens Photos showing only animated images and always goes on chain:
  Send asks GIF Quality (the photo tiers), `GIFPrep` re-encodes it to fit, and it goes as an
  `image/gif` photo (MESSAGING.md, "GIFs"). Bubbles and full screen play it
  (`AnimatedImageView`, one frame decoded at a time). No GIF search: GIPHY and Klipy forbid
  storing their GIFs, which on chain is permanent (owner's call: Photos only for now).
- **On chain or via Nextcloud:** with a Nextcloud server connected, Camera / Photo / Voice Message
  open `ComposerMediaRouteStep` (`Views/Chat/ComposerMediaRoute.swift`) and ask every time. That
  choice replaced the old "Send Media via Nextcloud" setting.
  - Via Nextcloud: full-quality uploads, videos from the camera or the library, and voice notes
    up to `ComposerMediaLimits.nextcloudVoiceSeconds` (5 min, app-wide).
  - On chain: compressed photos and voice notes, both in the binary media frame (MESSAGING.md;
    in groups too, inside the `gcomm` payload). Send on an on-chain photo asks High, Medium or
    Low (`PhotoQualitySheet`; `PhotoTier`: up to 1, 0.5 or 0.1 KAS, which is 368 / 184 / 36 KB in
    1:1 and 243 / 121.5 / 23.5 KB in groups). A photo bigger than one transaction goes as
    `mediaPart`-tagged chunks shown as one bubble once all are in ("Photos: quality tiers and
    multi-part photos" in MESSAGING.md). There is no Higher quality photos setting any more.
    Voice is 16 kbps CBR Opus in 60 ms
    frames, as long as 1 KAS of fees allows (`VoiceNotePolicy`): a 1:1 note runs up to 2:50 in
    parts of at most 14.5 s / 31 KB (0.977 KAS at the max), a group note up to 1:50 in parts of
    at most 9.8 s / 21 KB (0.964 KAS). The chat shows them as one bubble with gapless playback,
    and they count as one unread and one notification ("Long voice notes (multi-part)" in
    MESSAGING.md). Older and other clients can't read group voice notes until they're updated.
    Recording works the same in both composers: the button beside the bar stops the recording
    (as does the length limit), it encodes ("Encoding…"), then "Audio ready" with a play / pause
    preview of the note as it will be sent, and the button sends it; the trash throws it away
    at any stage (`ChatDetailView` audio mode, `VoiceNoteRecorder` in groups).
  - Camera and microphone access (`MediaAccess`, `Views/Shared/CameraCaptureView.swift`): the
    composers ask the first time, and once access is off show `mediaAccessAlert` (Camera / Microphone
    Access Required, Open Settings, Not Now) instead of a blank camera or a bare error. The
    permission prompts' reasons are in Info.plist, translated in each `<lang>.lproj/InfoPlist.strings`.
  - The message fee pill (text only; voice notes and photos price their own parts and can't be
    tapped) is capped by `MessageFeeLimit` (KaChatTransactionBuilder.swift): above 1 KAS the editor
    refuses, above 0.01 KAS it asks "Use a High Fee?", and the builder clamps a custom fee between
    the network minimum and the cap. Messages don't ask for Face ID, so this is their guard.
  - Drafts are per account (`kachat_message_drafts_<address>`) and are cleared on Log Out and
    Delete Account, along with every delivered notification. Quick reply needs the phone unlocked.
  - Paste, drop and share-extension photos go on chain. Pasted, dropped and share-extension
    photos opened in the composer ask for a quality too. A photo the share extension sends
    straight away has no sheet to ask, so it goes at Low.
- **Paying:** Send Kaspa (and `startInPaymentMode`) opens the Send KAS sheet, not a composer
  mode: the Send Kaspa steps from Amount (the keypad, KAS or fiat, Max) to the Review, which holds
  the encrypted memo (the payment payload's note, ≤140 chars, shown in the bubble), and
  `SwipeUpToSendScrollView` (swipe up to send; an amount under the dust limit is warned about on
  the Review, not asked again). See "Send Kaspa screens". The memo
  is sealed to the recipient, and the seed reads it back on another device (see
  "Reading back what you sent").
- **After paying:** the swipe-up screen shows Sent with the transaction until Done (a deferred
  payment just closes the sheet). Tapping a payment bubble (sent or received) opens its
  details half sheet: amount, memo, time, View in Explorer (the Settings explorer) and Copy
  Transaction ID. A payment that isn't on chain yet says so instead.

### Smooth scrolling (2026-11-24)

The feed, the Chats list and chat history redraw rows many times a second while they scroll, so
nothing in a row's body may scan a whole post or message, read UserDefaults or the App Group, hash
files or decode images. Remember results instead: `ArcadeChallenge` / `KaPlayBotChallenge` check
for their scheme in place before matching, the group row's preview and group bubbles' text are
memoized per message (keys: the content's stamp, `KachatNamesRegistry.identityRevision` and
`GroupDisplayNamesRevision`, so edits and renames show), Message Requests' count is memoized in
ChatService (`requestCountMemo`), KaPost tips are held in memory (`KaPostTipLedger.tipsCache`;
`record` re-reads the App Group, which the extension also writes), assigned photos are cached by
address and decoded once, avatar links are parsed once (`avatarSource`), `AppSettings.activeNetwork`
reads the network without copying the settings, and `KachatNameLabel.showsEnding` /
`WhoCanMessage.current` are cached (`DefaultsBackedCache`). A post's action row is built once and
lays itself out in one pass (`KaPostActionRowLayout`: 18, 12 or 8 pt gaps, whichever fits; not
ViewThatFits). The Chats list rebuilds coalesced (180 ms, never held past a second) and only writes
a changed list.

### Long-press menus

Chat and group rows have no long-press menu: swipe left for Delete, Silence and Pin (your own chat
has only Silence), right for Mark as Read or Unread. Pinned chats and groups, being circles, keep the hold.

Every long-press menu is a half sheet of square tiles, three to a row: an icon over a short
title. This covers the message menu (`MessageActionsSheet`), and chat, bot and group circles. The
chat composers' **+** sheets (1:1 and group) use the same tiles.
- Build them with `ActionSheetRow`s inside `ActionSheetTiles`. The row's `subtitle` becomes the
  VoiceOver hint.
- Size the sheet with `ActionSheetTileMetrics.sheetHeight(tiles:)`.
- Other half sheets (confirmations, account menus) keep the row form.

### List titles and search

Contacts and Chats draw their title and search field themselves (`PinnedListHeader`,
`Views/Shared/ActionSheet.swift`) above the list, so neither scrolls away; Settings uses it for its
title alone. Not `.searchable` or a
large title: the large title collapsed into the bar on a scroll, where the balance took its place,
so the title could go missing. The bar stays `.inline` with a principal item, so it doesn't show
the title a second time.

### Creating an account, backups and Delete Account

These match KaPay (ported 2026-11-01); keep them matched with KaPay's copy.

Create New Account makes an account in one tap: 24 words, no passphrase, the next free default
name (`WalletManager.nextDefaultAccountName`: My Account, My Account 2 and on), then the Welcome
Guide as before (`commitCreatedWalletForOnboarding` arms it and holds sync). "Advanced: Create with
a Passphrase" (`CreateWalletView`) is the only other way: also 24 words, through
`PassphraseOptionView`, whose entry screen shows the chatting address and its balance as you type.
Import still takes 12 or 24 words.

Creating never shows the seed phrase: an account made here is owed a backup
(`AccountBackupStatus`), and until the backup steps (`AccountBackupView`: why, get ready, the words
six at a time, a check of four random words, the passphrase and its check if there is one, where
to keep them) are finished, Profile shows `AccountBackupBanner` at its top (red once the chatting
address holds funds; Profile only since 2026-11-23) and the dock's Profile icon a yellow dot
(`ProfileDockIcon`) and the Delete Account warning leads with Back Up Account; deleting is never blocked. The steps never offer a copy; Settings > Back Up Account > View 12 or 24 Words does
(a reveal lasts 20 seconds). Imported and older accounts are never owed one. Importing, by typing
the words or from a card, or finishing the steps starts a six-month timer; when it runs out Wallet shows `BackupHygieneCard`, and
`BackupHygieneView` asks for five random words in random order on `SeedPhraseKeyboardView`, then
the passphrase if there is one. Passing, or Can't Complete This and the backup steps again, starts
the timer over; closing leaves the card up.

**NFC card backup** (`Services/NFCCard.swift`, in production builds since 2026-11-04;
`NFCCard.isAvailable` hides it where NFC can't read these cards, such as iPad): an extra copy of the words of a seed phrase the user
already has, on a Java Card loaded with [KaChat-NFC](https://github.com/KaspaSilver/KaChat-NFC) through
Kaspa Quick Start's NFC Card page. Not cold storage: the card never generates or uses a key. The
card commands and backup format are that repo's `docs/PROTOCOL.md`, shared across apps; change
them there first. Settings > Back Up Account > Back Up to NFC Card (`NFCCardBackupView`, behind the seed phrase's
biometric gate) only exists for an account with a BIP39 passphrase, because that passphrase is what
protects the account: it's never written to the card. The screen scans the card, takes a 6-digit
PIN, then saves and reads back. The PIN also derives the encryption key, so there's no separate
password. A forgotten PIN means reloading the card through Quick Start. The Import chooser's Restore from NFC Card (`NFCCardRestoreView`) reads with the PIN, asks
for the passphrase and checks it against the saved chatting address. It imports with the saved
name, family and chatting index, and like any import owes no backup. Saving to a card never clears
the backup warning, so the written phrase stays the main copy. The App ID needs Near Field Communication Tag
Reading on.

Settings' last row is Delete Account (`DeleteAccountSheet`, the warning the sign-in screen's
Delete also shows; `WalletManager.deleteCurrentAccount`), and Log Out is the last row on Profile.
Deleting removes the account,
its messages, contacts and the bell's notifications from this device and revokes the Nextcloud app
password the user pasted in when connecting; the encrypted files stay on the server.

Incoming photos in a 1:1 chat have one rule and no setting (`ContactsManager.photosUnlockDate`):
hidden until both sides have sent a message and 10 minutes have passed, with no way to reveal one
early. While the app is open, every contact's profile is looked up again once an hour
(`ContactsManager.startProfileRescans`).

Every sign-in gets new tabs (`ContentView`'s `signInSession`, the `MainTabView` id, bumped on
sign-out), opening on Chats; without it SwiftUI brought the last account's tabs back, on Settings
and with no onAppear. Biometrics for account login are off by default.

### Face ID on deleting, not on sends

Sends don't ask for Face ID (owner's call, 2026-11-13): the swipe in `SwipeUpToSendScrollView` is the
confirmation, and a Siri or Shortcuts payment goes on its spoken Confirm, on an unlocked phone
(`.requiresAuthentication`). Messages don't ask either. `DeviceAuth` still guards both Delete Account
sheets, the keys-missing screen's Remove, .kachat name
transactions, the seed phrase and private keys. A device with no passcode can't do those
(`DeviceAuth` refuses and says why).

No privacy cover in the App Switcher (owner's call, 2026-11-15): the app's snapshot shows what was
on screen. Don't add it back, and audits shouldn't flag it. The snapshot must match the app's
Appearance: `WindowAppearance` (KaChatApp.swift) puts the setting on every window as it shows and on
every scene change (2026-11-23: a card drawn half Light, half Dark had black names on black).
A cold launch shows the K globe: Info.plist's `UILaunchScreen` (`KLogo` on `LaunchBackground`, white
or black with the phone), then `LoadingView` draws the same globe in the same place until the
account is loaded.

### Reading back what you sent

A seed reads back what it sent (since 2026-11-04), so history comes back on any device with no
extra transaction, fee or format change. `KasiaCipher.encrypt(senderPrivateKey:)` derives a
message's ephemeral key from the chatting key and the message's random nonce (HKDF,
`kachat-sent-message-v1`), and `decryptSent` works it out again to reach the shared secret. To the
recipient it's an ordinary message. Messages (`decryptSentMessage`) and payment memos
(`decryptSentPayment`) both do this. Whoever holds the seed can read these, which is the point.
Anything sent before this used a random key that's gone: it stays the hidden
`sentViaOtherDevicePlaceholder` unless an imported chat archive has its text. The full protocol note is
in MESSAGING.md; other clients need the same change for their sends to be recoverable.

### Send Kaspa screens

Every Send Kaspa screen is built from the shared pieces in `Views/Shared/SendKaspaComponents.swift`,
so they match: the 1:1 chat's Send KAS sheet, Send Kaspa (`WithdrawKaspaView`: Wallet's Send,
the Address Book, an address's Send, paying a payment request). Coin Control
(`CoinControlView`) lives there too. `SpendingAddressWithdrawView` is left for compounding one
spending address's coins: a review ("Consolidating X KAS", read-only) whose fee row's Edit swaps
in `SendFeeEditorScreen` in place (`editingFee`, `showFeeEditor(_:)`); the Max amount is worked
out again when the fee speed, a custom fee or the coins change. Amounts on the step screens are
`KaspaUnit.plain` (trailing zeros trimmed, "2.5 KAS"), never `%.8f`. The pieces and the step flow are KaPay's (KaChat Wallet's), ported
2026-10-28; keep them matched with KaPay's copy.

A send is steps, each sliding in (forward from the right, back from the left: a `Step` enum and
`go(to:)`), each drawing its own header (`SendStepHeader`) with the navigation bar hidden:
1. **To**: `SendStepScreen` + `SendStepQuestion` ("Who are you sending to?") + `SendRecipientCard`
   (`focusOnAppear`; Paste, Scan QR and Addresses pills under the field). On this first step the
   header has only the title and Cancel sits at the bottom beside Continue (`SendContinueButton`);
   later steps have Back and Cancel in the header.
2. **From**: "Where are you sending from?" with the Chatting Address and Choose an Address pills.
   Chatting Address shows a card with its address and balance; Choose an Address lists every
   address right on the screen (`OwnAddressList`: cards with Used / Unused and the balance, a
   check and teal outline on the picked one), no sheet. Picking the chatting address from the
   list goes back to its pill; Continue stays off while Choose an Address is on with nothing
   picked. The screen loads the From balance itself (`.task(id: source)`).
3. **Amount**: `KaspaKeypadAmountEntry`, the app's own number pad (`KaspaKeypad`,
   `KeypadAmountText`: 1-9, the locale's decimal point, 0, delete - hold to clear; at most 8
   decimals in KAS, 2 in your currency), so no system keyboard comes up. Above it a "To" chip and
   a "From" chip. The KAS / currency switch and Max stay; the footnote says Available, red when
   the amount is more than the From address holds. Continue reads "Review".
4. **Review**: `SwipeUpToSendScrollView` with `onBack`: "You're sending" with its value in your
   currency, a To / From / Total (amount + fee) card, then `SendFeeControls`. Only the fee speed,
   Coin Control and the fee's Edit can change; a Max amount is worked out again when they or From
   change. Starting the swipe dismisses any keyboard (`dismissSystemKeyboard()`).
5. **Fee editor**: the fee row's Edit (`onEditFee`) opens `SendFeeEditorScreen`: the whole fee on
   the keypad, "The network needs at least X KAS. A lower fee is raised to that.", an orange
   warning above ten times the minimum; Cancel and Confirm at the bottom, Confirm back to the review.

Where the steps start:
- `WithdrawKaspaView` opens on To; a pre-filled recipient (the Address Book) or a payment
  request on From, with Back still reaching To (a request's Amount has the amount fixed: no
  keypad, the request summary instead); From is skipped when it's fixed (an address's own Send,
  `lockedSource`); Compound UTXOs opens on the Review.
- The chat's Send KAS sheet (`ChatDetailView.paymentSheet`, `PaymentStep`) has no To step (the
  recipient is the chat): it opens on From, with a "To <name>" chip above the question, then
  Amount with the To and From chips, and its Review also holds
  the encrypted memo field (it changes the fee, so a Max amount is worked out again), the
  empty-chatting-address warning and the dust warning.

Every payment request is paid here, on Send Kaspa with it filled in, wherever it was tapped,
pasted or scanned (since 2026-11-21: KaPay is retired, so `KaPayHandoff` is gone;
`KaChatLinkRouter.openPaymentRequest`). Your own request shows itself. A request's QR holds its
kachat.app link; `kapay://pay/...` links older apps made still open here.

Every send has a **From** step: Chatting Address (the default) or Choose an Address
(`OwnAddressList`: every address of the account, each marked Used or Unused), so it is always
plain which address the Kaspa leaves. Request Payment (`CreatePaymentRequestView`) is steps
too: "Where do you want to be paid?" (Fresh Address, or Choose an Address with `OwnAddressList`
on the screen), "How much?" on the keypad, then a review with the memo; its bottom button is Copy
Payment Request (Share sits under the memo), or Send Payment Request when it was opened from a chat. There is no "primary spending
address" in the UI and no Chats Payment Privacy (removed 2026-10-13: no fresh-address offers to
contacts; payments go to the contact's chatting address; other clients' `addr_pool` envelopes are
swallowed). A 1:1 chat payment From a spending address is a plain transfer plus a `payment_notice`
from the chatting address, so it shows in the chat on both sides (MESSAGING.md). Wallet has one Manage Addresses card; Manage Addresses lists the chatting address
first, then the spending addresses.

| Piece | What it is |
|---|---|
| `SendStepHeader` / `SendStepScreen` / `SendContinueButton` / `SendStepQuestion` | A step's header (Back, title, Cancel), its frame with Continue pinned at the bottom (Cancel beside it on a first step), and its big question |
| `SendStepChip` | The "To …" / "From …" glass chip above a step's content (the From and Amount steps, the chat sheet's "To <name>"); `isAddress` shows an address monospaced and cut in the middle |
| `KaspaKeypadAmountEntry` / `KaspaKeypad` / `KeypadAmountText` | The Amount step: the app's own number pad and the big typed amount |
| `SendFeeEditorScreen` | The Review's fee editor (the fee on the keypad, the network minimum, the high-fee warning) |
| `SendRecipientCard` | Address or name, with Paste, Scan QR and Addresses pills under the field and the lookup status. The screen runs the .kachat lookup (`NameServicesClient.resolveEverywhere`) |
| `SendSource` | Where a send comes from: the Chatting Address or a chosen address |
| `OwnAddressList` | The account's addresses (chatting first) as cards with balance and Used / Unused, the picked one checked - the From step and Request Payment's "Where do you want to be paid?" |
| `SelectablePill` | A choice pill, the chosen one filled in (From, Request Payment's address) |
| `KaspaAmountEntry` | The big amount typed on the system keyboard, the KAS / currency switch and Max (screens not yet on the steps) |
| `SendFeeControls` | Network fee, the speed, and Coin Control. With `onEditFee` (the Review) the fee has an Edit pill that opens `SendFeeEditorScreen`; without it, tap the fee to type a custom one |
| `SendInfoPill` | A small one-line pill (available balance, fee) |
| `SendActionButton` | Slide the knob to the right end to send. `requiresSlide: false` makes it a tap, for a step that moves nothing by itself |
| `SwipeUpToSendScrollView` | Wallet's Send Kaspa and a spending address's Send (as in KaChat Wallet): swipe the bottom bar up about a third of the way and the whole screen rises into a full-screen BlockDAG (`BlockDAGAnimationView`) while sending, then Sent with the transaction, or Failed with the error and Try Again. Draws its own header (`SendStepHeader`; with `onBack`, Back and Cancel - the Review step). Debug builds launched with `KACHAT_FAIL_SEND=1` fail every send (`SendFailureSimulation`). Also the chat's Send KAS sheet. `dismissSystemKeyboard()` puts any keyboard away |

Change these pieces rather than one screen, so the screens stay matched.

### Swap

Back since 2026-11-23 (owner's call; it left for App Review guideline 3.1.5(iii) on 2026-10-01, which
asked for exchange licensing per country): the Wallet tab's Swap button (beside Send, Receive and
Request; it replaced the Swap Stablecoins card) opens `SwapView` full screen
(`Views/Tokens/SwapView.swift`, `SwapService`, `SwapModels`, `ChangeNowAPIClient`).
- Swap's history (`kachat_swap_history_<address>`) and agreements are per account and go with it
  (`SwapService.removeAllData`); its choices reset on an account switch, and `TrestlyTrade.run`
  refuses a target that isn't the unlocked key's address (audit 2026-11-24 #5). ChangeNOW's answer
  must match the request (payout address, coins, amount) before its deposit address shows, and the
  deposit card is built from the created exchange (amount, coin, payout address). XRP (`needsMemo`)
  shows ChangeNOW's destination tag (`payinExtraId`) as required, and a payout tag goes as
  `extraId` (audit 2026-11-24 #1, #2, #6).
- First `SwapAgreementsView` ("Before You Swap"), until accepted on this account
  (`kachat_swap_agreements_v1_<address>`; bump `SwapService.agreementsVersion` when the text
  changes): ChangeNOW's and Trestly's, each a third party with its terms and one checkbox; Continue
  needs both.
- The screen is the old ChangeNOW Swap (You Send, flip, You Get, Swap History, Add to Portfolio):
  KAS is always one side. Any other coin goes through ChangeNOW: a deposit address and QR, paid by
  the person; swapped KAS lands on a fresh spending address. Its key is built in:
  `KaChat/Secrets.xcconfig` (gitignored, from `Secrets.xcconfig.example`) feeds `ChangeNowAPIKey`
  in Info.plist through Version.xcconfig's `#include?`; Xcode Cloud writes the file from the
  workflow's secret `CHANGENOW_API_KEY` (`ci_scripts/ci_post_clone.sh`). With no key, ChangeNOW
  coins say "ChangeNOW swaps aren't available in this build."
- kUSDT (first in the coin picker, `SwapCoin.kusdt`) goes through Trestly's pool instead: the quote
  is Trestly's `prepare` (only "You Send" is typed), Swap runs `TrestlyTrade.run` with a minimum 1%
  under the quote, shown in `TrestlyApprovalSheet` (`native`), signed only on Approve, from the
  Chatting Address or one picked under Swap From (`KusdtSwapFromPicker`: addresses holding kUSDT or
  KAS, never quantum). `TrestlyTrade` is the one trade path, shared with `TrestlyProvider`: holds,
  requotes, reserved coins and the swap's notification all live there.

### Tokens (kUSDT)

Ported from KaPay on 2026-11-19 (KaPay's CLAUDE.md "Tokens (kUSDT)" is the full reference; keep the two in step). Since 2026-11-21 KaChat trades too (all-in-one): Wallet's Swap trades KAS ⇄ kUSDT itself (see "Swap"); Trestly's site inside KaChat (no longer opened from anywhere since Swap Stablecoins left on 2026-11-23) connects to one address (`TrestlyProvider`, kusdt-open SPEC section 14); trades are checked and built by Trestly's own pool code (`kusdt-wallet.js`, pinned) in the hidden builder page, which a content rule list keeps off the network except the public Kaspa node WebSockets (`wss://*.kaspa.stream|red|green|blue`); its HTTP goes through `KusdtNetRelay`'s allow-list. Swaps are approved in `TrestlyApprovalSheet`.
- `Services/Tokens/`: `Kusdt` (deployment ids, the pinned KCC20 template `Resources/kusdt-kcc20-template.json` checked by SHA-256, the 112-byte state and its P2SH script), `KusdtBalances` (Trestly's API, each coin believed only once the node holds that outpoint at the recomputed script with kUSDT's covenant id; `Expected` coins a send just made), `KusdtCore` (Trestly's WebAssembly builder in a hidden, offline `WKWebView`, files in `Resources/KusdtCore/` hash-pinned), `KusdtTransfer` (sends of at most 3 coins, KAS for the fee and change coin from the same address, fee from the token's own KAS on a whole send, every output checked before submit; Combine Coins). A send marks itself with `AddressActivityNotifier.markOwnTransaction`, so its KAS change is never "Received KAS".
- `Views/Tokens/`: `TokenWallet` (refresh, Discover, visibility, fresh addresses, pending coins, Received notifications polled every 30 s from `MainTabView` (90 s until 2026-11-22), titled just "Received 1.00 kUSDT" with no address line, history kept on the phone, cleared with the account), `TokenBalanceCard` + `SlidingCardPager` + `BalancePagePills` (the Wallet tab's card swipes Kaspa ⇄ kUSDT; each says Tap to Manage: Kaspa opens Manage Addresses, kUSDT opens `TokenManageView`), `TokenManageView` / `TokenAddressView` / `TokenAddressVisibilityView`, `TokenSendView` (with Fund This Address), `TokenCombineView`, `SendAssetChooser` (Wallet's Send asks "What are you sending?"), `TokenSupport.swift` (`fittedSheetDetents`, `lowercasedKaspaAddress`, `SwipeUpLabels.transaction`).
- A tapped "Received kUSDT" notification (thread `token-received`) sets `TokenRoute.pending` and opens Manage kUSDT on the Wallet tab; the Notifications list has the `.token` source.
- Tokens live only on the Chatting Address and regular (legacy P2PK) spending addresses, never quantum ones, and never go to a script address. So Receive hands out a fresh REGULAR address (`WalletManager.freshReceiveAddress`, `lowestUnusedRegularAddress`), and Manage Addresses' Address Actions has Generate Non-Quantum Address and Generate Quantum-Resistant Address. Each address row's ⋮ has Send to Chatting Address. Every receive screen is `Views/Shared/AddressReceiveView.swift` (QR on white, privacy note, tap anywhere to copy).
- Every Manage kUSDT row has a ⋮ (owner's call, 2026-11-21, the Chatting Address too): Rename, Copy, Show QR Code, Send to Chatting Address, Combine Coins (more than one coin) and Hide; the Chatting Address's has only Copy, Show QR Code and Combine Coins.
- Each Manage kUSDT row carries Manage Addresses' Used / Unused tag (owner's call, 2026-11-20, as KaPay has it; `TokenManageView.isUsed`): orange Used, green Unused. The Chatting Address is always Used; another address is Used once it holds kUSDT (units or coins), has kUSDT history on this phone (`TokenWallet.activity(of:at:)`), or Manage Addresses knows it as used (a `SpendingAddressEntry` with `everUsed` or a balance: the cached list first, then the live one). No "Checking" state: it shows what's known now.
- Every address Manage kUSDT lists also shows in Manage Addresses (owner's call, 2026-11-20, as KaPay has it). **One way only, never a two-way sync:** an address using kUSDT needs KAS on it (the network fee, and the 1.5 KAS every kUSDT coin carries), so it must always be visible on the Kaspa side; a Kaspa address doesn't need kUSDT, so Manage kUSDT never has to list Kaspa addresses. `TokenWallet.listedSpendingIndices(of:)` is that set. Manage Addresses shows any of them that's hidden again once its list loads (`showKusdtListedAddresses`). Its row ⋮ Hide refuses with a toast. Address Visibility shows them locked and dimmed, and a tap gives the "Shown for kUSDT" alert. Hide All leaves them shown. Once one is hidden from Manage kUSDT, it hides here as usual.

## Documentation

| File | Description |
|------|-------------|
| `CLAUDE.md` | This file - project overview and guidance for Claude Code |
| `README.md` | Public project overview: what this repository is, with a link to home.kachat.app |
| `MESSAGING.md` | Kasia messaging protocol - encryption, handshakes, message types |
| `POOLS_v2.md` | gRPC node pool architecture - discovery, scoring, failover |
| `PUSH_NOTIFICATIONS.md` | Push notification architecture and rollout notes |
| `KAPOSTS_INDEXER.md` | Handoff/build guide for the KaChat-owned KaPosts indexer (protocol, API compatibility bar, required extensions). Server contract only: the feature left the app 2026-10-24 |
| `KAPOSTS_REPLIES_FIX.md` | The short server ask: the two read endpoints that make reply threads complete (`get-post`, optionally `get-thread`). Hand this over on its own; `KAPOSTS_INDEXER.md` is the reference behind it. Server contract only: the feature left the app 2026-10-24 |
| `PUBLIC_CHATS_INDEXER.md` | Handoff/build guide for the KaChat Public Chats indexer (curated room history incl. `chess-arena`, REST spec, push, Docker; code/API keep their `broadcast` identifiers). Server contract only: the feature left the app 2026-10-24 |
| `TRANSLATION_SERVICE.md` | Handoff/build guide for the KaChat post translation endpoint (server-side translation of KaPosts, cached by txid; replaced the on-device Apple Translation / ML Kit path). Server contract only: the feature left the app 2026-10-24 |
| `PUSH_EXTENSIONS.md` | Server handoff: remote push for public chats + KaPosts (registration fields, APNs payload specs, routing contracts). The app registers the public chat and KaPosts fields empty since 2026-10-24; §5 (call ringing) is retired since calls left on 2026-11-11 |
| `GROUP_MESSAGES_INDEXER.md` | Server handoff: the batched group-message read (`POST /group-messages/by-blinded-group-ids`) and the `since` reads (`/group-messages/since`, `/group-control/since`) the app polls for live group traffic while open; both fall back to the older paths (per-member GETs, the block stream) on an indexer without them |
| `ARCADE.md` | KaPlay's arcade (Snake, 2048): the `#kplay-arcade` stamp, SplitMix64 and both games' exact rules with test vectors (the indexer replays every stamp), the `/arcade/leaderboard` endpoint and `kachatarcade://` challenges |
| `ONLINE_CHESS.md` | Online Chess (5.1): public 1v1 and 8-player knockout tournaments in Kaspa Hub > Chess Online, every move a transaction in the `chess-arena` room, no referee (deterministic rules in `ChessTournamentEngine`), chain-time clocks with allowances; leaderboard handoff for the indexer. Server contract only: the feature left the app 2026-10-24 |
| `KACHAT_APP_LINKS.md` | The kachat.app link site (`web_site/server/`): every shared link is `https://kachat.app/...` - Open Graph previews everywhere, Universal/App Links into the app, post-only page with download buttons without it |
| `STATS_INDEXER.md` | Server handoff: `GET /stats`, the per-category transaction counts (messages, payments, groups, public chats, KaPosts, chess...) behind KaChat Stats. The iPhone screen left 2026-10-24 and is back since 2026-11-21 (Kaspa Hub > Stats); home.kachat.app reads the same endpoint |
| `STATS_WINDOWS_FIX.md` | The short server ask: 24h/7d windows for the six chat-side `/stats` categories (messages, handshakes, payments, groups, self-stash), which today send `total` only. Hand this over on its own; `STATS_INDEXER.md` is the contract behind it |
| `KACHAT_NAMES.md` | Design of `.kachat` names on Kaspa covenants: gap registry (uniqueness), commit-wait-register, name UTXO with trustless list/buy, offers, address-keyed profiles, indexer + app work, phased plan |
| `INDEXER_HANDOFF.md` | The queue of indexer work from iPhone changes: the iPhone session writes what the indexer needs to support an app change, and the indexer session works the Open items when the owner says "check iOS". This session never changes kachat-indexer itself |
| `KACHAT_NAMES_INDEXER.md` | Indexer handoff: (A) run a testnet-10 instance of the whole indexer for the app's Testnet mode; (B-E) the `names` module - following the covenant registry from spends, offer payload markers, status/expiry, address profiles (`kchat:1:profile:`), the names/market/identity API and name push events |
| `NEXTCLOUD_SYNC.md` | The shared contract for Nextcloud Automatic Sync: contacts only on iOS since 2026-11-05 (`kachat-contacts.json`); for Android, Desktop and the extension until they move, one `kachat-backup.json` overwritten in place (never extra files), folder discovery, read-merge-write, merge rules (chats, groups, Address Book, portfolios - the wallet app's, passed through here), timings, error handling, per-client conformance |
| `DETERMINISTIC_ALIASES.md` | Deterministic alias derivation (shipped protocol - see `Utilities/DeterministicAlias.swift`): algorithm, migration notes, legacy-alias compatibility |
| `NO_HANDSHAKE_MESSAGING.md` | No-handshake 1:1 chats (5.2): the inbox tag on a first message, Message Requests, private chats, the indexer handoff and porting notes |
| `QUANTUM_SAFE_CHATS.md` | Plan, not built: hybrid post-quantum (X-Wing) chats against harvest-now-decrypt-later, with seed-derived self-sealing, per-conversation setup, groups, UI and rollout |

Historical plan/design documents were removed from the repo in the 4.0 hygiene pass; shipped code is the source of truth for those features.

## External References

The `external/` directory is gitignored except for `external/opus/`, which contains the vendored `Opus.xcframework` (a real linked build dependency for voice messages, not reference material). Reference repos (rusty-kaspa, kasia-indexer, kaspa-grpc, etc.) may be cloned locally under `external/` for protocol research, but they are not tracked in this repository.
