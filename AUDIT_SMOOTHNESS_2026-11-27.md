# K smoothness audit, 2026-11-27

**Status (later the same day): fixed and built, not committed, not tried on a device.**
Partial or left out, by choice:
- C1: the rebuild stays on the main thread. A byte check (`PayloadSniff`) now skips the chess and
  reply decodes for nearly every message, and each game is summarized over its own messages only.
- C6: done for 1:1 and groups, not rooms (no scroll view to measure there).
- C7: room reactions are memoized per room; there's no per-room snapshot object yet.
- C8: detection is prewarmed off the main thread for an open room's newest 60 messages; a row drawn
  before that still detects on the main thread.
- C11: only the comment is fixed (the guard was removed on purpose, to keep fling momentum).
- P5: a new thread level opens at its top; Back doesn't restore the earlier offset.
- P6: the trims are left as they were.
- P7: the rows aren't memoized (at most 4 re-sorts a second now).
- P9: there's no batch record for backfills.
- P10: back-to-top, the Bookmarks sort, the action-row layout cache and the text-parts key are left
  as they were.
- L5: labels are cached in memory; the rows aren't prebuilt.
- L12: the frozen "12s ago" on a pushed Explorer page is left.
- T4: lookups are no longer queued; the sync still runs on activation.

**Scope:** scrolling and screen changes only, in four parts:
- chats (the Chats list, 1:1, groups, public rooms);
- Posts and the bell;
- the wallet, address and other long lists (Manage Addresses, kUSDT, Cold Storage, Contacts, Portfolio, Explorer, .kachat, Settings, Arcade);
- moving between screens (dock, Kaspa Hub menu, sheets, Send steps, app activation).

**Method:** each part was read by its own reviewer. Every finding was then checked against the code; line numbers are as of commit d88891ea plus the working tree.

This audit builds on the 2026-11-24 and 2026-11-25 smoothness passes (CLAUDE.md, "Smooth scrolling"). What those passes fixed isn't repeated here.

**Severity:**
- **High:** a hitch most people hit.
- **Medium:** a hitch in some cases, or wasted redraws on a busy path.
- **Low:** minor.

The fix order at the end puts the biggest wins first.

## Chats

**C1. High: an open 1:1 chat rebuilds its whole history on every change.**
- Where: `ChatDetailView.swift:630-688` (`rebuildMessageSnapshotIfNeeded`), run from `.onChange(of: conversation?.messages)` (:1304).
- What happens: about half a second after opening, the chat holds its full stored history (`loadFullHistory`). From then on, every new message from the 2 s poll and every pending-to-sent flip re-runs the full rebuild on the main thread: a digest, a sort, two dedupe dictionaries, and a chess parse (`ChessCodec.parseAny(MessageReplyCodec.unwrappedText(...))`) of every message.
- Both parse caches hold 1,024 entries (`Models.swift:969`, :1432). Past about 1,000 messages they thrash, so every JSON-looking payload (voice parts, photos, replies) is decoded twice per rebuild.
- `ChessGameService.summarize` then re-sorts and re-parses once per game.
- Fix:
  - Rebuild off the main thread over a copy.
  - Add a fast path for the common case (new messages appended at the end).
  - Look for `"chess_` in the first bytes before any JSON decode.
  - Key the parse caches by txid.

**C2. High: name and picture lookups still redraw whole chat screens.**
- Where: `KachatNamesRegistry.identitiesChanged` (:1127-1131).
- What happens: it sends `ContactsManager.objectWillChange` and `AddressBookManager.objectWillChange` on every lookup batch (every 250 ms while lookups run). Everything observing those stores redraws:
  - the 1:1, group and room screens;
  - the Chats list;
  - every visible group bubble row (`GroupChatDetailView.swift:2880`);
  - every `GroupChatRow`.
- `ConversationRow` (`ChatListView.swift:2175-2177`) also observes `KachatNamesRegistry` and `AddressBookManager` directly, so `isRefreshing` and `revision` redraw every chat row.
- Scrolling up a busy room or group queues lookups, and each answered batch redraws the screen mid-fling. `IdentityChangeTicker` was built for exactly this, but these stores bypass it.
- Fix: have `identitiesChanged` tick only the ticker, and have these views observe the ticker.

