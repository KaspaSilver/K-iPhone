import SwiftUI
import UIKit

// MARK: - Request Payment (Profile > the send / receive button > Request Payment)

/// Makes a payment request link: to your chatting or spending address, an exact amount and what
/// it's for. Copy (or share) the link and send it anywhere; in KaChat it opens Send Kaspa filled
/// in (`PaymentRequest`, `KaChatInternalLink.paymentRequest`). Made from a 1:1 chat's + sheet
/// (`recipient`), it is for that person: the button sends it into the chat instead.
struct CreatePaymentRequestView: View {
    /// The contact it is for (a 1:1 chat): Send Payment Request sends it to them.
    var recipient: Contact? = nil

    enum Destination: Hashable {
        /// A brand-new spending address, never revealed, used or handed out.
        case fresh
        /// One of your addresses, picked from the list: the chatting address or a spending one.
        case chosen
    }

    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    @State private var destination: Destination = .fresh
    /// The brand-new address reserved for this request (`reserveFreshSpendingAddresses`) - only
    /// when it's copied, shared or sent, so opening the screen and cancelling uses none up. Once
    /// per screen: Copy, Share and Send all reuse it, so no two requests share an address.
    @State private var freshAddress: String?
    /// The next brand-new address, shown before it's reserved.
    @State private var nextFreshAddress: String?
    @State private var chosenAddress: String?
    @State private var amountInput = ""
    @State private var memo = ""
    @State private var copied = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var shareItem: ShareURL?
    /// The request shown as a QR (Show Request As QR).
    @State private var qrRequest: PaymentRequest?

    private struct ShareURL: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var chattingAddress: String? { walletManager.currentWallet?.publicAddress }

    private var amountSompi: UInt64? {
        guard let sompi = KaspaUnit.sompi(fromUserText: amountInput), sompi > 0 else { return nil }
        return sompi
    }

    /// Ready to hand out: an amount, and an address (or a fresh one to be made).
    private var canMake: Bool {
        amountSompi != nil && (destination == .fresh || chosenAddress != nil)
    }

    /// Like a send, in steps: where to be paid, how much (on the app's keypad), then the review
    /// with the memo, Copy and Share (Send Payment Request for a chat).
    private enum Step: Int { case destination, amount, review }
    @State private var step: Step = .destination
    @State private var stepForward = true

