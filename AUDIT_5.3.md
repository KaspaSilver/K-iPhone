# KaChat 5.3 audit

**Date:** 2026-11-13
**Code:** commit ca013fc8, plus the 5.3 version bump (not yet committed)
**Method:** read-only. Five reviewers covered money, messaging and groups, sync and message loss, on-device security, and the UI with the changes since 5.2.3. KaPost's audit reported one more item (item 1). I re-checked the main items marked ✔ against the code myself.
**Not covered:** App Store review items, by standing request.

**Result:**
- One crash any sender can trigger.
- No critical money or crypto defect. Signing, coin selection, change, storage mass, the fee check against the Review, network prefixes, the ECIES and group ciphers, roster signing and replay protection all held up.
- A dozen medium items, mostly on these edges: Retry, multi-part sends, notifications, account removal and the voice recorders.

---

## Status after fixes (2026-11-13)

Everything below is fixed in the working tree (not built, not committed) except these:

- **Left as is, with reasons:**
  - **Copied group message in someone else's transaction (block scan).** A gcomm transaction carries
    no proof of its sender, so checking it isn't possible. The copy can only win a narrow race, and
    then the bubble's text and sender are still the genuine signed ones; only its txId differs.
  - **Unreadable keychain at launch, and the Secure Enclave fallback.** Treating either as missing
    could send users to recovery for nothing or lock out a device. Log lines were added.
  - **Nextcloud share links never expire.** Expiring them would break media in old messages.
  - **A failed app-password revoke during Delete Account** isn't shown, since that screen is gone.
    A plain Disconnect now says so.
  - **Burst gap:** if part 1 of a note can't be read (it rings) and part 2 can, part 2 rings once more.
- **Needs your decision:**
  - **Backups.** Contacts and Address Book entries live in UserDefaults, which can't be excluded
    one key at a time. Excluding them means moving them into files, a migration with data-loss risk.
- **Also fixed, from KaPost's audit of shared code:** the block stream lost at launch, key reads after
  Log Out, spent-coin holds now 10 minutes, an input and mass cap on message coin picks (asks to
  Compound UTXOs), the spending-address change slot picked inside the send queue, covenant coins
  left out of plain spends, a double-tap guard on 1:1 voice Retry, and the voice bubble anchored
  on its lowest part so it doesn't hop while sending.
- **Also fixed, from KaPay's audit of shared code:**
  - **Sends:** "did it go out" checks need a verified, non-orphan answer.
  - **Addresses:** checked for prefix and length, and name-service answers are validated. Uppercase QR addresses work.
  - **Subscriptions:** they stop on Log Out and account switch.
  - **Node pool:** the connection pool is capped, and active nodes must be on the right network and in sync.
  - **Coins:** they are held before a submit.
  - **Notifications:** "Received" is silent when the transaction can't be read.
  - **Push:** an old account's push unregister can't remove the new one.
  - **Names:** the KNS reveal record is kept until its commit is surely spent, and name times can't overflow.
  - **Other:** Keychain writes update in place, and the in-app language is used everywhere.
  - **Not in KaChat:** Portfolio and the .kachat claim flow.
- **Behaviour changes to know:**
  - A group control message the extension can't read is now silent too, including an invite it
    can't read in time; that invite still shows in Message Requests when the app opens.
  - The message fee pill only adjusts text fees. Voice notes and photos show their own fee.

