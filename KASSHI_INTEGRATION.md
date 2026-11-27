# Connecting K inside the K app: Kasshi integration

For the Kasshi team (kasshi.io). This covers how a person who opens Kasshi from inside the K
iPhone app signs in and pays with K directly: no extension, no seed phrase and no Google account.

## Summary

Kasshi already supports K on desktop. The "K" tile in **Sign in with your Kaspa wallet** finds
the K browser extension through `window.kapay || window.kachat` and uses its `requestAccounts`,
`getPublicKey`, `signMessage` and `sendKaspa`.

The K iPhone app puts **the same `window.kachat` provider** into kasshi.io when it is opened
in K's built-in browser (Kaspa Hub > Kasshi, its own card since 2026-11-26). The calls, return
shapes and error codes match the extension. Kasshi's existing K code should therefore work inside
the app with **no change**: the K tile shows "Installed", and the sign-in, deposit and withdraw
flows run as they do on desktop.

Each request opens a native K sheet: Connect, Sign or Send, with Approve and Decline. Kasshi's
page never sees a key.

The rest of this doc covers:
- the exact contract, so Kasshi can check it against its code;
- the few things that differ in the app (sessions, mobile layout);
- a short list of small, optional asks.

## 1. The provider (same as the K extension)

The provider is injected at document start, in the main frame only, and only on
`https://kasshi.io` (subdomains included). It is frozen and not writable.

```js
window.kachat            // the provider; window.kapay is not set by the app
window.kachat.isKaChat   // true
window.kachat.version    // "1"
window.kachat.platform   // "ios" in the K app (absent in the extension); see section 4
// fired once the provider is in place:
window.addEventListener("kachat#initialized", ...)
```

Kasshi's `jm()` checks `window.kapay || window.kachat` for a `requestAccounts` function. That
check already matches.

| Call | Returns | K shows |
|---|---|---|
| `requestAccounts()` | `["kaspa:q..."]`: the address the person picked | Connect sheet: the site, then which address to connect (see "Which address connects" below). Approving it marks the site as connected for this browser session |
| `getAccounts()` | `[]` until connected, then the address | nothing |
| `getNetwork()` | `"mainnet"` or `"testnet-10"` (`null` until connected) | nothing |
| `getPublicKey()` | 33-byte compressed public key, hex (`"02..."` / `"03..."`) | nothing (connected only) |
| `getBalance()` | `{ confirmed, unconfirmed, total }` in **sompi**, as numbers | nothing (connected only) |
| `signMessage(text)` | signature, 64-byte Schnorr, **hex** | Sign sheet showing the full text |
| `sendKaspa(to, sompi, { priorityFee })` | txid (64 hex) | K's own Send review (To, amount, From, fee), then a swipe up to send. The txid comes back as soon as the send is out |
| `disconnect()` | `true` | nothing; the site must call `requestAccounts()` again |
| `on("accountsChanged" \| "disconnect" \| "networkChanged", fn)` / `removeListener` | | |

### Message signing

The signature uses the KasWare-compatible personal-message scheme, the same one the K extension
uses:

```
schnorr_sign(privkey, blake2b-256(key = "PersonalMessageSigningHash", msg = utf8(text)))
```

It is hex-encoded. Kasshi's `/api/wallet-auth/verify` already accepts this from the K extension,
so nothing changes server-side. The key is the connected address's own key, matching the
address `requestAccounts()` returned and the key `getPublicKey()` returned.

Text limit: 4,096 characters. The challenge from `/api/wallet-auth/challenge` is well under that.

### Which address connects

The Connect sheet asks the person which address to connect:
- **Chatting Address** (the default): the address people message and pay in K.
- **Choose an Address:** any other regular address of their K account, listed with its balance.
  This keeps a Kasshi account apart from their K username and chats.

A few rules follow from that:
- Quantum-resistant addresses (P2SH) aren't offered: their key doesn't map to the address the way
  Kasshi's signature check expects.
- Everything after that uses the picked address: `getPublicKey`, `getBalance`, `signMessage`, the
  sends' source, and where withdrawals land.
- K remembers the last address picked for kasshi.io, per K account, and suggests it next time.
- To change address, the person disconnects (Kasshi's Disconnect, or `disconnect()`) and
  connects again. `accountsChanged` then fires with the new address.

### Sending

- `sompi` is a whole number above zero, as a number or a digit string. Kasshi passes
  `Math.round(kas * 1e8)`, which works. `to` must be a `kaspa:` address.
- `priorityFee` is accepted but not used in the app: the person picks the fee speed on K's
  review, as for every send.
- K builds and signs the transaction itself, from the connected address.
- The person confirms on K's Send review screen, the same one K uses for every payment.

### Errors

Errors are thrown as `Error`, with `code` set. The messages say "K".

| code | Meaning | What Kasshi should do |
|---|---|---|
| `4001` | Declined in K. K refuses that site's requests for a few seconds afterwards | Show "Request rejected in K" (Kasshi's `Qy()` already does) |
| `4002` | **May have been sent** (extension only; the app shows a failed send in K with Try Again, and closing it answers `4001`) | Don't retry blindly. Check the txid or the deposit address first |
| `4100` | Not connected yet | Call `requestAccounts()` |
| `4200` | Method not supported | |
| `4900` | K couldn't reach the network | Retry later |
| `-32002` | A request from this site is already waiting in K | Wait |
| `-32602` | Bad parameters | |

