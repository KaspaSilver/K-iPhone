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

- **2026-11-23 - KaPlay arcade boards (Snake, 2048).** Not committed yet (iPhone working tree);
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

## Done

- **2026-10-22 - Chess leaderboard periods (This month / All time).** KaChat 77d6038,
  ONLINE_CHESS.md §6. `GET /chess/leaderboard` and `/chess/player` take `period=month|all`, the
  response carries `period` and `since`, and both boards count from the fresh-start cutoff
  `1792647960000`. Done in kachat-indexer eaae9d2, before this file existed.