## Fix before 5.3

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| 1 | **Critical** ✔ | **A voice part can crash the app every time its chat opens.** `readFloat` accepts any finite duration, and `Int((durationMs / 1000 * 24000).rounded())` traps on e.g. 1e300. A contact, group member or Message Request can send it, and the bubble decodes it as soon as it's on screen. | `Views/Chat/MessageBubbleView.swift:3190`, `:3343` | Clamp the duration to `(VoicePartTag.maxPartSeconds + 1) * 1000` ms before converting, or reject larger values in `readFloat`. |
| 2 | Medium ✔ | **A message's custom fee has no limit or warning.** "Adjust Network Fee" takes any amount, and the builder pays it all as miner fee. Messages don't ask for Face ID. A typo of 99.9 for 0.0001 burns about 99.9 KAS on "hi". A value below the network minimum isn't raised either, so that send is rejected. | `Views/Chat/ChatDetailView.swift:4272`, `Views/Chat/GroupChatDetailView.swift:1236`, `Services/KaChatTransactionBuilder.swift:1293` | Use the same rules as `SendFeeEditorScreen`: raise to the minimum, warn above 10× it, and cap it (e.g. at 1 KAS). |
| 3 | Medium ✔ | **Group Retry can send parts twice.** The "still failed?" check reads the copy that was passed in, not the live row, and the view has no in-flight flag. While a Retry runs, the bubble still shows Failed, because Failed outranks Sending. A second tap sends the remaining parts again, each paying its fee a second time. | `Services/GroupChatService.swift:2024`, `:2061`; `Views/Chat/GroupChatDetailView.swift:2392`; `Models/Models.swift:1828` | Re-read the live row as 1:1 does (`ChatService+Conversations.swift:1715`). Mark every failed part Sending before the loop. Add an in-flight guard. |
| 4 | Medium | **1:1 parts can go out of order, and the composer clears too early.** A retryable error on a part schedules a later retry and returns as if it had worked, so the following parts go immediately and the composer clears while that part is still unsent. Unconfirmed escalation: the waiting part's row may take another part's txId and be lost. | `Services/ChatService+Conversations.swift:1596-1615`, `:2120-2146` | Inside a multi-part send, treat a scheduled retry as a failure. Stop there and mark the rest Failed. |
| 5 | Medium ✔ | **Quick reply works on a locked phone.** The Reply action has no `.authenticationRequired`, so anyone holding the locked phone can send messages, with their fees, from the owner's chatting address. | `App/KaChatApp.swift:705-711`, `:729-773` | Add `.authenticationRequired`. Check that the Apple Watch reply still works. |
| 6 | Medium ✔ | **The notification extension can't read group media off chain.** The REST API's payload is hex of the whole `kchat:1:gcomm:…` string, but the group path adds the prefix again and parses the hex, which never matches. So every group photo and voice note shows "New group message", rings in groups set to Silent or Mentions-only, and its part tag is never read. Broken since September. | `KaChatNotificationService/NotificationService.swift:617-634`, `:946` | Hex-decode to UTF-8 and strip the `kchat:1:gcomm:` / `ciph_msg:1:gcomm:` prefix before parsing, as 1:1's `decodePayloadString` does. |
| 7 | Medium | **Group control messages ring.** Only `gctl_root` is decoded. Epoch changes on every member add or remove, photo changes, and your own invite accept or reject ring with "Group update" and raise the badge. | `NotificationService.swift:720-728`, `:996-1004` | Deliver every control type except a new root silently. |
| 8 | Medium ✔ | **Drafts outlive the account.** One global UserDefaults key, keyed by contact address only, holds every draft. Log Out and Delete Account never clear it, so account B can find account A's half-typed message in the composer. | `Services/ChatService.swift:308`, `Services/ChatService+Persistence.swift:1428-1460` | Key drafts by wallet and clear them on Delete Account (and on Log Out, if wanted). |
| 9 | Medium | **Notifications survive Delete Account and Log Out.** Decrypted banners stay in Notification Center, and Reply on one can send from whichever account is now signed in. | `Services/WalletManager.swift:596-619`, `:744-788` | Call `removeAllDeliveredNotifications()` and `removeAllPendingNotificationRequests()` there. |
| 10 | Medium ✔ | **Leaving a group chat doesn't stop the recorder.** Opening a member's 1:1 chat from the group keeps the group recording going with the mic on. Popping the screen loses an Audio ready note without a word and leaves its temp files. 1:1 cancels in onDisappear. | `Views/Chat/GroupChatDetailView.swift:874-879` | Call `recorder.cancel()` in onDisappear. |
| 11 | Medium | **In 1:1, the trash during Encoding… doesn't stop the encode.** The encode Task isn't tracked. Trashing early shows a "Failed to encode audio" alert. Trashing later fills the deleted note back into the composer and the fee bubble. | `Views/Chat/ChatDetailView.swift:4447-4455`, `:4500-4528` | Keep the Task, cancel it in `cancelRecording`, and check for a token after each await, as `VoiceNoteRecorder` does. |
| 12 | Low-Med | **Queued group sends aren't tied to an account.** Switching account, logging out or deleting mid-way through a 10-part group note still signs the remaining parts with the old key. Their status writes go to the new account's group file. | `Services/GroupChatService.swift:1909-1925`, `:2265` | Check the account at each queue turn, as 1:1's `refuseIfAccountChanged` does. |
| 13 | Low-Med | **Delete Account leaves the group database on disk.** Rows are batch-deleted, but `KaChatGroups-<hash>.sqlite` and its WAL stay: names, rosters, reactions, and restored group messages, which are stored as plain bytes. | `Services/WalletManager.swift:750-755`, `Services/GroupStore.swift:245`, `:659-669` | Destroy the store files as `MessageStore.destroyLocalStoreFiles()` does. |

