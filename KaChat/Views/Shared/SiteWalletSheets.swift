import SwiftUI

/// The sheets a website opened in K's browser asks through `KaChatSiteWallet` (Kasshi, owner
/// 2026-11-26): Connect (which address), Sign (a message) and Send (K's own Send Kaspa review).
/// Built from the Send Kaspa pieces so they look like every other send step.
struct SiteWalletSheet: View {
    @ObservedObject var wallet: KaChatSiteWallet
    let request: KaChatSiteWallet.Request
    @StateObject private var settingsViewModel = SettingsViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch request.kind {
        case .connect:
            SiteConnectView(host: request.host, onConnect: { source in
                wallet.approveConnect(source: source, host: request.host)
                dismiss()
            }, onDecline: { dismiss() })
        case .sign(let message):
            SiteSignView(host: request.host, address: wallet.connection?.address ?? "", message: message,
                         onSign: {
                             wallet.approveSign(message)
                             dismiss()
                         }, onDecline: { dismiss() })
        case .send(let to, let sompi):
            if let connection = wallet.connection, let account = WalletManager.shared.currentWallet {
                WithdrawKaspaView(
                    fromAddress: account.publicAddress,
                    availableBalanceSompi: nil,
                    paymentRequest: PaymentRequest(address: to, amountSompi: sompi, memo: "", toChattingAddress: false),
                    lockedSource: connection.source,
                    siteHost: request.host,
                    onSent: { txId in wallet.sent(txId: txId) }
                )
                .environmentObject(ChatService.shared)
                .environmentObject(ContactsManager.shared)
                .environmentObject(WalletManager.shared)
                .environmentObject(settingsViewModel)
            }
        }
    }
}

/// The site's name and what it is asking, at the top of Connect and Sign.
private struct SiteHeader: View {
    let host: String
    let note: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.scaled(size: 20, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                Text(verbatim: host)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(note)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sendKaspaGlass(cornerRadius: 16))
    }
}

/// Connect: which address the site gets. The Chatting Address, or another regular address of the
/// account (`OwnAddressList`, quantum ones left out). The address picked last time is suggested.
struct SiteConnectView: View {
    let host: String
    let onConnect: (SendSource) -> Void
    let onDecline: () -> Void

    @State private var source: SendSource = .chatting
    @State private var choosing = false

    var body: some View {
        SendStepScreen(title: Text("Connect to K"),
                       onCancel: onDecline,
                       continueTitle: "Connect",
                       canContinue: !(choosing && source == .chatting)) {
            onConnect(source)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SiteHeader(host: host, note: "This site sees the address you connect and its balance. It can ask you to sign in or to pay, and nothing happens without your OK here.")
                    SendStepQuestion(text: "Which address do you want to connect?")
                    HStack(spacing: 10) {
                        SelectablePill(title: "Chatting Address", selected: !choosing) {
                            choosing = false
                            source = .chatting
                        }
                        SelectablePill(title: "Choose an Address", selected: choosing) {
                            choosing = true
                        }
                    }
                    if choosing {
                        Text("Another address keeps this site apart from your username and chats.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        OwnAddressList(selected: source == .chatting ? nil : source.address, excludeQuantum: true) { picked in
                            source = picked
                            if picked == .chatting { choosing = false }
                        }
                    } else if let wallet = WalletManager.shared.currentWallet {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Chatting Address")
                                    .font(.subheadline.weight(.semibold))
                                Text(verbatim: "\(wallet.publicAddress.prefix(14))...\(wallet.publicAddress.suffix(6))")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if let balance = wallet.balanceSompi {
                                Text(verbatim: "\(KaspaUnit.plain(balance)) \(KaspaUnit.symbol)")
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                            }
                        }
                        .padding(14)
                        .background(sendKaspaGlass(cornerRadius: 16))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .task {
            // the address connected last time on this site
            guard let index = KaChatSiteWallet.rememberedSpendingIndex(host: host) else { return }
            let all = await WalletManager.shared.getSpendingAddressList()
            guard let entry = all.first(where: { $0.index == index && !$0.isQuantum }) else { return }
            source = .spending(index: entry.index, address: entry.address, label: entry.displayLabel)
            choosing = true
        }
    }
}

/// Sign: the site's message in full, signed with the connected address's key.
struct SiteSignView: View {
    let host: String
    let address: String
    let message: String
    let onSign: () -> Void
    let onDecline: () -> Void

    var body: some View {
        SendStepScreen(title: Text("Sign Message"),
                       onCancel: onDecline,
                       continueTitle: "Sign",
                       canContinue: true) {
            onSign()
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SiteHeader(host: host, note: "Signing proves you own this address. It costs nothing and sends no Kaspa.")
                    SendStepChip(label: "Address", value: address, isAddress: true)
                    Text("Message")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Text(verbatim: message)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(sendKaspaGlass(cornerRadius: 16))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
    }
}

/// On a site's send: who asked for it, in place of a payment request's card.
struct SiteRequestNote: View {
    let host: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Requested by")
                .font(.caption.weight(.semibold))
                .foregroundColor(.accentColor)
                .textCase(.uppercase)
            Text(verbatim: host)
                .font(.headline)
            Text("Check the amount and the address before you send.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(sendKaspaGlass(cornerRadius: 16))
    }
}
