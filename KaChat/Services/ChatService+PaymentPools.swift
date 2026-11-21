import Foundation
import Combine

// The payment's From, and what is left of Chats Payment Privacy.
//
// Chats Payment Privacy (fresh spending addresses offered to contacts through invisible
// `addr_pool` envelopes, payments sent to them, `payment_notice` bubbles) was removed on
// 2026-10-13: the person now picks where a payment comes FROM on every send screen (Chatting
// Address or Choose an Address), and payments go to the contact's chatting address. Other
// clients may still send `addr_pool` / `addr_pool_request`; they are swallowed so they never
// show as text.
//
// `payment_notice` lives on for one job (XP-022): a chat payment sent From a spending address
// is a plain transfer the payee can't place, so the chatting address sends a notice naming it
// right after, and both sides file it in their 1:1 chat. A notice for a payment to any other
// address (an old app paying one of our former pool addresses) is dropped (XP-023).

extension ChatService {
    /// The address a payment is funded from: the chatting address (nil, the default From) or
    /// the spending address at `spendingIndex` (Choose an Address).
    func paymentFundingSourceAddress(spendingIndex: Int? = nil) throws -> String {
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let spendingIndex else { return wallet.publicAddress }
        guard let address = WalletManager.shared.spendingAddress(at: spendingIndex) else {
            throw KasiaError.walletNotFound
        }
        return address
    }

    // MARK: - Chat payments From a spending address

