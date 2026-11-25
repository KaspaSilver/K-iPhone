# Indexer hand-off from the iPhone app

The iPhone (Apple) session does not change kachat-indexer. Anything the indexer needs because of
an iPhone change is written here, and the indexer session picks it up when the owner says
"check iOS".

**For the indexer session:** work through the **Open** items in order. When one is done, move it
to **Done** with your kachat-indexer commit, and keep the app-side contract as written. If a
contract can't be met as written, say so to the owner rather than changing the app's side.

**For the iPhone session:** add an item for every app change that needs the indexer to store,
serve or check something new, or to change how it does. Say what the app sends and expects
(endpoint, request, response, rules) and which KaChat commit and spec file it comes from, so the
item stands on its own.

## Open

- **2026-11-23 - KaPlay arcade boards (Snake, 2048).** Committed (518fdc8c);
  spec ARCADE.md. The app stamps every finished game as a plaintext broadcast in the hidden room
  `#kplay-arcade` (ARCADE.md §1) and reads the boards from
  `GET /arcade/leaderboard?game=snake|2048&period=month|all&limit=100` (§5). The indexer:
  1. follows `#kplay-arcade` broadcasts as it does `#chess-bots` (sender = the player);
  2. replays each stamp with the rules in §2-§4 and keeps only those whose replay reaches the
     stamped `score` (one per game id `g`); the test vectors in §2-§4 must pass;
  3. serves the endpoint: per address its best checked score in the period (`month` = the UTC
     calendar month as the chess boards count it, `all` = since the chess fresh-start cutoff),
     highest first, earlier stamp on a tie, with `games` (checked stamps in the period), `since`
     and each row's `at` (block time, ms) and `tx`.
  Until it is served, the app shows each player's own stamped scores only.

- **2026-11-24 - Push for @username mentions in public chats.** People can now be @'d by their .kachat username in public chats (rooms), as plain
  text in the message: `@alice` or `@alice.kachat` (any case) after the start of the text, a space
  or an opening bracket or quote, `a-z 0-9 -`, 1-32 characters, the ending optional; the token ends
  at the next character outside `a-z 0-9 -`. Rooms only push to people whose bell is on for that
  room, so a mention in any other room reaches nobody while their app is closed. The indexer:
  1. for each new room message (not the hidden `chess-arena`, `chess-bots`, `kplay-arcade` rooms,
     not edits or reactions), finds the @tokens, looks each name up in the names registry (the
     address its owner set, as `/identity` and profiles answer) and drops names that aren't
     registered and the sender's own;
  2. pushes each mentioned address that has a registered device, once per message, whether or not
     its bell is on for the room: the room push as today (`type` the room's, thread
     `broadcast:<room>`), with `mention: true` and `sender` (the sender's address) in the
     payload so the extension can say "mentioned you in #room". Skip it when the sender is in the
     device's `hidden_broadcast_senders` (any room's list, or the global one). Since 2026-11-24 the
     extension silences room pushes for rooms whose bell is off unless `mention` is true, and
     every new download starts with all rooms silenced, so this push is the only way a mention in
     a room reaches someone whose app is closed.
  The app already outlines messages that @ the reader and banners while open; this is only the
  closed-app push. KaPost mentions need nothing new (the signed `mentions` array already drives
  the `mention` notification).

- **2026-11-24 - Notification switches the registration now carries.** Since the iPhone's
  notifications audit, register and update send `notify_sound` (Settings > Notifications > Play
  sound; false = silent pushes, `silent_tokens`) and `kaposts_notify_mentions` (Settings > KaPost >
  Mentions). Both are already in `PushRegisterPayload` / `PushUpdatePayload`; please confirm that
  `notify_sound` = false also covers `address_activity` and `name_event` pushes (they carry no
  mutable-content, so the app can't quiet them) and that `kaposts_notify_mentions` = false skips
  the KaPost `mention` push. A device with no chats now registers with only `primary_address` and
  `watch_only_addresses` (Received KAS and .kachat), which `register` already accepts.
  Also please send `address_activity` pushes with `mutable-content: 1` (push.rs builds them with
  `mutable_content: None`): the app's push extension then records them (so K doesn't announce the
  same receive again when it opens) and applies the device's switches (Push Notifications off,
  Play sound off) while the app is closed.

## Done

- **2026-10-22 - Chess leaderboard periods (This month / All time).** KaChat 77d6038,
  ONLINE_CHESS.md §6. `GET /chess/leaderboard` and `/chess/player` take `period=month|all`, the
  response carries `period` and `since`, and both boards count from the fresh-start cutoff
  `1792647960000`. Done in kachat-indexer eaae9d2, before this file existed.