    /// The address the request pays: the fresh one (reserved, else the one it will be), or the pick.
    private var payeeAddress: String? {
        switch destination {
        case .fresh: return freshAddress ?? nextFreshAddress
        case .chosen: return chosenAddress
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                switch step {
                case .destination: destinationStep.transition(stepTransition)
                case .amount: amountStep.transition(stepTransition)
                case .review: reviewStep.transition(stepTransition)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: amountInput) { _ in copied = false }
            .onChange(of: memo) { _ in copied = false }
            .onChange(of: destination) { _ in copied = false }
            .onChange(of: chosenAddress) { _ in copied = false }
            .task {
                // derived, not reserved: opening the screen and cancelling uses no address up.
                // The fresh slot is quantum-safe (KIP-22) now, matching what reserving returns.
                // Checked on chain (IOS-101), so the preview never shows a slot already used.
                // Slot and address from the same account (IOS-109).
                nextFreshAddress = await WalletManager.shared.verifiedFreshQuantumSlot()?.address
            }
            .sheet(item: $shareItem) { item in
                PaymentRequestShareSheet(url: item.url)
            }
            .sheet(item: $qrRequest) { request in
                PaymentRequestQRSheet(request: request)
            }
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: stepForward ? .trailing : .leading),
                    removal: .move(edge: stepForward ? .leading : .trailing))
    }

    private func go(to next: Step) {
        dismissSystemKeyboard()
        stepForward = next.rawValue > step.rawValue
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { step = next }
        }
    }

    // MARK: Where

    private var destinationStep: some View {
        SendStepScreen(title: Text("Request Payment"), onCancel: { dismiss() }, canContinue: payeeAddress != nil) {
            go(to: .amount)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SendStepQuestion(text: "Where do you want to be paid?")
                    HStack(spacing: 10) {
                        SelectablePill(title: "Fresh Address", selected: destination == .fresh) {
                            destination = .fresh
                        }
                        SelectablePill(title: "Choose an Address", selected: destination == .chosen) {
                            destination = .chosen
                        }
                    }

                    switch destination {
                    case .fresh:
                        if let address = freshAddress ?? nextFreshAddress {
                            AddressResolutionCard(address: address)
                            Text("A brand-new address of yours that has never been used or handed out.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        } else {
                            HStack { Spacer(); ProgressView(); Spacer() }
                                .padding(.vertical, 18)
                        }
                    case .chosen:
                        // the list right here, no sheet: tap the address that gets paid
                        Text("Pick which of your addresses gets paid.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        OwnAddressList(selected: chosenAddress) { picked in
                            chosenAddress = picked.address
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: How much

    private var amountStep: some View {
        SendStepScreen(title: Text("Request Payment"), onBack: { go(to: .destination) }, onCancel: { dismiss() },
                       continueTitle: "Review", canContinue: amountSompi != nil) {
            go(to: .review)
        } content: {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    SendStepQuestion(text: "How much?")
                    if let payeeAddress {
                        SendInfoPill {
                            HStack(spacing: 4) {
                                Text("Paid to")
                                Text(verbatim: "\(payeeAddress.prefix(14))...\(payeeAddress.suffix(6))")
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                KaspaKeypadAmountEntry(
                    fiatAmountState: fiatAmountState,
                    onAmountChange: { amountInput = $0 },
                    showsMax: false,
                    onMax: {}
                )
            }
        }
    }

    // MARK: Review

    private var reviewStep: some View {
        SendStepScreen(title: Text("Review"), onBack: { go(to: .amount) }, onCancel: { dismiss() },
                       continueTitle: recipient != nil ? "Send Payment Request" : (copied ? "Copied" : "Copy Payment Request"),
                       canContinue: canMake && !isWorking,
                       secondaryTitle: recipient == nil ? "Show Request As QR" : nil,
                       secondaryIcon: "qrcode",
                       onSecondary: recipient == nil ? showQR : nil) {
            if let recipient {
                send(to: recipient)
            } else {
                copy()
            }
        } content: {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Text("You're requesting")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if let amountSompi {
                            Text(verbatim: "\(KaspaUnit.plain(amountSompi)) \(KaspaUnit.symbol)")
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            if let price = KasPriceModel.shared.currentPriceUsd, price > 0 {
                                Text(verbatim: formatFiatAmount(Double(amountSompi) / 100_000_000.0 * price,
                                                                currency: KasPriceModel.shared.currentCurrency))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paid to")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        AddressResolutionCard(address: payeeAddress)
                    }

                    VStack(alignment: .trailing, spacing: 6) {
                        TextField("What it's for (optional)", text: $memo, axis: .vertical)
                            .lineLimit(1...4)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(.regularMaterial)
                            )
                            .onChange(of: memo) { value in
                                if value.count > PaymentRequest.memoLimit {
                                    memo = String(value.prefix(PaymentRequest.memoLimit))
                                }
                            }
                        Text(verbatim: "\(memo.count)/\(PaymentRequest.memoLimit)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(payeeAddress == chattingAddress
                         ? "The payment lands in your chat with whoever pays, with the memo."
                         : "The memo shows to whoever pays, but doesn't travel with the payment.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }

                    if recipient == nil {
                        Button(action: share) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canMake || isWorking)
                    }

                    Text("Anyone who opens it in KaChat gets Send Kaspa with this filled in, and sees it was made by your chatting address (signed with its key).")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// The request to hand out, signed by your chatting address (whoever pays sees it's from you,
    /// even when it's paid to a spending address, which has no identity). A fresh address is
    /// reserved here, the first time it's needed.
    private func makeRequest() async -> PaymentRequest? {
        guard let sompi = amountSompi else { return nil }
        let address: String
        switch destination {
        case .fresh:
            if let freshAddress {
                address = freshAddress
            } else {
                guard let reserved = await walletManager.reserveFreshSpendingAddresses(count: 1).first?.address else {
                    errorMessage = AppLocalization.string("Couldn't make a new address. Please try again.")
                    return nil
                }
                freshAddress = reserved
                address = reserved
                // watched from now on, so its payment shows the moment it lands
                ChatService.shared.checkAndResubscribeIfNeeded()
            }
        case .chosen:
            guard let chosenAddress else { return nil }
            address = chosenAddress
        }
        let unsigned = PaymentRequest(address: address, amountSompi: sompi, memo: memo,
                                      toChattingAddress: address == chattingAddress)
        // an account whose key isn't on this phone can still ask; the payer is told it's unsigned
        guard let creator = chattingAddress, let key = WalletManager.shared.getPrivateKey() else { return unsigned }
        return unsigned.signed(by: creator, privateKey: key) ?? unsigned
    }

    /// Sends the request into the chat as a message: it shows there as a Payment Request card,
    /// which they tap to pay.
    private func send(to contact: Contact) {
        // two taps in one frame would each reserve a fresh address
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            guard let request = await makeRequest() else { isWorking = false; return }
            do {
                try await ChatService.shared.sendMessage(to: contact, content: request.shareURLString, feeOverride: nil)
                Haptics.success()
                dismiss()
            } catch {
                isWorking = false
                errorMessage = UserFacingError.message(for: error)
            }
        }
    }

    private func copy() {
        // two taps in one frame would each reserve a fresh address
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            guard let request = await makeRequest() else { return }
            UIPasteboard.general.string = request.shareURLString
            Haptics.success()
            copied = true
        }
    }

    /// Show Request As QR: the same signed request, as a code to scan with a phone's camera.
    private func showQR() {
        // two taps in one frame would each reserve a fresh address
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            guard let request = await makeRequest() else { return }
            qrRequest = request
        }
    }

    private func share() {
        // two taps in one frame would each reserve a fresh address
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            guard let request = await makeRequest(), let url = URL(string: request.shareURLString) else { return }
            shareItem = ShareURL(url: url)
        }
    }
}

/// A payment request as a QR: its kachat.app link, so an iPhone's camera opens KaChat on Send,
/// filled in. (Until 2026-11-21 a request to a spending address held a `kapay://pay/` link for
/// KaPay; KaPay is retired and KaChat pays every request itself, and still opens those links.)
private struct PaymentRequestQRSheet: View {
    let request: PaymentRequest
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    private var payload: String {
        request.shareURLString
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 4) {
                        Text(verbatim: "\(KaspaUnit.plain(request.amountSompi)) \(KaspaUnit.symbol)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        let memo = request.memo.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !memo.isEmpty {
                            Text(verbatim: memo)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 8)

                    Group {
                        if let image {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(width: 260, height: 260)
                    .padding(16)
                    // white, with a quiet zone, so every camera reads it in dark mode too
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white))

                    Text("Scan it with an iPhone's camera to pay in KaChat, with everything filled in.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Payment Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { image = ZeroBalanceFundingCardView.makeChattingAddressQRCode(from: payload) }
        }
    }
}

private struct PaymentRequestShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Paying one

// Every payment request is paid here since 2026-11-21 (KaPay is retired): someone else's opens
// Send Kaspa filled in, your own shows itself (`PaymentRequestSheetPresenter`). `kapay://pay/...`
// links an older KaPay or KaChat made still open, in KaChat (`KaChatApp.handleIncomingURL`).

/// A text view where pasting someone's payment request opens Send Kaspa (the KaPosts composer;
/// the chat composers' `ComposerUITextView` does the same).
final class PaymentRequestAwareTextView: UITextView {
    override func paste(_ sender: Any?) {
        if PaymentRequestPaste.openIfRequest(UIPasteboard.general.string) { return }
        super.paste(sender)
    }
}

/// Pasting a payment request anywhere in KaChat opens Send Kaspa with it. Only text that is the
/// link and nothing else, and only someone else's request: your own pastes as text, so you can
/// send it to the person who should pay.
enum PaymentRequestPaste {
    @MainActor
    static func openIfRequest(_ text: String?) -> Bool {
        guard let text, let match = KaChatInternalLink.match(in: text), match.coversWholeMessage,
              case .paymentRequest(let request) = match.link, !request.isOwn else { return false }
        KaChatLinkRouter.openPaymentRequest(request)
        return true
    }
}

/// What a payment request asks for, above the amount on Send Kaspa.
struct PaymentRequestSummary: View {
    let request: PaymentRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Requested")
                .font(.caption.weight(.semibold))
                .foregroundColor(.accentColor)
                .textCase(.uppercase)
            Text(verbatim: "\(request.amountText) \(KaspaUnit.symbol)")
                .font(.headline)
            if !request.memo.isEmpty {
                Text(verbatim: request.memo)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(request.toChattingAddress
                 ? "Paid as a chat payment: it shows in your chat with them."
                 : "Paid to their spending address.")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider().padding(.vertical, 4)

            if let creator = request.creator {
                // Who made it - the address was checked against the signature in the link when
                // it was opened; the name on the card has its own check below.
                RequestedByHeader(creator: creator)
                AddressResolutionCard(address: creator)
                if creator.lowercased() != request.address.lowercased() {
                    Text("Signed by their chatting address. The payment goes to the address above.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Label("Not signed: who made this request can't be confirmed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
    }
}

/// "Requested by", above the requester's card. The signature proves the address and says nothing
/// about the name the card shows, which is the registry's answer for that address (possibly a
/// cached one), so the green check waits for the name itself to resolve back to this address.
private struct RequestedByHeader: View {
    let creator: String

    /// re-renders when the creator's .kachat identity lands (`cachedIdentity` fills in the background)
    @ObservedObject private var kachatRegistry = KachatNamesRegistry.shared
    @State private var verifiedName: String?

    private var shownName: String? {
        kachatRegistry.cachedIdentity(for: creator)?.label
    }

    var body: some View {
        let isVerified = shownName != nil && verifiedName == shownName
        Label("Requested by", systemImage: isVerified ? "checkmark.seal.fill" : "person.crop.circle")
            .font(.caption.weight(.semibold))
            .foregroundColor(isVerified ? .green : .secondary)
            .task(id: shownName) { await verify(shownName) }
    }

    private func verify(_ name: String?) async {
        verifiedName = nil
        guard let name, let owner = KachatNamesRegistry.keyOf(creator),
              case .registered(let info)? = try? await kachatRegistry.lookup(name),
              info.owner == owner, info.status(graceMs: kachatRegistry.graceMs) != .lapsed,
              !Task.isCancelled else { return }
        verifiedName = name
    }
}

/// A payment request link in a chat's composer, shown above the field before sending: the same
/// details the bubble's card (`KaChatInternalLinkCardView`) will show. The X takes the link out
/// of the message.
struct ComposerPaymentRequestPreview: View {
    let request: PaymentRequest
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                Image(systemName: "arrow.up.circle")
                    .font(.scaled(size: 18, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Payment Request")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .textCase(.uppercase)
                Text(verbatim: "\(request.amountText) \(KaspaUnit.symbol)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if !request.memo.isEmpty {
                    Text(verbatim: request.memo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.scaled(size: 20))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove"))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
        )
    }
}

/// One of your own payment requests, tapped in a chat: what it asks for and where it pays into,
/// with its link to copy or share again. Nothing to pay - it's yours.
struct OwnPaymentRequestView: View {
    let request: PaymentRequest
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Text(verbatim: "\(request.amountText) \(KaspaUnit.symbol)")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                        if !request.memo.isEmpty {
                            Text(verbatim: request.memo)
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(request.toChattingAddress ? "Paid to your chatting address" : "Paid to your spending address")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .textCase(.uppercase)
                        AddressResolutionCard(address: request.address)
                        Text(request.toChattingAddress
                             ? "The payment lands in your chat with whoever pays, with the memo."
                             : "Paid to a brand-new address of yours, used for this request only. The memo shows to whoever pays, but doesn't travel with the payment.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    SendActionButton(
                        title: copied ? "Copied" : "Copy Payment Request",
                        isBusy: false,
                        isEnabled: true,
                        requiresSlide: false
                    ) {
                        UIPasteboard.general.string = request.shareURLString
                        Haptics.success()
                        copied = true
                    }

                    if let url = URL(string: request.shareURLString) {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle("Your Payment Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// A payment request link in a KaPost, drawn as a card instead of the link's long text: the
/// amount (and what it comes to in the app's currency), the memo, who signed it, and a Pay
/// button. A tap opens it from the card itself (Send Kaspa filled in, or your own request), so it
/// works inside threads and profiles (full-screen covers the dock's sheet can't show over) too.
struct KaPostPaymentRequestCard: View {
    let request: PaymentRequest

    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @ObservedObject private var priceService = KasPriceModel.shared
    @State private var presented: PaymentRequest?

    private var fiatText: String? {
        let currency = settingsViewModel.settings.currency
        guard let price = priceService.price(in: currency), price > 0 else { return nil }
        return "\u{2248} " + formatFiatAmount(Double(request.amountSompi) / 100_000_000 * price, currency: currency)
    }

    private var creatorName: String? {
        guard let creator = request.creator else { return nil }
        if let name = KachatLive.identityName(creator) { return name }
        return ContactsManager.shared.displayName(for: creator)
    }

    var body: some View {
        let isOwn = request.isOwn
        Button {
            Haptics.impact(.light)
            presented = request
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image("KaspaLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Payment Request")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .textCase(.uppercase)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "\(request.amountText) \(KaspaUnit.symbol)")
                                .font(.system(.title2, design: .rounded).weight(.bold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            if let fiatText {
                                Text(verbatim: fiatText)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if !request.memo.isEmpty {
                            Text(verbatim: request.memo)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    if let creatorName {
                        Label {
                            Text(verbatim: creatorName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    } else {
                        Label("Not signed", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.orange)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 5) {
                        Image(systemName: isOwn ? "eye" : "arrow.up.circle.fill")
                        Text(isOwn ? "View" : "Pay")
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(isOwn ? .accentColor : .white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(isOwn ? Color.accentColor.opacity(0.15) : Color.accentColor))
                    .fixedSize()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(isOwn ? "Shows your payment request." : "Opens Send Kaspa to pay it."))
        .contextMenu {
            Button {
                UIPasteboard.general.string = request.shareURLString
                Haptics.success()
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
        }
        // what `PaymentRequestSheetPresenter` shows
        .sheet(item: $presented) { request in
            if request.isOwn {
                OwnPaymentRequestView(request: request)
                    .environmentObject(settingsViewModel)
            } else if let wallet = WalletManager.shared.currentWallet {
                WithdrawKaspaView(
                    fromAddress: wallet.publicAddress,
                    availableBalanceSompi: wallet.balanceSompi,
                    paymentRequest: request
                )
                .environmentObject(ChatService.shared)
                .environmentObject(ContactsManager.shared)
                .environmentObject(WalletManager.shared)
                .environmentObject(settingsViewModel)
            }
        }
    }
}

/// Presents Send Kaspa for the payment request waiting in `PaymentRequestRouter` - a tapped
/// request card, a pasted link, a link opened from outside the app.
struct PaymentRequestSheetPresenter: ViewModifier {
    @ObservedObject private var router = PaymentRequestRouter.shared
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $router.pending) { request in
                if request.isOwn {
                    OwnPaymentRequestView(request: request)
                        .environmentObject(settingsViewModel)
                } else if let wallet = WalletManager.shared.currentWallet {
                    WithdrawKaspaView(
                        fromAddress: wallet.publicAddress,
                        availableBalanceSompi: wallet.balanceSompi,
                        paymentRequest: request
                    )
                    .environmentObject(ChatService.shared)
                    .environmentObject(ContactsManager.shared)
                    .environmentObject(WalletManager.shared)
                    .environmentObject(settingsViewModel)
                }
            }
    }
}