## 2. Kasshi's flows, as they will run in the app

Nothing here needs new code. It is listed so Kasshi can check its assumptions.

1. **Sign in.** The tile calls `requestAccounts()`, then `getPublicKey()`. Kasshi calls
   `POST /api/wallet-auth/challenge { address }`, then `signMessage(challenge)`, then
   `POST /api/wallet-auth/verify { address, signature, challenge, publicKey, provider: "kapay" }`.
   Opened from K's Kaspa Hub (since 2026-11-27), K asks first: "Sign In to Kasshi", which address.
   After that, `requestAccounts()` answers at once with that address, and the first
   `signMessage()` within two minutes (the sign-in challenge) is signed with no second sheet.
   Later `signMessage()` calls and every `sendKaspa()` still ask in K. K also fires
   `accountsChanged` with the address each time a page finishes loading, so see ask (e).
2. **Deposit.** `sendKaspa(internalAddress, sompi)` opens K's Send review for that amount to the
   Kasshi wallet address. After the swipe, the txid comes back.
3. **Withdraw.** This is server-side (Kasshi pays out to the K address), so nothing happens in K.
   The KAS shows up in K's Wallet as Received KAS.
4. **Account switch in K.** Switching K accounts closes K's browser, and the page with it: the
   next visit starts unconnected and signs in again.

## 3. What differs inside the app

- **Sessions don't persist.** K's built-in browser keeps no cookies or storage after it closes.
  This is on purpose: nothing carries across K accounts. So `kasshi_external_wallet` in
  localStorage is gone next time, and the person signs in again: Connect, then Sign, about two
  seconds. If Kasshi wants a smoother return, see ask (c).
- **Links to other sites open in Safari.** The built-in browser stays on kasshi.io (and its
  subdomains). "Sign in with Google" redirects to accounts.google.com, so it would leave K for
  Safari, and the Google login would end up in Safari, not in K. Inside K, the wallet tiles are
  the way to sign in. See ask (a).
- **Phone layout.** It is the ordinary mobile page in an iOS `WKWebView`
  (`AppleWebKit`, no `Chrome` in the user agent). Kasshi's Safari detection (`VN`) will say
  Safari/Apple. Video and audio playback work as in Safari.
- **The person picks the address.** The Chatting Address or another address of their K account
  (see "Which address connects"). One person can therefore sign in with different addresses on
  different visits, and each address is a different Kasshi account to Kasshi.

## 4. Asks for Kasshi (small, optional)

a. **Lead with K inside the app.** When `window.kachat?.platform === "ios"` the visitor is in the
   K app. Show the K tile first, or alone, above Google and the seed import:
   - the Google button would bounce them out to Safari;
   - the seed import box asks for a seed phrase inside another app's browser, which K users are
     taught never to do.

b. **"Get it" link for K.** On phones, the "Get it" link for the K tile (no `window.kachat`) could
   point to `https://kachat.app` instead of the Chrome Web Store, which iOS can't install from.

c. **(Optional) Silent re-sign-in.** If Kasshi wants returning K users signed in without the Sign
   step, it could keep a longer-lived session token server-side keyed to the address. When
   `getAccounts()` returns the same address, reuse it and refresh with `/api/wallet-auth/refresh`.
   The Connect sheet would still show once per browser session.

e. **(Optional) Sign in on its own inside K.** When `window.kachat?.platform === "ios"` and
   `getAccounts()` returns an address on load (or `accountsChanged` fires with one), the person
   already picked it in K's "Sign In to Kasshi" sheet. Kasshi can run its wallet sign-in right
   away (challenge, `signMessage`, verify) without its Create Account modal: K signs that first
   challenge with no sheet, so the person goes from picking the address to signed in.

d. **(Optional) "Open in K" button.** When kasshi.io is opened in mobile Safari, a button could
   open the same page inside K:
   ```
   https://kachat.app/open?url=https%3A%2F%2Fkasshi.io%2Fvideo%2F<id>
   ```
   K will open only https kasshi.io URLs through this link (any other URL is refused), in its
   built-in browser with the provider ready. Without K installed, the link lands on kachat.app's
   download page.

## 5. K's side (for reference)

Built in K for iPhone (2026-11-26):
- the `window.kachat` provider in K's built-in browser, on kasshi.io (and its subdomains) only;
- the native Connect (with the address choice), Sign and Send sheets;
- from Kaspa Hub, the "Sign In to Kasshi" sheet first, which pre-connects the address and approves
  the sign-in signature that follows (2026-11-27);
- `accountsChanged` with the address on connect, and with `[]` plus `disconnect` after `disconnect()`.

Not built yet: the `kachat.app/open?url=` link from ask (d).

Kasshi can also test against the K browser extension: the in-app provider answers the same way.

Questions: reply through the K team's usual contact.