**C3. High: scrolling up a group re-filters and re-sorts its whole history for every page.**
- Where: `GroupChatDetailView.swift:429-454`.
- What happens: the timeline cache key includes the loaded window (`loadedGroupMessageCount`). Each page loaded at the top re-runs the filter and `.sorted` over every message, the voice grouping, and the timeline.
- The 1:1 chat has a milder version: `DerivedMessagesCache.Key` includes `loadedMessageCount` (`ChatDetailView.swift:545-563`). Its `photosUnlockDate` also filters all messages three times when no date is stored yet.
- Fix: cache the filtered, sorted array on the content alone. A bigger window then only re-slices it.

**C4. Medium: the Chats list underneath redraws while a chat is open, and works during the pop.**
- While a chat is open:
  - `ConversationRow` observes all of `ChatService` (`ChatListView.swift:2173`) and `GroupChatRow` all of `GroupChatService`.
  - Every publish while a chat is open (entering it, marking it read, reactions, reply state, poll arrivals) re-runs the list underneath. That includes `allEntries`, which merges and sorts every chat and group (:1070-1090), and the bot-circle scan (:1096-1103).
- On the way back (`onAppear`, :431-438), during the pop animation:
  - `loadedConversationCount` is reset, so someone scrolled past row 80 loses those rows mid-slide.
  - `trimLeftConversationIfNeeded()` publishes `conversations`.
  - `refreshFilteredConversations()` filters and sorts every conversation synchronously.
- Fix:
  - Make the two rows plain Equatable value rows (as `ChatsRoomRow` is) with `.equatable()`.
  - Hold `allEntries` in state.
  - Don't reset the paging on appear.
  - Run the trim and refresh after the pop has finished (about 0.4 s).

