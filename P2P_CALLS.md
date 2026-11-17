# Peer-to-peer calls (proposal)

Status: proposal, nothing built. This is the protocol spec and the porting notes for every
client. iOS goes first.

Voice (and later video) calls with no account and no call server. Kaspa carries two small
encrypted messages, the offer and the answer. The audio goes straight between the two phones,
encrypted end to end. A server is only involved when the two networks can't reach each other
directly (section 5), and even then it can't hear the call.

## 1. How a call works

```
Alice                                   Kaspa                                   Bob
  | gather connection options              |                                      |
  |-- rtc_offer (1:1 message) ------------>|------------------------------------> | rings (CallKit)
  |                                        |                                      | taps Answer,
  |                                        |                                      | gathers options
  | <--------------------------------------|<------------- rtc_answer (1:1 message)|
  |                                                                               |
  |<================ WebRTC: ICE, then DTLS-SRTP audio, phone to phone ==========>|
  |                                                                               |
  |-- hang up, mute, network changes: over the call's own data channel, no fee -->|
```

- A call costs two ordinary 1:1 messages, the offer and the answer, each about the fee of a 2 KB
  text message. Nothing else touches the chain while the call runs.
- Setup takes about as long as two messages take to arrive, usually a second or two each.

## 2. Messages

Call messages are ordinary 1:1 contextual messages (`kchat:1:comm:<alias>:<sealed>`, MESSAGING.md):
a self-spend from the sender's own address, sealed to the other person's key, with the usual
deterministic alias. The sealed content is one of these JSON envelopes.

### rtc_offer

```json
{"type":"rtc_offer","v":1,"callId":"<32 hex>","media":"audio","sdp":"v=0\r\n..."}
```

- `callId`: 16 random bytes, lowercase hex. It names the call in every later message.
- `media`: `"audio"` or `"video"`.
- `sdp`: the caller's complete WebRTC offer **after** candidate gathering has finished (or after
  2 s, whichever is first). Candidates are not trickled: each extra message would cost a fee and
  a second.

### rtc_answer

```json
{"type":"rtc_answer","v":1,"callId":"<32 hex>","sdp":"v=0\r\n..."}
```

- The callee's complete answer, gathered the same way.

### rtc_end

```json
{"type":"rtc_end","v":1,"callId":"<32 hex>","reason":"cancelled"}
```

- `reason` is one of:
  - `cancelled`: the caller hung up before an answer.
  - `declined`: the callee tapped Decline.
  - `busy`: the callee is already on a call.
- Sent only when the call never connected. Once connected, hanging up goes over the data
  channel (section 4) and costs nothing.
- Optional. Without one, the other side gives up when the ring times out (section 3).

Unknown fields are ignored. An envelope with a `v` the client doesn't know is dropped.

**Not `call_*`:** the iPhone app drops `call_*` envelopes, the retired Nextcloud Talk call messages
(MESSAGING.md, "Call messages"). These new ones use `rtc_` so nothing confuses the two.

## 3. Rules (every client)

- **Who the caller is.** An offer counts only if its transaction spends coins from the caller's
  own address, so it is signed by the caller's key. Combined with the alias only the two people
  can derive, this is what proves who is calling. The DTLS fingerprint inside the SDP is
  therefore authentic. That fingerprint ties the encrypted media to the caller, so nobody in the
  middle can take over the call.
- **Only accepted chats ring.** An offer from an address whose conversation isn't accepted yet
  (still a Message Request, or blocked) never rings and is never answered. The caller just rings
  out. This keeps strangers from making the phone ring, and from learning its IP address
  (section 6).
- **Only live offers ring.** An offer rings only when it arrives live, through the address
  subscription, the mempool or a push, and only if its transaction is less than 60 s old by block
  time, when known. History sync never rings. A `callId` already seen never rings again.
- **Ring timeout.** 45 s. Past that the caller stops, and the callee shows "Missed call".
- **Call log in the chat.** An offer is shown as a call row: Outgoing call, Incoming call or
  Missed call, with the duration once it ends. `rtc_answer` and `rtc_end` are never shown as
  bubbles. Edits and reactions on any `rtc_` envelope are dropped.
- **Both call at once.** When each side has an open offer to the other, the offer with the
  lower `callId` (as bytes) wins. The other side drops its own offer and answers the winner.
- **Several devices on one seed.**
  - All of the callee's devices ring. The first to answer sends `rtc_answer`.
  - The others see that answer, since a seed reads back its own sent messages (MESSAGING.md), and
    stop ringing.
  - The caller ignores a second answer for the same `callId`.