## Fix soon (low)

**Notifications**
- **The 60-second burst rule is too broad.** It silences a second person's long note in the same group, and separate notes from one sender. The rule also applies to parts whose tag was read. Use it only for pushes that couldn't be read, and key it by group and sender. (`NotificationService.swift:349-355`, `:653-656`, `:713-716`; added 2026-11-11.)
- **Per-push state isn't reset in `didReceive`:** `voicePartKey`, `partBurstOwner` and `readOffChain`. If iOS reuses the instance, a plain message can go quiet. (`NotificationService.swift:29-40`, `:85-89`)

**Messaging and groups**
- **The hex parser accepts a `+` sign.** `"+a"` reads as `"0a"`, so a copy of a group id passes as a new group and gets past the lowercasing rule. Accept only `0-9a-f`. (`Utilities/KaChatCipher.swift:364`, its copy in `NotificationService.swift`)
- **The rebuilt media JSON escapes only `\` and `"`.** A sender's own control characters in `name`, or a quote in `mimeType`, show their message as raw text. (`Models/Models.swift:1506-1510`, `NotificationService.swift:2106`)
- **Block scan, unconfirmed in practice:** a copied group message, in someone else's transaction, can take the original's msg_id. Check the transaction's sender against `sender_pub`. (`GroupChatService.swift:2733-2740`)

**Money**
- **A custom fee set in voice mode, or for a Nextcloud photo, is shown but ignored, and stays set for the next text.** (`ChatDetailView.swift:2942`, `:2963`, `:5233`, `:4658`)
- **"0 KAS" shows when the balance is unknown:** the Contacts toolbar, the Manage Addresses chatting row, and a Total that leaves the chatting part out. Show "--" as Wallet does. (`SettingsView.swift:2599`, `ManageAddressesView.swift:281`, `:385`)
- **A chat payment From a spending address shows a higher fee than it pays.** It's priced with the payload it doesn't carry, and the separate notice transaction's fee isn't shown. (`ChatService+Conversations.swift:3784-3821`, `:2853`)
- **The Siri/Shortcuts confirm shows no fee, and can show a blank recipient** for an auto-added contact. (`Shortcuts/KaChatShortcuts.swift:271-287`)
- **Max goes through Double**, so it can be off by a sompi above about 90M KAS. (`ChatDetailView.swift:3528`, `ContactsView.swift:4434`)
- **The deferred chat-payment retry rebuilds without the Review's fee check** (up to 0.1 KAS of folded change). (`ChatService+Conversations.swift:2586-2596`)
- **The composer keeps a voice note after a part fails.** Sending it again sends the whole note anew, up to 1 KAS again. Clear it or point to Retry. (`ChatDetailView.swift:5229-5262`)
- **Unconfirmed:** the service-layer address check is looser than the UI's, and `.k` / `.kaspa` name answers go in unvalidated. Validate with `KaspaAddress.isValid` in `sendWithdrawal` and `sendFromSpendingAddress`. (`ChatService+Conversations.swift:3006`, `:3226`)