**C5. Medium: switching Private Chats ⇄ Public Chats animates a diff of the whole list.**
- Where: `ChatListView.swift:971-977` and :389-391 (the dock's Chats tapped again).
- What happens: `CycleCapsuleButton` (`ActionSheet.swift:1306`) sets the page inside `withAnimation`. Both pages are one `List` with different row ids, so every chat row animates out and every room row animates in as one batch update. The result is a jumble and a hitch instead of a fade.
- Fix: `.id(listPage)` with `.transition(.opacity)` on the list, or switch the page with animations off and fade the container.

**C6. Medium: jump to newest animates across thousands of rows.**
- Where: the jump button (`ChatDetailView.swift:1564`) and the scroll after your own send (:1000-1010) both use `withAnimation { scrollTo("bottom_anchor") }`.
- What happens: after "jump to start" or a deep scroll up, that animates through every row in the window. This is the freeze the code already warns about at :4080 and :4146.
- The same pattern is in groups (`GroupChatDetailView.swift:604`) and rooms (`PublicChatChannelView.swift:678`).
- Fix: when the window is large, shrink it and jump without animation near the bottom, then animate only the last screen.

**C7. Medium: a public room redraws on any room activity anywhere.**
- Where: `PublicChatChannelView.swift:12` observes all of `PublicChatService`.
- What happens: other rooms' sweeps, read markers and arena traffic all re-run the open room's body. Each run rebuilds `Array(shownMessages.enumerated())` (:497) and the 20-argument row for each visible row. Each row's `reactions(forChannel:)` loops over every voice-note anchor (`PublicChatService.swift:1976-1991`).
- The rows are Equatable, but building their arguments isn't free.
- Fix: observe a per-room snapshot object (as the Rooms list does with `PublicChatRoomSummaries`), and merge reactions once per pass.

**C8. Medium: room rows detect the message's language in their body.**
- Where: `PublicChatMessageRow` → `canTranslate` → `PostTranslationService.canOffer` → `NLLanguageRecognizer` (`PostTranslationService.swift:130-136`).
- What happens: it runs on the main thread the first time each message draws, so opening a room pays it for every visible row during the push.
- Every row also observes `PostTranslationService` (:1569), so one translation redraws all rows.
- Fix: detect the language off the main thread when messages load, and pass the translation state into the row as a value.

**C9. Medium: the 2 s poll scans every chat's messages for each message it gets back.**
- Where: `findLocalMessage` (`ChatService+Fetching.swift:2779-2784`, called at :2385).
- What happens: the 90 s rewind returns recent messages again on every poll during a live back-and-forth, which is exactly when someone is scrolling.
- Fix: look in the contact's own chat first, or keep a txid index.

**C10. Low: the timeline ids build a string per row on every pass.**
- Where: `ChatTimelineItem.id` and `GroupTimelineItem.id` build `"message-\(uuid)"`.
- What happens: a lazy `ForEach` computes every id on every pass. After "jump to start" that is thousands of strings per pass.
- Fix: a Hashable enum id.

**C11. Low: restoring the scroll place while the finger is down.**
- Where: `ChatDetailView.swift:1791-1817`.
- What happens: the comment says the restore is skipped while dragging, but the guard was removed in a73ef06d. Both this and the bottom anchor can adjust the scroll in the same moment, which may show as a nudge under the finger (not reproduced).
- Fix: put `isTracking` back, or rely on the anchor alone; fix the comment either way.

**C12. Low: small per-row costs in the Chats list.**
- A voice-note last message re-reads up to 48 parts per pass (`ChatListView.swift:2345-2357`).
- A group row walks all reactions on every pass (`GroupChatListView.swift:117-148`).
- Each day separator copies the settings (`AppSettings.load()`, `ChatTimelineLayout.swift:110`).
- Fix: memoize each.

## Posts and the bell

**P1. High: Following ⇄ Feed throws the loaded feed away and rebuilds it twice, inside an animation.**
- Where: `onChange(of: selectedFeed)` (`KaPostsView.swift:951-965`) and the reset in `loadFeed` (:1900-1909).
- What happens: Following and Feed share `remotePosts`. Switching between them first shows the old posts under the new filter, then swaps to page one of the new source.
- Every page you had scrolled in is lost, and the scroll offset stays over different content, so the view jumps.
- The cycle button runs the change inside `withAnimation`.
- Fix: keep posts and paging per source, load a source only on its first visit or when stale, and animate only the fade.

**P2. Medium-High: typing a reply in a thread redraws the whole Posts screen per keystroke.**
- Where: `replyText`, `replySelection` and `isReplyFocused` (:406-413) are state on the root `KaPostsView`.
- What happens: each keystroke re-runs the root body, the feed under it and the thread sheet. That includes the recursive `findPost` (:2371) and `commentsExcludingThread`, run twice.
- Fix: a child view holds the reply text; it reaches the root only on Send.

**P3. Medium: opening any post or profile renders the whole window on the CPU first.**
- Where: `KaPostsSlideSnapshot.capture()` (:12136-12148), on every `kaPostsPresent` and every in-thread push.
- What happens: it runs `window.drawHierarchy` into an image and also takes a `snapshotView`. The slide uses the snapshot view. Only the menu drawer (`KaPostsFeedDrawer.swift:22`) uses the image.
- Fix: take the snapshot view only, and render the image only when opening the drawer (or when no snapshot view came back).

**P4. Medium: the Posts screen observes the action scheduler it never reads.**
- Where: `@ObservedObject scheduler` (:602).
- What happens: every like, repost, vote or post publishes twice (when it's held, and when it goes out 5 s later), often mid-scroll, re-running the feed and profile roots.
- Each poll card (:6326) also redraws on any action's countdown.
- Fix: `private var scheduler: KaPostsActionScheduler { .shared }`, and a key-scoped switch for poll cards.

**P5. Medium: thread levels keep the previous level's scroll position.**
- Where: `postDetailSheet` swaps the post in place.
- What happens: opening a reply from deep in a thread lands mid-list, and Back lands at the child's offset.
- Fix: `.id(postId)` on the thread's scroll view (optionally remembering each level's offset for Back).

**P6. Medium: the composer redoes whole-text work on every keystroke.**
- `mentionQuery` (:10013) compiles a regex and scans the whole text, twice per pass.
- `inlinePreviews` (:9744) runs four link matchers.
- With Show Fee Estimate on, the fee row encodes the post and estimates the fee twice.
- The text is trimmed about 8 times per pass, and `keepEditorVisible` animates a `scrollTo` per keystroke.
- `MarkdownComposerField.updateUIView` compares the whole text.
- Fix: a precompiled regex on the text's tail, previews and fee computed in the debounced task, and a scroll only when the caret is near the bottom.

**P7. Medium: the bell's list re-sorts everything whenever a name or picture lands.**
- Where: `KaPostsNotificationsView` observes `KachatNamesRegistry` and `KachatSocialImageResolver` directly (:11371-11372).
- What happens: the list's own avatars trigger those lookups, and each answer re-filters and re-sorts every row.
- Fix: observe `IdentityChangeTicker`, and memoize the rows.

**P8. Medium-Low: hidden feeds and a hidden Posts section still redraw.**
- Each cell observes `PostTranslationService` (:6772), so one Translate tap redraws every cell in all three feeds. Each redraw calls `canOffer`, which copies the settings three times (`AppSettings.load()`).
- `KaPostsHiddenFreeze` (:758) ignores `hubSectionHidden`, so Posts kept alive behind another Hub section still redraws on identity ticks.
- Fix: a small translate subview that listens only to its own key, and `shown && !hubHidden`.

**P9. Medium-Low: the bell's store sorts, encodes and saves on every insert.**
- Where: `GlobalNotificationCenter.record` (:137-149).
- What happens: a room backfill of N mentions does all of that N times on the main thread.
- Fix: insert in place, save at most once a second, and record backfills as one batch.

**P10. Low: small costs.**
- `ThreadProbeClaims.scheduleSave` writes 2,048-entry arrays to UserDefaults about once a second while scrolling (:2902).
- Back-to-top animates across the whole feed, then snaps up to three times (:1303-1319).
- Profile and Bookmarks re-sort on every pass (:4751, :4050).
- `isCheckingForNewPosts` is state nothing reads (:324).
- `KaPostActionRowLayout` has no layout cache (:7786).
- The text-parts memo key copies the whole post text (:6563).

## Wallet, addresses and other lists

**L1. High: the Cold Storage account screen reshuffles every time you come back to it.**
- Where: `ColdStorageView.swift:670` runs the full `loadEntries()` on every appear.
- What happens: `getAddressList` returns every address as unused, so used-but-empty addresses jump into the Unused group at the top. Seconds later the probes finish and the rows jump back.
- Fix: carry the earlier used flags over (as the `balancesOnly` path does), and on a quick return run `balancesOnly: true`.

**L2. High (accounts with many addresses): `OwnAddressList` isn't lazy and puts a blur behind every row.**
- Where: `SendKaspaComponents.swift:1897-1925`, row background at :2017.
- What happens: every address is built at once with a `.regularMaterial` layer. Every used-flag answer (up to two per address) redraws the whole list, starting while the From step is still sliding in.
- This list is used by every send's Choose an Address, Request Payment, Swap, the site sign-in and tips.
- Fix: a `LazyVStack`, a flat fill, and batched used answers.

**L3. Medium: Manage Addresses redraws on every ChatService change.**
- Where: `ManageAddressesView.swift:12`, and the same at :1164 (send), :1975 (history) and :2579 (visibility).
- What happens: the screen holds `@EnvironmentObject chatService` only to call methods. Every chat publish re-sorts the list and redraws every card.
- The Send Kaspa screen (`WithdrawKaspaView`, `ContactsView.swift:1094-1095`) does the same with `chatService` and `contactsManager`, so it redraws during the step slides and the swipe-up lift.
- Fix: `ChatService.shared` (and `ContactsManager.shared`), unobserved.

**L4. Medium: the Manage Addresses probes and reloads are unbatched.**
- Where: `ManageAddressesView.swift:676-694` and :137-150.
- What happens: each used/unused answer writes two values, so two redraws and a re-sort per address, and rows move between groups as you scroll.
- Three activity notifications each start their own full reload, with no debounce.
- The pull-down progress re-sorts the list on every index it checks.
- Fix: batch the answers, debounce reloads as Cold Storage does (`reloadAfterActivity`), and throttle the progress.

**L5. Medium: address history rows decode JSON while drawing.**
- Where: `transactionRow` (`ManageAddressesView.swift:2346`, :2360) calls `ownAddressLabel(for:)` twice per output.
- What happens: each call reads UserDefaults and decodes all labels (`WalletManager+SpendingAddresses.swift:188-196`, :855).
- Fix: build the row models once in `loadTransactions()`, and keep the labels in memory.

**L6. Medium: Swap's QR codes are made in `body` with a new `CIContext`.**
- Where: `SwapView.swift:1587` (`swapQRImage` at :1517) and :818 (`makeQRCodeImage` at :1014).
- What happens: this runs during the deposit screen's push and on every `SwapService` publish.
- Fix: make the QR once, off the main thread, as `AddressReceiveView` does.

**L7. Medium: dragging on a chart rebuilds the whole screen per point.**
- Explorer (`ExplorerChartView.swift:279`, :444-497): `selected` is the screen's own state, so each step rebuilds the 240-point chart, the summary and the Mining Estimate. It finds the point with a linear scan.
- Portfolio (`PortfolioView.swift:1063-1076`, :449, :501): the same pattern, and it also writes the parent's `scrubbed`, so the whole Portfolio screen rebuilds on each step.
- Fix: draw the marks in a child view that takes only the points; the rule and dot go in an overlay that owns the selection; binary search for the point.

**L8. Medium: Explorer pages draw long lists all at once.**
- Where: address history (`ExplorerViews.swift:1176`, :1301), a block's transactions (:1051), and a transaction's inputs and outputs (:889).
- What happens: these are `VStack`s inside a `ScrollView`, so every row is built and rebuilt on each Load More.
- `history` is a computed filter, read three times per body.
- Fix: `LazyVStack`, and keep the filtered history in state.

**L9. Low-Medium: Explorer home redraws everything once a second.**
- Where: `publishStats` (`ExplorerAPI.swift:868-886`).
- What happens: it includes `daaScore`, which changes on every flush, so the stats publish every second. That undoes the earlier "only the DAA ticks" fix.
- Fix: drop `daaScore` from `ExplorerNetworkStats` (`ExplorerDAAScore` reads it live), and move the latest-transactions list into its own view.

**L10. Low-Medium: the Settings tab decrypts the seed every time it appears.**
- Where: `SettingsView.swift:165-173` calls `getSeedPhrase()` on the main thread just to learn whether there's a passphrase.
- Fix: cache that per account.

**L11. Low-Medium: kUSDT publishes on every poll.**
- Where: `WalletTokens.swift:306` (also :927, :936) sets `lastError = nil` even when it's already nil.
- What happens: every poll redraws Manage kUSDT. Each redraw reads visibility from UserDefaults per holding, filters history per row, and decodes the labels.
- Fix: write only on a change, and keep the visibility sets in memory.

**L12. Low: small costs.**
- Contacts decodes photos on the main thread on first scroll-in (`AddressBookManager.swift:225-231`).
- .kachat Recent Activity (`KachatNamesLiveViews.swift:1222`) and the Arcade leaderboard (`ArcadeViews.swift:140`) are 100-row `VStack`s.
- Offer tiles make a new `DateComponentsFormatter` per call (`KachatNamesLiveViews.swift:1404`).
- Side note, not smoothness: Explorer's "12s ago" on a pushed page stays frozen, because the root's presence pauses the clock.

## Moving between screens

**T1. Medium: picking a Kaspa Hub section builds it while the menu is still closing.**
- Where: `KaspaHubView.swift:576-578`.
- What happens: `close()` starts a 0.3 s spring, then 0.15 s later the tab switches and the section is built for the first time (Posts, the Explorer, a web view), so the close stalls.
- Kasshi also shows its sign-in sheet in `onAppear`, in the same pass.
- Fix:
  - Switch the section first, then remove the menu without animation (or pick on the close's completion).
  - Show Kasshi's sheet a moment after it appears.

**T2. Low-Medium: opening or closing the Hub menu rebuilds the dock inside the spring.**
- Where: `showHubMenu` is `MainTabView` state (:30, :285, :294, :338).
- What happens: each toggle re-runs every tab item. `DockDotIcon.symbol` (`SettingsView.swift:2916-2921`, :2960-2964) makes a new UIImage on every call, so the Profile and Settings tab images are replaced on every switch. This is a likely source of the dock glass twitching (not confirmed on a device).
- Fix: keep the menu flag in a small object only the overlay observes, and cache the symbol images.

**T3. Low-Medium: Send steps hide the keyboard during the slide.**
- Where: `ContactsView.swift:1237-1251`, and the same in `PaymentRequestViews.swift:108`, `ColdStorageView.swift:1301` and `KachatNamesLiveViews.swift:1800`.
- What happens: the pinned Continue moves down with the keyboard while sliding sideways, so it travels diagonally.
- Fix: ignore the keyboard's safe area during the slide, or slide on `keyboardWillHide`.

**T4. Low: coming back to K re-asks for every contact's name.**
- Where: `syncContactsForExtension` (`KaChatApp.swift:214`, `SharedDataManager.swift:90-122`).
- What happens: every activation calls `displayName(for:)` per contact on the main thread. That queues an identity lookup for each contact older than 5 minutes, then a burst of redraws when the answers land.
- Fix: read the cached names without queuing lookups, and sync only on background or a contacts change.

**T5. Low: the App struct observes services it never reads.**
- Where: `KaChatApp.swift:10-15`.
- What happens: `chatService`, `groupChatService`, `pushManager` and `contactsManager` are `@StateObject`s that re-run the scene body on each publish.
- Fix: inject the singletons directly.

**T6. Low: the BlockDAG runs at 120 Hz.**
- Where: `SendKaspaComponents.swift:1292`, :1530, :1723.
- What happens: it runs while the swipe is only being dragged, and keeps running dimmed after Sent or Failed.
- Fix: pause it once finished, and cap it at 60 fps.

## Checked and fine

- **Chats:**
  - The composers type without redrawing their screens.
  - Bubble parsing is cached, with size guards; photo thumbnails decode off the main thread.
  - The open chat's poll publishes nothing when nothing is new.
  - Room and room-list rows are Equatable.
  - "Jump to start" and jump-to-reply land unanimated.
- **Posts:**
  - Cell equality covers every field that changes pixels.
  - Link, markdown and language results are cached.
  - Feed ids are stable, and the hidden feeds' bodies are frozen.
  - The undo toast redraws only itself, and the slide moves with Core Animation.
  - Avatars decode thumbnails, and the new repost lookups are cached.
- **Wallet and lists:**
  - Balance refreshes publish only on a real change, and address derivation is cached.
  - Manage Addresses, Manage kUSDT, Cold Storage and Buy/Sell History are lazy `List`s.
  - The address cards use a flat gradient.
  - The receive QR is made off the main thread.
  - The Explorer feed is built off the main thread and its graph pauses when hidden.
- **Screens:**
  - The dock never reloads (`.id(layout.dock)` is fixed), and badges write only changes.
  - `closeAllCovers` has no animation.
  - Hidden Hub sections really pause their polls (`onScreenPresence`).
  - The foreground beat aligns the polls, and activation has its cold-start grace and 15 s debounce.
  - The 1:1 chat's full history load waits out the push.

## Fix order

1. **The big hitches:**
   - C1 (1:1 rebuild);
   - C2 (identity redraws; this also fixes most of P7);
   - P1 (Following ⇄ Feed);
   - L1 (Cold Storage reshuffle);
   - L2 (`OwnAddressList`);
   - C3 (group paging).
2. **Transitions:**
   - C4 and C5 (Chats list pop and page switch);
   - P3 (post open);
   - T1 (Hub pick);
   - C6 (jump to newest).
3. **Needless observation, one line each:**
   - P4 (the scheduler);
   - L3 (`chatService` in Manage Addresses and Send);
   - T5 (the App struct);
   - L9 (`daaScore`);
   - L11 (`lastError`).
4. **The rest**, by area.