## 4. During the call

- WebRTC with DTLS-SRTP: Opus audio, plus video when `media` is `"video"`.
- The connection opens one data channel, `kachat-ctl`, for small JSON control messages:
  - `{"t":"hangup"}`
  - `{"t":"mute","on":true}`
  - `{"t":"video","on":false}`
  - `{"t":"renegotiate","sdp":"..."}`: an ICE restart when a phone switches between Wi-Fi and
    mobile data. It goes over the data channel while it still works.
- If the connection drops and can't be restored within 10 s, the call ends on both sides.

## 5. Getting through networks

Each client offers three connection levels. Each level adds to the one before it:

| Level | `iceServers` | Connects when | Server involved |
|---|---|---|---|
| Direct | none | both have public IPv6, or are on the same Wi-Fi, or one has an open IPv4 port | none |
| + Address lookup (STUN) | a STUN server | most home and many mobile IPv4 networks | answers "what's my public address", sees no call |
| + Relay (TURN) | a TURN server | everything else (strict mobile carriers, office networks) | forwards encrypted packets it can't read |

- Direct needs no server at all. With no STUN server, WebRTC simply offers the phone's own
  addresses, including any global IPv6 address.
- STUN is a one-packet question and answer. It needs no account, and many free public servers
  exist. Clients let the user set the server, like the indexer URL.
- TURN is the only part that costs someone bandwidth. Without it, some calls between some
  networks won't connect; the app then says "Couldn't connect. Your networks don't allow a direct
  call."

## 6. Privacy

- A direct call shows each person's IP address to the other, which is the reason only accepted
  chats ring.
- A **Hide my IP** setting, if a relay is configured, makes every call go through it
  (`iceTransportPolicy = relay`). The other person then sees only the relay's address.
- Kaspa shows only what any 1:1 message shows: two self-spends from two addresses that can't be
  linked to each other. Nothing on chain says a call happened.
- The indexer and push servers see two ordinary 1:1 messages and can't read them.

## 7. Ringing when the app is closed (iOS)

- The offer arrives as the usual 1:1 push. The notification extension already decrypts those.
- When it finds a live `rtc_offer` from an accepted chat, it hands the payload to the app with
  `CXProvider.reportNewIncomingVoIPPushPayload(_:completion:)` (iOS 14.5+, made for end-to-end
  encrypted apps). The app then reports the call to CallKit, which rings like a phone call.
  Check on a device that this works with the current notification extension setup.
- This needs no VoIP push from the server, and the server never learns that a push was a call.
- A late offer becomes a "Missed call" notification. `rtc_answer` and `rtc_end` pushes stay silent.
- The SDP may be too large to fit in the push. The extension then fetches the transaction over
  REST, as it already does for payloads that don't fit.

## 8. iOS implementation notes

- **WebRTC:** the WebRTC framework, from a maintained Swift package build of Google's WebRTC;
  pick one and pin the version.
- **Calls UI:** CallKit for the call itself, and PushKit only for the extension handoff above.
- **Audio session:** `AVAudioSession` `.playAndRecord` with `.voiceChat`, owned by CallKit's
  audio activation callbacks.
- **Background modes:** `voip` and `audio`. Microphone access is already granted for voice notes;
  video adds the camera.
- **Code:**
  - A `CallService`, `@MainActor`, owns the peer connection and the call state.
  - Offers and answers go out through the normal 1:1 send path.
  - Incoming envelopes are caught in `ChatService.addMessageToConversation`, next to edits and
    reactions.
- **Docs:** update MESSAGING.md ("Call messages") once this ships.

## 9. Porting notes (Android, desktop)

- **Ship the receive side first.** Every client should drop `rtc_answer` and `rtc_end`, and show
  `rtc_offer` as a call row, before any client sends offers. Otherwise an older client shows raw
  JSON.
- **Android:** a self-managed `ConnectionService`. The incoming 1:1 FCM push wakes the app, which
  decrypts the offer and shows the incoming-call screen.
- **Desktop:** browser WebRTC works as is. Ringing needs the app open.
- **Same SDP everywhere.** No platform may strip fields from the SDP. Opus must be offered.

## 10. Open decisions (owner)

1. Audio only first, or video in the first version.
2. The default connection level: Direct only, or with a STUN server (whose).
3. Whether to run a relay at all, and whether to offer Hide my IP.
4. Whether Decline sends `rtc_end` (one more fee, but the caller learns at once) or stays silent.