**Recording UI**
- **Not translated:** "Recording...", "Audio ready", "Recording failed. Please try again.", "Camera not available on this device." and "Failed to send voice message: …" aren't in any `Localizable.strings`, so they show in English in 18 languages. (`GroupChatDetailView.swift:1869`, `:1879`; `ChatDetailView.swift:~2823`, `~2847`)
- **The group recording clock counts timer ticks and ignores audio interruptions.** A call or going to the background stops capture, but the ring keeps counting. Read `recorder.currentTime` and handle `AVAudioSession.interruptionNotification` in both composers. (`VoiceNoteRecorder.swift:117-123`)

**.kachat endings**
- **The setting leaks into saved names.** With endings off, adding alice.kachat to the Address Book saves the name "alice", which then syncs to Nextcloud and KaPay. Save the canonical name, not the display form. (`Views/Contacts/AddressBookView.swift:719`, `:723`)

**On-device data**
- **Contacts, Address Book entries, notes and photos go into iCloud and Finder backups.** Exclude them from backup like the chat-list snapshot. (`ContactsManager.swift:313`, `AddressBookManager.swift:41`, `:287-312`)
- **Nextcloud:**
  - A failed app-password revoke is only logged, and the user is told it worked. (`NextcloudService.swift:383-396`)
  - Media share links are public, never expire and outlive Delete Account. (`NextcloudService.swift:1392-1402`)
- **Temp files left behind:**
  - The `kachat-group-voice-`, `kachat-capture-` and `kachat-picked-video-` prefixes aren't swept (`CacheManager.swift:194`).
  - The group `.m4a` leaks if reading it throws (`GroupChatDetailView.swift:2103`).
  - The Address Book export JSON is never deleted (`AddressBookView.swift:204-218`).
- **Unconfirmed:** a keychain `.unavailable` read signs in with no usable key (`WalletManager.swift:299`). A failed Secure Enclave wrap stores the seed unwrapped without saying so (`KeychainService.swift:505-511`, `:542-547`). Both are still device-only.

**Docs**
- **MESSAGING.md contradicts itself on group photos.** Lines 259 and 420-421 say they stay text; line 324 and the code say they're frames. Android and Desktop would show iOS group photos blank.
- **MESSAGING.md says the extension reads group parts' tags off chain** (lines 404-409). That's untrue until item 6 is fixed.
- **`LAUNCH_AUDIT.md`** is the 5.1 audit and names files and features that are gone. Delete it or mark it historical.

## Needs your decision

- ~~**A handshake moves 0.2 KAS to the other person with no Face ID.**~~ Settled 2026-11-13: no send asks for Face ID now, Kaspa included.

## Checked and sound

- **Money:**
  - **Sending:** coin selection, change and folding, storage mass, the 80-input cap and the fee check against the Review.
  - **Network and gates:** the network-prefix refusal on every send, amount parsing that can't trap.
  - **Multi-part media:** the whole cost is checked before the first part.
  - **Payments:** payment-request signatures, and `payment_notice` checked on chain.
- **Crypto:**
  - ECIES binding, and sent-message recovery that matches MESSAGING.md.
  - Media frame bounds, `VoicePartTag` validation, and part grouping keyed by the verified sender.
  - WebM depth and size caps.
  - The gcomm sender, roster and signature checks, the saved msg_id counter (no nonce reuse), and roster signing, invites and tombstones.
- **Sync:**
  - A failed read never counts as read; the full-sync backoff; the indexer-down fallbacks and rewind.
  - One unread per multi-part note.
  - The extension-to-app handoff; 1:1 sends bound to their account; leftover Sending rows settled at launch.
- **Security:**
  - Keychain items are device-only and never synced.
  - Account removal paths ask `DeviceAuth`; seed and private-key copies expire.
  - NFC uses PBKDF2 (600k) and AES-GCM.
  - The Nextcloud contacts file is encrypted.
  - No keys or message text in the App Group; logs shorten addresses.
  - The link router allows http, https and mailto only.
- **UI:**
  - The calls removal is complete.
  - Every key added since 4f8e14bb is in all 19 languages.
  - The new group recorder's cancel and double-send guards; `MediaAccess`; the photo tiers; one-bubble grouping; import wallet type; the chat-list fix.
  - No removed feature is still reachable.
