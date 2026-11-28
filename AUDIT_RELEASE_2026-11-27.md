# K release audit, 2026-11-27

**Status (later the same day): fixed, built, retested on the simulator; not committed.**
Everything below is fixed except, by choice or need:
- R3: Connect still defaults to the Chatting Address (owner decision); site signing now refuses
  every KaPost-shaped text, which closes the attack.
- C6: the permit cap applies when K knows the order's amount; an unknown amount is no longer
  refused (refusing it would stop every card buy, since the page asks before the card is charged).
- B7: the second UTXO read for baselines is kept (reusing a cached total risked false
  "Balance increased").
- T2: a tap during a system sheet's dismissal is still iOS's; a tap while the Hub menu opens now
  closes it instead of reaching the screen beneath; the post-close tap and the Back-with-keyboard
  tap work in one go.
- Explorer screen text stays English (owner's choice); its demo numbers are Debug-only.
- The Mac Release build still uses the development push environment (needs its own entitlements
  file in the project); App Attest's entitlement is kept.
Retested on the simulator: Chats rows, one-tap Back while typing, the Hub menu, the Explorer,
Settings order, the Wallet's fiat; no crash. Translations were added in all 19 languages (3,138
keys each) but not read by a native speaker.

**What was checked:** the code at d88891ea plus the working tree (today's smoothness fixes and the always-in-the-bell change, built but not committed). Five reviewers read it in parallel:
- today's changes (regressions);
- security;
- battery, network and memory;
- payments and messaging;
- dead code, strings and docs.

Their key findings were then checked against the code. After that the app was built, launched on the iPhone 17 Pro simulator and tapped through; see "Tested in the app" at the end.

**Verdict:** no Critical or High bug in money, keys or crypto. Before release, the items under "Fix before release" should be done:
- two regressions from today's bell change;
- one way a website could sign Posts actions in your name;
- two notices that can be lost or sent from the wrong account;
- three crash traps;
- untranslated chess and notification text;
- the release build settings.

**Severity:**
- **High:** most users will see it, or it crashes / sends something wrong.
- **Medium:** real, but needs a specific situation.
- **Low:** minor.

## Fix before release

**R1. Received Kaspa can buzz the phone with notifications off (regression, today).**
- Where: `AddressActivityNotifier.swift` `postReceiveNotification` / `postBalanceIncreasedNotification` call `applySoundPreference(to:)`, which runs `Haptics.impact` when sound is off and vibration on.
- Cause: now that bell-only rows go through these functions, the haptic fires even with notifications or Address Activity off.
- Fix: apply the sound and haptic only when the banner is shown; never for "Balance increased".

**R2. The first catch-up after the update can file months-old receives in the bell (regression, today).**
- Where: `AddressActivityNotifier.runCatchUpIfNeeded` now attributes every own address's balance increase, quiet ones too. Only the chatting address has a floor (`chattingCatchUpFloorKey`).
- Effect: for a Cold Storage account with Alerts Off, or spending addresses with their switch off, receives that were never marked handled surface once (up to 10 per address). They're dated when they happened and don't raise the badge, but they clutter the list.
- Fix: give every address a floor like the chatting address's, set silently the first time it's attributed, and file only newer transactions.

**R3. A website's Sign request can make valid Posts actions in your name (security, Medium).**
- Where: `KaChatSiteWallet.sign` and KaPost actions both use the KasWare personal-message Schnorr scheme with the same key (Connect defaults to the Chatting Address). The indexer accepts an action whose signature matches the embedded pubkey.
- Attack: a compromised `*.kasshi.io` page asks to sign `delete:<post id>`, `follow:<pubkey>` or `<base64>:[]`. The Sign sheet shows only that string. Once approved, anyone can broadcast it as a delete, follow or post by you.
- Fix:
  - refuse to sign texts in KaPost's signing shapes (`edit:`, `delete:`, `poll:`, `pollvote:`, `tip:`, `schedule:`, `cancel-schedule:`, `follow:`, `unfollow:`, `<base64>:<json>`, `<64 hex>:…`);
  - better still, never sign for a site with the chatting key: default Connect to a regular spending address;
  - long term, domain-separate KaPost signatures (indexer change).

**R4. A payment notice can be lost, or sent from the other account (Medium).**
- Where: `ChatService+PaymentPools.sendUnsentPaymentNotices` reads `unsentNotices`, awaits the sends, then writes the leftovers back under the account that's current at the end.
- Effect:
  - a notice kept while the retry runs is overwritten and lost, so the payee never sees the payment or memo in the chat;
  - after an account switch mid-retry, A's notices are written under B's key, and then either dropped or sent from B's chatting address. That links the accounts, which `keepUnsentNotice` exists to prevent.
- Fix: capture the account at the start, re-read the list at the end and remove only the sent txids, and keep notices whose contact isn't loaded.

**R5. A Send Dollars from a chat whose answer was lost can be recorded under the wrong account (Medium).**
- Where: `TokenSendView`'s 3-minute watcher calls `onSent` → `ChatService.recordTokenPayment`, which uses whatever account is current.
- Effect: switch accounts within 3 minutes and the "Sent kUSDT" bubble lands in B's chat, and B's chatting address sends the notice (fee, and the accounts get linked).
- Fix: pass the owner and drop the call if the account changed.

**R6. Three crash traps on bad input (Medium).**
- `KaChatSiteWallet.swift:306`: `abs(now - ms)` overflows on `Timestamp: -9223372036854775808` from the page. Fix: range-check `ms` first.
- `CardBuy.swift:241`: `UInt64((dollars * 1.01 + 1) * 1_000_000)` traps on `inf` or a huge amount from Trestly's order API. Fix: accept only finite amounts up to 1,000,000.
- `ChatService+Fetching.swift:227/234`, `ChatService+Decryption.swift:767/769`, `ChatService+PushAndSync.swift:1441`: `totalToUs += output.amount` traps if a (user-configurable) REST answer sums past `UInt64.max`. That happens on every sync, so the app would crash on every launch. Fix: `addingReportingOverflow` and skip the transaction (the Explorer already does this).

**R7. Untranslated text people see often (High, strings).**
- 1:1 chess status (`ChessGameService.statusText`: "Your turn", "Checkmate - You win!", "Game declined", "You lost on time"…) shows in English in every language.
- Notification and banner previews are English on the lock screen:
  - app banners (`ChatService+Fetching.swift:3467-3495`: "Reacted %@", "Edited a message", "Sent a photo / voice message / video / file");
  - the push extension (`NotificationService.swift:2118-2126`, `:2166-2168`, `:1939`). The extension's table has only 16 keys.
- Fix: add keys in all 19 languages (both tables) and look them up.

**R8. Release build settings.**
- `KACHAT_IS_RELEASE = NO` (`Version.xcconfig`), so About shows "5.4 (2579)". Set it to YES for the App Store archive, as its comment says.
- Check before a *local* archive: the Info.plists use `$(KACHAT_BUILD_NUMBER)` = 1 and the "Local Build Number" phase skips installs, so a local archive may go up as build 1. Xcode Cloud rewrites it and is unaffected.
- The Explorer shows made-up numbers when a source fails, labeled "demo":
  - K Activity (`ExplorerDemo.kActivity`);
  - the Network Fee tile and the fees chart when Kaspalytics doesn't answer, and always on testnet.
  - A wallet shouldn't ship random-walk numbers: show "–" in Release and keep the demo under `#if DEBUG`.

## Should fix

**Battery and network.**
- **B1. Full block stream app-wide during a KaPost indexer outage** (`KaPostsChainFallback`). Three failures in 120 s, including cellular timeouts, turn on about 10 blocks/s on any tab, on Wi-Fi or cellular. Fix: only while a Posts feed is on screen and on a non-expensive path, and don't count timeouts right after a network change.
- **B2. `mempoolPayloadByTxId` never pruned on the self-stash path** (`ChatService+UtxoProcessing.swift:1655`, `resolveAndProcessSelfStash` returns without clearing it). Every contact transaction with self-change keeps its hex payload for the session; group photos add MB a day. Fix: remove the entry on every exit, cap it, and clear it on account switch.
- **B3. Control Center, the notification shade or Face ID re-run the full group catch-up** (`KaChatApp` `.active` after `.inactive`). That's 2N+1 indexer requests for N groups, plus App Group writes with no unchanged check. Fix: run the foreground block only when coming from `.background`, or debounce it 30-60 s.
- **B4. With push registered, rooms and groups still poll every beat** (`PublicChatService.sweepClosedRooms`, the GroupChatService pass). Fix: every 5 minutes when push is reliable, with a push-triggered fetch, as KaPost does.
- **B5. Timers not on `ForegroundBeat`.** The 1:1 sweep (which calls `syncInbox()` every 30/60 s whatever the subscription or push state), its group ride-along (180 s), the unnamed-identity sweep (60 s), KaPost's new-posts check (60 s) and the open-group pass. On cellular the radio wakes about twice per beat.
- **B6. Today's bell change costs REST per receive** (`AddressActivityNotifier`). With Address Activity off, each receive is now fetched (4 tries) even when it won't ring. Chat payments are fetched twice, and the catch-up pulls 10 full transactions (mostly your own photos and voice on the chatting address). Fix: share a short txid cache with ChatService, and read 3 transactions, not 10.
- **B7. Every UTXO batch forces a balance read and UserDefaults writes**, contacts' batches included (`ChatService+UtxoProcessing.swift:494`). Each message you send also rewrites the 500-entry handled list and reads the baselines again.

**Correctness.**
- **C1. Cold Storage's quick return skips the Used probes** (today, L1). A just-used change address stays Unused until a pull. Fix: on a quick return, still probe the changed and unknown addresses.
- **C2. Chats rows freeze day and language text** (today, C4). The equatable row has no day or locale input, so "10:15 PM" doesn't become "Yesterday" after midnight, and previews don't follow a language switch until the row's data changes. Fix: add a day stamp and the locale to the row's inputs.
- **C3. Chats list memo can give rows stale messages** (today). `EntriesKey` compares conversations by tail only, so a long voice note's earlier part going Failed can show a stale status. Fix: memoize ids and order, then map to the live conversations.
- **C4. Manage Addresses' debounce can cancel a load in progress** (today, L4), leaving rows "Checking" and caching a half-probed list. Fix: cancel only while it's sleeping, or queue one more reload.
- **C5. A payment From a spending address whose answer was lost never sends its notice**, even after it lands (`settleUnconfirmedSend`). The payee gets the KAS but no chat bubble or memo.
- **C6. Card-buy permit cap only applies when K already tracks the order** (`CardBuy.swift:236-244`). Otherwise a permit up to $1,000,000 to an unchecked spender reaches the sheet. Fix: refuse unless a followed order has a known amount.
- **C7. A kUSDT payment notice counts as verified on the REST API's covenant id alone** (`ChatService+PaymentPools.swift:664`). Fix: confirm on the node while the coin is unspent.
- **C8. Shortcuts can read all decrypted messages and send messages with no K prompt** (`KaChatShortcuts.swift:148-238`). Fix: confirm, or drop `contentRaw`.

**Seen in the app.**
- **T1. A room opened for the first time lands a few messages above the newest** (#kaspa, just joined). The jump button then works. It isn't from today's changes: the first scroll to the bottom runs while the room is still filling (lazy row heights), so it lands short. Fix: scroll again once the first page is in.
- **T2. A tap right after closing a sheet or a post is lost** (the dock after the bell's Done; reopening a post right after Back; a Hub menu item tapped while the menu is still springing open). Each worked on the second tap. Fix: shorten or let taps through the dismiss.

## Low

**Strings.**
- No keys yet:
  - the Kasshi sign-in error and its "Couldn't Sign In" alert;
  - Swap's "Sent from K";
  - Portfolio's "Delete %lld Transactions?";
  - the .kachat expiry footer;
  - Face ID "Unlock to sign in to %@";
  - "Send Kaspa from Address #%lld";
  - "Cold Storage %lld";
  - several group system lines and progress labels;
  - Portfolio asset descriptions.
- About 200 service error texts (`KasiaError`, UTXO and fee errors) are English everywhere: localize the common ones first.
- The Explorer (about 45 strings) is English by the owner's choice; its labels still say "KaChat Message" and "KaPost". Decide before release.
- Old names in text people see:
  - "KaPost's server isn't answering", alert titles "KaPost", and "Turn off Testnet in Settings > Connection" (the path is now Connection Settings);
  - "No KaChat backup was found", "That file isn't a KaChat contacts export";
  - the export file name "KaChat Contacts…";
  - the extensions' copyright "© 2025 KaChat".
- `NSPhotoLibraryAddUsageDescription` is the only permission prompt that doesn't say K.
- About 40 unused keys ("Show .kachat Endings", "KaChat Stats", "You Send", "Swap History"…).

**Dead code.**
- The onboarding sync hold (`holdSyncForOnboarding` and its branches) and `initialSyncPhase`: published 5 times per sync, nothing reads it.
- Unused functions:
  - `hasBeenPlayed`, `isJoined`, `lowestUnusedQuantumAddress`, `prepareForChatMessage`;
  - `GroupMentionCodec.encodeForSending`, `refetch`, `typedQuery`, `makeQRCodeImage`, `totalUnreadCount`, `doneCount`;
  - `StatsJSON`, `ExplorerAPI.UTXOAnswer`.
- `publicChatBadge` observed and never read in the dock copy.
- `TokenWallet.sample()` (fake "alice.kachat" data, unreachable).
- Stale comments about Show .kachat Endings and the Explorer's "design stage".
- P2P_CALLS.md (a proposal for a feature that's out).

**Entitlements.**
- The Mac entitlements still have addressbook and `aps-environment = development` for Release.
- The App Attest entitlement is unused.

**Memory and battery.**
- `FeeShimmerOverlay` runs uncapped (120 Hz).
- `AddressBookManager.photoCache` is count-only (about 100 MB ceiling); `ProfileQRCodeCache` has no limit.
- The QR scanner's camera can stay on if it's dismissed right after it opens.
- Two 60 s clocks redraw whole chat screens, in the background too.

**Smaller correctness.**
- Kasshi's 10-minute payment hold resets when Kasshi is closed.
- A Trestly "maybe sent" hold can lift early after a relaunch.
- Cold Storage Max can be refused for a quantum address with more than 32 coins after a "Not confirmed" send.
- The audio conversion reads a `CMBlockBuffer` without checking it's contiguous.
- The bell can lose up to 1 s of rows on a crash.
- The stashed Posts feed misses deletes and edits seen during an indexer outage.

**Changes made today without the owner asking (to confirm):**
- `OwnAddressList` rows are now a flat fill instead of glass;
- a Hub section opens after a 0.15 s fade instead of the spring close;
- Kasshi's sign-in shows 0.4 s after the page.

**Display, seen in the app.**
- Fiat is inconsistent: "$0.1399" on the Wallet card, "$0.14" on Manage Addresses.
- Zero is "0.00000000 KAS" on cards but "0 KAS" elsewhere.
- Explorer history shows "−0 KAS" for posts and handshakes (the fee rounds away).
- kUSDT is "2.659812" in the Explorer, "1.00" elsewhere.
- Settings lists Posts between Diagnostics and Help (not alphabetical).
- Choose an Address lists spending addresses as #2, #8, #0, and the quantum #0 has no tag there.
- The Send To step shows the name twice (the card and "Resolved: …").

**CLAUDE.md drift.**
- Line 21 still lists KaChat Stats.
- "Settings > KaPosts / KaPost", "KaPlay" and "Kaspa Hub > Chess Online" in several places (lines 353, 433-435, 477, 869, 1367).
- The Swap paragraph still describes "You Send / flip / Swap History" (line 1271).
- The PUSH_EXTENSIONS row contradicts line 428.
- The Code Organization tree is missing Explorer/, Tokens/, KaPosts/, Chess/, Games/, Portfolio/ and ColdStorage/.

## Checked and fine

- **Keys:** device-only Keychain with Secure Enclave wrapping. No secrets in logs, the App Group or the clipboard (seed and kpub copies are local and expire in 30 s). Face ID gates seed, keys, names and Delete Account.
- **Signing surfaces:**
  - Kasshi: https, allowed hosts, main frame, the narrow auto-sign.
  - Trestly: origin pinned, the approval shows the minimum out.
  - KusdtCore: pinned files, content rules, relay allow-list.
  - The in-app browser stays on its site.
- **Deep links** only pre-fill; payment requests go through Review. There are no ATS exceptions.
- **Crypto:** unique nonces (random 12 bytes; group device id plus counter), sent-message HKDF, `SecRandomCopyBytes` entropy.
- **Sends:**
  - swipe-to-send can't double-send;
  - Max and fee re-pricing are correct, and rebuilt sends that cost more than the Review are refused;
  - kUSDT outputs are checked before submit;
  - Cold Storage `broadcastSigned` checks;
  - Swap's deposit can't be paid twice;
  - .kachat prices are capped at what was shown.
- **Account removal** covers every per-wallet key. Debug-only flags are all under `#if DEBUG`. There are no TODO/FIXME or `print(` calls. All 19 languages have the same 3,104 keys with matching placeholders.
- **Today's smoothness fixes** reviewed line by line:
  - `PayloadSniff` misses no real reply or chess message;
  - the chat row `==` covers unread count, silenced, the last message, edits, fetch state, reactions and the name;
  - Posts' per-source feeds, reply bar, snapshot, scheduler and translation changes are sound;
  - the bell store flushes on background and account switch;
  - Explorer observers cover every live read;
  - the group / 1:1 window caches and the Hub menu state are correct.

## Tested in the app (simulator, mainnet account, 2026-11-27)

Built and launched on the iPhone 17 Pro simulator. No crash. The only faults logged were 3 SwiftUI "Invalid Configuration" lines at launch.

After the owner's go-ahead, real on-chain actions were run too, each with the text "testing before release".

| Area | What was done | Result |
|---|---|---|
| Chats | Private ⇄ Public Chats switch | Fades, no row shuffle |
| Public room | Add Room, Join #kaspa, open, scroll up through history, Translate, jump to newest, back, leave the room (swipe Delete) | Works; first open lands short of the newest (T1) |
| 1:1 chat | Open kaspasilver, tap a payment bubble, View in Explorer | Details sheet and K Explorer's transaction page work |
| Kaspa Hub | Menu from a section, pick Posts / Cold Storage / Explorer / Kasshi / Arcade | Works; a pick during the opening spring is lost (T2) |
| Posts | Feed → Popular → Following → Feed, open a post, type a reply with "@kas" suggestions, back, reopen | Each feed keeps its posts; mentions suggest; the draft clears on close |
| Wallet | Send: name lookup, From (Chatting / Choose an Address), keypad 0.5, Review, fee editor, cancel | All steps work; nothing sent |
| Manage Addresses | Open, cards and tags | Works |
| Profile | Header, bell | Bell lists the Received KAS rows |
| Settings | Connection Status | Node and indexer connected, 155 ms |
| Cold Storage | Account card, Tap to View Addresses | Works |
| Explorer | Live home, search "kaspasilver", address page | Works ("−0 KAS" rows, old "KaPost" label) |
| Kasshi | Sign In sheet appears after the page, Cancel, page loads, X returns to the previous tab | Works; didn't sign in |
| Arcade | 2048 page and leaderboard | Works; didn't play (a finished game stamps on chain) |

**On chain (owner's go-ahead, mainnet):**

| Action | Result |
|---|---|
| 1:1 message to kaspasilver | Sent ✓; the Chats row's preview and time updated at once (value rows working) |
| Group message in "Test" | Sent ✓; the group row moved to the top with the new preview |
| Post | Published ✓ (green check), shown at the top of Feed |
| Reply to that post | Published ✓; the reply box cleared; the profile shows the post with 1 reply |
| Snake game | Game over at 1, "Score stamped on Kaspa" ✓ |
| Payment, 0.2 KAS to kaspasilver from the chat, memo "testing before release" | Sent ✓ (tx 72c5e798…20de271ef), bubble shows the amount and memo; fee re-priced when the memo was typed (0.00219603 → 0.00221803) |
| Bell after the payment | No false "Received" from the payment's change ✓ |

Total spent about 0.21 KAS (0.2 sent, the rest fees). Seen while doing it:
- T3: the 1:1 chat's Back needed two taps while the message box had focus (the first only dropped the focus).
- T4: a reply to your own post shows as an ordinary reply right after posting, with no thread line. It may join up once the indexer has it; check on a device.
- SwiftUI logged "Invalid Configuration" faults again around posting (18:26), as at launch. No visible effect, but worth a look in Xcode's console.

Not tried:
- the remaining transaction types (likes, follows, names, swaps, buy, Send Dollars, kUSDT);
- Rename (it would change the account's data);
- group chats beyond the list;
- push notifications;
- account switching;
- Delete Account.
