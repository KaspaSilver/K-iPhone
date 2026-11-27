import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Every address of this account, reached from Profile > Manage Addresses: the chatting address
/// first, then the spending addresses, each with its balance and whether it was used, a
/// "generate new address" action, rename, QR, hide. Which address a send comes from is picked on
/// the send screen itself (From), so there is no "primary" here.
struct ManageAddressesView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    @State private var entries: [SpendingAddressEntry] = []
    @State private var isLoading = false
    @State private var isGenerating = false
    @State private var isDiscovering = false
    @State private var errorMessage: String?
    @State private var qrTarget: SpendingAddressEntry?
    /// A row's ⋮ > Send to Chatting Address: Send Kaspa from that address, the Chatting Address
    /// filled in as the recipient.
    @State private var sendToChattingTarget: SpendingAddressEntry?
    /// A card's Send: Send Kaspa from that address.
    @State private var sendTarget: SpendingAddressEntry?
    /// The Chatting Address card's Send and Receive.
    @State private var showChattingSend = false
    @State private var showChattingReceive = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    /// Addresses that own at least one KNS domain (cached assets-by-owner lookup) - drives the
    /// "Contains domain" row tag and promotes those rows into the funded group in the sort.
    @State private var domainOwningAddresses: Set<String> = []
    /// Zero-balance addresses whose used/unused probe has NOT confirmed an answer - either
    /// still in flight this load, or failed (network/rate limit). Their badge shows a neutral
    /// "Checking" state instead of a possibly-wrong "Unused", and Generate refuses to recycle
    /// them without a targeted probe. Seeded with every unprobed row at the start of a load
    /// and shrunk per-row the moment each probe lands, so low rows resolve within a second
    /// or two of the screen opening instead of when the whole sweep ends.
    @State private var unknownUsedAddresses: Set<String> = []
    /// Quantum (KIP-22) rows whose key is on chain (they spent once): the shield is off for
    /// good. Seeded from the local marks, confirmed per row by the on-chain probe.
    @State private var quantumSpentAddresses: Set<String> = []
    /// The bulk show/hide checklist, reached from the Address Actions sheet - it is one of this
    /// account's address actions, so it lives with the others rather than as an unlabelled
    /// checklist glyph in the toolbar.
    @State private var showVisibilityManager = false
    /// The floating +'s half sheet: a regular or a quantum-protected address.
    @State private var showNewAddressSheet = false
    /// The half sheet behind a card's ⋮.
    @State private var addressActionsTarget: SpendingAddressEntry?
    /// Live scan position while discovering, so the actions sheet can count up rather than sit
    /// on a spinner for the half-minute a gap-limit walk takes.
    @State private var discoveryProgress: WalletManager.SpendingDiscoveryProgress?

    /// Authoritative primary index, read live from WalletManager rather than the rows'
    /// snapshotted `isCurrent` flags - a payment send can rotate the primary while this
    /// screen's entries are stale, and every isCurrent-dependent decision here (the star,
    /// the sort, Set as Primary / Hide menu items) must follow the rotation immediately.
    /// WalletManager republishes `currentWallet` on rotation, so this recomputes right away.
    private var primaryIndex: Int {
        walletManager.currentSpendingAddressIndex
    }

    /// The spending rows shown: everything not hidden.
    private var visibleEntries: [SpendingAddressEntry] {
        entries.filter { !$0.hidden }
    }

    /// The spending addresses under the Chatting Address: unused ones first, newest first - so a
    /// freshly generated address lands right under the Chatting Address - then the used ones in
    /// number order (owner's call, 2026-10-27, from KaChat Wallet). One still being checked counts
    /// as unused until its check says otherwise.
    private var sortedEntries: [SpendingAddressEntry] {
        func isUsed(_ entry: SpendingAddressEntry) -> Bool { entry.everUsed || entry.balanceSompi > 0 }
        return visibleEntries.sorted { a, b in
            let aUsed = isUsed(a), bUsed = isUsed(b)
            if aUsed != bUsed { return !aUsed }
            return aUsed ? a.index < b.index : a.index > b.index
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                addressesTabContent
            }
            .listStyle(.plain)
            // Pulling down is Discover Addresses (owner, 2026-11-26: its own button is gone): it
            // scans for every address holding a balance or a username, then reloads, as the
            // Wallet tab's pull does.
            .refreshable {
                await discoverAddresses()
            }
            // Room to scroll the last row out from under the floating button.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 72)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            newAddressButton
        }
        .navigationTitle("Manage Addresses")
        .navigationBarTitleDisplayMode(.inline)
        // Address Visibility at the top right (owner, 2026-11-26), not in a sheet behind the
        // floating button.
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Haptics.impact(.light)
                    showVisibilityManager = true
                } label: {
                    Image(systemName: "checklist")
                }
                .accessibilityLabel(Text("Address Visibility"))
            }
        }
        .sheet(item: $addressActionsTarget) { entry in
            addressRowActionsSheet(entry)
                .presentationDetents([.height(rowActionsSheetHeight(entry))])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showVisibilityManager, onDismiss: {
            // Apply the visibility edits to the rows we already have IMMEDIATELY -
            // loadEntries() re-fetches every balance and used-flag, which takes long
            // enough on big wallets that the screen looked stale after hitting Done.
            applyVisibilityChangesInstantly()
            Task { await loadEntries() }
        }) {
            SpendingAddressVisibilityView()
        }
        .task {
            await loadEntries()
        }
        // Live own-address receive detected (AddressActivityNotifier) - refresh balances so
        // the screen reflects the funds without a manual pull.
        .onReceive(NotificationCenter.default.publisher(for: .ownAddressActivity)) { _ in
            Task { await loadEntries() }
        }
        // Always-post variant: also fires for self-send change (payment rotation,
        // consolidation) that the notification-gated event above suppresses.
        .onReceive(NotificationCenter.default.publisher(for: .ownAddressUtxoActivity)) { _ in
            Task { await loadEntries() }
        }
        // Primary pointer rotated (post-send rotation or Set as Primary elsewhere) - the rows
        // already read the live primary index for the star and menu guards, so they update the
        // moment WalletManager republishes; this reload refreshes balances and the persisted
        // snapshot so the old primary's row is consistent (and hideable) right away.
        .onReceive(NotificationCenter.default.publisher(for: .spendingPrimaryChanged)) { _ in
            Task { await loadEntries() }
        }
        .toast(message: toastMessage)
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $qrTarget) { entry in
            SpendingAddressQRView(entry: entry)
        }
        .sheet(item: $sendTarget) { entry in
            if let wallet = WalletManager.shared.currentWallet {
                WithdrawKaspaView(fromAddress: wallet.publicAddress, availableBalanceSompi: entry.balanceSompi,
                                  lockedSource: .spending(index: entry.index, address: entry.address,
                                                          label: entry.displayLabel)) {
                    Task { await loadEntries() }
                }
                .environmentObject(ContactsManager.shared)
            }
        }
        .sheet(isPresented: $showChattingSend) {
            if let wallet = WalletManager.shared.currentWallet {
                WithdrawKaspaView(fromAddress: wallet.publicAddress, availableBalanceSompi: wallet.balanceSompi ?? 0,
                                  lockedSource: .chatting) {
                    Task { await loadEntries() }
                }
                .environmentObject(ContactsManager.shared)
            }
        }
        .sheet(isPresented: $showChattingReceive) {
            if let wallet = WalletManager.shared.currentWallet {
                NavigationStack {
                    ChattingAddressQRView(address: wallet.publicAddress, balanceSompi: wallet.balanceSompi)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Close") { showChattingReceive = false }
                            }
                        }
                }
            }
        }
        .sheet(item: $sendToChattingTarget) { entry in
            if let wallet = WalletManager.shared.currentWallet {
                WithdrawKaspaView(fromAddress: wallet.publicAddress, availableBalanceSompi: entry.balanceSompi,
                                  prefillAddress: wallet.publicAddress,
                                  lockedSource: .spending(index: entry.index, address: entry.address,
                                                          label: entry.displayLabel)) {
                    Task { await loadEntries() }
                }
            }
        }
    }

    /// Every address: the total, the actions, then the chatting address, then the spending ones.
    @ViewBuilder
    private var addressesTabContent: some View {
        accountSummary
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

        discoveryStatus
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

        if let wallet = walletManager.currentWallet {
            chattingAddressRow(wallet)
                .padding(.vertical, 6)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }

        if isLoading && entries.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.top, 20)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else if visibleEntries.isEmpty {
            emptyState
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            // Swipe left to hide (owner, 2026-11-22), like marking mail read: a partial swipe
            // shows the Hide button, a full swipe hides at once. Same rules as the row menu's
            // Hide Address (`hideAddress`: a kUSDT-listed address refuses with a toast).
            ForEach(sortedEntries) { entry in
                addressRow(entry)
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            Haptics.impact(.medium)
                            hideAddress(entry)
                        } label: {
                            Label("Hide", systemImage: "eye.slash.fill")
                        }
                        .tint(.orange)
                    }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "creditcard")
                .font(.scaled(size: 40))
                .foregroundColor(.secondary)
            Text("No Spending Addresses")
                .font(.headline)
            Text("Generate one below to start sending payments from a separate address than the one you chat from.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// The chatting address, first in the list, on the same card as the others: no rename.
    private func chattingAddressRow(_ wallet: Wallet) -> some View {
        ManagedAddressCard(
            name: AppLocalization.string("Chatting Address"),
            amount: Self.kasAmount(wallet.balanceSompi),
            canSend: (wallet.balanceSompi ?? 0) > 0,
            used: .used,
            ownsUsername: domainOwningAddresses.contains(wallet.publicAddress),
            quantum: .notProtected,
            nameAccessory: {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            },
            detail: {
                if let sompi = wallet.balanceSompi { KaspaFiatText(sompi: sompi) }
            },
            onCopy: {
                UIPasteboard.general.string = wallet.publicAddress
                Haptics.success()
                showToast(wallet.publicAddress.addressCopiedToastText)
            },
            onSend: { showChattingSend = true },
            onReceive: { showChattingReceive = true },
            rename: nil,
            onMore: nil
        ) {
            ChattingAddressManageView(address: wallet.publicAddress)
        }
    }

    private static func kasAmount(_ sompi: UInt64?) -> String {
        "\(sompi.map { KaspaUnit.groupedExact($0) } ?? "--") \(KaspaUnit.symbol)"
    }

    private func addressRow(_ entry: SpendingAddressEntry) -> some View {
        let isUsed = entry.everUsed || entry.balanceSompi > 0
        // The history probe for this address failed on the last load: used-ness is unknown,
        // and claiming "Unused" could invite address reuse. Pull to refresh re-checks.
        let usedUnknown = !isUsed && unknownUsedAddresses.contains(entry.address)

        return ManagedAddressCard(
            name: entry.displayLabel,
            amount: Self.kasAmount(entry.balanceSompi),
            canSend: entry.balanceSompi > 0,
            used: isUsed ? .used : (usedUnknown ? .checking : .unused),
            ownsUsername: domainOwningAddresses.contains(entry.address),
            quantum: quantumState(for: entry),
            nameAccessory: { EmptyView() },
            detail: { KaspaFiatText(sompi: entry.balanceSompi) },
            onCopy: {
                UIPasteboard.general.string = entry.address
                // A copied address can be handed out for kUSDT like Receive's: the regular look
                // watches it, so a coin sent there is announced (audit 2026-11-25 M2). Quantum
                // addresses never hold tokens.
                if !entry.isQuantum { TokenWallet.shared.noteReceiveAddressShown(entry.address) }
                Haptics.success()
                showToast(entry.address.addressCopiedToastText)
            },
            onSend: { sendTarget = entry },
            onReceive: { qrTarget = entry },
            // In place: each keystroke saved, the row's label kept in step so the list and
            // the address's page agree; empty goes back to "Address #n".
            rename: InlineRename(current: entry.label ?? "", placeholder: entry.displayTitle) { text in
                walletManager.setSpendingAddressLabel(index: entry.index, label: text)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let position = entries.firstIndex(where: { $0.id == entry.id }) {
                    entries[position].label = trimmed.isEmpty ? nil : trimmed
                }
            },
            // The rest (Send to Chatting Address, Hide) in a half sheet. See `addressRowActionsSheet`.
            onMore: { addressActionsTarget = entry }
        ) {
            SpendingAddressTransactionHistoryView(entry: entry)
        }
    }

    /// The quantum (KIP-22) state of an address, spelled out on its card (owner, 2026-11-26):
    /// - protected: a quantum-resistant address whose key has never been on chain.
    /// - not protected: any regular address, or a quantum one that SPENT once, so its key is
    ///   public forever (orange when funds sit on it again: move them to a fresh address).
    private func quantumState(for entry: SpendingAddressEntry) -> QuantumProtection {
        guard entry.isQuantum else { return .notProtected }
        let spent = quantumSpentAddresses.contains(entry.address.lowercased())
        if !spent { return .protected }
        return entry.balanceSompi > 0 ? .revealedWithFunds : .notProtected
    }

    /// Everything this account holds: the chatting address and every spending address, hidden
    /// ones too - the same total as Profile's Manage Addresses card.
    /// Nil while the chatting address's balance is unknown, so the Total shows "--" instead of
    /// a figure that silently leaves that part out.
    private var totalBalanceSompi: UInt64? {
        guard let chatting = walletManager.currentWallet?.balanceSompi else { return nil }
        return chatting + entries.reduce(0) { $0 + $1.balanceSompi }
    }

    /// The total in the same card as an address's own page (`AddressBalanceCard`, as KaPay has
    /// it), with its worth in your currency on mainnet; a dash until it's known.
    @ViewBuilder
    private var accountSummary: some View {
        if let totalBalanceSompi {
            KaspaAddressBalanceCard(label: AppLocalization.string("Total Balance"), sompi: totalBalanceSompi)
        } else {
            AddressBalanceCard(label: AppLocalization.string("Total Balance"), amount: "-- \(KaspaUnit.symbol)", detail: nil)
        }
    }

    /// The floating +: asks which kind of address (owner, 2026-11-26), saying plainly that kUSDT
    /// can't go to or from a quantum-protected one.
    private var newAddressButton: some View {
        Button {
            Haptics.impact(.light)
            showNewAddressSheet = true
        } label: {
            Group {
                if isGenerating {
                    ProgressView()
                } else {
                    Image(systemName: "plus")
                        .font(.scaled(size: 24, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
            }
            .frame(width: 56, height: 56)
            .background(
                Circle()
                    .fill(.regularMaterial)
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                    .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
            )
        }
        .buttonStyle(.plain)
        // not while a pull-down Discover is still writing the list (audit 2026-11-26)
        .disabled(isGenerating || isDiscovering)
        .opacity(isDiscovering ? 0.5 : 1)
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .accessibilityLabel(Text("New Address"))
        .sheet(isPresented: $showNewAddressSheet) {
            newAddressSheet
                .fittedSheetDetents(285)
                .presentationDragIndicator(.visible)
        }
    }

    /// Regular or quantum-protected. Both rows say what they're for; the warning repeats it.
    private var newAddressSheet: some View {
        VStack(spacing: 12) {
            Text("New Address")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)
            ActionSheetRow(
                title: "Regular Address",
                subtitle: "Works with everything: Kaspa and kUSDT.",
                systemImage: "plus.circle"
            ) {
                showNewAddressSheet = false
                generateNew(quantum: false)
            }
            ActionSheetRow(
                title: "Quantum-Protected Address",
                subtitle: "Keeps its key hidden until it spends. Kaspa only.",
                systemImage: "shield"
            ) {
                showNewAddressSheet = false
                generateNew(quantum: true)
            }
            Label("kUSDT can't be sent to or received on a quantum-protected address.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// While a pull-down scan runs: how far it is, under the Total Balance.
    @ViewBuilder
    private var discoveryStatus: some View {
        if isDiscovering, let progress = discoveryProgress {
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking address #\(progress.checkingIndex)")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text(progress.foundCount == 0
                     ? "No addresses with a balance or username yet"
                     : "\(progress.foundCount) found so far")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
    }

    /// Rows vary by address, so the detent has to as well - see `addressRowActionsSheet`.
    private func rowActionsSheetHeight(_ entry: SpendingAddressEntry) -> CGFloat {
        // Copy, Send, Receive and Rename are on the card itself (owner, 2026-11-26).
        let rows = 2
        return CGFloat(120 + rows * 62)
    }

    /// The half sheet behind one address row's ellipsis, replacing the menu that was there.
    private func addressRowActionsSheet(_ entry: SpendingAddressEntry) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(entry.displayLabel)
                    .font(.headline)
                Text(entry.shortAddress)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            // Send Kaspa from this address with the Chatting Address already the recipient
            ActionSheetRow(
                title: "Send to Chatting Address",
                subtitle: "Moves Kaspa from this address to your Chatting Address.",
                systemImage: "arrow.up.circle",
                isDisabled: entry.balanceSompi == 0
            ) {
                addressActionsTarget = nil
                DispatchQueue.main.async { sendToChattingTarget = entry }
            }
            // Hide straight from the row - same effect as unchecking it in Address Visibility,
            // without opening that screen. Any address, funded too: it comes back from there.
            ActionSheetRow(
                title: "Hide Address",
                subtitle: "Removes it from this list. Re-enable it in Address Visibility.",
                systemImage: "eye.slash",
                tint: .orange
            ) {
                addressActionsTarget = nil
                hideAddress(entry)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Row-menu "Hide Address": flips the same per-wallet hidden flag the Address Visibility
    /// checklist edits (so it shows unchecked there), updates the row in place, and refreshes
    /// the persisted snapshot. setSpendingAddressHidden re-verifies primary/zero-balance
    /// server-side and returns false if the address can't be hidden.
    private func hideAddress(_ entry: SpendingAddressEntry) {
        if TokenWallet.shared.listedSpendingIndices().contains(entry.index) {
            showToast(AppLocalization.string("This address is on your kUSDT list, so it stays here. Hide it from Manage kUSDT first."))
            return
        }
        Task {
            let ok = await walletManager.setSpendingAddressHidden(index: entry.index, hidden: true)
            guard ok else {
                showToast("This address can't be hidden.")
                return
            }
            if let position = entries.firstIndex(where: { $0.id == entry.id }) {
                var updated = entries[position]
                updated.hidden = true
                entries[position] = updated
            }
            walletManager.storeSpendingAddressListCache(entries)
            Haptics.success()
            showToast("Address hidden. Re-enable it in Address Visibility.")
        }
    }

    /// Instant sync after the Address Visibility sheet closes: stamp the stored hidden
    /// set onto the rows already loaded and add any newly revealed indices (pager-derived
    /// addresses beyond what this screen had), so the list reflects the user's edits the
    /// moment they hit Done. The full loadEntries() that follows fills in balances/used.
    private func applyVisibilityChangesInstantly() {
        let hidden = walletManager.hiddenSpendingIndexSet()
        var updated = entries
        for i in updated.indices {
            updated[i].hidden = hidden.contains(updated[i].index)
        }
        let known = Set(updated.map(\.index))
        let maxIndex = walletManager.maxSpendingAddressIndex
        if maxIndex >= 0 {
            for index in 0...maxIndex where !known.contains(index) && !hidden.contains(index) {
                guard let address = walletManager.spendingAddress(at: index) else { continue }
                updated.append(SpendingAddressEntry(
                    index: index,
                    address: address,
                    balanceSompi: 0,
                    isCurrent: index == walletManager.currentSpendingAddressIndex,
                    everUsed: false,
                    label: nil,
                    hidden: false
                ))
            }
        }
        entries = updated.sorted { $0.index < $1.index }
    }

    /// Every address Manage kUSDT lists is shown here too (owner's call, 2026-11-20): one hidden
    /// here (Hide, Hide All, an older choice) is shown again, and stays checked in Address Visibility.
    private func showKusdtListedAddresses() async {
        let tokens = TokenWallet.shared
        await tokens.refreshIfStale()
        let listed = tokens.listedSpendingIndices()
        var changed = false
        for (i, entry) in entries.enumerated() where entry.hidden && listed.contains(entry.index) {
            guard await walletManager.setSpendingAddressHidden(index: entry.index, hidden: false) else { continue }
            if i < entries.count, entries[i].index == entry.index { entries[i].hidden = false }
            changed = true
        }
        if changed { walletManager.storeSpendingAddressListCache(entries) }
    }

    private func loadEntries() async {
        // Instant paint from the persisted snapshot of the last full load — the screen shows
        // rows immediately (even with the network down) while the live refresh below replaces
        // them. Only used when we have nothing on screen yet, so a live list never regresses.
        if entries.isEmpty {
            let cached = walletManager.cachedSpendingAddressList()
            if !cached.isEmpty { entries = cached }
        }
        isLoading = entries.isEmpty
        let baseEntries = await walletManager.getSpendingAddressList()

        // Resolve everything answerable WITHOUT a network probe before the rows paint:
        // funded rows are used by definition (a balance proves history - persist that, it's
        // monotonic), and zero-balance rows take a cached answer when one exists (persistent
        // used cache, or this session's confirmed-unused memory). Only rows with no cached
        // answer go on the probe list; a failed earlier probe keeps its last known everUsed
        // (from the cached snapshot / previous load) instead of resetting to false.
        let previousUsed = Dictionary(entries.map { ($0.address, $0.everUsed) }, uniquingKeysWith: { first, _ in first })
        var toProbe: [SpendingAddressEntry] = []
        var merged = baseEntries.map { entry -> SpendingAddressEntry in
            var updated = entry
            if entry.balanceSompi > 0 {
                updated.everUsed = true
                chatService.markSpendingAddressUsed(entry.address)
            } else if let cached = chatService.cachedSpendingAddressUsedState(entry.address) {
                updated.everUsed = cached
            } else {
                updated.everUsed = previousUsed[entry.address] ?? false
                toProbe.append(entry)
            }
            return updated
        }
        merged.sort { $0.index < $1.index }
        entries = merged
        // Every not-yet-confirmed row shows "Checking" from the first frame and clears the
        // moment its OWN probe lands below - not when the whole sweep ends.
        unknownUsedAddresses = Set(toProbe.map(\.address))
        isLoading = false
        // its own task: the Used / Unused probes below don't wait on Trestly
        Task { await showKusdtListedAddresses() }

        // Quantum shields: local spend marks at once, then the chain's word per row for spends
        // made on another device or before a restore (a spent mark is permanent - a revealed
        // key cannot be unrevealed).
        quantumSpentAddresses = Set(merged.filter { $0.isQuantum }.map { $0.address.lowercased() }
            .filter { WalletManager.shared.isQuantumAddressSpentLocally($0) })
        let shieldCandidates = merged.filter { $0.isQuantum && !quantumSpentAddresses.contains($0.address.lowercased()) }
        if !shieldCandidates.isEmpty {
            Task {
                for entry in shieldCandidates {
                    if await chatService.quantumAddressSpentState(entry.address) == true {
                        quantumSpentAddresses.insert(entry.address.lowercased())
                    }
                }
            }
        }

        // Lowest indices first: they are the Generate-recycling candidates, so they should be
        // the first badges to resolve (within a second or two of the screen opening).
        //
        // Bounded concurrency, not fully serial and not unbounded: firing every zero-balance
        // address's request at once risked the REST host/CDN rate-limiting the burst and
        // returning a degraded response that isn't a clean empty result - but one-at-a-time
        // made load time scale linearly with how many zero-balance addresses existed. The cap
        // is 8 now that each probe is a one-integer transactions-count response instead of a
        // full resolved transaction, so even a full in-flight batch is tiny on the wire.
        toProbe.sort { $0.index < $1.index }
        let concurrencyLimit = 8
        var pending = toProbe.makeIterator()
        await withTaskGroup(of: (String, Bool?).self) { group in
            for _ in 0..<concurrencyLimit {
                guard let entry = pending.next() else { break }
                group.addTask { (entry.address, await self.chatService.spendingAddressUsedState(entry.address)) }
            }
            while let (address, used) = await group.next() {
                if let used {
                    if let position = entries.firstIndex(where: { $0.address == address }) {
                        entries[position].everUsed = used
                    }
                    unknownUsedAddresses.remove(address)
                    AppLog.log("[ManageAddresses] everUsed check address=…%@ used=%@", String(address.suffix(8)), used ? "true" : "false")
                }
                // A failed probe stays in unknownUsedAddresses: the badge keeps showing
                // "Checking" (never a possibly-wrong "Unused") and pull to refresh retries.
                if let entry = pending.next() {
                    group.addTask { (entry.address, await self.chatService.spendingAddressUsedState(entry.address)) }
                }
            }
        }

        // Persist the freshly-loaded snapshot so the NEXT open paints instantly from cache.
        walletManager.storeSpendingAddressListCache(entries)

        // Contains-domain tags (.kachat names), after the rows are already visible.
        // The chatting address first: it can hold a domain as much as any spending address.
        let addresses = (walletManager.currentWallet.map { [$0.publicAddress] } ?? []) + baseEntries.map { $0.address }
        // the addresses holding a .kachat name
        let owners = await KachatNamesRegistry.shared.ownersOfNames(among: addresses)
        domainOwningAddresses = owners
    }

    /// Address Actions' two Generate rows (owner's call, 2026-11-19, as in KaPay): a regular
    /// address (Receive's kind, the one that takes kUSDT too) or a quantum-resistant one, each
    /// chosen on purpose.
    private func generateNew(quantum: Bool) {
        guard !isGenerating else { return }
        isGenerating = true
        Task {
            // A sequence, not a single answer: each press yields the lowest HIDDEN unused
            // index (un-hiding it), and extends the chain past the all-time max once no
            // hidden unused index remains - so repeat presses keep producing new rows.
            //
            // Fast path (Android parity): pick from the rows this screen already live-loaded
            // instead of re-fetching the list and re-probing history per press - recycling
            // trusts only a session-confirmed-unused row. A candidate whose probe hasn't
            // resolved yet (still "Checking") gets ONE targeted probe of just that row,
            // walking up to the next candidate when it turns out used, under a short overall
            // budget so the press never feels slow - this is what makes Generate reliably
            // yield the LOWEST unused index instead of skipping unresolved low rows. Only
            // when the budget runs out or a probe fails do we fall through to deriving past
            // the all-time max, which is provably fresh by construction and needs no network
            // at all. A background reload reconciles afterwards.
            let primaryIndex = walletManager.currentSpendingAddressIndex
            // One chain per row: recycling considers only hidden unused rows of the chain asked
            // for, and the fresh path extends that chain.
            let candidates = entries
                .sorted { $0.index < $1.index }
                .filter { entry in
                    entry.isQuantum == quantum
                        && entry.hidden
                        && entry.index != primaryIndex
                        && entry.balanceSompi == 0
                        && !entry.everUsed
                }
            var chosen: Int?
            let probeDeadline = Date().addingTimeInterval(2.0)
            for candidate in candidates {
                // Re-check against LIVE row state: the background sweep may have resolved
                // this row (either way) while an earlier iteration's probe was in flight.
                let live = entries.first(where: { $0.address == candidate.address }) ?? candidate
                if live.everUsed || live.balanceSompi > 0 || !live.hidden { continue }
                if !unknownUsedAddresses.contains(candidate.address) {
                    // Confirmed unused this session - the true lowest recyclable row.
                    chosen = candidate.index
                    break
                }
                // Unresolved: one targeted probe of just this row, bounded by what's left
                // of the press's overall budget.
                guard let used = await timedUsedProbe(candidate.address, deadline: probeDeadline) else {
                    break // budget spent or probe failed - the derive-past-max path is always safe
                }
                if let position = entries.firstIndex(where: { $0.address == candidate.address }) {
                    entries[position].everUsed = used
                }
                unknownUsedAddresses.remove(candidate.address)
                if !used {
                    chosen = candidate.index
                    break
                }
                // Confirmed used: keep walking to the next-lowest candidate.
            }
            let index: Int
            if let chosen {
                index = chosen
                _ = await walletManager.setSpendingAddressHidden(index: index, hidden: false)
                if let i = entries.firstIndex(where: { $0.index == index }) {
                    entries[i].hidden = false
                }
            } else {
                if quantum {
                    index = await walletManager.generateNextQuantumAddress()
                } else {
                    // past the regular chain's all-time end: never revealed, funded or handed out
                    await walletManager.generateNextSpendingAddress()
                    index = walletManager.maxSpendingAddressIndex
                }
                if let address = walletManager.spendingAddress(at: index) {
                    entries.append(SpendingAddressEntry(
                        index: index,
                        address: address,
                        balanceSompi: 0,
                        isCurrent: false,
                        everUsed: false,
                        label: nil,
                        hidden: false
                    ))
                    entries.sort { $0.index < $1.index }
                }
            }
            isGenerating = false
            // A new regular address is about to be handed out: watched for kUSDT like Receive's
            // (audit 2026-11-25 M2). Quantum addresses never hold tokens.
            if !quantum, let address = walletManager.spendingAddress(at: index) {
                TokenWallet.shared.noteReceiveAddressShown(address)
            }
            // showToast auto-dismisses on the standard timer and replaces (never stacks or
            // extends) any toast a rapid earlier press put up. The old direct assignment
            // here never scheduled a dismissal, so the success toast lingered indefinitely.
            showToast(String(format: AppLocalization.string("Address #%d is ready."), locale: AppLocalization.locale, WalletManager.addressNumber(forIndex: index)))
            Task { await loadEntries() }
        }
    }

    /// One used-state probe raced against Generate's overall deadline. Returns the probe's
    /// tri-state answer, collapsed to `nil` for BOTH "probe failed" and "deadline hit" -
    /// Generate treats the two identically (don't recycle, fall back to derive-past-max).
    /// Returns immediately without a request when the budget is already gone.
    private func timedUsedProbe(_ address: String, deadline: Date) async -> Bool? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.05 else { return nil }
        let service = chatService
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await service.spendingAddressUsedState(address) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Discover Addresses, run by pulling down: finds every address holding a balance or a
    /// username (the gap-limit walk), then reloads. Waits for the scan, so the pull's spinner
    /// stays until it's done, and says what it found in a toast.
    private func discoverAddresses() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        discoveryProgress = WalletManager.SpendingDiscoveryProgress(checkingIndex: 0, foundCount: 0)
        let discovered = await walletManager.discoverSpendingAddresses { progress in
            discoveryProgress = progress
        }
        await loadEntries()
        isDiscovering = false
        discoveryProgress = nil
        // One key per plural form, translated (audit 2026-11-24 #34, #36).
        let summary = discovered == 0
            ? AppLocalization.string("No addresses with a balance or username found.")
            : discovered == 1
                ? AppLocalization.string("Found 1 address with a balance or username.")
                : String(format: AppLocalization.string("Found %lld addresses with a balance or username."), discovered)
        showToast(summary)
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
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

/// One address on Manage Addresses (owner, 2026-11-26): drawn like the Total Balance card, with
/// its name, balance, worth in your currency and Used / Unused, then Copy, Send, Receive and
/// Rename, and "Tap to View History" (the whole card opens the address's page, where the full
/// address shows). The address itself isn't on the card.
/// Manage kUSDT draws its addresses with it too (owner, 2026-11-26: "the same setup").
struct ManagedAddressCard<Accessory: View, Detail: View, Destination: View>: View {
    enum UsedState { case used, unused, checking }

    let name: String
    /// The balance, large ("12.5 KAS", "3.00 kUSDT"), or "--" while unknown.
    let amount: String
    /// Send is off when there's nothing to send.
    let canSend: Bool
    let used: UsedState
    let ownsUsername: Bool
    /// Nil leaves the tag off (kUSDT: it only ever lives on regular addresses).
    let quantum: QuantumProtection?
    @ViewBuilder let nameAccessory: () -> Accessory
    /// Under the amount: its worth in your currency, and anything else the asset needs.
    @ViewBuilder let detail: () -> Detail
    let onCopy: () -> Void
    let onSend: () -> Void
    let onReceive: () -> Void
    /// Rename in place (owner, 2026-11-27): Rename turns the name into a text field with the
    /// keyboard up, and each keystroke is saved. Nil for the Chatting Address, which keeps its name.
    let rename: InlineRename?
    /// The ⋮: the address's other actions. Nil for none.
    let onMore: (() -> Void)?
    /// The top-right button hides the address at once (an eye with a slash) instead of opening
    /// the ⋮ sheet: Cold Storage, where Hide is the only other action (owner, 2026-11-27).
    var moreIsHide = false
    @ViewBuilder let destination: () -> Destination

    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            NavigationLink {
                destination()
            } label: {
                EmptyView()
            }
            .opacity(0)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isRenaming, let rename {
                        InlineRenameField(placeholder: rename.placeholder, draft: $draft, focused: $nameFocused) {
                            isRenaming = false
                        }
                        .onChange(of: draft) { rename.onChange($0) }
                    } else {
                        Text(verbatim: name)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    nameAccessory()
                    // Beside the name (owner, 2026-11-26); out of the way while it's typed
                    if let quantum, !isRenaming {
                        QuantumProtectionTag(state: quantum)
                            .fixedSize()
                    }
                    Spacer(minLength: 4)
                    if let onMore {
                        Button {
                            Haptics.impact(.light)
                            onMore()
                        } label: {
                            Image(systemName: moreIsHide ? "eye.slash" : "ellipsis")
                                .font(.scaled(size: moreIsHide ? 16 : 18, weight: .bold))
                                .rotationEffect(.degrees(moreIsHide ? 0 : 90))
                                .foregroundColor(.secondary)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text(moreIsHide ? "Hide Address" : "More"))
                    }
                }
                Text(verbatim: amount)
                    .font(.title.weight(.bold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                detail()
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                usedTag
                    .padding(.top, 2)
                if ownsUsername {
                    ContainsDomainTag()
                        .padding(.top, 2)
                }

                HStack(spacing: 0) {
                    actionButton("Copy", systemImage: "doc.on.doc", action: onCopy)
                    actionButton("Send", systemImage: "arrow.up", isDisabled: !canSend, action: onSend)
                    actionButton("Receive", systemImage: "arrow.down", action: onReceive)
                    if let rename {
                        if isRenaming {
                            actionButton("Done", systemImage: "checkmark") { nameFocused = false }
                        } else {
                            actionButton("Rename", systemImage: "pencil") {
                                draft = rename.current
                                isRenaming = true
                                // a turn later: the field doesn't exist yet on this tap
                                DispatchQueue.main.async { nameFocused = true }
                            }
                        }
                    }
                }
                .padding(.top, 10)

                HStack(spacing: 4) {
                    Spacer()
                    Text("Tap to View History")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                    Spacer()
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(.accentColor)
                .padding(.top, 8)
            }
            .padding(18)
        }
        .background(BalanceCardBackground())
        // The keyboard going away (Done, return, a tap elsewhere) ends the rename.
        .onChange(of: nameFocused) { focused in
            if !focused { isRenaming = false }
        }
    }

    @ViewBuilder
    private var usedTag: some View {
        switch used {
        case .used:
            Text("Used").font(.headline).foregroundColor(.orange)
        case .unused:
            Text("Unused").font(.headline).foregroundColor(.green)
        case .checking:
            Text("Checking").font(.headline).foregroundColor(.secondary)
        }
    }

    private func actionButton(_ title: LocalizedStringKey, systemImage: String, isDisabled: Bool = false,
                              action: @escaping () -> Void) -> some View {
        AddressCardActionButton(title: title, systemImage: systemImage, isDisabled: isDisabled, action: action)
    }
}

/// A round button with its name under it, on Manage Addresses' cards and Cold Storage's account
/// cards. Borderless, so in a List row it takes only its own taps and the rest of the card still
/// opens what the card leads to.
struct AddressCardActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.scaled(size: 16, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.accentColor.opacity(0.18)))
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }
}

/// A card's in-place rename (owner, 2026-11-27: no pop-up): the name it has now ("" for the
/// default), the default shown while the field is empty, and where each keystroke is saved
/// (an empty name goes back to the default).
struct InlineRename {
    let current: String
    let placeholder: String
    let onChange: (String) -> Void
}

/// The name as a text field, in the name's own place and size, while a card is being renamed.
struct InlineRenameField: View {
    let placeholder: String
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    var font: Font = .headline
    let onDone: () -> Void

    var body: some View {
        TextField(placeholder, text: $draft)
            .font(font)
            .foregroundColor(.primary)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused(focused)
            .onSubmit(onDone)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.accentColor.opacity(0.6), lineWidth: 1))
    }
}

/// Whether an address keeps its key hidden from a future quantum computer.
enum QuantumProtection {
    /// A quantum-resistant address that has never spent.
    case protected
    /// A regular address, or a quantum one whose key a spend revealed.
    case notProtected
    /// A quantum address whose key a spend revealed, with funds on it again.
    case revealedWithFunds
}

/// "Quantum Protected" / "Not Quantum Protected", spelled out on an address card in place of
/// the shield icon (owner, 2026-11-26).
struct QuantumProtectionTag: View {
    let state: QuantumProtection

    var body: some View {
        let protected = state == .protected
        let color: Color = protected ? .green : (state == .revealedWithFunds ? .orange : .secondary)
        Text(LocalizedStringKey(protected ? "Quantum Protected" : "Not Quantum Protected"))
            .font(.caption.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .lineLimit(1)
    }
}

/// Small teal-tinted capsule shown on address rows that own at least one KNS or .kachat domain:
/// Manage Addresses (the chatting address and the spending ones) and Cold Storage. Same
/// capsule treatment as the app's other inline badges (e.g. KNSDomainCard's "Primary"), tinted
/// with the accent color instead of drawn on a dark card.
struct ContainsDomainTag: View {
    var body: some View {
        Text("Contains username")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

/// Scoped withdraw dialog for a single spending address — change stays on that same address
/// (no rotation), unlike the auto-sweep-and-rotate behavior of a regular chat payment. Widened
/// from `private` so ContactsView.swift's Profile-tab "Spending Address" dropdown can reuse it
/// for the primary spending address rather than duplicating this whole flow.
struct SpendingAddressWithdrawView: View {
    let entry: SpendingAddressEntry
    /// Pre-fills the recipient with `entry.address` itself (a self-send) and auto-fills Max, for
    /// the "Compound UTXOs" entry point - merges every UTXO at this address into one. Locks the
    /// recipient field instead of just pre-filling it, since editing it away from `entry.address` would defeat the
    /// point of a compound send.
    var isCompoundMode: Bool = false
    /// UTXOs already loaded for `entry.address` by the parent (the list the user is looking at).
    /// Passed through the compound flow so the "Max" estimate and send don't depend on a second
    /// pooled fetch that can transiently return empty - which was surfacing as a spurious
    /// "No spendable UTXOs available" when compounding a large UTXO set.
    var preloadedUtxos: [UTXO] = []
    let onComplete: () -> Void

    @EnvironmentObject var chatService: ChatService
    // (no ContactsManager: it was observed and never read, audit 2026-11-24 #29)
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var priceModel = KasPriceModel.shared
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    @State private var addressInput = ""
    @State private var isValidAddress = false
    @State private var amountInput = ""
    @State private var showQRScanner = false
    @State private var isSending = false
    @State private var isEstimatingMax = false
    /// The running Max: a late answer for an older speed or coin pick is dropped.
    @State private var maxRequest = UUID()
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

    /// The actual address to use (resolved from a KNS domain, or the direct input) - same
    /// precedence as ContactsView's WithdrawKaspaView/AddContactView.
    private var effectiveAddress: String {
        resolvedAddress ?? addressInput
    }

    /// True once we have a usable recipient - either a resolved KNS domain or a directly valid
    /// Kaspa address (mirrors WithdrawKaspaView.hasValidRecipient).
    private var hasValidRecipient: Bool {
        if resolvedAddress != nil { return true }
        return isValidAddress && !isResolvingKNS
    }

    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var normalFeeSompi: UInt64?
    /// The fee this exact send pays at the chosen speed (network fee, extra and any change too
    /// small to keep), from an estimate made with that extra; nil until it is known.
    @State private var builtFeeSompi: UInt64?
    @State private var isEstimatingFee = false
    /// The amount a Max set that is what one transaction can carry, not the whole balance: the
    /// note shows while the amount is still that one.
    @State private var cappedMaxAmount: String?
    /// The amount Max last set: while it's still the amount, a fee change works Max out again.
    @State private var maxSetAmount: String?
    /// Why the fee couldn't be worked out (usually: not enough Kaspa for the amount and fee).
    @State private var feeError: String?

    private var usedMax: Bool { maxSetAmount != nil && maxSetAmount == amountInput }
    @State private var customExtraFeeSompi: UInt64?
    @State private var isEditingFee = false
    @State private var customFeeText = ""
    /// The fee editor (the fee row's Edit) is on screen in place of the review.
    @State private var editingFee = false
    @State private var feeDraft = ""

    @State private var manualUtxos: [UTXO]?
    /// `manualUtxos` came from Coin Control, not from Compound pinning its one-transaction chunk.
    @State private var coinsPickedByHand = false
    @State private var showCoinControl = false

    private var amountSompi: UInt64? {
        guard let sompi = KaspaUnit.sompi(fromUserText: amountInput), sompi > 0 else { return nil }
        return sompi
    }

    /// The swipe waits for the amount and the fee it shows to be the ones that will be sent: not
    /// while Max or the fee is being worked out again, and not when the fee couldn't be.
    private var canSend: Bool {
        hasValidRecipient && amountSompi != nil && !isSending
            && !isEstimatingMax && !isEstimatingFee && feeError == nil && totalFeeSompi != nil
    }

    /// Extra priority tip on top of the base (Normal-tier) fee, for network congestion. A
    /// manually-entered custom fee (tapped on the Network Fee row) overrides the tier
    /// multiplier until a tier is tapped again - same behavior as the chatting-address
    /// withdraw flow (ContactsView.WithdrawKaspaView).
    private var extraFeeSompi: UInt64 {
        guard let normalFeeSompi else { return 0 }
        if let customExtraFeeSompi { return customExtraFeeSompi }
        return normalFeeSompi * (feeTier.multiplier - 1)
    }

    private var totalFeeSompi: UInt64? {
        guard normalFeeSompi != nil else { return nil }
        return builtFeeSompi
    }

    /// The speed and a custom fee are in the key: the fee shown is worked out with the extra
    /// actually paid (it can take another coin, or leave no change worth keeping).
    /// Bumped when a send stopped because its fee went up: the Review works the fee out again.
    @State private var feeRefresh = 0

    private var feeEstimationKey: String {
        let manualKey = manualUtxos?.map { "\($0.outpoint.transactionId):\($0.outpoint.index)" }.sorted().joined(separator: ",") ?? ""
        return "\(source.index)|\(hasValidRecipient ? effectiveAddress : "")|\(amountSompi ?? 0)|\(manualKey)|\(feeTier.rawValue)|\(customExtraFeeSompi.map { String($0) } ?? "")|\(feeRefresh)"
    }

    /// The spending address this send comes from: `entry` (the primary, from Profile or the
    /// Chats New sheet), unless another was picked from the Available pill for this one send.
    /// The primary itself doesn't change.
    @State private var chosenSource: SpendingAddressEntry?
    @State private var showSourcePicker = false
    private var source: SpendingAddressEntry { chosenSource ?? entry }

    var body: some View {
        NavigationStack {
            ZStack {
                if editingFee {
                    // The send flow's fee editor: the whole fee on the keypad, Confirm back here.
                    SendFeeEditorScreen(draft: $feeDraft, minimumSompi: normalFeeSompi,
                                        onCancel: { showFeeEditor(false) }) { typed in
                        if let normalFeeSompi {
                            customExtraFeeSompi = typed > normalFeeSompi ? typed - normalFeeSompi : 0
                        }
                        showFeeEditor(false)
                    }
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
                } else {
                    review
                        .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .interactiveDismissDisabled()
    }

    private func showFeeEditor(_ show: Bool) {
        if show, let totalFeeSompi { feeDraft = formatKasTrimmed(totalFeeSompi) }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { editingFee = show }
    }

    /// The review: in Compound UTXOs (this screen's one use) the recipient is this address and
    /// the amount everything on it, so only the fee and coin control change before swiping up.
    private var review: some View {
            SwipeUpToSendScrollView(
                screenTitle: isCompoundMode ? "Compound UTXOs"
                    : "Send Kaspa from Address #\(WalletManager.addressNumber(forIndex: source.index))",
                onCancel: { dismiss() },
                title: isCompoundMode ? "Swipe up to Consolidate" : "Swipe up to Send",
                isBusy: isSending,
                isEnabled: canSend,
                amountSompi: amountSompi,
                recipient: isCompoundMode ? nil : effectiveAddress,
                sent: sentTransaction,
                failureMessage: errorMessage,
                onDone: {
                    sentTransaction = nil
                    onComplete()
                    dismiss()
                },
                action: send
            ) {
                VStack(spacing: 18) {
                    SendRecipientCard(
                        input: $addressInput,
                        lockedAddress: isCompoundMode ? source.address : nil,
                        isResolving: isResolvingKNS,
                        resolvedAddress: resolvedAddress,
                        resolvedName: resolvedDomain,
                        lookupError: knsError,
                        isValidAddress: isValidAddress,
                        onScan: { showQRScanner = true },
                        nameResolutions: nameResolutions,
                        selectedTLD: selectedTLD,
                        onSelectResolution: selectResolution
                    )

                    if isCompoundMode {
                        VStack(spacing: 6) {
                            Text("Consolidating")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            if let amountSompi {
                                Text(verbatim: "\(formatKasTrimmed(amountSompi)) \(KaspaUnit.symbol)")
                                    .font(.system(size: 40, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                            } else {
                                ProgressView().frame(height: 48)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                    } else {
                        KaspaAmountEntry(
                            fiatAmountState: fiatAmountState,
                            onAmountChange: { amountInput = $0 },
                            isEstimatingMax: isEstimatingMax,
                            maxEnabled: hasValidRecipient,
                            onMax: setMaxAmount
                        )
                        .padding(.top, 8)
                    }

                    // Tap to send from a different spending address (not in Compound, which is
                    // about this one address).
                    Button {
                        showSourcePicker = true
                    } label: {
                        SendInfoPill {
                            HStack(spacing: 6) {
                                KaspaUnit.text("Available: %@ KAS", formatKasTrimmed(source.balanceSompi))
                                Text(verbatim: "·")
                                Text(source.displayLabel)
                                if !isCompoundMode {
                                    Image(systemName: "chevron.down")
                                        .font(.caption2.weight(.bold))
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isCompoundMode)
                    .accessibilityHint(Text("Choose which spending address to send from"))

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
                        onEditFee: { showFeeEditor(true) }
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
                    } else if let cappedMaxAmount, cappedMaxAmount == amountInput {
                        // Why Max isn't the whole balance: one transaction spends at most
                        // `maxInputsPerTransaction` coins, and this address holds more.
                        Text(String(format: AppLocalization.string("Max is what one transaction can carry: its largest %d coins. Compound UTXOs combines the rest."),
                                    locale: AppLocalization.locale, KasiaTransactionBuilder.maxInputsPerTransaction))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            // The recipient card only shows the lookup; this screen runs it.
            .onChange(of: addressInput) { handleInputChange($0) }
            .onChange(of: feeTier) { _ in
                customExtraFeeSompi = nil
                isEditingFee = false
                if isCompoundMode || usedMax { setMaxAmount() }
            }
            .onChange(of: customExtraFeeSompi) { _ in
                // Compound and Max send everything: the amount is what's left after the fee
                if isCompoundMode || usedMax { setMaxAmount() }
            }
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
                let index = source.index
                let recipient = effectiveAddress
                let coins = manualUtxos
                let preloaded = isCompoundMode ? preloadedUtxos : []
                do {
                    // The Normal fee is the base the speeds multiply (and the editor's minimum);
                    // with the extra in, the estimate builds the same shape the send will.
                    let base = try await chatService.estimateSpendingAddressWithdrawalFee(index: index, toAddress: recipient, amountSompi: amountSompi, manualUtxos: coins, availableUtxos: preloaded)
                    guard !Task.isCancelled else { return }
                    let extra = customExtraFeeSompi ?? base.networkFee * (feeTier.multiplier - 1)
                    var paid = base
                    if extra > 0 {
                        paid = try await chatService.estimateSpendingAddressWithdrawalFee(index: index, toAddress: recipient, amountSompi: amountSompi, manualUtxos: coins, extraFeeSompi: extra, availableUtxos: preloaded)
                    }
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
                if isCompoundMode {
                    addressInput = source.address
                    isValidAddress = true
                    setMaxAmount()
                }
            }
            // The header (Cancel, title) is SwipeUpToSendScrollView's own, so it moves with the swipe.
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { code in
                    handleScannedQRCode(code)
                }
            }
            .sheet(isPresented: $showSourcePicker) {
                SpendingSourcePicker(currentIndex: source.index) { picked in
                    chosenSource = picked
                    // Coin control and the fee belong to the address they were set for.
                    manualUtxos = nil
                    coinsPickedByHand = false
                    customExtraFeeSompi = nil
                    errorMessage = nil
                }
            }
            .sheet(isPresented: $showCoinControl) {
                CoinControlView(fromAddress: source.address, initialSelection: manualUtxos) { selection in
                    manualUtxos = selection
                    coinsPickedByHand = selection?.isEmpty == false
                    if isCompoundMode { setMaxAmount() }
                }
            }
            // The confirmation is the swipe-up's own full screen (SwipeUpToSendScrollView).
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
        isEstimatingMax = true
        errorMessage = nil
        let request = UUID()
        maxRequest = request
        let recipient = effectiveAddress
        let customExtra = customExtraFeeSompi
        let multiplier = feeTier.multiplier
        let index = source.index
        let coins = manualUtxos
        let preloaded = preloadedUtxos
        let compound = isCompoundMode
        // A Compound consolidates the coins picked in Coin Control when there are any.
        let pickedCoins = compound && coinsPickedByHand ? coins : nil
        Task {
            do {
                // The speed's extra is priced from what Max sends, never from the typed amount's
                // fee: that send's fee is smaller, and the send charges the extra on this one's.
                var tipSompi = customExtra ?? 0
                if customExtra == nil, multiplier > 1 {
                    let provisionalAmount: UInt64
                    let provisionalCoins: [UTXO]?
                    if pickedCoins != nil {
                        provisionalAmount = try await chatService.estimateMaxSpendingAddressAmount(index: index, toAddress: recipient, manualUtxos: pickedCoins, availableUtxos: preloaded).amountSompi
                        provisionalCoins = pickedCoins
                    } else if compound {
                        let chunk = try await chatService.maxConsolidatableChunk(index: index, availableUtxos: preloaded)
                        provisionalAmount = chunk.amountSompi
                        provisionalCoins = chunk.utxos
                    } else {
                        provisionalAmount = try await chatService.estimateMaxSpendingAddressAmount(index: index, toAddress: recipient, manualUtxos: coins).amountSompi
                        provisionalCoins = coins
                    }
                    let base = try await chatService.estimateSpendingAddressWithdrawalFee(index: index, toAddress: recipient, amountSompi: provisionalAmount, manualUtxos: provisionalCoins, availableUtxos: compound ? preloaded : [])
                    tipSompi = base.networkFee * (multiplier - 1)
                }
                if pickedCoins != nil {
                    let result = try await chatService.estimateMaxSpendingAddressAmount(index: index, toAddress: recipient, manualUtxos: pickedCoins, extraFeeSompi: tipSompi, availableUtxos: preloaded)
                    await MainActor.run {
                        guard maxRequest == request else { return }
                        amountInput = fiatAmountState.setMaxSompi(result.amountSompi, priceInCurrency: priceModel.currentPriceUsd)
                        maxSetAmount = amountInput
                        isEstimatingMax = false
                    }
                } else if isCompoundMode {
                    // Consolidation is bounded by Kaspa's per-transaction mass cap, so estimate the
                    // max over only the UTXOs that fit ONE transaction (largest-first) and pin the
                    // send to exactly those inputs. This is why "Max" works even when the address has
                    // more UTXOs than a single tx can hold - it consolidates one batch; repeat to
                    // reduce further.
                    let (maxSompi, utxos) = try await chatService.maxConsolidatableChunk(index: source.index, extraFeeSompi: tipSompi, availableUtxos: preloadedUtxos)
                    await MainActor.run {
                        guard maxRequest == request else { return }
                        manualUtxos = utxos
                        amountInput = fiatAmountState.setMaxSompi(maxSompi, priceInCurrency: priceModel.currentPriceUsd)
                        maxSetAmount = amountInput
                        isEstimatingMax = false
                    }
                } else {
                    let result = try await chatService.estimateMaxSpendingAddressAmount(index: source.index, toAddress: recipient, manualUtxos: manualUtxos, extraFeeSompi: tipSompi)
                    await MainActor.run {
                        guard maxRequest == request else { return }
                        amountInput = fiatAmountState.setMaxSompi(result.amountSompi, priceInCurrency: priceModel.currentPriceUsd)
                        cappedMaxAmount = result.cappedAtInputLimit ? amountInput : nil
                        maxSetAmount = amountInput
                        isEstimatingMax = false
                    }
                }
            } catch {
                await MainActor.run {
                    guard maxRequest == request else { return }
                    errorMessage = UserFacingError.message(for: error)
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
    /// clamped up to that minimum rather than rejected outright, matching the chatting-address
    /// withdraw flow's identical behavior.
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
        // In compound mode, `manualUtxos` is the one-transaction chunk pinned by setMaxAmount() and
        // `recipient` is this address itself, so this self-sends exactly those inputs = one
        // consolidation transaction. In normal mode it's a regular send.
        let recipient = effectiveAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let tipSompi = extraFeeSompi
        // what the Review showed: a send rebuilt at the swipe that would pay more doesn't go
        let expectedFee = totalFeeSompi
        Task {
            do {
                try await SendFailureSimulation.failIfEnabled()
                let txId = try await chatService.sendFromSpendingAddress(index: source.index, toAddress: recipient, amountSompi: amountSompi, manualUtxos: manualUtxos, extraFeeSompi: tipSompi, expectedFeeSompi: expectedFee)
                await MainActor.run {
                    isSending = false
                    sentTransaction = SentTransaction(
                        txId: txId,
                        amountSompi: amountSompi,
                        // A compound is a self-send: naming this address as the recipient reads
                        // as a mistake, so it just says how much moved.
                        recipient: isCompoundMode ? nil : recipient
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

/// White-background QR display for a single spending address, matching the same visual
/// treatment as ChattingAddressQRView (literal colors, not adaptive semantic colors, so text
/// stays readable regardless of system dark/light mode without affecting the nav bar).
/// Which spending address a send comes from, picked from a Send screen's Available pill (the
/// spending-address Send, and the 1:1 chat's Send KAS sheet):
/// every spending address you can see (plus hidden ones that hold Kaspa), funded ones first, each
/// with its balance. Picking one changes this send only - the primary stays where it is.
struct SpendingSourcePicker: View {
    let currentIndex: Int
    let onPick: (SpendingAddressEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SpendingAddressEntry]?

    var body: some View {
        NavigationStack {
            Group {
                if let entries {
                    List(entries) { entry in
                        Button {
                            onPick(entry)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(entry.displayLabel)
                                            .font(.subheadline.weight(.semibold))
                                        if entry.isCurrent {
                                            Text("Primary")
                                                .font(.caption2.weight(.bold))
                                                .foregroundColor(.accentColor)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                        }
                                    }
                                    Text(verbatim: "\(entry.address.prefix(14))...\(entry.address.suffix(6))")
                                        .font(.caption.monospaced())
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(verbatim: "\(formatKasTrimmed(entry.balanceSompi)) \(KaspaUnit.symbol)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundColor(entry.balanceSompi > 0 ? .primary : .secondary)
                                if entry.index == currentIndex {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Send From")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            let all = await WalletManager.shared.getSpendingAddressList()
            entries = all
                .filter { !$0.hidden || $0.balanceSompi > 0 || $0.index == currentIndex }
                .sorted { ($0.balanceSompi > 0 ? 0 : 1, $0.index) < ($1.balanceSompi > 0 ? 0 : 1, $1.index) }
        }
    }
}

/// One spending address's receive page, on the shared receive screen (`AddressReceiveView`). A
/// quantum-resistant one says it's for Kaspa only: kUSDT can't be traded from it.
private struct SpendingAddressQRView: View {
    let entry: SpendingAddressEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AddressReceiveView(
                title: AppLocalization.string("Receive Kaspa"),
                address: entry.address,
                addressLabel: entry.displayLabel,
                balanceLine: KaspaUnit.groupedAmount(entry.balanceSompi),
                privacyNote: entry.isQuantum ? ReceiveNotes.quantumAddress : ReceiveNotes.spendingAddress,
                notes: entry.isQuantum
                    ? [ReceiveNotes.kaspaOnly, ReceiveNotes.noKusdtOnQuantum]
                    : [ReceiveNotes.kaspaAndKusdt],
                icon: { KaspaLogoIcon() }
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

/// Reveals a single spending address's own derived private key - not the wallet's seed phrase -
/// so a specific address's spending capability can be exported/backed up without exposing the
/// rest of the wallet. Mirrors SettingsView's seed-phrase reveal flow at the same sensitivity
/// level (SecureView screenshot protection, tap-to-reveal with a 7s auto-hide timer, clipboard
/// auto-clear after 30s) rather than inventing a lighter-weight pattern for equally sensitive
/// key material. The caller gates presentation behind `DeviceAuth`/biometrics already, same as
/// the seed-phrase entry point does.
private struct SpendingAddressPrivateKeyView: View {
    let entry: SpendingAddressEntry
    @Environment(\.dismiss) private var dismiss

    @State private var isRevealed = false
    @State private var revealToken = UUID()
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    private var privateKeyHex: String {
        WalletManager.shared.spendingPrivateKey(at: entry.index)?.hexString ?? "Unavailable"
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
            .navigationTitle(entry.displayLabel)
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

/// Transaction history for a single spending address. Tapping a transaction opens it
/// directly on whichever block explorer is selected in Settings > Connection > Kaspa
/// Explorer, rather than showing an in-app detail screen.
struct SpendingAddressTransactionHistoryView: View {
    let entry: SpendingAddressEntry
    /// Send and Receive at the bottom: only where Manage Addresses' card isn't behind the page
    /// (a tapped address-activity notification).
    var showsSendReceive = false

    @State private var showAddressActions = false
    @State private var showPublicKeySheet = false
    /// What a row of the options sheet opens next, run from its onDismiss.
    @State private var afterAddressActions: (() -> Void)?

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
    @State private var utxoLabels: [String: String] = [:]
    @State private var renamingUtxo: UTXO?
    @State private var renameUtxoText = ""

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
            KaspaAddressBalanceCard(label: entry.displayLabel, address: entry.address, sompi: entry.balanceSompi)

            // The app's page switch (`PageCycleBar`), not a segmented control.
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
                AddressDomainsTab(address: entry.address)
            }
        }
        .navigationTitle(entry.displayLabel)
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
                // A quantum address keeps its key hidden until it spends: that's the point of it.
                showsPublicKey: !WalletManager.isQuantumIndex(entry.index),
                explorerURL: settingsViewModel.settings.kaspaExplorer.addressURL(for: entry.address),
                onViewPrivateKey: {
                    afterAddressActions = {
                        if settingsViewModel.settings.biometricSpendingKeyEnabled {
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
            AddressPublicKeyView(address: entry.address, note: "This is the public half of this address. It cannot spend anything.")
        }
        // Send and Receive are on Manage Addresses' card (owner, 2026-11-26); only a page opened
        // from a notification, with no card behind it, keeps them.
        .safeAreaInset(edge: .bottom) {
            if showsSendReceive {
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
                .disabled(entry.balanceSompi == 0)
                .opacity(entry.balanceSompi == 0 ? 0.5 : 1)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
            }
        }
        .sheet(isPresented: $showReceiveSheet) {
            SpendingAddressQRView(entry: entry)
        }
        .sheet(isPresented: $showSendSheet) {
            // Send from this address's own page: it is the From, with no other to pick.
            if let wallet = WalletManager.shared.currentWallet {
                WithdrawKaspaView(fromAddress: wallet.publicAddress, availableBalanceSompi: wallet.balanceSompi,
                                  lockedSource: .spending(index: entry.index, address: entry.address,
                                                          label: entry.displayLabel)) {
                    Task {
                        await loadTransactions()
                        await loadUtxos()
                    }
                }
                .environmentObject(ContactsManager.shared)
            }
        }
        .sheet(isPresented: $showCompoundSheet) {
            SpendingAddressWithdrawView(entry: entry, isCompoundMode: true, preloadedUtxos: utxos) {
                Task {
                    await loadTransactions()
                    await loadUtxos()
                }
            }
        }
        .sheet(isPresented: $showPrivateKeySheet) {
            SpendingAddressPrivateKeyView(entry: entry)
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
                    WalletManager.shared.setSpendingUtxoLabel(address: entry.address, outpointKey: outpointKey(renamingUtxo), label: renameUtxoText)
                    utxoLabels = WalletManager.shared.loadSpendingUtxoLabels(address: entry.address)
                }
                renamingUtxo = nil
            }
            Button("Cancel", role: .cancel) {
                renamingUtxo = nil
            }
        }
        .task {
            utxoLabels = WalletManager.shared.loadSpendingUtxoLabels(address: entry.address)
            // The push used to stutter: both loads fired mid-animation and their state writes
            // re-rendered the lists under it. Let the transition land first, then load history
            // and UTXOs side by side.
            isLoading = true
            isLoadingUtxos = true
            try? await Task.sleep(nanoseconds: 420_000_000)
            async let history: Void = loadTransactions()
            async let coins: Void = loadUtxos()
            _ = await (history, coins)
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
                address: entry.address,
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
                    Text("Combines this address's UTXOs to reduce the inputs a future send needs. A single transaction can only merge so many at once, so if this address has a very large number, tap Compound again after it confirms to keep reducing.")
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
            utxos = try await NodePoolService.shared.getUtxosByAddresses([entry.address])
            utxoLoadError = nil
        } catch {
            // The list keeps what it had; an outage is not an empty address.
            utxoLoadError = UserFacingError.message(for: error)
        }
        isLoadingUtxos = false
    }

    /// Where an outgoing transaction's Kaspa went, by owner: to other people, and to this
    /// wallet's other addresses (the change), so a Sent row adds up (owner, 2026-11-22: an
    /// address got 10, sent 1, and the 8.99 of change to another address wasn't shown).
    private struct OutgoingBreakdown {
        var toOthers: UInt64 = 0
        /// Own addresses other than this one, by label, in output order.
        var change: [(label: String, sompi: UInt64)] = []
        var changeTotal: UInt64 { change.reduce(0) { $0 + $1.sompi } }
    }

    private func outgoingBreakdown(_ tx: KaspaFullTransactionResponse) -> OutgoingBreakdown {
        var result = OutgoingBreakdown()
        let this = entry.address.lowercased()
        for output in tx.outputs {
            guard let address = output.scriptPublicKeyAddress?.lowercased(), !address.isEmpty, address != this else { continue }
            if let label = WalletManager.shared.ownAddressLabel(for: address) {
                if let index = result.change.firstIndex(where: { $0.label == label }) {
                    result.change[index].sompi += output.amount
                } else {
                    result.change.append((label, output.amount))
                }
            } else {
                result.toOthers += output.amount
            }
        }
        return result
    }

    private func transactionRow(_ tx: KaspaFullTransactionResponse) -> some View {
        var info = tx.direction(for: entry.address)
        // An outgoing row counts what went to other people as Sent, and each of this wallet's
        // other addresses that got change on its own line; all of it to our own addresses is
        // Moved.
        var breakdown: OutgoingBreakdown? = info?.isOutgoing == true ? outgoingBreakdown(tx) : nil
        // A swap also spends the pool's coins: count only what left this wallet (several of its
        // addresses funding one send each show the whole send).
        if let current = breakdown,
           let own = tx.ownHistoryAmount(for: entry.address, toOthers: current.toOthers, ownChange: current.changeTotal,
                                         isOwnAddress: { WalletManager.shared.ownAddressLabel(for: $0) != nil }) {
            if own.isOutgoing {
                breakdown?.toOthers = own.amountSompi
            } else {
                info = (isOutgoing: false, amountSompi: own.amountSompi)
                breakdown = nil
            }
        }
        let moved = breakdown.map { $0.toOthers == 0 && $0.changeTotal > 0 } ?? false
        if let breakdown, info != nil {
            info!.amountSompi = moved ? breakdown.changeTotal : breakdown.toOthers
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
                if let breakdown, !breakdown.change.isEmpty {
                    ForEach(Array(breakdown.change.enumerated()), id: \.offset) { _, change in
                        Text(verbatim: moved
                             ? String(format: AppLocalization.string("To %@"), change.label)
                             : String(format: AppLocalization.string("Change %@ to %@"),
                                      "\(formatKasExact(change.sompi)) \(KaspaUnit.symbol)", change.label))
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.orange)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Text(tx.transactionId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let blockTime = tx.blockTime {
                    Text(Date(timeIntervalSince1970: Double(blockTime) / 1000).formatted(date: .abbreviated, time: .shortened))
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
                // The network fee this transaction paid (inputs minus outputs). Every
                // transaction has one, whoever sent it; on a received one it is what the
                // sender paid.
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

    private func loadTransactions() async {
        isLoading = true
        // Confirmed live against api.kaspa.org that limit=500 works fine in a single call
        // (~0.7s) - cuts this from up to 4 sequential round trips down to 1.
        let result = await chatService.fetchFullTransactionsResult(for: entry.address, pageSize: 200, maxTransactions: 200)
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

// MARK: - Bulk address visibility (toolbar checklist on Manage Addresses)

/// Address Visibility: first a card per chain - Quantum Addresses and Non-Quantum Addresses, drawn
/// like Connection Settings' cards (2026-11-20) - then that chain's checklist (owner's design,
/// 2026-10-21). One pager over raw indices could
/// never reach the quantum chain, which starts at `quantumIndexBase`. Hide All covers both.
private struct SpendingAddressVisibilityView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [SpendingAddressEntry] = []
    @State private var isLoading = true
    @State private var showHideAllConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    chainCard(quantum: true)
                    chainCard(quantum: false)
                }
                .padding()
            }
            .navigationTitle("Address Visibility")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Hide All Addresses?", isPresented: $showHideAllConfirm) {
                Button("Hide All", role: .destructive) { hideAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Manage Addresses starts over with only your chatting address. Nothing is lost: bring any address back here, and its Kaspa still counts in your total.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hide All") { showHideAllConfirm = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task { await load() }
        }
    }

    /// A card like Connection Settings' (2026-11-20): the chain's icon in its circle, its name
    /// with how many of its addresses Manage Addresses shows and what they hold under it, and the
    /// chevron.
    private func chainCard(quantum: Bool) -> some View {
        let chain = entries.filter { $0.isQuantum == quantum }
        // The Chatting Address is the legacy list's always-shown #0.
        let chattingRows = quantum ? 0 : 1
        let shown = chain.filter { !$0.hidden }.count + chattingRows
        // Hidden addresses count too: their Kaspa is still in the account's total.
        let balance = chain.reduce(quantum ? 0 : walletManager.currentWallet?.balanceSompi ?? 0) { $0 + $1.balanceSompi }
        return NavigationLink {
            AddressVisibilityChainList(quantum: quantum, entries: $entries, isLoading: isLoading)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: quantum ? "shield.fill" : "circle.grid.2x2.fill")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(quantum ? "Quantum Addresses" : "Non-Quantum Addresses")
                        .font(.headline)
                        .foregroundColor(.primary)
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        HStack(spacing: 6) {
                            Text("\(shown) of \(chain.count + chattingRows) shown")
                                .foregroundColor(.secondary)
                            Text(verbatim: KaspaUnit.amount(balance))
                                .fontWeight(.semibold)
                                .foregroundColor(balance > 0 ? .accentColor : .secondary)
                        }
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        entries = await walletManager.getSpendingAddressList()
        isLoading = false
    }

    /// Every revealed address hidden, both chains: the list starts from nothing.
    private func hideAll() {
        walletManager.hideAllSpendingAddresses()
        // what Manage kUSDT lists stays shown here too
        let listed = TokenWallet.shared.listedSpendingIndices()
        entries = entries.map { var e = $0; e.hidden = !listed.contains(e.index); return e }
        Task {
            for index in listed { _ = await walletManager.setSpendingAddressHidden(index: index, hidden: false) }
        }
    }
}

/// A very compact list of EVERY revealed spending address with a toggleable checkmark per row -
/// checked = shown on the Manage Addresses list. Built for wallets with a hundred-plus revealed
/// addresses: tap through as many rows as you like in one sitting. Each row also shows whether
/// the address has ever been used on-chain (balance counts as used; swept-to-zero addresses are
/// checked against history lazily). The primary address and any address holding a balance can't
/// be hidden - the same rules WalletManager.setSpendingAddressHidden enforces server-side.
/// Addresses actively offered to contacts as payment-pool reservations don't appear here at
/// all: the checklist mirrors the main Addresses list, and those rows live on the Chat
/// Privacy tab (they can't be hidden or unhidden while the offer is live anyway).
private struct AddressVisibilityChainList: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var chatService: ChatService

    /// Which chain this list pages: the quantum chain lives at `quantumIndexBase` and up, so
    /// one pager over raw indices never reached it (its first page was #20,000).
    let quantum: Bool
    @Binding var entries: [SpendingAddressEntry]
    let isLoading: Bool
    /// Addresses currently offered to contacts as Chats Payment Privacy pool reservations.
    /// They DO appear in this checklist - always checked, with the checkbox inert and the row
    /// labeled "Chat privacy address" - so the user sees the full picture, but they can't be
    /// unchecked while the offer is live. They still stay out of the MAIN Addresses list (the
    /// Chat Privacy tab owns them); this is checklist-only visibility.
    /// "This address is on your kUSDT list", after a tap on such a row.
    @State private var showKusdtNote = false
    /// The slots Manage kUSDT lists, worked out once per page rather than per row.
    @State private var kusdtListed: Set<Int> = []
    /// Lazily-filled history results for zero-balance addresses (address -> ever used).
    @State private var usedByAddress: [String: Bool] = [:]
    /// Pager: 50 addresses per page, endless - pages past the revealed set derive future
    /// indices on the fly (checking one reveals it without flooding the main list).
    @State private var page = 0
    private let pageSize = 50
    /// The rows for the current page, by raw index order - STATE, rebuilt by `rebuildPage()`,
    /// never derived inside `body`. The old computed-property version called the public
    /// `walletManager.spendingAddress(at:)` once per beyond-revealed row during body
    /// evaluation: 50 separate Secure Enclave seed decrypts + PBKDF2 runs on the main thread
    /// per page render (and an all-nil page - i.e. a blank list - whenever the keychain read
    /// transiently failed), which is why tapping the next page appeared to load nothing.
    /// `rebuildPage()` derives the whole page through one shared change-key derivation instead.
    @State private var pageEntries: [SpendingAddressEntry] = []

    var body: some View {
        Group {
            if isLoading && entries.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if pageEntries.isEmpty {
                            Text("These addresses couldn't be derived right now. Go back a page or reopen this screen to retry.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .listRowSeparator(.hidden)
                        }
                        if !quantum, page == 0, let wallet = walletManager.currentWallet {
                            chattingRow(wallet)
                        }
                        ForEach(pageEntries) { entry in
                            row(entry)
                        }
                    }
                    .listStyle(.plain)
                    // New identity per page: guarantees a fresh list AND resets the scroll
                    // position to the top on every page transition.
                    .id(page)
                }
            }
            .safeAreaInset(edge: .bottom) {
                pagerBar
            }
            .navigationTitle(quantum ? "Quantum Addresses" : "Non-Quantum Addresses")
            .alert("Shown for kUSDT", isPresented: $showKusdtNote) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This address is on your kUSDT list, so it stays here. Hide it from Manage kUSDT first.")
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                kusdtListed = TokenWallet.shared.listedSpendingIndices()
                rebuildPage()
            }
            .onReceive(TokenWallet.shared.$holdings) { _ in kusdtListed = TokenWallet.shared.listedSpendingIndices() }
            .onChange(of: page) { _ in rebuildPage() }
            .onChange(of: entries) { _ in rebuildPage() }
    }

    /// Recomputes the current page's rows: revealed indices come from the loaded entries;
    /// anything beyond derives its address through ONE shared change-key derivation
    /// (`spendingAddresses(inRange:)` - single seed decrypt for the whole page). Unrevealed
    /// rows render unchecked.
    private func rebuildPage() {
        let byIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.index, $0) })
        let start = (quantum ? WalletManager.quantumIndexBase : 0) + page * pageSize
        let range = start..<(start + pageSize)
        let derived = walletManager.spendingAddresses(inRange: range)
        pageEntries = range.compactMap { index -> SpendingAddressEntry? in
            if let existing = byIndex[index] { return existing }
            guard let address = derived[index] else { return nil }
            return SpendingAddressEntry(
                index: index, address: address, balanceSompi: 0,
                isCurrent: false, everUsed: false, label: nil, hidden: true
            )
        }
    }

    /// Bottom pager: "#start - #end" with arrows; the right arrow never runs out (pages past
    /// the revealed set derive future addresses).
    private var pagerBar: some View {
        HStack {
            Button {
                page = max(0, page - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 44, height: 36)
            }
            .disabled(page == 0)
            Spacer()
            Text("#\(pagerRange.lowerBound) - #\(pagerRange.upperBound)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Spacer()
            Button {
                page += 1
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .frame(width: 44, height: 36)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    /// The numbers on the current page. The legacy chain's first page also holds #0, the
    /// Chatting Address.
    private var pagerRange: ClosedRange<Int> {
        let first = (quantum ? WalletManager.quantumIndexBase : 0) + page * pageSize
        let lower = !quantum && page == 0 ? 0 : WalletManager.addressNumber(forIndex: first)
        return lower...WalletManager.addressNumber(forIndex: first + pageSize - 1)
    }

    /// #0: always shown on Manage Addresses, so it's checked and tapping it does nothing.
    private func chattingRow(_ wallet: Wallet) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.scaled(size: 20))
                .foregroundColor(.accentColor)
                .opacity(0.45)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: "#0")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                    Text("Chatting Address")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(verbatim: "\(wallet.publicAddress.prefix(16))…\(wallet.publicAddress.suffix(6))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let balance = wallet.balanceSompi, balance > 0 {
                Text(verbatim: "\(String(format: "%.4f", Double(balance) / 100_000_000.0)) \(KaspaUnit.symbol)")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.accentColor)
            }
        }
        .listRowSeparatorTint(Color.secondary.opacity(0.2))
    }

    private func row(_ entry: SpendingAddressEntry) -> some View {
        let funded = entry.balanceSompi > 0
        // Every row toggles both ways - funded ones too (Hide All starts the list over).
        let visible = !entry.hidden
        // on Manage kUSDT's list: it stays shown here
        let locked = visible && kusdtListed.contains(entry.index)
        return HStack(spacing: 10) {
            Image(systemName: visible ? "checkmark.circle.fill" : "circle")
                .font(.scaled(size: 20))
                .foregroundColor(visible ? .accentColor : .secondary)
                .opacity(locked ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    // The chain-local number; the shield marks the quantum chain's rows apart
                    // from the legacy chain's same numbers.
                    Text("#\(WalletManager.addressNumber(forIndex: entry.index))")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                    if entry.isQuantum {
                        Image(systemName: "shield")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if let label = entry.label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Text("\(entry.address.prefix(16))…\(entry.address.suffix(6))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            usedTag(entry, funded: funded)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(entry) }
        .listRowSeparatorTint(Color.secondary.opacity(0.2))
        .task(id: entry.address) { await ensureUsedLoaded(entry, funded: funded) }
    }

    @ViewBuilder
    private func usedTag(_ entry: SpendingAddressEntry, funded: Bool) -> some View {
        if funded {
            Text(verbatim: "\(String(format: "%.4f", Double(entry.balanceSompi) / 100_000_000.0)) \(KaspaUnit.symbol)")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.accentColor)
        } else if let used = usedByAddress[entry.address] {
            Text(used ? "Used" : "Unused")
                .font(.caption2.weight(.semibold))
                .foregroundColor(used ? .orange : .secondary)
        } else {
            Text("…")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    /// One history lookup per zero-balance address, cached for the session of this sheet.
    /// A failed probe stores nothing, so the row keeps its neutral "…" badge (never a
    /// possibly-wrong "Unused") and the next appearance of the row retries.
    private func ensureUsedLoaded(_ entry: SpendingAddressEntry, funded: Bool) async {
        guard !funded, usedByAddress[entry.address] == nil else { return }
        if let used = await chatService.spendingAddressUsedState(entry.address) {
            usedByAddress[entry.address] = used
        }
    }

    private func toggle(_ entry: SpendingAddressEntry) {
        if !entry.hidden, kusdtListed.contains(entry.index) {
            Haptics.impact(.light)
            showKusdtNote = true
            return
        }
        Task {
            // Per chain: a quantum slot (1,000,000+) must not hide that a legacy row lies past the
            // legacy bound - the row would only be unhidden and the bound never extended.
            let revealedMax = entries.filter { $0.isQuantum == entry.isQuantum }.map(\.index).max()
                ?? (entry.isQuantum ? WalletManager.quantumIndexBase - 1 : -1)
            if entry.index > revealedMax {
                // A derived future index from the endless pager: reveal exactly this one
                // (indices in between stay hidden so the main list doesn't flood).
                await walletManager.revealSpendingAddress(at: entry.index)
                entries = await walletManager.getSpendingAddressList()
            } else {
                let ok = await walletManager.setSpendingAddressHidden(index: entry.index, hidden: !entry.hidden)
                guard ok else { return }
                if let position = entries.firstIndex(where: { $0.id == entry.id }) {
                    var updated = entries[position]
                    updated.hidden.toggle()
                    entries[position] = updated
                }
            }
        }
    }
}
