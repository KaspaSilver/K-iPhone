import SwiftUI
import WebKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

/// Resolves a fresh receive address before drawing the QR, so the code on screen is never
/// one that has already appeared on chain.
///
/// A view of its own rather than resolving in the NavigationLink's destination builder: that
/// builder is evaluated eagerly while the row is merely on screen, so any work in it would
/// run whether or not the user ever taps, and it cannot await.
/// Opened from Wallet's Receive button. Never substitutes the
/// CHATTING address for the spending role; if nothing can be derived this instant (locked
/// keychain) it says so rather than showing the wrong address.
struct ReceiveKaspaQRView: View {
    @EnvironmentObject private var walletManager: WalletManager
    @State private var address: String?
    @State private var resolving = true

    var body: some View {
        Group {
            if let address {
                // the shared receive screen (owner's design, 2026-11-19, from kUSDT's): a fresh
                // REGULAR address, which takes kUSDT as well as Kaspa
                AddressReceiveView(
                    title: AppLocalization.string("Receive Kaspa"),
                    address: address,
                    addressLabel: walletManager.ownAddressLabel(for: address),
                    privacyNote: ReceiveNotes.freshAddress,
                    notes: [
                        ReceiveNotes.kaspaAndKusdt,
                        ReceiveNote(kind: .info, text: AppLocalization.string("It lands in this account and shows in your spending total. Use it for everything except .kachat names.")),
                    ],
                    icon: { KaspaLogoIcon() }
                )
            } else if resolving {
                ProgressView("Preparing a fresh address")
                    .font(.subheadline)
                    .padding()
            } else {
                Text("Spending address is unlocking — go back and try again.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
        .task {
            guard address == nil else { return }
            // Warmed on Wallet's appear - when it is there this screen draws immediately,
            // and the check below is a no-op re-confirmation rather than something the user
            // waits behind.
            if let warmed = ReceiveAddressWarmCache.address(for: walletManager.currentWallet?.publicAddress) {
                address = warmed
                resolving = false
            }
            // shown now: it goes on the Manage Addresses list (and is watched for payments)
            let resolved = await walletManager.freshReceiveAddress(revealing: true)
            // Only swap if the warmed answer went stale between warming and opening. A QR is
            // scanned the instant it appears, so it must not change under a pointed camera
            // for any lesser reason.
            if resolved != address { address = resolved }
            ReceiveAddressWarmCache.store(resolved, for: walletManager.currentWallet?.publicAddress)
            resolving = false
        }
    }
}


/// Your Domains, as a card on the Wallet tab (owner's call, 2026-11-19: it moved there from
/// Profile, beside the Chatting Address card, as KaPay has it). Only .kachat names since
/// 2026-11-23 (owner's call: every other name service is gone): the row counts the account's
/// names and opens them (`KachatLiveDomainsTab`: claim, renew, list, set as primary).
struct YourDomainsCard: View {
    var onToast: (String, ToastStyle) -> Void = { _, _ in }
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var kachatRegistry = KachatNamesRegistry.shared
    /// The account's .kachat names (in grace included, lapsed not). 0 where the registry isn't
    /// launched.
    @State private var kachatOwnedCount = 0

    var body: some View {
        if let walletAddress = walletManager.currentWallet?.publicAddress {
            NavigationLink {
                KachatLiveDomainsTab(walletAddress: walletAddress)
                    .navigationTitle("Your Usernames")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                HStack {
                    Label("Your Usernames", systemImage: "at")
                        .foregroundColor(.primary)
                    Spacer()
                    Text("\(kachatOwnedCount)")
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(glassBackground(cornerRadius: 18))
            // Reloads whenever the registry moves (a name bought, renewed or transferred lands).
            .task(id: "\(walletAddress)-\(kachatRegistry.revision)") {
                await loadKachatOwnedCount(walletAddress)
            }
        }
    }

    private func loadKachatOwnedCount(_ address: String) async {
        guard KachatNamesService.isLaunched, let key = KachatNamesRegistry.keyOf(address) else {
            kachatOwnedCount = 0
            return
        }
        await kachatRegistry.refreshIfStale(maxAge: 300)
        // the same names Your Domains lists: a lapsed one isn't yours any more
        guard let names = try? await kachatRegistry.heldNames(owner: key) else { return }
        kachatOwnedCount = names.count
        // and one that lapses while the Wallet tab is open comes off the count right then
        await kachatRegistry.dropLapsed(from: names) { kachatOwnedCount = $0.count }
    }
}

/// Share Profile: your Chatting Address's QR on white, the address, and Copy Share Link, which
/// puts your profile link (the one User Info > Share sends: it previews with your name and
/// avatar) on the clipboard and says so.
struct ShareProfileSheet: View {
    let address: String
    let shareURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: UIImage?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Group {
                        if let qrImage {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(width: 240, height: 240)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white))
                    .padding(.top, 8)

                    Text("Chatting Address")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)
                    Text(verbatim: address)
                        .font(.footnote.monospaced())
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)

                    Button {
                        UIPasteboard.general.string = shareURL.absoluteString
                        Haptics.success()
                        showToast(AppLocalization.string("Share link copied."))
                    } label: {
                        Label("Copy Share Link", systemImage: "link")
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle("Share Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .toast(message: toastMessage)
        }
        .presentationDetents([.large])
        .onAppear {
            qrImage = ProfileQRCodeCache.cachedImage(for: address)
            ProfileQRCodeCache.preload(address: address) { image in
                if let image { qrImage = image }
            }
        }
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) { toastMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) { toastMessage = nil }
            }
        }
    }
}

/// The Receive QR's address, decided ahead of the tap.
///
/// A plain box rather than state on a view: the value is warmed by the Profile screen and read
/// by the QR screen, which is presented by a NavigationLink and so has no chance to run anything
/// before its first frame. Process-lifetime only - it is a head start, never a source of truth,
/// and `freshReceiveAddress` re-confirms it on every open.
enum ReceiveAddressWarmCache {
    /// Kept with the account it was worked out for: another account, or the other network, must
    /// never open on this address.
    @MainActor private static var entry: (account: String, address: String)?

    @MainActor static func address(for account: String?) -> String? {
        guard let entry, entry.account == account else { return nil }
        return entry.address
    }

    @MainActor static func store(_ address: String?, for account: String?) {
        entry = address.flatMap { address in account.map { (account: $0, address: address) } }
    }
}

/// The teal name card, for any name service: the name, and an optional corner badge
/// ("Primary" on KNS, "Settling" on a `.kaspa` name still inside its settling window).
struct DomainNameCardView: View {
    let title: String
    var badge: String? = nil
    /// A small line in the bottom-right corner (Your Domains > .kachat: when it expires).
    var footnote: String? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.accentColor)
                .frame(height: 100)
                .overlay(
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 20)
                )

            if let badge {
                Text(badge)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.35)))
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let footnote {
                Text(verbatim: footnote)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.black.opacity(0.65))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
    }
}

/// Transaction history for the chatting (identity) address, reached from its dropdown in
/// Profile. Same pattern as ManageAddressesView's SpendingAddressTransactionHistoryView: tapping
/// a transaction opens it directly on whichever block explorer is selected in Settings >
/// Connection > Kaspa Explorer, rather than showing an in-app detail screen.
/// Full-featured detail screen for the wallet's own chatting/identity address — field-for-field
/// the same screen as ManageAddressesView's SpendingAddressTransactionHistoryView (balance,
/// Transaction History/UTXOs tabs, Compound UTXOs, Export private key, Explorer, Receive/Send),
/// just address-based instead of index-based. Reached from the Profile screen's Chatting Address
/// section's "Manage Address" row.
struct ChattingAddressManageView: View {
    let address: String

    /// The tapped transaction, while its action chooser is up.
    @State private var transactionActionTarget: KaspaFullTransactionResponse?

    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    private enum Tab: String, CaseIterable {
        case transactions = "History"
        case utxos = "UTXOs"
        case kachatDomains = "Domains"
    }

    @State private var selectedTab: Tab = .transactions
    @State private var transactions: [KaspaFullTransactionResponse] = []
    /// The last history fetch gave up partway. Kept separate from `transactions.isEmpty` because
    /// the two mean opposite things and used to render identically: a rate-limited request looked
    /// exactly like an address that has never been used.
    @State private var historyIncomplete = false
    @State private var isLoading = false
    @State private var utxos: [UTXO] = []
    @State private var isLoadingUtxos = false
    /// See `CoinControlView.loadError`.
    @State private var utxoLoadError: String?
    @State private var showReceiveSheet = false
    @State private var showSendSheet = false
    @State private var showCompoundSheet = false
    @State private var showPrivateKeySheet = false
    /// The "Address Actions" half sheet, and the public-key screen it can open.
    @State private var showAddressActions = false
    @State private var showPublicKeySheet = false
    /// What a row of that sheet opens next, run from its onDismiss: a sheet presented while
    /// another is still closing can be dropped by iOS.
    @State private var afterAddressActions: (() -> Void)?
    @State private var utxoLabels: [String: String] = [:]
    @State private var renamingUtxo: UTXO?
    @State private var renameUtxoText = ""