    /// Tells the chat about a payment just sent From a spending address: an encrypted
    /// `payment_notice` from the chatting address, so the payee's app files the payment (and its
    /// memo, which travels only here) in the chat with us. Our own bubble is already there.
    /// Fire-and-forget: if it fails, the payee still has the KAS, shown in their self-chat.
    func sendSpendingPaymentNotice(to contact: Contact, txId: String, amountSompi: UInt64, memo: String) {
        let trimmedMemo = String(memo.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PaymentNoticeContent.maxMemoLength))
        let payload = PaymentPoolCodec.encode(
            PaymentNoticeContent(txId: txId.lowercased(), amountSompi: amountSompi, address: contact.address,
                                 memo: trimmedMemo.isEmpty ? nil : trimmedMemo)
        )
        guard !payload.isEmpty else { return }
        let owner = WalletManager.shared.currentWallet?.publicAddress
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.enqueueOutgoingTxOperation {
                    try await self.sendEnvelopeInternal(to: contact, payload: payload, owner: owner)
                }
                AppLog.log("[ChatService] Sent payment_notice for %@", String(txId.prefix(12)))
            } catch {
                // usually an empty chatting address: kept, and sent once it has KAS (IOS-086)
                AppLog.log("[ChatService] payment_notice send failed for %@, kept for later: %@",
                           String(txId.prefix(12)), error.localizedDescription)
                self.keepUnsentNotice(UnsentPaymentNotice(contactAddress: contact.address, payload: payload, txId: txId),
                                      owner: owner)
            }
        }
    }

    // MARK: - Notices waiting for the chatting address

    struct UnsentPaymentNotice: Codable, Equatable {
        let contactAddress: String
        let payload: String
        let txId: String
    }

    private var unsentNoticesKey: String? {
        WalletManager.shared.currentWallet.map { Self.unsentNoticesKey(owner: $0.publicAddress) }
    }

    private static func unsentNoticesKey(owner: String) -> String {
        "kachat_unsent_payment_notices.\(owner.lowercased())"
    }

    private var unsentNotices: [UnsentPaymentNotice] {
        get {
            guard let key = unsentNoticesKey, let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([UnsentPaymentNotice].self, from: data)) ?? []
        }
        set {
            guard let key = unsentNoticesKey else { return }
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: key)
            } else if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    /// Kept under the account that made the payment (`owner`), never the one active when the send
    /// failed: after a switch, sending it from the other account's chatting address would link the
    /// two accounts on chain.
    private func keepUnsentNotice(_ notice: UnsentPaymentNotice, owner: String?) {
        guard let owner else { return }
        let key = Self.unsentNoticesKey(owner: owner)
        var list = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([UnsentPaymentNotice].self, from: $0) } ?? []
        guard !list.contains(where: { $0.txId == notice.txId }) else { return }
        list.append(notice)
        if let data = try? JSONEncoder().encode(Array(list.suffix(50))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Sends the notices that failed for want of KAS on the chatting address - called when its
    /// balance turns positive (`observeChattingBalanceForNotices`). One at a time; any that
    /// still fails stays for next time.
    func sendUnsentPaymentNotices() async {
        guard !sendingUnsentNotices else { return }
        let pending = unsentNotices
        guard !pending.isEmpty else { return }
        sendingUnsentNotices = true
        defer { sendingUnsentNotices = false }
        var left: [UnsentPaymentNotice] = []
        let owner = WalletManager.shared.currentWallet?.publicAddress
        for notice in pending {
            guard let contact = contactsManager.getContact(byAddress: notice.contactAddress) else { continue }
            do {
                _ = try await enqueueOutgoingTxOperation {
                    try await self.sendEnvelopeInternal(to: contact, payload: notice.payload, owner: owner)
                }
                AppLog.log("[ChatService] Sent a kept payment_notice for %@", String(notice.txId.prefix(12)))
            } catch {
                left.append(notice)
            }
        }
        unsentNotices = left
    }

    /// The chatting address got KAS: the notices waiting for it go out.
    func observeChattingBalanceForNotices() {
        unsentNoticesCancellable = WalletManager.shared.$currentWallet
            .map { $0?.balanceSompi ?? 0 }
            .removeDuplicates()
            .filter { $0 > 0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { await self?.sendUnsentPaymentNotices() }
            }
    }

    /// A `payment_notice` in a 1:1 chat - theirs (they paid us From a spending address) or our own
    /// read back on another device. It names a payment to the receiving side's chatting address;
    /// anything else (an old app's pool payment) is dropped. The payment becomes a payment bubble
    /// in this chat, with its memo. Deduped by the payment's txId.
    ///
    /// Any contact can send a notice naming any public txid (IOS-083), so a received one is checked
    /// on chain BEFORE anything is filed: the tx must pay our chatting address exactly the amount,
    /// carry no payload (a plain transfer) and be paid by nobody we know as another contact. Only
    /// a plain transfer from an unknown address that landed in the self-chat may move into the
    /// chat; another chat's payment, a message, or anything sent by us is never touched.
    func handlePaymentNotice(_ notice: PaymentNoticeContent, message: ChatMessage, contactAddress: String) {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        let walletAddress = wallet.publicAddress
        let txId = notice.txId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard txId.count == 64, txId.allSatisfy(\.isHexDigit), notice.amountSompi > 0 else { return }
        let paidAddress = message.isOutgoing ? contactAddress : walletAddress
        guard notice.address.lowercased() == paidAddress.lowercased() else {
            AppLog.log("[ChatService] Dropped payment_notice %@ - not a payment to the chatting address",
                       String(txId.prefix(12)))
            return
        }
        let isOutgoing = message.isOutgoing
        let memo = String((notice.memo ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(PaymentNoticeContent.maxMemoLength))

        Task { @MainActor [weak self] in
            guard let self, self.isActiveWallet(walletAddress) else { return }
            let existing = await self.findLocalMessage(txId: txId)
            if let existing {
                let counterpart = existing.isOutgoing ? existing.receiverAddress : existing.senderAddress
                if existing.isOutgoing == isOutgoing, counterpart.lowercased() == contactAddress.lowercased() {
                    // already in this chat; one filed unverified gets its chain check again
                    guard !isOutgoing, existing.messageType == .payment, existing.deliveryStatus == .warning else { return }
                    switch await self.checkNoticeOnChain(txId: txId, paidAddress: walletAddress,
                                                         claimedSompi: notice.amountSompi, payer: contactAddress) {
                    case .valid:
                        _ = self.updateIncomingPaymentStatus(
                            txId: txId, deliveryStatus: .sent,
                            content: self.paymentNoticeText(amountSompi: notice.amountSompi, memo: memo, isOutgoing: false))
                        self.saveMessages()
                    case .invalid(let reason):
                        // still this notice's unverified bubble after the await?
                        guard self.isActiveWallet(walletAddress),
                              let current = await self.findLocalMessage(txId: txId),
                              !current.isOutgoing, current.deliveryStatus == .warning,
                              current.senderAddress.lowercased() == contactAddress.lowercased() else { return }
                        // the claim was false: its unverified bubble goes (a real payment under
                        // that txid is filed where it belongs by the next payment fetch)
                        self.unmarkNoticeBubble(txId)
                        self.removeMessage(txId: txId)
                        self.messageStore.deleteMessage(txId: txId)
                        self.saveMessages()
                        AppLog.log("[ChatService] Removed unverified payment_notice bubble %@ - %@", String(txId.prefix(12)), reason)
                    case .unknown:
                        break
                    }
                    return
                }
                guard !isOutgoing, self.isClaimableSelfChatPayment(existing, walletAddress: walletAddress) else {
                    AppLog.log("[ChatService] Dropped payment_notice %@ - it names a message that isn't an unclaimed self-chat payment",
                               String(txId.prefix(12)))
                    return
                }
            }
            if isOutgoing {
                // our own notice on another device: the outgoing bubble, if this device has none
                guard existing == nil else { return }
                self.fileNoticeBubble(txId: txId, notice: notice, memo: memo, message: message, contactAddress: contactAddress,
                                      walletAddress: walletAddress, isOutgoing: true, status: .sent, moving: false)
                return
            }
            switch await self.checkNoticeOnChain(txId: txId, paidAddress: walletAddress,
                                                 claimedSompi: notice.amountSompi, payer: contactAddress) {
            case .valid:
                // Placement again, after the await: another notice for the same txid may have
                // claimed it meanwhile (first notice wins), or the record may have appeared.
                guard self.isActiveWallet(walletAddress) else { return }
                let current = await self.findLocalMessage(txId: txId)
                if let current {
                    guard self.isClaimableSelfChatPayment(current, walletAddress: walletAddress) else {
                        AppLog.log("[ChatService] Dropped payment_notice %@ - claimed or filed while it was checked",
                                   String(txId.prefix(12)))
                        return
                    }
                    self.removeMessage(txId: txId)
                }
                self.fileNoticeBubble(txId: txId, notice: notice, memo: memo, message: message, contactAddress: contactAddress,
                                      walletAddress: walletAddress, isOutgoing: false, status: .sent, moving: current != nil)
            case .invalid(let reason):
                AppLog.log("[ChatService] Dropped payment_notice %@ - %@", String(txId.prefix(12)), reason)
            case .unknown:
                // no chain answer: never move a record on an unchecked claim; with nothing stored
                // yet, show it marked unverified (checked again when the notice is read again).
                // After the await: still this wallet (a switch meanwhile must not file A's bubble
                // into B - IOS-090), and still nothing stored under that txid.
                guard existing == nil, self.isActiveWallet(walletAddress),
                      await self.findLocalMessage(txId: txId) == nil else { return }
                self.fileNoticeBubble(txId: txId, notice: notice, memo: memo, message: message, contactAddress: contactAddress,
                                      walletAddress: walletAddress, isOutgoing: false, status: .warning, moving: false)
            }
        }
    }

    /// A stored message a received notice may claim: an incoming payment from an address that is
    /// no contact of ours (so it sits in the self-chat with "From:") and none of our own.
    private func isClaimableSelfChatPayment(_ m: ChatMessage, walletAddress: String) -> Bool {
        guard m.messageType == .payment, !m.isOutgoing else { return false }
        let sender = m.senderAddress.lowercased()
        guard !sender.isEmpty, !ownAddressesForNotices(walletAddress: walletAddress).contains(sender) else { return false }
        return contactsManager.getContact(byAddress: m.senderAddress) == nil
    }

    /// Every address this phone knows as the person's own, lowercased: the chatting address,
    /// every revealed spending address, every saved account's chatting and (cached) spending
    /// addresses. A transfer from any of them is the person moving their own
    /// money, which no contact's notice may ever claim (IOS-083).
    private func ownAddressesForNotices(walletAddress: String) -> Set<String> {
        var own = Set(WalletManager.shared.allSpendingAddresses().map { $0.lowercased() })
        own.insert(walletAddress.lowercased())
        // every saved account: its chatting address and every spending address this phone
        // derived for it (run 10: B's Address #2 topping up A's chatting address is ours too)
        for account in WalletManager.shared.savedAccounts {
            own.insert(account.publicAddress.lowercased())
            for spending in WalletManager.shared.cachedSpendingAddresses(ofAccount: account.publicAddress) {
                own.insert(spending.lowercased())
            }
        }
        return own
    }

    private func fileNoticeBubble(txId: String, notice: PaymentNoticeContent, memo: String, message: ChatMessage,
                                  contactAddress: String, walletAddress: String, isOutgoing: Bool,
                                  status: ChatMessage.DeliveryStatus, moving: Bool) {
        let bubble = ChatMessage(
            txId: txId,
            senderAddress: isOutgoing ? walletAddress : contactAddress,
            receiverAddress: notice.address,
            content: paymentNoticeText(amountSompi: notice.amountSompi, memo: memo, isOutgoing: isOutgoing),
            timestamp: message.timestamp,
            blockTime: message.blockTime,
            acceptingBlock: nil,
            isOutgoing: isOutgoing,
            messageType: .payment,
            deliveryStatus: status
        )
        if !isOutgoing { markNoticeBubble(txId, wallet: walletAddress) }
        addMessageToConversation(bubble, contactAddress: contactAddress)
        if moving, let key = messageEncryptionKey() {
            messageStore.upsertMessage(bubble, contactAddress: contactAddress, encryptionKey: key, refile: true)
        }
        saveMessages()
        AppLog.log("[ChatService] Payment %@ filed in its chat from a payment_notice (%@)",
                   String(txId.prefix(12)), status.rawValue)
    }

    // MARK: Bubbles a notice filed (IOS-083, run 11)
    //
    // A received payment a payment_notice filed in its sender's chat is that notice's to confirm
    // (its chain check, with the own-address and other-contact rules). The generic incoming-payment
    // code (UTXO resolution, the REST payment sync, the warning retry) knows nothing of notices,
    // and promoting such a bubble to "sent" in place would confirm a claim nobody checked - so it
    // leaves the txids listed here alone. Per wallet, the newest 2,000.

    private var noticeBubblesKey: String? {
        WalletManager.shared.currentWallet.map { Self.noticeBubblesKey(wallet: $0.publicAddress) }
    }

    private static func noticeBubblesKey(wallet: String) -> String {
        "kachat_notice_bubbles_\(wallet.lowercased())"
    }

    func isNoticeBubble(_ txId: String) -> Bool {
        guard let key = noticeBubblesKey else { return false }
        return (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(txId.lowercased())
    }

    /// `wallet`: the wallet the bubble was filed for (default: the active one).
    func markNoticeBubble(_ txId: String, wallet: String? = nil) {
        guard let key = wallet.map(Self.noticeBubblesKey(wallet:)) ?? noticeBubblesKey else { return }
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !ids.contains(txId.lowercased()) else { return }
        ids.append(txId.lowercased())
        UserDefaults.standard.set(Array(ids.suffix(2000)), forKey: key)
    }

    func unmarkNoticeBubble(_ txId: String) {
        guard let key = noticeBubblesKey else { return }
        let ids = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != txId.lowercased() }
        UserDefaults.standard.set(ids, forKey: key)
    }

    // MARK: Token payment bubbles
    //
    // A token payment's txid is a covenant transaction: it spends a token coin (a P2SH input), so
    // the contract filter (`isKachatContractTransaction`) hides it from payment chats for good, and
    // `removeSuppressedPaymentMessages` then took the bubble with it - the payer's card showed and
    // vanished once the chatting address's own transactions were read. The token bubbles are listed
    // here, per wallet (the newest 2,000), and that cleanup leaves them alone.

    nonisolated static func tokenBubblesKey(wallet: String) -> String {
        "kachat_token_payment_bubbles_\(wallet.lowercased())"
    }

    /// The active wallet's token payment bubbles.
    func tokenPaymentBubbleTxIds() -> Set<String> {
        guard let wallet = WalletManager.shared.currentWallet else { return [] }
        return Set(UserDefaults.standard.stringArray(forKey: Self.tokenBubblesKey(wallet: wallet.publicAddress)) ?? [])
    }

    func markTokenPaymentBubble(_ txId: String, wallet: String) {
        let key = Self.tokenBubblesKey(wallet: wallet)
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !ids.contains(txId.lowercased()) else { return }
        ids.append(txId.lowercased())
        UserDefaults.standard.set(Array(ids.suffix(2000)), forKey: key)
    }

    private enum NoticeCheck {
        case valid
        case invalid(String)
        /// the transaction couldn't be read (not indexed yet, or no answer)
        case unknown
    }

    /// What the chain says about a received notice: the tx pays `paidAddress` exactly
    /// `claimedSompi`, carries no payload (a chat payment or a message is never a notice's
    /// payment), and none of its inputs is ours (any of `ownAddressesForNotices`) or another
    /// contact's.
    private func checkNoticeOnChain(txId: String, paidAddress: String, claimedSompi: UInt64, payer: String) async -> NoticeCheck {
        guard let url = kaspaRestURL(path: "/transactions/\(txId)",
                                     queryItems: [URLQueryItem(name: "resolve_previous_outpoints", value: "light")]),
              let (data, response) = try? await URLSession.shared.data(for: Self.timedRequest(url)),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let fullTx = try? JSONDecoder().decode(KaspaFullTransactionResponse.self, from: data) else {
            return .unknown
        }
        let paid = fullTx.outputs
            .filter { $0.scriptPublicKeyAddress?.lowercased() == paidAddress.lowercased() }
            .reduce(UInt64(0)) { $0 + $1.amount }
        guard paid == claimedSompi else { return .invalid("it pays \(paid) sompi, not \(claimedSompi)") }
        guard (fullTx.payload ?? "").isEmpty else { return .invalid("the transaction carries a payload") }
        // an input without a resolved address could be one of ours: no chain answer yet
        let rawInputs = fullTx.inputs ?? []
        guard !rawInputs.isEmpty, rawInputs.allSatisfy({ $0.previousOutpointAddress != nil }) else { return .unknown }
        let inputs = rawInputs.compactMap { $0.previousOutpointAddress?.lowercased() }
        let own = ownAddressesForNotices(walletAddress: paidAddress)
        for input in inputs {
            if own.contains(input) { return .invalid("paid by one of our own addresses") }
            if input != payer.lowercased(), contactsManager.getContact(byAddress: input) != nil {
                return .invalid("paid by another contact")
            }
        }
        return .valid
    }

    // MARK: - Token payments in a chat (Send Dollars, 2026-11-20)
    //
    // A token transfer (kUSDT) is a covenant transaction with no chat payload, so the payee can't
    // tell which chat it belongs to. Right after it goes out, the payer's chatting address sends a
    // `token_payment_notice` in the 1:1 chat; the payer's bubble is made here, the payee's once the
    // notice checks out on chain (MESSAGING.md, "Token Payments in a Chat").

    /// A dollar send from a chat went out: the payer's bubble now, and the notice for the payee.
    /// If the notice can't go (an empty chatting address), it is kept and sent once there's KAS.
    func recordTokenPayment(to contact: Contact, token: WalletToken, txId: String, index: UInt32, amount: UInt64) {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        let txId = txId.lowercased()
        // once per payment: a send whose outcome was unknown can report in twice
        guard !(conversations.first(where: { $0.contact.address == contact.address })?.messages
            .contains(where: { $0.txId == txId }) ?? false) else { return }
        let now = Date()
        let bubble = ChatMessage(
            txId: txId,
            senderAddress: wallet.publicAddress,
            receiverAddress: contact.address,
            content: tokenPaymentText(amount: amount, token: token, isOutgoing: true),
            timestamp: now,
            blockTime: UInt64(now.timeIntervalSince1970 * 1000),
            acceptingBlock: nil,
            isOutgoing: true,
            messageType: .payment,
            deliveryStatus: .sent
        )
        insertOwnTokenBubble(bubble, contactAddress: contact.address)

        let payload = PaymentPoolCodec.encode(
            TokenPaymentNoticeContent(token: token.id, txId: txId, index: index, amount: amount, address: contact.address)
        )
        guard !payload.isEmpty else { return }
        let owner = wallet.publicAddress
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.enqueueOutgoingTxOperation {
                    try await self.sendEnvelopeInternal(to: contact, payload: payload, owner: owner)
                }
                AppLog.log("[ChatService] Sent token_payment_notice for %@", String(txId.prefix(12)))
            } catch {
                AppLog.log("[ChatService] token_payment_notice send failed for %@, kept for later: %@",
                           String(txId.prefix(12)), error.localizedDescription)
                self.keepUnsentNotice(UnsentPaymentNotice(contactAddress: contact.address, payload: payload, txId: txId),
                                      owner: owner)
            }
        }
    }

    /// Our own token payment bubble, straight into the chat: not through
    /// `addMessageToConversation`, whose outgoing path would take it as the answer to a Kaspa
    /// payment still pending in this chat.
    private func insertOwnTokenBubble(_ bubble: ChatMessage, contactAddress: String) {
        // deleted stays deleted, when our own notice is read back
        guard !DeletedMessageLog.contains(bubble.txId, kind: .chat) else { return }
        markTokenPaymentBubble(bubble.txId, wallet: bubble.senderAddress)
        if let index = conversations.firstIndex(where: { $0.contact.address == contactAddress }) {
            guard !conversations[index].messages.contains(where: { $0.txId == bubble.txId }) else { return }
            updateConversation(at: index) { $0.messages.append(bubble) }
        } else {
            addMessageToConversation(bubble, contactAddress: contactAddress)
        }
        saveMessages()
    }

    /// A `token_payment_notice` in a 1:1 chat: theirs (they sent us dollars) or our own read back
    /// on another device. Like `handlePaymentNotice`: it must name the receiving side's chatting
    /// address, a received one is checked on chain before it shows, an unchecked one shows marked
    /// unverified, and nothing already stored under that txid is moved or overwritten.
    func handleTokenPaymentNotice(_ notice: TokenPaymentNoticeContent, message: ChatMessage, contactAddress: String) {
        guard let wallet = WalletManager.shared.currentWallet,
              let token = WalletToken.all.first(where: { $0.id == notice.token }) else { return }
        let walletAddress = wallet.publicAddress
        let txId = notice.txId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard txId.count == 64, txId.allSatisfy(\.isHexDigit), notice.amount > 0 else { return }
        let paidAddress = message.isOutgoing ? contactAddress : walletAddress
        guard notice.address.lowercased() == paidAddress.lowercased() else {
            AppLog.log("[ChatService] Dropped token_payment_notice %@ - not a payment to the chatting address",
                       String(txId.prefix(12)))
            return
        }
        let isOutgoing = message.isOutgoing
        let text = tokenPaymentText(amount: notice.amount, token: token, isOutgoing: isOutgoing)

        Task { @MainActor [weak self] in
            guard let self, self.isActiveWallet(walletAddress) else { return }
            if let existing = await self.findLocalMessage(txId: txId) {
                // only this notice's own unverified bubble is checked again; anything else stays
                guard !isOutgoing, !existing.isOutgoing, existing.messageType == .payment,
                      existing.deliveryStatus == .warning,
                      existing.senderAddress.lowercased() == contactAddress.lowercased() else { return }
                switch await self.checkTokenNoticeOnChain(notice, token: token, txId: txId, paidAddress: walletAddress, payer: contactAddress) {
                case .valid:
                    _ = self.updateIncomingPaymentStatus(txId: txId, deliveryStatus: .sent, content: text)
                    self.saveMessages()
                case .invalid(let reason):
                    // still this notice's unverified bubble after the await?
                    guard self.isActiveWallet(walletAddress),
                          let current = await self.findLocalMessage(txId: txId),
                          !current.isOutgoing, current.deliveryStatus == .warning,
                          current.senderAddress.lowercased() == contactAddress.lowercased() else { return }
                    self.unmarkNoticeBubble(txId)
                    self.removeMessage(txId: txId)
                    self.messageStore.deleteMessage(txId: txId)
                    self.saveMessages()
                    AppLog.log("[ChatService] Removed unverified token_payment_notice bubble %@ - %@", String(txId.prefix(12)), reason)
                case .unknown:
                    break
                }
                return
            }
            // An unchecked claim shows without its amount: anyone can make a look-alike coin, and
            // only the token's covenant id (checked once the chain answers) tells them apart.
            let bubble = { (status: ChatMessage.DeliveryStatus) in
                ChatMessage(
                    txId: txId,
                    senderAddress: isOutgoing ? walletAddress : contactAddress,
                    receiverAddress: notice.address,
                    content: status == .warning
                        ? String(format: AppLocalization.string("Unverified %@ payment"), token.symbol)
                        : text,
                    timestamp: message.timestamp,
                    blockTime: message.blockTime,
                    acceptingBlock: nil,
                    isOutgoing: isOutgoing,
                    messageType: .payment,
                    deliveryStatus: status
                )
            }
            if isOutgoing {
                // our own notice on another device: the bubble this device doesn't have
                self.insertOwnTokenBubble(bubble(.sent), contactAddress: contactAddress)
                return
            }
            let check = await self.checkTokenNoticeOnChain(notice, token: token, txId: txId, paidAddress: walletAddress, payer: contactAddress)
            // after the await: still this wallet, and still nothing stored under that txid
            guard self.isActiveWallet(walletAddress), await self.findLocalMessage(txId: txId) == nil else { return }
            let status: ChatMessage.DeliveryStatus
            switch check {
            case .valid: status = .sent
            case .unknown: status = .warning
            case .invalid(let reason):
                AppLog.log("[ChatService] Dropped token_payment_notice %@ - %@", String(txId.prefix(12)), reason)
                return
            }
            // the generic payment code leaves it to this notice to confirm
            self.markNoticeBubble(txId, wallet: walletAddress)
            self.markTokenPaymentBubble(txId, wallet: walletAddress)
            self.addMessageToConversation(bubble(status), contactAddress: contactAddress)
            self.saveMessages()
            AppLog.log("[ChatService] Token payment %@ filed in its chat from a token_payment_notice (%@)",
                       String(txId.prefix(12)), status.rawValue)
        }
    }

    /// What the chain says about a received token notice:
    /// - output `index` of the transaction is the coin of exactly `amount` owned by `paidAddress`
    ///   (its script worked out here from the pinned template), carrying the token's covenant id
    ///   (from the explorer, else from the node while the coin is unspent);
    /// - no input is ours or another contact's: by address, and for a token coin being spent, by
    ///   the owner key in its state (a coin's input address is its P2SH, which matches nobody, so a
    ///   contact could otherwise claim our own Combine Coins or another contact's whole send).
    /// A coin spent since still shows in the transaction, so this works for history too.
    private func checkTokenNoticeOnChain(_ notice: TokenPaymentNoticeContent, token: WalletToken, txId: String,
                                         paidAddress: String, payer: String) async -> NoticeCheck {
        guard token == .kusdt else { return .invalid("not a token this app can check") }
        guard let template = Kusdt.template else { return .unknown }
        guard let owner = Kusdt.schnorrOwner(of: paidAddress) else { return .invalid("the chatting address can't hold tokens") }
        let script = Kusdt.lockingScript(.plain(owner: owner, amount: notice.amount), template: template)
        guard let coinAddress = Kusdt.address(ofLockingScript: script) else { return .unknown }
        guard let url = kaspaRestURL(path: "/transactions/\(txId)",
                                     queryItems: [URLQueryItem(name: "resolve_previous_outpoints", value: "light")]),
              let (data, response) = try? await URLSession.shared.data(for: Self.timedRequest(url)),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let fullTx = try? JSONDecoder().decode(KaspaFullTransactionResponse.self, from: data) else {
            return .unknown
        }
        let position = Int(notice.index)
        let output = fullTx.outputs.first(where: { $0.index == position })
            ?? (fullTx.outputs.indices.contains(position) && fullTx.outputs[position].index == nil ? fullTx.outputs[position] : nil)
        guard let output else { return .invalid("it has no output \(notice.index)") }
        guard output.scriptPublicKeyAddress?.lowercased() == coinAddress.lowercased() else {
            return .invalid("output \(notice.index) isn't a coin of that amount for this address")
        }

        // who paid
        let rawInputs = fullTx.inputs ?? []
        guard !rawInputs.isEmpty, rawInputs.allSatisfy({ $0.previousOutpointAddress != nil }) else { return .unknown }
        let own = ownAddressesForNotices(walletAddress: paidAddress)
        let payerAddress = payer.lowercased()
        let ownKeys = Set(own.compactMap { Kusdt.schnorrOwner(of: $0) })
        let payerKey = Kusdt.schnorrOwner(of: payer)
        let otherContactKeys = Set(contactsManager.contacts
            .filter { $0.address.lowercased() != payerAddress }
            .compactMap { Kusdt.schnorrOwner(of: $0.address) })
        let prefixHex = Kusdt.hex(template.prefix)
        for input in rawInputs {
            guard let address = input.previousOutpointAddress?.lowercased() else { return .unknown }
            if own.contains(address) { return .invalid("paid by one of our own addresses") }
            if address != payerAddress, contactsManager.getContact(byAddress: address) != nil {
                return .invalid("paid by another contact")
            }
            // a script input: if it spends a token coin, its owner is in the coin's state
            guard Kusdt.schnorrOwner(of: address) == nil else { continue }
            guard let sigScript = input.signatureScript?.lowercased() else { return .unknown }
            guard let coinOwner = Self.tokenCoinOwner(signatureScriptHex: sigScript, templatePrefixHex: prefixHex) else { continue }
            if ownKeys.contains(coinOwner) { return .invalid("it spends one of our own coins") }
            if coinOwner != payerKey, otherContactKeys.contains(coinOwner) { return .invalid("it spends another contact's coin") }
        }

        // the real token: its covenant id, from the explorer or else the node
        if let covenant = output.covenantId?.lowercased(), !covenant.isEmpty {
            return covenant == Kusdt.hex(Kusdt.current.covenantId) ? .valid : .invalid("the coin isn't \(token.symbol)")
        }
        guard let utxos = try? await NodePoolService.shared.getUtxosByAddresses([coinAddress], allowRestFallback: false),
              let coin = utxos.first(where: { $0.outpoint.transactionId.lowercased() == txId && $0.outpoint.index == notice.index }) else {
            // spent since, or no node answer: can't tell it from a look-alike
            return .unknown
        }
        guard coin.scriptPublicKey == script, coin.covenantId?.lowercased() == Kusdt.hex(Kusdt.current.covenantId) else {
            return .invalid("the coin isn't \(token.symbol)")
        }
        return .valid
    }

    /// The owner key of a token coin an input spends: the redeem script, the last push of a P2SH
    /// input's signature script, is `prefix ‖ 112-byte state ‖ suffix`, and the state's bytes 10-41
    /// are the owner (`Kusdt.State.encoded`). Nil when the input doesn't spend a token coin.
    nonisolated static func tokenCoinOwner(signatureScriptHex hex: String, templatePrefixHex prefix: String) -> Data? {
        var searchStart = hex.startIndex
        while let found = hex.range(of: prefix, range: searchStart..<hex.endIndex) {
            let offset = hex.distance(from: hex.startIndex, to: found.lowerBound)
            // byte-aligned only
            if offset % 2 == 0 {
                let stateHex = hex[found.upperBound...].prefix(224)
                if stateHex.count == 224, stateHex.hasPrefix("08") {
                    let ownerHex = stateHex.dropFirst(20).prefix(64)
                    if stateHex.dropFirst(18).hasPrefix("20"), let owner = Kusdt.unhexOrNil(String(ownerHex)) {
                        return owner
                    }
                }
            }
            searchStart = hex.index(after: found.lowerBound)
        }
        return nil
    }

    /// "Sent 12.50 kUSDT" / "Received 12.50 kUSDT": the amount with a dot and no grouping, so the
    /// payment bubble reads it back (`MessageBubbleView.paymentCardParts`).
    func tokenPaymentText(amount: UInt64, token: WalletToken, isOutgoing: Bool) -> String {
        String(format: AppLocalization.string(isOutgoing ? "Sent %1$@ %2$@" : "Received %1$@ %2$@"),
               token.plainAmount(amount), token.symbol)
    }

    private func paymentNoticeText(amountSompi: UInt64, memo: String, isOutgoing: Bool) -> String {
        let amount = formatKasAmount(amountSompi)
        if memo.isEmpty {
            return String(format: KaspaUnit.label(AppLocalization.string(isOutgoing ? "Sent %@ KAS" : "Received %@ KAS")), amount)
        }
        return String(format: KaspaUnit.label(AppLocalization.string(isOutgoing ? "Sent %@ KAS — %@" : "Received %@ KAS — %@")),
                      amount, memo)
    }
}