    /// The wallet's own balance for this address (Manage Addresses shows the same number), so the
    /// card and Send don't sit at 0 while the UTXOs load; the UTXOs' sum only when it isn't known.
    private var balanceSompi: UInt64 {
        if let wallet = WalletManager.shared.currentWallet, wallet.publicAddress == address,
           let balance = wallet.balanceSompi {
            return balance
        }
        return utxos.reduce(UInt64(0)) { $0 + $1.amount }
    }

    private func outpointKey(_ utxo: UTXO) -> String {
        "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)"
    }

    /// Plain names - History, UTXOs - the way the user asked for them.
    /// The .kachat page is called Usernames (owner, 2026-11-24), like the Wallet's card.
    private func tabLabel(_ tab: Tab) -> String {
        tab == .kachatDomains ? "Usernames" : tab.rawValue
    }

    var body: some View {
        VStack(spacing: 0) {
            KaspaAddressBalanceCard(label: AppLocalization.string("Chatting Address"), sompi: balanceSompi)

            // Right above what it switches, the way Chats has it.
            PageCycleBar(
                tabs: Tab.allCases.map { (tab: $0, title: tabLabel($0)) },
                selection: $selectedTab
            )

            switch selectedTab {
            case .transactions:
                transactionsList
            case .utxos:
                utxosList
            case .kachatDomains:
                AddressDomainsTab(address: address)
            }
        }
        .navigationTitle("Chatting Address")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                AddressOptionsButton { showAddressActions = true }
            }
        }
        .sheet(isPresented: $showAddressActions, onDismiss: {
            let next = afterAddressActions
            afterAddressActions = nil
            next?()
        }) {
            let sheet = AddressActionsSheet(
                explorerURL: settingsViewModel.settings.kaspaExplorer.addressURL(for: address),
                onViewPrivateKey: {
                    afterAddressActions = {
                        if settingsViewModel.settings.biometricSeedPhraseEnabled {
                            DeviceAuth.authenticate(reason: "Unlock to view this address's private key") {
                                showPrivateKeySheet = true
                            }
                        } else {
                            showPrivateKeySheet = true
                        }
                    }
                    showAddressActions = false
                },
                onViewPublicKey: {
                    afterAddressActions = { showPublicKeySheet = true }
                    showAddressActions = false
                },
                onViewInExplorer: { url in
                    showAddressActions = false
                    UIApplication.shared.open(url)
                }
            )
            sheet
                .presentationDetents([.height(sheet.height)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPublicKeySheet) {
            AddressPublicKeyView(address: address, note: "This is the public half of your chatting address. It identifies you and cannot spend anything.")
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    showReceiveSheet = true
                } label: {
                    Label("Receive", systemImage: "qrcode")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                Button {
                    showSendSheet = true
                } label: {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                .disabled(balanceSompi == 0)
                .opacity(balanceSompi == 0 ? 0.5 : 1)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .sheet(isPresented: $showReceiveSheet) {
            NavigationStack {
                ChattingAddressQRView(address: address, balanceSompi: balanceSompi)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Close") { showReceiveSheet = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showSendSheet) {
            WithdrawKaspaView(fromAddress: address, availableBalanceSompi: balanceSompi,
                              lockedSource: .chatting) {
                Task {
                    await loadTransactions()
                    await loadUtxos()
                }
            }
        }
        .sheet(isPresented: $showCompoundSheet) {
            WithdrawKaspaView(fromAddress: address, availableBalanceSompi: balanceSompi, isCompoundMode: true) {
                Task {
                    await loadTransactions()
                    await loadUtxos()
                }
            }
        }
        .sheet(isPresented: $showPrivateKeySheet) {
            ChattingAddressPrivateKeyView(address: address)
        }
        .alert(
            "Rename UTXO",
            isPresented: Binding(
                get: { renamingUtxo != nil },
                set: { if !$0 { renamingUtxo = nil } }
            )
        ) {
            TextField("Name", text: $renameUtxoText)
            Button("Save") {
                if let renamingUtxo {
                    WalletManager.shared.setSpendingUtxoLabel(address: address, outpointKey: outpointKey(renamingUtxo), label: renameUtxoText)
                    utxoLabels = WalletManager.shared.loadSpendingUtxoLabels(address: address)
                }
                renamingUtxo = nil
            }
            Button("Cancel", role: .cancel) {
                renamingUtxo = nil
            }
        }
        .task {
            utxoLabels = WalletManager.shared.loadSpendingUtxoLabels(address: address)
            await loadTransactions()
            await loadUtxos()
        }
    }

    private var transactionsList: some View {
        List {
            if isLoading && transactions.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if transactions.isEmpty && historyIncomplete {
                // A failed fetch is not an empty history. Saying "No transactions yet." here was
                // a confident answer about someone's money that the app had not actually got.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Could not load transactions.")
                        .foregroundColor(.secondary)
                    Button("Try Again") {
                        Task { await loadTransactions() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            } else if transactions.isEmpty {
                Text("No transactions yet.")
                    .foregroundColor(.secondary)
            } else {
                if historyIncomplete {
                    // Some pages landed, some did not. Say so rather than letting a truncated
                    // list read as the whole history.
                    Text("Some transactions could not be loaded. Pull to refresh to try again.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                ForEach(transactions, id: \.transactionId) { tx in
                    Button {
                        Haptics.impact(.light)
                        // Tapping a transaction asks what to do with it.
                        transactionActionTarget = tx
                    } label: {
                        transactionRow(tx)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        // The menu is a sheet rather than a confirmation dialog so each option can say what it
        // does, and so the transaction it applies to stays on screen while you choose.
        .sheet(item: $transactionActionTarget) { tx in
            TransactionActionsSheet(
                transaction: tx,
                address: address,
                onOpenExplorer: { openInExplorer(tx) }
            )
        }
        .refreshable {
            await loadTransactions()
        }
    }

    private var utxosList: some View {
        List {
            if utxos.count > 1 {
                Section {
                    Button {
                        showCompoundSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.merge")
                            Text("Compound UTXOs")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                } footer: {
                    Text("Combines all UTXOs at this address into a single one, to reduce the number of inputs a future send needs.")
                }
            }
            if isLoadingUtxos && utxos.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if utxos.isEmpty {
                if let utxoLoadError {
                    UtxoLoadFailureRow(detail: utxoLoadError) {
                        Task { await loadUtxos() }
                    }
                } else {
                    Text("No UTXOs.")
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(Array(utxos.enumerated()), id: \.offset) { _, utxo in
                    utxoRow(utxo)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await loadUtxos()
        }
    }

    private func utxoRow(_ utxo: UTXO) -> some View {
        HStack(spacing: 12) {
            Image(systemName: utxo.isCoinbase ? "cube.fill" : "circle.grid.2x2.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if let label = utxoLabels[outpointKey(utxo)], !label.isEmpty {
                    Text(label)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                }
                Text(verbatim: "\(formatKasExact(utxo.amount)) \(KaspaUnit.symbol)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("\(utxo.outpoint.transactionId):\(utxo.outpoint.index)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if utxo.isCoinbase {
                Text("Coinbase")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }
            Button {
                renameUtxoText = utxoLabels[outpointKey(utxo)] ?? ""
                renamingUtxo = utxo
            } label: {
                Image(systemName: "pencil")
                    .foregroundColor(.accentColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func loadUtxos() async {
        isLoadingUtxos = true
        do {
            utxos = try await NodePoolService.shared.getUtxosByAddresses([address])
            utxoLoadError = nil
        } catch {
            // The list keeps what it had; an outage is not an empty address.
            utxoLoadError = UserFacingError.message(for: error)
        }
        isLoadingUtxos = false
    }

    private func transactionRow(_ tx: KaspaFullTransactionResponse) -> some View {
        var info = tx.direction(for: address)
        // As Manage Addresses' history (owner, 2026-11-22): Sent counts what went to other
        // people, each of this wallet's other addresses that got change has its own line, and
        // all of it to our own addresses is Moved.
        var toOthers: UInt64 = 0
        var change: [(label: String, sompi: UInt64)] = []
        if info?.isOutgoing == true {
            let this = address.lowercased()
            for output in tx.outputs {
                guard let to = output.scriptPublicKeyAddress?.lowercased(), !to.isEmpty, to != this else { continue }
                if let label = WalletManager.shared.ownAddressLabel(for: to) {
                    if let index = change.firstIndex(where: { $0.label == label }) {
                        change[index].sompi += output.amount
                    } else {
                        change.append((label, output.amount))
                    }
                } else {
                    toOthers += output.amount
                }
            }
        }
        let changeTotal = change.reduce(UInt64(0)) { $0 + $1.sompi }
        let moved = info?.isOutgoing == true && toOthers == 0 && changeTotal > 0
        if info?.isOutgoing == true {
            info!.amountSompi = moved ? changeTotal : toOthers
        }
        return HStack(spacing: 12) {
            Image(systemName: info?.isOutgoing == true ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundColor(info == nil ? .secondary : (info!.isOutgoing ? .red : .green))

            VStack(alignment: .leading, spacing: 2) {
                Text(info == nil ? "Transaction" : (info!.isOutgoing ? (moved ? "Moved" : "Sent") : "Received"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(info == nil ? .secondary : (info!.isOutgoing ? .red : .green))
                ForEach(Array(change.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: moved
                         ? String(format: AppLocalization.string("To %@"), line.label)
                         : String(format: AppLocalization.string("Change %@ to %@"),
                                  "\(formatKasExact(line.sompi)) \(KaspaUnit.symbol)", line.label))
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(tx.transactionId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let blockTime = tx.blockTime {
                    Text(Date(timeIntervalSince1970: Double(blockTime) / 1000).formatted(Self.blockTimeFormat))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let info {
                    Text(verbatim: "\(info.isOutgoing ? "-" : "+")\(formatKasExact(info.amountSompi)) \(KaspaUnit.symbol)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(info.isOutgoing ? .red : .green)
                }
                // The network fee this transaction paid (inputs minus outputs).
                if let fee = tx.feeText() {
                    Text(fee)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    /// Built once: `Date.formatted(date:time:)` resolves a fresh style per call, and this runs
    /// for every transaction row on every render of the list.
    private static let blockTimeFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)

    private func loadTransactions() async {
        isLoading = true
        // Confirmed live against api.kaspa.org that limit=500 works fine in a single call
        // (~0.7s) - cuts this from up to 4 sequential round trips down to 1.
        let result = await chatService.fetchFullTransactionsResult(for: address, pageSize: 200, maxTransactions: 200)
        // block rewards the chain never accepted paid nothing: not history
        transactions = result.transactions.filter(\.belongsInHistory)
        historyIncomplete = !result.complete
        isLoading = false
    }

    private func openInExplorer(_ tx: KaspaFullTransactionResponse) {
        guard let url = settingsViewModel.settings.kaspaExplorer.txURL(for: tx.transactionId) else { return }
        UIApplication.shared.open(url)
    }
}

/// Private-key reveal for the wallet's own chatting/identity address — mirrors
/// SpendingAddressPrivateKeyView, but reads the wallet's own root private key rather than a
/// derived spending key, since the identity address isn't part of the spending-chain derivation.
/// Gated by `biometricSeedPhraseEnabled` (not `biometricSpendingKeyEnabled`) since this is the
/// wallet's primary key, matching the same higher-stakes gate as Settings > Back Up Account.
private struct ChattingAddressPrivateKeyView: View {
    let address: String
    @Environment(\.dismiss) private var dismiss

    @State private var isRevealed = false
    @State private var revealToken = UUID()
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    private var privateKeyHex: String {
        WalletManager.shared.getPrivateKey()?.hexString ?? "Unavailable"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Security Warning", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundColor(.orange)
                    Text("Anyone with this address's private key can spend its funds. Never share it with anyone.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if isRevealed {
                    SecureView {
                        Text(privateKeyHex)
                            .font(.system(.footnote, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        copySensitiveToClipboard(privateKeyHex)
                        Haptics.success()
                        showToast("Private key copied. Clipboard will clear in 30s.")
                    } label: {
                        Label("Copy Private Key Hex", systemImage: "doc.on.doc")
                    }
                    .padding(.top)
                } else {
                    Button {
                        isRevealed = true
                        let token = UUID()
                        revealToken = token
                        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                            if revealToken == token {
                                isRevealed = false
                            }
                        }
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "eye.slash.fill")
                                .font(.largeTitle)
                            Text("Tap to reveal private key")
                                .font(.subheadline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(60)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Chatting Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .toast(message: toastMessage)
        }
    }

    /// Sensitive copy: hard 30s system expiration + localOnly (no Universal Clipboard sync);
    /// the asyncAfter wipe is an in-app belt-and-suspenders clear (see SettingsView's twin).
    private func copySensitiveToClipboard(_ value: String) {
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)]
        )
        let copiedValue = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if UIPasteboard.general.string == copiedValue {
                UIPasteboard.general.string = ""
            }
        }
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}

/// An address's public key, from the Address Actions sheet.
///
/// Nothing is derived or unlocked to show this: a Kaspa P2PK address IS its public key in bech32,
/// so this decodes the address the screen already has. No reveal gate and no clipboard expiry
/// either - unlike the private key alongside it, this is a value you hand out on purpose.
struct AddressPublicKeyView: View {
    let address: String
    let note: LocalizedStringKey
    @Environment(\.dismiss) private var dismiss

    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    /// nil only for an address shape that carries no key (script-hash), which the wallet's own
    /// chatting address never is.
    private var publicKeyHex: String? {
        KaspaAddress.publicKey(from: address)?.hexString
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Safe to share", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                    Text(note)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if let publicKeyHex {
                    Text(publicKeyHex)
                        .font(.system(.footnote, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Button {
                        UIPasteboard.general.string = publicKeyHex
                        Haptics.success()
                        showToast("Public key copied")
                    } label: {
                        Label("Copy Public Key", systemImage: "doc.on.doc")
                    }
                } else {
                    Text("This address does not carry a public key.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Public Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .toast(message: toastMessage)
        }
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}

/// The Chatting Address's receive page, on the shared receive screen (`AddressReceiveView`,
/// owner's design 2026-11-19, as in KaPay): its QR on white, the note that it shows your .kachat
/// name, what may be sent there, and what it's for. A tap anywhere copies it.
struct ChattingAddressQRView: View {
    let address: String
    let balanceSompi: UInt64?
    var showsBalance = true
    var subtitle: String = "Use for chatting and acquiring usernames."

    var body: some View {
        AddressReceiveView(
            title: AppLocalization.string("Chatting Address"),
            address: address,
            balanceLine: showsBalance ? balanceSompi.map(KaspaUnit.groupedAmount) : nil,
            privacyNote: ReceiveNotes.chattingAddress,
            notes: [
                ReceiveNotes.kaspaAndKusdt,
                // Looked up, not shown verbatim - it read English in every language.
                ReceiveNote(kind: .info, text: AppLocalization.string(subtitle)),
            ],
            icon: { KaspaLogoIcon() }
        )
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Fee-priority tiers for the Withdraw Kaspa flow — each tier is a multiplier applied to the
/// already-estimated base (Normal) fee, letting the user pay extra during network congestion
/// without a second network round-trip per tier.
enum WithdrawFeeTier: String, CaseIterable, Identifiable, Hashable {
    case normal = "Normal"
    case fast = "Fast"
    case priority = "Priority"

    var id: String { rawValue }

    var multiplier: UInt64 {
        switch self {
        case .normal: return 1
        case .fast: return 2
        case .priority: return 5
        }
    }
}

/// Custom success card replacing a plain alert so the transaction id can be a real tappable
/// link (native SwiftUI alerts can't embed interactive text in their message) - shared by every
/// "you just sent Kaspa" flow (chatting-address withdraw, Manage Addresses' per-address send).
/// Sends a plain KAS transfer from the wallet's chatting (identity) address to an arbitrary
/// recipient address. Reuses AddContactView's address-entry conventions (paste/QR scan,
/// live validation) but with an amount field instead of a contact-name field, since this
/// isn't creating a contact.
struct WithdrawKaspaView: View {
    let fromAddress: String
    let availableBalanceSompi: UInt64?
    /// Pre-fills the recipient with `fromAddress` itself (a self-send) and auto-fills Max, for
    /// the "Compound UTXOs" entry point - merges every UTXO at this address into one. Locks the
    /// recipient field instead of just pre-filling it, matching SpendingAddressWithdrawView's
    /// identical Compound UTXOs behavior.
    var isCompoundMode: Bool = false
    /// Pre-fills the recipient (Address Book > Send KAS); it stays editable.
    var prefillAddress: String? = nil
    /// Someone's payment request (a tapped or pasted link): its address is locked in, its amount
    /// and memo filled in. A request pasted into the recipient field does the same.
    var paymentRequest: PaymentRequest? = nil
    /// Opened from one address's history (its Send button): the Kaspa leaves from that address
    /// and the From section offers no other.
    var lockedSource: SendSource? = nil
    var onComplete: (() -> Void)? = nil

    /// The request this send pays, if any (`paymentRequest`, or one pasted in).
    @State private var activeRequest: PaymentRequest?
    /// Where the Kaspa leaves from (the From section): the chatting address by default.
    @State private var source: SendSource = .chatting
    /// The From address's balance, loaded by the From step.
    @State private var sourceBalanceSompi: UInt64?

    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var priceModel = KasPriceModel.shared
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    @State private var addressInput = ""
    @State private var isValidAddress = false
    @State private var amountInput = ""
    @State private var showQRScanner = false
    @State private var isSending = false
    @State private var errorMessage: String?
    /// The completed send, driving the sent-confirmation half sheet.
    @State private var sentTransaction: SentTransaction?

    @State private var isResolvingKNS = false
    @State private var resolvedAddress: String?
    @State private var resolvedDomain: String?
    /// Every service's answer for a typed name and the one in use: the rest go under "Other domains".
    @State private var nameResolutions: [NameResolution] = []
    @State private var selectedTLD: NameServiceTLD?
    @State private var knsError: String?

    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var normalFeeSompi: UInt64?
    /// The fee this exact send pays at the chosen speed (network fee, extra and any change too
    /// small to keep), from an estimate made with that extra; nil until it is known.
    @State private var builtFeeSompi: UInt64?
    @State private var isEstimatingFee = false
    @State private var isEstimatingMax = false
    /// The Max on screen is what one transaction can carry, not the whole balance (the address
    /// holds more coins than one transaction can spend).
    @State private var maxCapped = false
    /// The latest Max request: an older one finishing later (a speed tapped twice fast) is dropped.
    @State private var maxRequest = UUID()
    @State private var customExtraFeeSompi: UInt64?
    @State private var isEditingFee = false
    @State private var customFeeText = ""

    @State private var manualUtxos: [UTXO]?
    @State private var showCoinControl = false

    /// The step on screen; nil until the first move (then `initialStep`).
    @State private var step: Step?
    /// The last move went forward: the next step comes in from the right.
    @State private var stepForward = true
    /// The amount is Max: a fee or coin change works it out again.
    @State private var usedMax = false
    /// The From step's Choose an Address is on (its list shows), before or after a pick.
    @State private var choosingFrom = false
    /// Why the fee couldn't be worked out (usually: not enough Kaspa for the amount and fee).
    @State private var feeError: String?
    /// The fee being typed on the fee screen, in KAS.
    @State private var feeDraft = ""


    /// The actual address to use (resolved from a KNS domain, or the direct input).
    private var effectiveAddress: String {
        resolvedAddress ?? addressInput
    }

    private var amountSompi: UInt64? {
        guard let sompi = KaspaUnit.sompi(fromUserText: amountInput), sompi > 0 else { return nil }
        return sompi
    }

    /// True once we have a usable recipient — either a resolved KNS domain or a directly
    /// valid Kaspa address (mirrors AddContactView.canAdd's precedence).
    private var hasValidRecipient: Bool {
        if resolvedAddress != nil { return true }
        return isValidAddress && !isResolvingKNS
    }

    /// The swipe waits for the amount and the fee it shows to be the ones that will be sent: not
    /// while Max or the fee is being worked out again, and not when the fee couldn't be.
    private var canSend: Bool {
        hasValidRecipient && amountSompi != nil && !isSending
            && !isEstimatingMax && !isEstimatingFee && feeError == nil && totalFeeSompi != nil
    }

    /// Extra priority tip on top of the base (Normal-tier) fee, for network congestion.
    /// A manually-entered custom fee (tapped on the Network Fee row) overrides the tier
    /// multiplier until a tier is tapped again.
    private var extraFeeSompi: UInt64 {
        guard let normalFeeSompi else { return 0 }
        if let customExtraFeeSompi { return customExtraFeeSompi }
        return normalFeeSompi * (feeTier.multiplier - 1)
    }

    private var totalFeeSompi: UInt64? {
        guard normalFeeSompi != nil else { return nil }
        return builtFeeSompi
    }

    /// Debounce/cancellation key. The speed and a custom fee are in it: a bigger extra can make the
    /// send take another coin, or no longer leave change worth keeping, so the fee shown is worked
    /// out with the extra actually paid rather than added on top of the Normal estimate.
    /// Bumped when a send stopped because its fee went up: the Review works the fee out again.
    @State private var feeRefresh = 0

    private var feeEstimationKey: String {
        let manualKey = manualUtxos?.map { "\($0.outpoint.transactionId):\($0.outpoint.index)" }.sorted().joined(separator: ",") ?? ""
        return "\(hasValidRecipient ? effectiveAddress : "")|\(amountSompi ?? 0)|\(manualKey)|\(source.spendingIndex ?? -1)|\(feeTier.rawValue)|\(customExtraFeeSompi.map { String($0) } ?? "")|\(feeRefresh)"
    }

    /// The three steps of a send: who it goes to, how much (on the app's own keypad, so no
    /// keyboard stays up), and a review where only the fee and coin control can change before
    /// swiping up to send.
    private enum Step: Int { case recipient, from, amount, review, fee }

    /// The step a send opens on: Compound UTXOs straight to the review (its recipient and amount
    /// are set), a payment request or a pre-filled recipient to From (or the amount, when From
    /// is fixed).
    private var initialStep: Step {
        if isCompoundMode { return .review }
        if paymentRequest != nil || prefillAddress != nil { return afterRecipient }
        return .recipient
    }

    /// The step after To: From, unless the send's From is fixed (an address's own Send).
    private var afterRecipient: Step { lockedSource == nil ? .from : .amount }

    private var currentStep: Step { step ?? initialStep }

    private var screenTitle: String {
        isCompoundMode ? "Compound UTXOs" : (activeRequest != nil ? "Payment Request" : "Send Kaspa")
    }

    /// Where Back goes from a step; nil for the first one. A payment request opened from a link
    /// has no recipient step (its address is fixed).
    private func backStep(from step: Step) -> Step? {
        switch step {
        case .recipient: return nil
        case .from: return paymentRequest != nil ? nil : .recipient
        case .amount:
            if lockedSource == nil { return .from }
            return (isCompoundMode || paymentRequest != nil) ? nil : .recipient
        case .review: return isCompoundMode ? nil : .amount
        case .fee: return .review
        }
    }

    private func go(to next: Step) {
        dismissSystemKeyboard()
        if next == .recipient, activeRequest != nil, paymentRequest == nil {
            // back from a pasted request: start the recipient over
            activeRequest = nil
            addressInput = ""
            amountInput = ""
            fiatAmountState.reset()
            usedMax = false
        }
        stepForward = next.rawValue > currentStep.rawValue
        // The leaving step re-renders with the new direction before it animates out.
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { step = next }
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: stepForward ? .trailing : .leading),
                    removal: .move(edge: stepForward ? .leading : .trailing))
    }

    /// The amount is more than the From address holds.
    private var exceedsBalance: Bool {
        guard let amountSompi, let sourceBalanceSompi else { return false }
        return amountSompi > sourceBalanceSompi
    }

    private var canContinueFromAmount: Bool {
        hasValidRecipient && amountSompi != nil && !exceedsBalance && !isEstimatingMax
    }

    var body: some View {
        NavigationStack {
            ZStack {
                switch currentStep {
                case .recipient:
                    recipientStep.transition(stepTransition)
                case .from:
                    fromStep.transition(stepTransition)
                case .amount:
                    amountStep.transition(stepTransition)
                case .review:
                    reviewStep.transition(stepTransition)
                case .fee:
                    feeStep.transition(stepTransition)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // The recipient card only shows the lookup; this screen runs it.
            .onChange(of: addressInput) { handleInputChange($0) }
            // coins picked on one address can't pay from another
            .onChange(of: source) { _ in
                manualUtxos = nil
                if usedMax { setMaxAmount() }
            }
            // the From address's balance: the amount's Available and its check
            .task(id: source) {
                sourceBalanceSompi = nil
                guard let address = source.address else { return }
                // A failed read says nothing about the balance: left unknown, not shown as 0.
                let utxos = try? await NodePoolService.shared.getUtxosByAddresses([address])
                guard !Task.isCancelled, let utxos else { return }
                sourceBalanceSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
            }
            .onChange(of: feeTier) { _ in
                customExtraFeeSompi = nil
                isEditingFee = false
                if usedMax { setMaxAmount() }
            }
            .onChange(of: customExtraFeeSompi) { _ in
                if usedMax { setMaxAmount() }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { code in
                    handleScannedQRCode(code)
                }
            }
            .sheet(isPresented: $showCoinControl) {
                CoinControlView(fromAddress: isCompoundMode ? fromAddress : (source.address ?? fromAddress), initialSelection: manualUtxos) { selection in
                    manualUtxos = selection
                    if usedMax { setMaxAmount() }
                }
            }
            // The confirmation is the swipe-up's own full screen (SwipeUpToSendScrollView).
            .task(id: feeEstimationKey) {
                guard hasValidRecipient, let amountSompi else {
                    normalFeeSompi = nil
                    builtFeeSompi = nil
                    feeError = nil
                    isEstimatingFee = false
                    return
                }
                isEstimatingFee = true
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                let index = source.spendingIndex
                let recipient = effectiveAddress
                let coins = manualUtxos
                let request = activeRequest
                func estimate(extra: UInt64) async throws -> SendFeeEstimate {
                    // A request to a chatting address goes out as a chat payment (see `send`),
                    // its memo encrypted inside: priced as that, not as a plain transfer.
                    if let request, request.toChattingAddress, request.address.lowercased() == recipient.lowercased() {
                        let contact = await contactsManager.getContact(byAddress: recipient) ?? Contact(address: recipient)
                        return try await chatService.estimatePaymentFee(to: contact, amountSompi: amountSompi, note: request.memo, sourceSpendingIndex: index, manualUtxos: coins, extraFeeSompi: extra)
                    }
                    if let index {
                        return try await chatService.estimateSpendingAddressWithdrawalFee(index: index, toAddress: recipient, amountSompi: amountSompi, manualUtxos: coins, extraFeeSompi: extra)
                    }
                    return try await chatService.estimateWithdrawalFee(toAddress: recipient, amountSompi: amountSompi, manualUtxos: coins, extraFeeSompi: extra)
                }
                do {
                    // The Normal fee is the base the speeds multiply (and the editor's minimum).
                    let base = try await estimate(extra: 0)
                    guard !Task.isCancelled else { return }
                    let extra = customExtraFeeSompi ?? base.networkFee * (feeTier.multiplier - 1)
                    // With the extra in, the estimate builds the same shape the send will: its
                    // network fee already holds the extra, and change too small to keep goes on top.
                    var paid = base
                    if extra > 0 { paid = try await estimate(extra: extra) }
                    guard !Task.isCancelled else { return }
                    normalFeeSompi = base.networkFee
                    builtFeeSompi = paid.networkFee + paid.foldedChange
                    feeError = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    normalFeeSompi = nil
                    builtFeeSompi = nil
                    feeError = UserFacingError.message(for: error)
                }
                isEstimatingFee = false
            }
            .task {
                if let lockedSource, source != lockedSource {
                    source = lockedSource
                }
                if isCompoundMode {
                    addressInput = fromAddress
                    isValidAddress = true
                    setMaxAmount()
                } else if let paymentRequest, activeRequest == nil {
                    apply(paymentRequest)
                } else if let prefillAddress, addressInput.isEmpty {
                    addressInput = prefillAddress
                }
            }
        }
        .sendKaspaSheetSizing()
        .interactiveDismissDisabled()
    }

    // MARK: Step 1 - To

    private var recipientStep: some View {
        SendStepScreen(title: Text(LocalizedStringKey(screenTitle)), onCancel: { dismiss() },
                       canContinue: hasValidRecipient) {
            go(to: afterRecipient)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SendStepQuestion(text: "Who are you sending to?")
                    SendRecipientCard(
                        input: $addressInput,
                        isResolving: isResolvingKNS,
                        resolvedAddress: resolvedAddress,
                        resolvedName: resolvedDomain,
                        lookupError: knsError,
                        isValidAddress: isValidAddress,
                        onScan: { showQRScanner = true },
                        nameResolutions: nameResolutions,
                        selectedTLD: selectedTLD,
                        onSelectResolution: selectResolution,
                        focusOnAppear: true
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: Step 3 - Amount

    private var amountStep: some View {
        SendStepScreen(title: Text(LocalizedStringKey(screenTitle)),
                       onBack: backStep(from: .amount).map { back in { go(to: back) } },
                       onCancel: { dismiss() }, continueTitle: "Review",
                       canContinue: canContinueFromAmount) {
            go(to: .review)
        } content: {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    recipientChip
                    fromChip
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)

                if let activeRequest {
                    // A request's amount is fixed: no keypad, the request itself instead.
                    ScrollView {
                        VStack(spacing: 18) {
                            reviewAmount
                            PaymentRequestSummary(request: activeRequest)
                            if exceedsBalance {
                                Text("This is more than the address you're sending from holds.")
                                    .font(.footnote)
                                    .foregroundColor(.red)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                    }
                } else {
                    KaspaKeypadAmountEntry(
                        fiatAmountState: fiatAmountState,
                        onAmountChange: { amountInput = $0 },
                        isEstimatingMax: isEstimatingMax,
                        maxEnabled: hasValidRecipient,
                        footnote: amountFootnote,
                        footnoteIsError: exceedsBalance || errorMessage != nil,
                        onMax: setMaxAmount,
                        onKeyTyped: {
                            usedMax = false
                            maxCapped = false
                            errorMessage = nil
                        }
                    )
                }
            }
        }
    }

    /// Under the typed amount: what's wrong with it, else what's available.
    private var amountFootnote: String? {
        if let errorMessage { return errorMessage }
        if exceedsBalance { return AppLocalization.string("This is more than the address you're sending from holds.") }
        if usedMax && maxCapped { return maxCappedNote }
        guard let sourceBalanceSompi else { return nil }
        return KaspaUnit.label(String(format: AppLocalization.string("Available: %@ KAS"), locale: AppLocalization.locale, formatKasTrimmed(sourceBalanceSompi)))
    }

    /// Why Max isn't the whole balance: one transaction spends at most
    /// `maxInputsPerTransaction` coins, and this address holds more.
    private var maxCappedNote: String {
        let limit = KasiaTransactionBuilder.maxInputsPerTransaction
        if isCompoundMode {
            return String(format: AppLocalization.string("One transaction can combine %d coins, so this combines the largest %d. Compound again for the rest."),
                          locale: AppLocalization.locale, limit, limit)
        }
        return String(format: AppLocalization.string("Max is what one transaction can carry: its largest %d coins. Compound UTXOs combines the rest."),
                      locale: AppLocalization.locale, limit)
    }

    // MARK: Step 2 - From

    /// "Where are you sending from?": the Chatting Address, or Choose an Address with your
    /// addresses listed right here (no sheet).
    private var fromStep: some View {
        SendStepScreen(title: Text(LocalizedStringKey(screenTitle)),
                       onBack: backStep(from: .from).map { back in { go(to: back) } },
                       onCancel: { dismiss() },
                       canContinue: !(choosingFrom && source == .chatting)) {
            go(to: .amount)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SendStepQuestion(text: "Where are you sending from?")
                    HStack(spacing: 10) {
                        SelectablePill(title: "Chatting Address", selected: !choosingFrom) {
                            choosingFrom = false
                            source = .chatting
                        }
                        SelectablePill(title: "Choose an Address", selected: choosingFrom) {
                            choosingFrom = true
                        }
                    }
                    if choosingFrom {
                        Text("Pick which of your addresses the Kaspa leaves from.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        OwnAddressList(selected: source == .chatting ? nil : source.address) { picked in
                            source = picked
                            // the chatting address picked from the list: back on its own pill
                            if picked == .chatting { choosingFrom = false }
                        }
                    } else if let address = source.address {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Chatting Address")
                                    .font(.subheadline.weight(.semibold))
                                Text(verbatim: "\(address.prefix(14))...\(address.suffix(6))")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if let sourceBalanceSompi {
                                Text(verbatim: "\(KaspaUnit.plain(sourceBalanceSompi)) \(KaspaUnit.symbol)")
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                            } else {
                                ProgressView().controlSize(.small)
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
    }

    /// "From Chatting Address" (or the picked address), on the amount step.
    private var fromChip: some View {
        SendStepChip(label: "From", value: sourceTitle)
    }

    /// "To alice.kachat" (or the address), so the amount step says where it is going.
    private var recipientChip: some View {
        SendStepChip(label: "To", value: recipientName ?? effectiveAddress, isAddress: recipientName == nil)
    }

    /// The recipient's name: the domain it resolved from, else its Address Book name.
    private var recipientName: String? {
        resolvedDomain ?? AddressBookManager.shared.entry(for: effectiveAddress)?.customName
    }

    // MARK: Step 4 - Review

    private var reviewStep: some View {
        SwipeUpToSendScrollView(
            screenTitle: isCompoundMode ? "Compound UTXOs" : "Review",
            onCancel: { dismiss() },
            onBack: backStep(from: .review).map { back in { go(to: back) } },
            title: isCompoundMode ? "Swipe up to Consolidate" : "Swipe up to Send",
            isBusy: isSending,
            isEnabled: canSend,
            amountSompi: amountSompi,
            recipient: isCompoundMode ? nil : (resolvedDomain ?? effectiveAddress),
            sent: sentTransaction,
            failureMessage: errorMessage,
            onDone: {
                sentTransaction = nil
                dismiss()
                onComplete?()
            },
            action: send
        ) {
            VStack(spacing: 18) {
                reviewAmount
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 14) {
                    reviewRow("To") {
                        if isCompoundMode {
                            Text("This address (consolidating)")
                        } else {
                            VStack(alignment: .trailing, spacing: 2) {
                                if let name = recipientName {
                                    Text(verbatim: name).fontWeight(.semibold)
                                }
                                Text(verbatim: effectiveAddress)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    Divider()
                    reviewRow("From") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(verbatim: sourceTitle).fontWeight(.semibold)
                            if let address = isCompoundMode ? fromAddress : source.address {
                                Text(verbatim: "\(address.prefix(14))...\(address.suffix(6))")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Divider()
                    reviewRow("Total") {
                        if let amountSompi, let totalFeeSompi {
                            Text(verbatim: "\(formatKasTrimmed(amountSompi + totalFeeSompi)) \(KaspaUnit.symbol)")
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        } else if isEstimatingFee || isEstimatingMax {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(verbatim: "—").foregroundColor(.secondary)
                        }
                    }
                }
                .font(.subheadline)
                .padding(14)
                .background(sendKaspaGlass(cornerRadius: 20))

                if let activeRequest {
                    PaymentRequestSummary(request: activeRequest)
                }

                // The only things that can still change: the fee and the coins it spends.
                SendFeeControls(
                    feeTier: $feeTier,
                    isEditingFee: $isEditingFee,
                    customFeeText: $customFeeText,
                    isEstimatingFee: isEstimatingFee,
                    feeText: totalFeeSompi.map { "\(formatKasTrimmed($0)) \(KaspaUnit.symbol)" },
                    onStartEditing: startEditingFee,
                    onCommit: commitCustomFee,
                    coinControlSummary: coinControlSummary(manualUtxos),
                    onCoinControl: { showCoinControl = true },
                    onEditFee: openFeeEditor
                )

                if let message = errorMessage ?? feeError {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                    // A failed estimate holds the swipe: never for good.
                    if errorMessage == nil {
                        Button("Try Again") { feeRefresh += 1 }
                            .font(.footnote.weight(.semibold))
                    }
                } else if usedMax && maxCapped {
                    Text(maxCappedNote)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Network fee (from the review)

    /// The fee editor: the whole fee typed on the keypad, Confirm back to the review.
    private var feeStep: some View {
        SendFeeEditorScreen(draft: $feeDraft, minimumSompi: normalFeeSompi,
                            onCancel: { go(to: .review) }) { typed in
            // never under the network's minimum
            guard let normalFeeSompi else { return }
            customExtraFeeSompi = typed > normalFeeSompi ? typed - normalFeeSompi : 0
            go(to: .review)
        }
    }

    private func openFeeEditor() {
        guard let totalFeeSompi else { return }
        feeDraft = formatKasTrimmed(totalFeeSompi)
        go(to: .fee)
    }

    /// The amount being sent, big, with its value in your currency under it.
    private var reviewAmount: some View {
        VStack(spacing: 6) {
            Text(isCompoundMode ? "Consolidating" : "You're sending")
                .font(.subheadline)
                .foregroundColor(.secondary)
            if let amountSompi {
                Text(verbatim: "\(formatKasTrimmed(amountSompi)) \(KaspaUnit.symbol)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let price = priceModel.currentPriceUsd, price > 0 {
                    Text(verbatim: formatFiatAmount(Double(amountSompi) / 100_000_000.0 * price,
                                                    currency: priceModel.currentCurrency))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                ProgressView()
                    .frame(height: 48)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func reviewRow<Value: View>(_ label: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            value()
                .multilineTextAlignment(.trailing)
        }
    }

    private var sourceTitle: String {
        if isCompoundMode { return AppLocalization.string("This address") }
        switch source {
        case .chatting: return AppLocalization.string("Chatting Address")
        case .spending(_, _, let label): return label
        }
    }

    private func handleInputChange(_ input: String) {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // An all-uppercase address (a compact QR code's "KASPA:QR...") is the same address in
        // lowercase: shown and used that way. The field's change runs this again, as a no-op.
        let trimmed = KaspaAddress.hasAddressPrefix(raw) ? KaspaAddress.normalizedCase(raw) : raw
        if trimmed != raw { addressInput = trimmed }

        resolvedAddress = nil
        resolvedDomain = nil
        knsError = nil
        isResolvingKNS = false
        nameResolutions = []
        selectedTLD = nil

        guard !trimmed.isEmpty else {
            isValidAddress = false
            return
        }

        // A payment request pasted in fills in everything it carries: only when the paste is the
        // link and nothing else, never one found inside some longer text.
        if !isCompoundMode, let match = KaChatInternalLink.match(in: trimmed), match.coversWholeMessage,
           case .paymentRequest(let request) = match.link {
            apply(request)
            if currentStep == .recipient { go(to: afterRecipient) }
            return
        }

        if KaspaAddress.hasAddressPrefix(trimmed) {
            // the other network's address is the same key on another chain: refused
            isValidAddress = KaspaAddress.isValidOnActiveNetwork(trimmed)
            return
        }

        if NameServicesClient.looksLikeName(trimmed) {
            isValidAddress = false
            resolveKNSDomain(trimmed)
        } else {
            isValidAddress = false
        }
    }

    /// Fills in a payment request: the address (locked), the exact amount and the memo.
    private func apply(_ request: PaymentRequest) {
        activeRequest = request
        // The request's amount is the amount: a Max from before it, or one still being worked
        // out, must not replace it when the speed, From or coins change.
        usedMax = false
        maxCapped = false
        maxRequest = UUID()
        isEstimatingMax = false
        addressInput = request.address
        isValidAddress = KaspaAddress.isValidOnActiveNetwork(request.address)
        // the exact amount is what's sent; the field shows it in whichever unit it is in
        amountInput = request.amountText
        _ = fiatAmountState.setMaxSompi(request.amountSompi, priceInCurrency: priceModel.currentPriceUsd)
    }

    /// Use one service's answer (the priority one, or a pick from "Other domains").
    private func selectResolution(_ resolution: NameResolution) {
        // A name service's answer must be a valid address on this network (NameResolution drops
        // others too; checked again here, where it becomes the address used).
        guard let address = resolution.address, KaspaAddress.isValidOnActiveNetwork(address) else { return }
        resolvedAddress = address
        resolvedDomain = resolution.display
        selectedTLD = resolution.tld
        knsError = nil
    }

    private func resolveKNSDomain(_ domain: String) {
        isResolvingKNS = true

        // On the main actor: the check below must read the field as it is now. Read from a
        // background task while typing fast, it could see an older value, take this lookup for a
        // stale one and stop - leaving "Looking up domain..." up for good.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)

            guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == domain else {
                return
            }

            // Every name service, in priority: the ending typed, else .kachat only (the others wait under Other domains)
            // (see NameServicesClient). The resolved line names which one answered; the others
            // are offered under "Other domains".
            let results = await NameServicesClient.shared.resolveEverywhere(domain)
            await MainActor.run {
                guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == domain else { return }
                nameResolutions = results
                isResolvingKNS = false
                if let resolution = NameServicesClient.primary(of: results, typed: domain), resolution.address != nil {
                    selectResolution(resolution)
                } else {
                    resolvedAddress = nil
                    resolvedDomain = nil
                    selectedTLD = nil
                    knsError = NameServicesClient.notFoundMessage(typed: domain, results: results)
                }
            }
        }
    }

    private func handleScannedQRCode(_ code: String) {
        var address = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if KaspaAddress.hasAddressPrefix(address) {
            if let queryIndex = address.firstIndex(of: "?") {
                address = String(address[..<queryIndex])
            }
            // After the query is gone: an all-uppercase QR address becomes lowercase
            address = KaspaAddress.normalizedCase(address)
        }
        addressInput = address
        handleInputChange(address)
    }

    private func setMaxAmount() {
        guard hasValidRecipient else { return }
        usedMax = true
        isEstimatingMax = true
        errorMessage = nil
        let recipient = effectiveAddress
        let customExtra = customExtraFeeSompi
        let multiplier = feeTier.multiplier
        let spendingIndex = isCompoundMode ? nil : source.spendingIndex
        let coins = manualUtxos
        let request = UUID()
        maxRequest = request
        Task {
            do {
                func maxSend(extra: UInt64) async throws -> (amountSompi: UInt64, cappedAtInputLimit: Bool) {
                    if let index = spendingIndex {
                        return try await chatService.estimateMaxSpendingAddressAmount(index: index, toAddress: recipient, manualUtxos: coins, extraFeeSompi: extra)
                    }
                    return try await chatService.estimateMaxWithdrawalAmount(toAddress: recipient, manualUtxos: coins, extraFeeSompi: extra)
                }
                // The speed's extra is priced from what Max sends, never from the typed amount's
                // fee: that send's fee is smaller, and the send charges the extra on this one's.
                var tipSompi = customExtra ?? 0
                if customExtra == nil, multiplier > 1 {
                    let provisional = try await maxSend(extra: 0)
                    let base: SendFeeEstimate
                    if let index = spendingIndex {
                        base = try await chatService.estimateSpendingAddressWithdrawalFee(index: index, toAddress: recipient, amountSompi: provisional.amountSompi, manualUtxos: coins)
                    } else {
                        base = try await chatService.estimateWithdrawalFee(toAddress: recipient, amountSompi: provisional.amountSompi, manualUtxos: coins)
                    }
                    tipSompi = base.networkFee * (multiplier - 1)
                }
                let result = try await maxSend(extra: tipSompi)
                await MainActor.run {
                    // a newer Max (another speed tapped meanwhile) decides the amount
                    guard maxRequest == request else { return }
                    amountInput = fiatAmountState.setMaxSompi(result.amountSompi, priceInCurrency: priceModel.currentPriceUsd)
                    maxCapped = result.cappedAtInputLimit
                    isEstimatingMax = false
                }
            } catch {
                await MainActor.run {
                    guard maxRequest == request else { return }
                    errorMessage = UserFacingError.message(for: error)
                    maxCapped = false
                    isEstimatingMax = false
                }
            }
        }
    }

    private func startEditingFee() {
        guard let totalFeeSompi else { return }
        customFeeText = formatKasTrimmed(totalFeeSompi)
        isEditingFee = true
    }

    /// Commits the manually-typed total fee. Values below the network-computed minimum are
    /// clamped up to that minimum rather than rejected outright — a transaction can't
    /// actually be submitted under the minimum, so silently flooring it is friendlier than
    /// an error for a value the user almost certainly meant as "as low as possible."
    private func commitCustomFee() {
        defer { isEditingFee = false }
        guard let normalFeeSompi, let totalSompi = KaspaUnit.sompi(fromUserText: customFeeText) else { return }
        customExtraFeeSompi = totalSompi > normalFeeSompi ? totalSompi - normalFeeSompi : 0
    }

    private func send() {
        // one send at a time: a second swipe or activation must never build a second transaction
        guard let amountSompi, !isSending else { return }
        isSending = true
        errorMessage = nil
        let recipient = effectiveAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let tipSompi = extraFeeSompi
        // what the Review showed: a send rebuilt at the swipe that would pay more doesn't go
        let expectedFee = totalFeeSompi
        let request = activeRequest
        let spendingIndex = source.spendingIndex
        Task {
            do {
                try await SendFailureSimulation.failIfEnabled()
                let txId: String
                if let request, request.toChattingAddress, request.address.lowercased() == recipient.lowercased(),
                   let contact = (try? contactsManager.addContact(address: recipient, alias: "", isAutoAdded: true))
                    ?? contactsManager.getContact(byAddress: recipient) {
                    // A chatting address: a chat payment, the memo encrypted to them inside it -
                    // it lands in your chat with them like any payment from the chat.
                    let paid = try await chatService.sendPayment(
                        to: contact, amountSompi: amountSompi, note: request.memo,
                        extraFeeSompi: tipSompi, sourceSpendingIndex: spendingIndex, manualUtxos: manualUtxos,
                        expectedFeeSompi: expectedFee
                    )
                    // nil means deferred (no confirmed inputs yet): the retry timer owns it and
                    // the bubble is already in the chat, but nothing has been sent to confirm.
                    guard let paid, !paid.isEmpty else {
                        await MainActor.run {
                            isSending = false
                            dismiss()
                            onComplete?()
                        }
                        return
                    }
                    txId = paid
                } else if let spendingIndex {
                    txId = try await chatService.sendFromSpendingAddress(index: spendingIndex, toAddress: recipient, amountSompi: amountSompi, manualUtxos: manualUtxos, extraFeeSompi: tipSompi, expectedFeeSompi: expectedFee)
                } else {
                    txId = try await chatService.sendWithdrawal(toAddress: recipient, amountSompi: amountSompi, manualUtxos: manualUtxos, extraFeeSompi: tipSompi, expectedFeeSompi: expectedFee)
                }
                await MainActor.run {
                    isSending = false
                    sentTransaction = SentTransaction(
                        txId: txId,
                        amountSompi: amountSompi,
                        // The domain when one was resolved, otherwise the address itself.
                        recipient: resolvedDomain ?? recipient
                    )
                }
            } catch {
                await MainActor.run {
                    isSending = false
                    errorMessage = UserFacingError.message(for: error)
                    // nothing went out; Try Again goes back to a Review with the fee of today's coins
                    if error is SendFeeChangedError { feeRefresh += 1 }
                }
            }
        }
    }
}

enum ProfileQRCodeCache {
    static let context = CIContext()
    static let imageCache = NSCache<NSString, UIImage>()
    static let renderQueue = DispatchQueue(label: "kasia.profile.qr.render", qos: .utility)

    static func cachedImage(for address: String) -> UIImage? {
        let uri = receiveURI(for: address)
        let key = uri as NSString
        return imageCache.object(forKey: key)
    }

    static func preload(address: String, completion: ((UIImage?) -> Void)?) {
        let uri = receiveURI(for: address)
        let key = uri as NSString

        if let cached = imageCache.object(forKey: key) {
            guard let completion else { return }
            DispatchQueue.main.async {
                completion(cached)
            }
            return
        }

        renderQueue.async {
            let image = generateImage(uri: uri)
            if let image {
                imageCache.setObject(image, forKey: key)
            }
            guard let completion else { return }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    private static func generateImage(uri: String) -> UIImage? {
        let data = Data(uri.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func receiveURI(for address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("kaspa:") {
            return trimmed
        }
        return "kaspa:\(trimmed)"
    }
}



// MARK: - Profile Help screen

/// All the app's guides in one place, reached from Settings > Help: the first-run Welcome
/// Guide, replayed through the Settings screen's own cover (callback), and KaPay's .kachat Names and kUSDT
/// guides (back 2026-11-21).
struct ProfileHelpView: View {
    let onWelcomeGuide: () -> Void
    /// KaPay's .kachat Names Guide (back 2026-11-21 with the .kachat market), full screen.
    @State private var showKachatSetupGuide = false

    var body: some View {
        List {
            Section {
                helpRow(
                    icon: "sparkles",
                    title: "Welcome Guide",
                    subtitle: "The full first-run tour: wallet, chats, payments and more."
                ) {
                    onWelcomeGuide()
                }
                // KaPay's two guides (2026-11-21, all-in-one)
                helpRow(
                    icon: "person.text.rectangle",
                    title: ".kachat Names Guide",
                    subtitle: "Claim a .kachat name, make it your name, and keep it."
                ) {
                    showKachatSetupGuide = true
                }
                NavigationLink {
                    TokenGuideView()
                } label: {
                    helpRowLabel(icon: "dollarsign.circle", title: "kUSDT Guide",
                                 subtitle: "What kUSDT is, where it lives, and how sending and swapping work.",
                                 showsChevron: false)
                }
            }
        }
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(isPresented: $showKachatSetupGuide) {
            KachatSetupGuideView { showKachatSetupGuide = false }
        }
    }

    private func helpRow(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            helpRowLabel(icon: icon, title: title, subtitle: subtitle, showsChevron: true)
        }
        .buttonStyle(.plain)
    }

    /// A row's icon, title and line; a NavigationLink draws its own chevron.
    private func helpRowLabel(icon: String, title: String, subtitle: String, showsChevron: Bool) -> some View {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.scaled(size: 20, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(LocalizedStringKey(subtitle))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
    }
}


// MARK: - Claim Testnet Kaspa (Profile, testnet only)

/// "Claim Testnet Kaspa", above the Chatting card on testnet. The official TN10 faucet sits
/// behind a Cloudflare check, so it can't be claimed from in the background: the button copies
/// the chatting address (`kaspatest:` form) and opens the faucet in the in-app browser, with a
/// strip saying it's copied, where you paste it, pass the
/// check and claim the most it offers. The faucet allows one claim a day, so once the address's
/// balance goes up after a visit the button locks for 24 hours (kept per address).
struct TestnetFaucetClaimButton: View {
    let address: String

    static let faucetURL = URL(string: "https://faucet-tn10.kaspanet.io")!
    private static let lockInterval: TimeInterval = 24 * 60 * 60

    @ObservedObject private var walletManager = WalletManager.shared
    @State private var showFaucet = false
    @State private var balanceBefore: UInt64?
    @State private var checkingClaim = false
    @State private var claimedAt: Date?

    private var defaultsKey: String { "kachat_tn10_faucet_claimed_\(address.lowercased())" }

    /// The chatting address in its TN10 (`kaspatest:`) form - what the faucet's address field
    /// takes. The wallet already shows it that way on testnet; this makes sure of it.
    private var tn10Address: String {
        guard let a = KaspaAddress(address: address.lowercased()), a.hrp != "kaspatest" else { return address }
        let converted = KaspaAddress(hrp: "kaspatest", type: a.type, payload: a.payload).address
        return converted.isEmpty ? address : converted
    }

    private func unlockDate(_ now: Date) -> Date? {
        guard let claimedAt else { return nil }
        let until = claimedAt.addingTimeInterval(Self.lockInterval)
        return until > now ? until : nil
    }

    private func remaining(until: Date, now: Date) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = until.timeIntervalSince(now) >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .abbreviated
        f.calendar?.locale = AppLocalization.locale
        return f.string(from: max(60, until.timeIntervalSince(now))) ?? ""
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let until = unlockDate(context.date)
            Button {
                UIPasteboard.general.string = tn10Address
                Haptics.success()
                balanceBefore = walletManager.currentWallet?.balanceSompi
                showFaucet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: checkingClaim ? "hourglass" : (until == nil ? "drop.fill" : "checkmark.circle.fill"))
                        .font(.title3)
                        .foregroundColor(until == nil ? .accentColor : .secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Claim Testnet Kaspa")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(until == nil ? .primary : .secondary)
                        Group {
                            if checkingClaim {
                                Text("Waiting for the faucet's payment...")
                            } else if let until {
                                Text(verbatim: String(format: AppLocalization.string("Claimed. You can claim again in %@."), remaining(until: until, now: context.date)))
                            } else {
                                Text("Copies your chatting address and opens the TN10 faucet: paste it, pass the check and claim the most it offers.")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    if until == nil, !checkingClaim {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.accentColor.opacity(until == nil ? 0.15 : 0.06)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(until != nil || checkingClaim)
        }
        .onAppear {
            claimedAt = UserDefaults.standard.object(forKey: defaultsKey) as? Date
        }
        .fullScreenCover(isPresented: $showFaucet, onDismiss: { Task { await checkForClaim() } }) {
            InAppBrowserScreen(
                url: Self.faucetURL,
                notice: AppLocalization.string("Your TN10 chatting address is copied. Paste it into the faucet's address field.")
            ) { showFaucet = false }
        }
    }

    /// After the faucet closes: the payment usually lands within seconds, so watch the chatting
    /// balance for up to a minute. A rise means the claim went through - lock for 24 hours.
    /// No rise (no claim, or the faucet refused) leaves the button free to try again.
    private func checkForClaim() async {
        guard let before = balanceBefore else { return }
        checkingClaim = true
        defer { checkingClaim = false }
        for attempt in 0..<12 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
            if let now = try? await walletManager.refreshBalance(force: true), now > before {
                let at = Date()
                claimedAt = at
                UserDefaults.standard.set(at, forKey: defaultsKey)
                Haptics.success()
                return
            }
        }
    }
}

/// Full-screen in-app browser: the X in the top-left is the ONLY way out (full-screen cover,
/// so there's no slide-down to dismiss).
///
/// While the browser is up, the app powers down like it was backgrounded: node discovery
/// pauses, the chat poll timer stops, and (in
/// remote-push mode) the UTXO subscription is released so notifications arrive via push -
/// exactly the closed-app path. All of it resumes when the X is tapped.
struct InAppBrowserScreen: View {
    let url: URL
    /// Optional strip under the top bar (Claim Testnet Kaspa: "your address is copied").
    var notice: String? = nil
    let onClose: () -> Void

    @State private var isLoading = true
    /// The page on screen now, not the site it opened on: a link or redirect that left the site
    /// would otherwise sit under the first site's name (audit 2026-11-21, #2).
    @State private var currentURL: URL?

    private var headerHost: String {
        let shown = currentURL ?? url
        let host = shown.host ?? ""
        return shown.scheme?.lowercased() == "https" ? host : "http://" + host
    }

    private func powerDownForBrowsing() {
        Task { @MainActor in
            await NodePoolService.shared.pauseDiscovery()
            ChatService.shared.stopPollingTimerOnly()
            if AppSettings.load().notificationMode == .remotePush {
                ChatService.shared.pauseUtxoSubscriptionForRemotePush()
            }
        }
    }

    private func powerUpAfterBrowsing() {
        Task { @MainActor in
            await NodePoolService.shared.resumeDiscovery()
            ChatService.shared.startPolling()
            if AppSettings.load().notificationMode == .remotePush {
                await ChatService.shared.resumeUtxoSubscriptionForRemotePush()
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    Haptics.impact(.light)
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.scaled(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.regularMaterial))
                }
                .buttonStyle(.plain)
                Spacer()
                Text(verbatim: headerHost)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if isLoading {
                    ProgressView()
                        .frame(width: 34, height: 34)
                } else {
                    Color.clear
                        .frame(width: 34, height: 34)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if let notice {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .foregroundColor(.accentColor)
                    Text(verbatim: notice)
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.accentColor.opacity(0.15))
            }
            Divider()
            InAppWebView(url: url, isLoading: $isLoading, currentURL: $currentURL)
                .ignoresSafeArea(edges: .bottom)
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear { powerDownForBrowsing() }
        .onDisappear { powerUpAfterBrowsing() }
    }
}

/// The browser stays on the site it opened (its host and that host's subdomains, "www." aside):
/// a link or redirect to any other http(s) site opens in Safari, and other schemes are refused
/// but for what a page itself needs (about:, blob:, and data: in frames). Its cookies and
/// storage last only while it's open (`.nonPersistent()`), so nothing carries across accounts
/// (audit 2026-11-21, #2).
private struct InAppWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var currentURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.observe(webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.urlObservation = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: InAppWebView
        /// The site the browser was opened on, without a leading "www.".
        private let siteHost: String
        var urlObservation: NSKeyValueObservation?

        init(_ parent: InAppWebView) {
            self.parent = parent
            let host = parent.url.host?.lowercased() ?? ""
            self.siteHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }

        /// Follows the page's address as it changes (links, redirects, history), for the header.
        func observe(_ webView: WKWebView) {
            urlObservation = webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                let now = webView.url
                DispatchQueue.main.async {
                    guard let self, let now, now.scheme?.lowercased() != "about" else { return }
                    self.parent.currentURL = now
                }
            }
        }

        private func isOnSite(_ url: URL) -> Bool {
            guard !siteHost.isEmpty, let host = url.host?.lowercased() else { return false }
            return host == siteHost || host.hasSuffix("." + siteHost)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.request.url,
                  let scheme = target.scheme?.lowercased() else {
                decisionHandler(.cancel)
                return
            }
            // nil: a new window (target="_blank", window.open)
            let frame = navigationAction.targetFrame
            let isMainFrame = frame?.isMainFrame ?? true
            switch scheme {
            case "http", "https":
                if !isMainFrame {
                    // a frame inside the page (a captcha, an embed): it can't replace the page or its header
                    decisionHandler(.allow)
                } else if isOnSite(target) {
                    if frame == nil {
                        // a new window on the same site opens here instead
                        webView.load(navigationAction.request)
                        decisionHandler(.cancel)
                    } else {
                        decisionHandler(.allow)
                    }
                } else {
                    // another site: Safari, never under this site's name. Only for a tapped link,
                    // a new window or the very first load's redirect, so a page's script can't
                    // keep throwing the person out to Safari.
                    let tapped = navigationAction.navigationType == .linkActivated || frame == nil
                    let firstLoad = webView.backForwardList.currentItem == nil
                    if tapped || firstLoad {
                        UIApplication.shared.open(target)
                    }
                    decisionHandler(.cancel)
                }
            case "about", "blob":
                decisionHandler(frame == nil ? .cancel : .allow)
            case "data":
                decisionHandler(isMainFrame ? .cancel : .allow)
            default:
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}

/// "Edit KaChat Profile": the live address profile editor (`KachatLiveProfileEditor`) on both
/// networks - it writes the `kchat:1:profile:` record, a self-send that needs no registry, so it
/// saves on mainnet too; only the primary name waits for mainnet's registry.
struct KaChatProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if KachatNamesService.isEnabled {
            KachatLiveProfileEditor()
        } else {
            comingSoonEditor
        }
    }

    private var comingSoonEditor: some View {
        NavigationStack {
            Form {
                Section("Avatar") {
                    Label("Choose Avatar", systemImage: "photo")
                        .foregroundColor(.secondary)
                }

                Section("Banner") {
                    Label("Choose Banner", systemImage: "photo.on.rectangle")
                        .foregroundColor(.secondary)
                }

                Section("Profile") {
                    ForEach(["Bio", "X handle", "Website", "Telegram", "Discord user id", "Email", "GitHub", "Redirect URL"], id: \.self) { field in
                        Text(LocalizedStringKey(field))
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text("None yet")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text(".kachat Name")
                }
            }
            .navigationTitle("Edit KaChat Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
