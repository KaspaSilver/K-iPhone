import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// A kpub on the clipboard: it reveals every address of the account and their whole history, so
/// it's copied like the app's other sensitive values (Settings' private key, Manage Addresses):
/// this phone only (no Universal Clipboard) and gone after 30 seconds, by the system's expiry and
/// an in-app clear as well (audit 2026-11-21 #4).
enum ColdStorageClipboard {
    static func copyKpub(_ kpub: String) {
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": kpub]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if UIPasteboard.general.string == kpub {
                UIPasteboard.general.string = ""
            }
        }
    }
}

/// Cold Storage — a fully separate area of the app for watching/spending funds held on an
/// air-gapped KasSigner device. Everything here is watch-only (public keys only); signing always
/// happens on the physical device via QR exchange, never inside KaChat.
struct ColdStorageListView: View {
    @ObservedObject private var manager = ColdStorageManager.shared

    @State private var showScanner = false
    @State private var showManualEntry = false
    @FocusState private var manualKpubFocused: Bool
    @FocusState private var importNameFocused: Bool
    @State private var manualKpubInput = ""
    @State private var pendingKpub: String?
    @State private var nameInput = ""
    @State private var importError: String?
    /// Account whose kpub QR is on screen.
    @State private var kpubQRTarget: ColdStorageAccount?
    /// Each account's balance (its addresses summed), the last known first, then read live.
    @State private var balances: [UUID: UInt64] = [:]
    /// The card's trash: the account waiting on "Remove Cold Storage Account".
    @State private var removeTarget: ColdStorageAccount?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    var body: some View {
        List {
            if manager.accounts.isEmpty {
                emptyState
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(manager.accounts) { account in
                    accountCard(account)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .padding(.vertical, 6)
                }
            }
        }
        // a store not tied to the signed-in account shows nothing and saves nothing
        .onAppear { manager.ensureTiedToSignedInAccount() }
        // Each card's balance: the last known at once, then the live read. Only while the list
        // shows (kept hidden in Kaspa Hub, it reads nothing).
        .onScreenPresence(appear: {
            Task { await loadBalances() }
        }, disappear: {})
        .onChange(of: manager.accounts.map(\.id)) { _ in
            Task { await loadBalances() }
        }
        .refreshable { await loadBalances() }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    pasteKpub()
                } label: {
                    Label("Paste kpub", systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                Button {
                    showScanner = true
                } label: {
                    Label("Scan", systemImage: "qrcode.viewfinder")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .pinnedTabHeader("Cold Storage")
        .toolbar {
            ToolbarItem(placement: .principal) {
                BalanceToolbarLabel()
            }
        }
        .toast(message: toastMessage)
        .sheet(item: $kpubQRTarget) { account in
            ColdStorageKpubQRView(account: account)
        }
        .alert(
            "Remove Cold Storage Account",
            isPresented: Binding(
                get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } }
            ),
            presenting: removeTarget
        ) { account in
            Button("Remove", role: .destructive) {
                manager.removeAccount(account)
                balances[account.id] = nil
                Haptics.success()
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This only removes it from K's watch list. It has no effect on the KasSigner device or any funds it holds.")
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                beginImport(kpub: code)
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingKpub != nil },
            set: { if !$0 { pendingKpub = nil } }
        )) {
            importNameSheet
        }
        .tint(.accentColor)
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .sheet(isPresented: $showManualEntry) {
            manualEntrySheet
        }
    }

    /// A half sheet rather than a full-screen form: it holds one field, and a whole screen for
    /// one paste is more ceremony than the step deserves.
    private var manualEntrySheet: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Enter kpub")
                    .font(.headline)
                Text("Paste the kpub exported from your KasSigner device. It contains no private key material.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            TextField("kpub...", text: $manualKpubInput, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(3...5)
                .focused($manualKpubFocused)
                .padding(14)
                .background(glassBackground(cornerRadius: 16))

            HStack(spacing: 12) {
                Button("Cancel") { showManualEntry = false }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.primary)
                    .background(glassBackground(cornerRadius: 16))

                Button("Next") {
                    showManualEntry = false
                    beginImport(kpub: manualKpubInput)
                }
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundColor(.black)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(manualKpubIsEmpty ? 0.4 : 1))
                )
                .disabled(manualKpubIsEmpty)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fittedSheetDetents(360)
        .presentationDragIndicator(.visible)
        // A turn later: the field does not exist yet on the tap that presented this.
        .onAppear { DispatchQueue.main.async { manualKpubFocused = true } }
    }

    /// Naming the imported account. A half sheet rather than a system alert, matching the kpub
    /// step it follows and every other menu on this screen - an alert box in the middle of a
    /// sheet-shaped flow was the one thing here that still looked like a dialog.
    private var importNameSheet: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Name This Account")
                    .font(.headline)
                Text("Give this account a name so you can recognize it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            TextField("Name", text: $nameInput)
                .font(.body)
                .focused($importNameFocused)
                .submitLabel(.done)
                .onSubmit { if !importNameIsEmpty { completeImport() } }
                .padding(14)
                .background(glassBackground(cornerRadius: 16))

            HStack(spacing: 12) {
                Button("Cancel") { pendingKpub = nil }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.primary)
                    .background(glassBackground(cornerRadius: 16))

                Button("Import") { completeImport() }
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.black)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(importNameIsEmpty ? 0.4 : 1))
                    )
                    .disabled(importNameIsEmpty)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fittedSheetDetents(280)
        .presentationDragIndicator(.visible)
        // A turn later: the field does not exist yet on the tap that presented this.
        .onAppear { DispatchQueue.main.async { importNameFocused = true } }
    }

    private var importNameIsEmpty: Bool {
        nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var manualKpubIsEmpty: Bool {
        manualKpubInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.scaled(size: 40))
                .foregroundColor(.secondary)
            Text("No Cold Storage Accounts")
                .font(.headline)
            Text("Scan or paste a kpub exported from your KasSigner device to watch its balance.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }


    private func accountCard(_ account: ColdStorageAccount) -> some View {
        ColdStorageAccountCard(
            account: account,
            sompi: balances[account.id],
            onCopyKpub: {
                ColdStorageClipboard.copyKpub(account.kpubString)
                Haptics.success()
                showToast("kpub copied to clipboard.")
            },
            onShowKpubQR: { kpubQRTarget = account },
            onToggleAlerts: {
                let on = !account.notifyOnReceive
                manager.setNotifyOnReceive(on, for: account)
                Haptics.selection()
                showToast(AppLocalization.string(on
                    ? "You'll be notified when this account receives Kaspa."
                    : "No more notifications when this account receives Kaspa."))
            },
            onRemove: {
                Haptics.impact(.light)
                removeTarget = account
            }
        )
    }

    /// Every account's balance: the last known at once, then each read live.
    private func loadBalances() async {
        for account in manager.accounts where balances[account.id] == nil {
            if let known = manager.lastKnownBalance(of: account) { balances[account.id] = known }
        }
        for account in manager.accounts {
            let entries = await manager.getAddressList(for: account)
            balances[account.id] = entries.reduce(0) { $0 + $1.balanceSompi }
        }
    }

    /// Paste kpub takes what's on the clipboard at once (owner, 2026-11-22): a valid kpub goes
    /// straight to the half sheet that names the account; anything else is a toast.
    private func pasteKpub() {
        let text = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, KaspaExtendedPublicKey(kpubString: text) != nil else {
            Haptics.error()
            showToast(AppLocalization.string("Not a valid kpub"))
            return
        }
        Haptics.impact(.light)
        beginImport(kpub: text)
    }

    private func beginImport(kpub: String) {
        let trimmed = kpub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KaspaExtendedPublicKey(kpubString: trimmed) != nil else {
            importError = ColdStorageError.invalidKpub.localizedDescription
            return
        }
        pendingKpub = trimmed
        nameInput = String(format: AppLocalization.string("Cold Storage %lld"), manager.accounts.count + 1)
    }

    private func completeImport() {
        guard let kpub = pendingKpub else { return }
        let result = manager.importAccount(kpubString: kpub, label: nameInput)
        pendingKpub = nil
        if case .failure(let error) = result {
            importError = UserFacingError.message(for: error)
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

/// One account on Manage Addresses' card (owner, 2026-11-27): its name, balance and worth,
/// then Copy kpub, kpub QR, Rename and its receive notifications right on the card, and "Tap to
/// View Addresses" (the whole card opens the account). Rename is in place: the name becomes a
/// text field with the keyboard up, saved when the rename ends (an empty name keeps the old one).
private struct ColdStorageAccountCard: View {
    let account: ColdStorageAccount
    let sompi: UInt64?
    let onCopyKpub: () -> Void
    let onShowKpubQR: () -> Void
    let onToggleAlerts: () -> Void
    /// The trash at the card's top right: asks, then removes the account from K.
    let onRemove: () -> Void

    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            NavigationLink {
                ColdStorageDetailView(account: account)
            } label: {
                EmptyView()
            }
            .opacity(0)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                    if isRenaming {
                        InlineRenameField(placeholder: account.label, draft: $draft, focused: $nameFocused) {
                            finishRename()
                        }
                    } else {
                        Text(verbatim: account.label)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                    // Remove, on the card with the account's other actions (owner, 2026-11-27)
                    Button(action: onRemove) {
                        Image(systemName: "trash")
                            .font(.scaled(size: 16, weight: .semibold))
                            .foregroundColor(.red)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Remove Account"))
                }
                Text(verbatim: ManagedAddressCardAmount.kas(sompi))
                    .font(.title.weight(.bold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let sompi {
                    KaspaFiatText(sompi: sompi)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 0) {
                    AddressCardActionButton(title: "Copy kpub", systemImage: "doc.on.doc", action: onCopyKpub)
                    AddressCardActionButton(title: "kpub QR", systemImage: "qrcode", action: onShowKpubQR)
                    if isRenaming {
                        AddressCardActionButton(title: "Done", systemImage: "checkmark") { nameFocused = false }
                    } else {
                        AddressCardActionButton(title: "Rename", systemImage: "pencil") {
                            draft = account.label
                            isRenaming = true
                            // a turn later: the field doesn't exist yet on this tap
                            DispatchQueue.main.async { nameFocused = true }
                        }
                    }
                    // Per account: this account's receives alone.
                    AddressCardActionButton(
                        title: account.notifyOnReceive ? "Alerts On" : "Alerts Off",
                        systemImage: account.notifyOnReceive ? "bell.fill" : "bell.slash",
                        action: onToggleAlerts
                    )
                }
                .padding(.top, 10)

                HStack(spacing: 4) {
                    Spacer()
                    Text("Tap to View Addresses")
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
            if !focused { finishRename() }
        }
        .onDisappear { finishRename() }
    }

    /// The name is saved once, when the rename ends. Saving each keystroke left a cleared name as
    /// its first letter ("C") and restarted the cold-address cache on every key (audit 2026-11-27
    /// M6). An empty field keeps the name it had.
    private func finishRename() {
        guard isRenaming else { return }
        isRenaming = false
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != account.label else { return }
        ColdStorageManager.shared.renameAccount(account, to: name)
    }
}

// MARK: - Detail

/// Address list for one Cold Storage account. Funded addresses sort to the top (newest index
/// first within each group), matching Manage Addresses' spending-chain sort so a freshly
/// generated (zero-balance) address lands right below the last funded one.
struct ColdStorageDetailView: View {
    let account: ColdStorageAccount

    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject private var manager = ColdStorageManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hubSectionHidden) private var hubHidden

    @State private var entries: [ColdStorageAddressEntry] = []
    @State private var isLoading = false
    @State private var isGenerating = false
    @State private var isDiscovering = false
    /// The floating +'s half sheet: the next regular address, or a quantum one scanned from the unit.
    @State private var showNewAddressSheet = false
    /// Quantum-Protected Address was picked there: its scan sheet opens once that one has closed,
    /// since a sheet opened while another is still going away is dropped.
    @State private var openAddQuantumAfterNewAddress = false
    @State private var showAddQuantum = false
    /// Quantum addresses whose key a spend has put on chain (Not Quantum Protected).
    @State private var quantumSpentAddresses: Set<String> = []
    /// Address whose own actions half sheet (the card's ⋮) is open.
    @State private var addressActionsTarget: ColdStorageAddressEntry?
    /// Live scan position while a pull-down Discover runs, shown under the Total Balance.
    @State private var discoveryProgress: ColdStorageManager.DiscoveryProgress?
    @State private var qrTarget: ColdStorageAddressEntry?
    @State private var sendTarget: ColdStorageAddressEntry?
    /// Quantum address whose unit number is being edited.
    @State private var editNumberTarget: ColdStorageAddressEntry?
    /// Quantum address, holding coins, waiting on "Stop Watching?".
    @State private var stopWatchingTarget: ColdStorageAddressEntry?
    @State private var showVisibilityManager = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var loadToken = UUID()
    /// A pending reload after coin activity (`reloadAfterActivity`).
    @State private var activityReload: Task<Void, Never>?
    /// When the last full load (used checks, name lookups) finished. Coming back within
    /// `quickReturn` reloads balances only, so the rows don't reshuffle (smoothness audit L1).
    @State private var lastFullLoad: Date?
    private static let quickReturn: TimeInterval = 120
    /// Addresses that own at least one .kachat name - drives the "Contains username" tag and
    /// counts as used in the sort.
    @State private var domainOwningAddresses: Set<String> = []
    /// Zero-balance addresses whose used/unused history probe FAILED on the last load - their
    /// tag shows a neutral "Checking" instead of a possibly-wrong "Unused".
    @State private var unknownUsedAddresses: Set<String> = []

    private var currentAccount: ColdStorageAccount {
        manager.accounts.first { $0.id == account.id } ?? account
    }

    private func isUsed(_ entry: ColdStorageAddressEntry) -> Bool {
        entry.everUsed || entry.balanceSompi > 0 || domainOwningAddresses.contains(entry.address)
    }

    /// Manage Addresses' order (owner, 2026-11-27: Cold Storage gets the same update): unused
    /// first, newest first, so a freshly generated address lands at the top, then the used ones in
    /// number order. Regular addresses before quantum ones within each group, as their numbers say.
    private var visibleEntries: [ColdStorageAddressEntry] {
        entries.filter { !$0.hidden }.sorted { a, b in
            let aUsed = isUsed(a), bUsed = isUsed(b)
            if aUsed != bUsed { return !aUsed }
            return aUsed ? a.index < b.index : a.index > b.index
        }
    }

    /// Every address, hidden ones too, as the account's card on the list and Manage Addresses
    /// count it (audit 2026-11-27 L16).
    private var totalBalanceSompi: UInt64 {
        entries.reduce(UInt64(0)) { $0.addingSaturated($1.balanceSompi) }
    }

    var body: some View {
        List {
            // Full width, as Manage Addresses shows its total (owner, 2026-11-22).
            KaspaAddressBalanceCard(label: AppLocalization.string("Total Balance"), sompi: totalBalanceSompi)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            discoveryStatus
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

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
                Text("No addresses discovered yet.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                // Swipe left to hide, as on Manage Addresses. An address holding Kaspa refuses
                // with a toast (`hideAddress`).
                ForEach(visibleEntries) { entry in
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
        .listStyle(.plain)
        // Pulling down is Discover Addresses, as on Manage Addresses: it scans for every address
        // holding a balance or a username, then reloads.
        .refreshable {
            await discoverAddresses()
        }
        // Room to scroll the last row out from under the floating button.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 72)
        }
        .overlay(alignment: .bottomTrailing) {
            newAddressButton
        }
        .navigationTitle(currentAccount.label)
        .navigationBarTitleDisplayMode(.inline)
        .toast(message: toastMessage)
        // Address Visibility at the top right, as on Manage Addresses. The account's own actions
        // (kpub, rename, alerts, remove) are on its card on the Cold Storage list (owner,
        // 2026-11-27), not in here.
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
        .sheet(isPresented: $showVisibilityManager, onDismiss: {
            // Apply the visibility edits to the rows we already have IMMEDIATELY -
            // loadEntries() re-fetches every balance and used-flag, which takes long
            // enough that the screen looked stale after hitting Done.
            applyVisibilityChangesInstantly()
            Task { await loadEntries() }
        }) {
            ColdStorageAddressVisibilityView(account: currentAccount)
        }
        // Only while the section shows: kept hidden in Kaspa Hub, `.task` derived addresses and
        // rescanned on every Hub tab selection. Showing again reloads, which also covers any
        // activity skipped below while hidden (audit 2026-11-24 #23).
        .onScreenPresence(appear: {
            let quick = lastFullLoad.map { Date().timeIntervalSince($0) < Self.quickReturn } ?? false
            Task { await loadEntries(balancesOnly: quick && !entries.isEmpty) }
        }, disappear: {})
        // Live own-address receive detected (AddressActivityNotifier) - refresh balances so
        // the screen reflects the funds without a manual pull.
        .onReceive(NotificationCenter.default.publisher(for: .ownAddressActivity)) { _ in
            guard !hubHidden else { return }
            reloadAfterActivity()
        }
        // Always-post variant: also fires for self-send change (withdrawal/compound change)
        // that the notification-gated event above suppresses.
        .onReceive(NotificationCenter.default.publisher(for: .ownAddressUtxoActivity)) { _ in
            guard !hubHidden else { return }
            reloadAfterActivity()
        }
        .sheet(item: $addressActionsTarget) { entry in
            addressRowActionsSheet(entry)
                .fittedSheetDetents(addressRowActionsHeight(entry))
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showNewAddressSheet, onDismiss: {
            if openAddQuantumAfterNewAddress {
                openAddQuantumAfterNewAddress = false
                showAddQuantum = true
            }
        }) {
            newAddressSheet
                .fittedSheetDetents(250)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddQuantum) {
            ColdQuantumAddressAddSheet(account: currentAccount) { added in
                showToast(AppLocalization.string("Quantum-resistant address added."))
                _ = added
                Task { await loadEntries() }
            }
        }
        .sheet(item: $editNumberTarget) { entry in
            ColdQuantumAddressNumberSheet(entry: entry, account: currentAccount) {
                Task { await loadEntries() }
            }
        }
        .alert(
            "Stop Watching This Address?",
            isPresented: Binding(
                get: { stopWatchingTarget != nil },
                set: { if !$0 { stopWatchingTarget = nil } }
            ),
            presenting: stopWatchingTarget
        ) { entry in
            Button("Stop Watching", role: .destructive) {
                stopWatching(entry)
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(KaspaUnit.label(String(format: AppLocalization.string("Its %@ KAS stay on chain at this address, on your KasSigner; K only stops showing them. Scan the address again from KasSigner to watch it again."),
                                        locale: AppLocalization.locale, KaspaUnit.plain(entry.balanceSompi))))
        }
        .sheet(item: $qrTarget) { entry in
            ColdStorageAddressQRView(entry: entry)
        }
        .sheet(item: $sendTarget) { entry in
            ColdSendFlowView(fromAddress: entry.address, availableBalanceSompi: entry.balanceSompi) {
                Task { await loadEntries() }
            }
            .sendKaspaSheetSizing()
        }
    }

    /// The floating +, as on Manage Addresses: asks which kind of address.
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
        // not while a pull-down Discover is still writing the list
        .disabled(isGenerating || isDiscovering)
        .opacity(isDiscovering ? 0.5 : 1)
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .accessibilityLabel(Text("New Address"))
    }

    /// Regular (the next unused address of the kpub) or quantum-protected (KasSigner never exports
    /// its quantum kpub, since it would show every key those addresses hide, so each is scanned
    /// from the unit).
    private var newAddressSheet: some View {
        VStack(spacing: 12) {
            Text("New Address")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)
            ActionSheetRow(
                title: "Regular Address",
                subtitle: "Reveals the next unused address in this account.",
                systemImage: "plus.circle"
            ) {
                showNewAddressSheet = false
                generateMore()
            }
            ActionSheetRow(
                title: "Quantum-Protected Address",
                subtitle: "Scan a KCC-3 address from KasSigner's address screen.",
                systemImage: "shield"
            ) {
                openAddQuantumAfterNewAddress = true
                showNewAddressSheet = false
            }
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

    /// The half sheet behind a card's ⋮: what isn't on the card itself.
    private func addressRowActionsSheet(_ entry: ColdStorageAddressEntry) -> some View {
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

            // Same effect as unchecking it in Address Visibility. Never an address holding Kaspa.
            ActionSheetRow(
                title: "Hide Address",
                subtitle: entry.balanceSompi > 0
                    ? "An address holding Kaspa stays on the list."
                    : "Removes it from this list. Re-enable it in Address Visibility.",
                systemImage: "eye.slash",
                tint: .orange,
                isDisabled: entry.balanceSompi > 0
            ) {
                addressActionsTarget = nil
                hideAddress(entry)
            }
            if entry.isQuantum {
                // A wrong number (or a change address given as a receive one) makes the unit
                // refuse the request: the person can put it right, or clear it to let the unit
                // search.
                ActionSheetRow(
                    title: "Edit Address Number",
                    subtitle: "The number and chain KasSigner shows for this address.",
                    systemImage: "number"
                ) {
                    addressActionsTarget = nil
                    DispatchQueue.main.async { editNumberTarget = entry }
                }
                // A quantum address added by mistake (or no longer wanted) goes from the account;
                // its coins stay on chain and it can be added again. With coins on it, only after
                // saying so.
                ActionSheetRow(
                    title: "Stop Watching",
                    subtitle: "Removes this quantum address from the account. Scan it again to add it back.",
                    systemImage: "minus.circle",
                    tint: .red
                ) {
                    addressActionsTarget = nil
                    if entry.balanceSompi > 0 {
                        DispatchQueue.main.async { stopWatchingTarget = entry }
                    } else {
                        stopWatching(entry)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// One address on Manage Addresses' card (owner, 2026-11-27): name, quantum tag, balance,
    /// worth, Used / Unused, then Copy, Send, Receive and Rename, and Tap to View History.
    private func addressRow(_ entry: ColdStorageAddressEntry) -> some View {
        let used = isUsed(entry)
        // The history probe for this address failed on the last load: used-ness is unknown,
        // and claiming "Unused" could invite address reuse. Pull to refresh re-checks.
        let usedUnknown = !used && unknownUsedAddresses.contains(entry.address)

        return ManagedAddressCard(
            name: entry.displayLabel,
            amount: ManagedAddressCardAmount.kas(entry.balanceSompi),
            canSend: entry.balanceSompi > 0,
            used: used ? .used : (usedUnknown ? .checking : .unused),
            ownsUsername: domainOwningAddresses.contains(entry.address),
            quantum: quantumState(for: entry),
            nameAccessory: { EmptyView() },
            detail: { KaspaFiatText(sompi: entry.balanceSompi) },
            onCopy: {
                UIPasteboard.general.string = entry.address
                Haptics.success()
                showToast(entry.address.addressCopiedToastText)
            },
            onSend: { sendTarget = entry },
            onReceive: { qrTarget = entry },
            // In place (owner, 2026-11-27), as Manage Addresses: each keystroke saved; empty goes
            // back to the default name.
            rename: InlineRename(current: entry.label ?? "", placeholder: entry.defaultLabel) { text in
                if let index = currentIndex(of: entry) {
                    manager.setAddressLabel(accountId: currentAccount.id, index: index, label: text)
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let position = entries.firstIndex(where: { $0.id == entry.id }) {
                    entries[position].label = trimmed.isEmpty ? nil : trimmed
                }
            },
            // A regular address has only Hide left (owner, 2026-11-27: Send to Chatting Address
            // isn't for Cold Storage), so the button hides it at once; a quantum one keeps the ⋮
            // for Edit Address Number and Stop Watching.
            onMore: {
                if entry.isQuantum {
                    addressActionsTarget = entry
                } else {
                    hideAddress(entry)
                }
            },
            moreIsHide: !entry.isQuantum
        ) {
            ColdStorageAddressTransactionHistoryView(entry: entry)
        }
    }

    /// As Manage Addresses tells it: a quantum address is protected until a spend puts its key on
    /// chain (orange once it holds Kaspa again); a regular one never is.
    private func quantumState(for entry: ColdStorageAddressEntry) -> QuantumProtection {
        guard entry.isQuantum else { return .notProtected }
        guard quantumSpentAddresses.contains(entry.address.lowercased()) else { return .protected }
        return entry.balanceSompi > 0 ? .revealedWithFunds : .notProtected
    }

    /// The ⋮ sheet's height (quantum addresses only): Hide, Edit Address Number, Stop Watching.
    private func addressRowActionsHeight(_ entry: ColdStorageAddressEntry) -> CGFloat {
        var rows = 1
        if entry.isQuantum { rows += 2 }
        return CGFloat(110 + 74 * rows)
    }

    /// The index an edit of this row files under now. A quantum entry's index moves when an
    /// earlier quantum address stops being watched, and the row may be from before that.
    private func currentIndex(of entry: ColdStorageAddressEntry) -> Int? {
        entry.isQuantum ? manager.currentQuantumIndex(of: entry.address, in: currentAccount) : entry.index
    }

    private func stopWatching(_ entry: ColdStorageAddressEntry) {
        manager.removeQuantumAddress(entry.address, from: currentAccount)
        entries.removeAll { $0.address == entry.address }
        Task { await loadEntries() }
    }

    /// "Hide Address" (the ⋮ or a swipe): flips the same per-account hidden flag the Address
    /// Visibility checklist edits (so it shows unchecked there) and updates the row in place.
    /// setAddressHidden re-verifies the live balance and returns false if the address holds
    /// Kaspa or the check fails.
    private func hideAddress(_ entry: ColdStorageAddressEntry) {
        if entry.balanceSompi > 0 {
            showToast(AppLocalization.string("An address holding Kaspa stays on the list."))
            return
        }
        Task {
            guard let index = currentIndex(of: entry) else { return }
            let ok = await manager.setAddressHidden(account: currentAccount, index: index, hidden: true)
            guard ok else {
                showToast("This address can't be hidden.")
                return
            }
            if let position = entries.firstIndex(where: { $0.id == entry.id }) {
                var updated = entries[position]
                updated.hidden = true
                entries[position] = updated
            }
            Haptics.success()
            showToast("Address hidden. Re-enable it in Address Visibility.")
        }
    }

    /// Coins moved on one of the phone's own addresses: balances again, two seconds after the
    /// last such change, without the per-address used checks and name lookups, which run on
    /// appear and pull (audit 2026-11-27 L21: a full reload on every UTXO change).
    private func reloadAfterActivity() {
        activityReload?.cancel()
        activityReload = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await loadEntries(balancesOnly: true)
        }
    }

    private func loadEntries(balancesOnly: Bool = false) async {
        isLoading = true
        let token = UUID()
        loadToken = token

        // getAddressList's balance fetch is now a single batched gRPC call (see
        // ColdStorageManager), so addresses + balances are ready fast — show them immediately
        // instead of also waiting on the slower per-address "used" REST scan below, which was
        // making the whole list sit behind a spinner until every address (even the empty ones
        // discovery just found) had been checked one at a time.
        let baseEntries = await manager.getAddressList(for: currentAccount)
        guard loadToken == token else { return }
        if balancesOnly {
            // what the earlier checks found stays; an address that held coins before was used
            let usedBefore = Set(entries.filter { $0.everUsed || $0.balanceSompi > 0 }.map(\.address))
            let balanceBefore = Dictionary(entries.map { ($0.address, $0.balanceSompi) },
                                           uniquingKeysWith: { first, _ in first })
            entries = baseEntries.map { entry in
                var entry = entry
                if usedBefore.contains(entry.address) { entry.everUsed = true }
                return entry
            }.sorted { $0.index < $1.index }
            isLoading = false
            // Still probe the rows whose balance moved and the ones whose last probe failed, so
            // a just-used change address doesn't stay Unused until a pull (release audit C1).
            let toProbe = entries.filter { entry in
                !entry.everUsed && entry.balanceSompi == 0
                    && (balanceBefore[entry.address] != entry.balanceSompi
                        || unknownUsedAddresses.contains(entry.address))
            }.map(\.address)
            guard !toProbe.isEmpty else { return }
            var updates: [String: Bool] = [:]
            var stillUnknown: Set<String> = []
            for address in toProbe {
                let used = await ChatService.shared.spendingAddressUsedState(address)
                guard loadToken == token else { return }
                if let used { updates[address] = used } else { stillUnknown.insert(address) }
            }
            if updates.values.contains(true) {
                var updated = entries
                for idx in updated.indices where updates[updated[idx].address] == true {
                    updated[idx].everUsed = true
                }
                entries = updated
            }
            let probed = Set(toProbe)
            unknownUsedAddresses = unknownUsedAddresses.subtracting(probed).union(stillUnknown)
            return
        }
        // Keep what the earlier checks found until the probes below answer: getAddressList
        // reads every address as unused, so used-but-empty rows jumped into the Unused group
        // and back (smoothness audit L1).
        let usedEarlier = Set(entries.filter(\.everUsed).map(\.address))
        entries = baseEntries.map { entry in
            var entry = entry
            if usedEarlier.contains(entry.address) { entry.everUsed = true }
            return entry
        }.sorted { $0.index < $1.index }
        isLoading = false

        // Which quantum addresses have spent, putting their key on chain (the slashed shield).
        let quantum = baseEntries.filter(\.isQuantum).map(\.address)
        if !quantum.isEmpty {
            Task {
                var spent = Set<String>()
                for address in quantum where await ChatService.shared.quantumAddressSpentState(address) == true {
                    spent.insert(address.lowercased())
                }
                if loadToken == token { quantumSpentAddresses = spent }
            }
        }

        // Backfills the "Used"/"Unused" badge for zero-balance addresses in the background.
        // Sequential, not concurrent — same rate-limit reasoning as Manage Addresses'
        // spending-chain "used" check: a burst of simultaneous REST requests risked the host
        // rate-limiting and returning a degraded response that reads as "unused" when it isn't.
        // Guarded by loadToken so a stale backfill from an earlier call (e.g. before a pull-to-
        // refresh or Generate More triggers a fresh loadEntries()) can't clobber newer entries.
        //
        // Collected into `updates` and applied to `entries` in a single commit at the end rather
        // than once per address: mutating the published array on every single result was
        // re-rendering that row mid-backfill, which — if its "..." menu happened to be open at
        // that moment — visibly flickered/dismissed the open menu.
        // Tri-state per address: true/false = confirmed by a successful probe, nil = the probe
        // failed (network/rate-limit) - those rows keep their previous badge state and show a
        // neutral "Checking" instead of a possibly-wrong "Unused".
        var updates: [String: Bool] = [:]
        var failedProbes: Set<String> = []
        for entry in baseEntries where entry.balanceSompi == 0 {
            let used = await ChatService.shared.spendingAddressUsedState(entry.address)
            guard loadToken == token else { return }
            if let used {
                updates[entry.address] = used
            } else {
                failedProbes.insert(entry.address)
            }
        }
        guard loadToken == token else { return }
        if !updates.isEmpty {
            // One write. An address once used stays used: a probe reading "unused" after an
            // earlier "used" is a degraded answer, and flipping it would move the row.
            var updated = entries
            for idx in updated.indices {
                if let used = updates[updated[idx].address], used || !usedEarlier.contains(updated[idx].address) {
                    updated[idx].everUsed = used
                }
            }
            entries = updated
        }
        unknownUsedAddresses = failedProbes.filter { address in
            !(entries.first(where: { $0.address == address })?.everUsed ?? false)
        }

        // Contains-domain tags (.kachat names), after the rows are already visible.
        let addresses = baseEntries.map { $0.address }
        guard loadToken == token else { return }
        // the addresses holding a .kachat name
        let owners = await KachatNamesRegistry.shared.ownersOfNames(among: addresses)
        guard loadToken == token else { return }
        if domainOwningAddresses != owners { domainOwningAddresses = owners }
        lastFullLoad = Date()
    }

    /// Stamps the fresh hidden set onto the rows already loaded and adds any newly revealed
    /// indices (pager-derived addresses beyond what this screen had), so the list reflects
    /// the user's edits the moment they hit Done. The full loadEntries() that follows fills
    /// in balances/used. Mirrors Manage Addresses' applyVisibilityChangesInstantly.
    private func applyVisibilityChangesInstantly() {
        let hidden = manager.hiddenIndexSet(accountId: currentAccount.id)
        var updated = entries
        for i in updated.indices {
            updated[i].hidden = hidden.contains(updated[i].index)
        }
        let known = Set(updated.map(\.index))
        let maxIndex = currentAccount.maxAddressIndex
        if maxIndex >= 0 {
            for index in 0...maxIndex where !known.contains(index) && !hidden.contains(index) {
                guard let address = manager.address(for: currentAccount, at: index) else { continue }
                updated.append(ColdStorageAddressEntry(
                    index: index,
                    address: address,
                    balanceSompi: 0,
                    hidden: false
                ))
            }
        }
        entries = updated.sorted { $0.index < $1.index }
    }

    private func generateMore() {
        guard !isGenerating else { return }
        isGenerating = true
        Task {
            let index = await manager.lowestUnusedAddress(for: currentAccount)
            await loadEntries()
            isGenerating = false
            showToast(String(format: AppLocalization.string("Address #%d is ready."), locale: AppLocalization.locale, Int(index)))
        }
    }

    /// Pull down: every address holding a balance or a username, then a reload. The count shows
    /// under the Total Balance while it runs and the result as a toast.
    private func discoverAddresses() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        discoveryProgress = ColdStorageManager.DiscoveryProgress(checkingIndex: 0, foundCount: 0)
        let discovered = await manager.discoverAddresses(for: currentAccount) { progress in
            discoveryProgress = progress
        }
        await loadEntries()
        isDiscovering = false
        discoveryProgress = nil
        // The count is addresses that hold a balance or a .kachat name - say so, rather than
        // "used", which is what the old high-water-mark number implied and was not.
        let summary = discovered == 0
            ? AppLocalization.string("No addresses with a balance or username found.")
            : discovered == 1
                ? AppLocalization.string("Found 1 address with a balance or username.")
                : String(format: AppLocalization.string("Found %lld addresses with a balance or username."),
                         locale: AppLocalization.locale, discovered)
        showToast(summary)
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

/// White-background QR display for a single Cold Storage address, matching the same visual
/// treatment as ManageAddressesView's SpendingAddressQRView.
/// A Cold Storage address's receive page, on the shared receive screen (`AddressReceiveView`). Its
/// key is on the KasSigner, which signs Kaspa only, so kUSDT isn't for here.
private struct ColdStorageAddressQRView: View {
    let entry: ColdStorageAddressEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AddressReceiveView(
                title: AppLocalization.string("Receive Kaspa"),
                address: entry.address,
                addressLabel: entry.displayLabel,
                balanceLine: KaspaUnit.groupedAmount(entry.balanceSompi),
                privacyNote: ReceiveNote(kind: .info, text: AppLocalization.string("A Cold Storage address: its key is on your KasSigner, never on this phone.")),
                notes: [
                    ReceiveNotes.kaspaOnly,
                    ReceiveNote(kind: .warning, text: AppLocalization.string("Don't send kUSDT here: Cold Storage can't move it.")),
                ],
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

/// The full "send" round trip for one Cold Storage address: enter recipient/amount, build an
/// unsigned transaction, display it as a KSPT QR (animated if it needs multiple frames) for the
/// KasSigner device to scan, scan the signed response back, verify it matches what was sent for
/// signing, and broadcast. The engine (ColdStorageSendEngine) never sees a private key — signing
/// happens entirely on the physical device.
private struct ColdSendFlowView: View {
    let fromAddress: String
    let availableBalanceSompi: UInt64
    /// Pre-fills the recipient with `fromAddress` itself (a self-send) and auto-fills Max, for
    /// the "Compound UTXOs" entry point — merges every UTXO at this address into one. Locks the
    /// recipient field instead of just pre-filling it, since editing it away from `fromAddress`
    /// would defeat the point of a compound send.
    var isCompoundMode: Bool = false
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject private var portfolioViewModel = PortfolioViewModel.shared
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    /// After the form (To, Amount, Review): Build, then KasSigner signs it from the QR, the
    /// signed transaction is scanned back, and the last screen is swipe up to send, as in Send
    /// Kaspa (the BlockDAG, then Sent or Failed with Try Again).
    private enum Step {
        case form
        case building
        case showingQR(ColdStorageSendEngine.UnsignedColdTx, [Data])
        case scanning(ColdStorageSendEngine.UnsignedColdTx, [Data])
        case signed(ColdStorageSendEngine.UnsignedColdTx, [Data], KsptCodec.Decoded)
        case failed(String)
    }

    @State private var step: Step = .form
    /// The signed transaction going out (the swipe-up), and how it went.
    @State private var isBroadcasting = false
    @State private var broadcastError: String?
    @State private var sentTransaction: SentTransaction?
    @State private var toAddress = ""
    @State private var isValidAddress = false
    @State private var amountText = ""
    @State private var isEstimatingMax = false
    @State private var showRecipientScanner = false

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
        resolvedAddress ?? toAddress
    }

    /// True once we have a usable recipient - either a resolved KNS domain or a directly valid
    /// Kaspa address (mirrors WithdrawKaspaView.hasValidRecipient).
    private var hasValidRecipient: Bool {
        if resolvedAddress != nil { return true }
        return isValidAddress && !isResolvingKNS
    }
    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var customExtraFeeSompi: UInt64?
    @State private var isEditingFee = false
    @State private var feeEditorText = ""
    /// Fetched once when the screen appears and reused everywhere the fee needs computing (the
    /// form preview, the QR screen, and the actual build/broadcast) — rather than letting each of
    /// those independently call `fetchQuotedFeeRateSompiPerGram()` and each potentially get a
    /// different live quote, which was exactly why the fee shown before Build didn't match what
    /// the real transaction ended up costing.
    @State private var liveFeeRateSompiPerGram: UInt64?
    /// Coin control — nil means automatic (greedy, largest-first) selection; non-nil fixes the
    /// exact input set the user picked instead.
    @State private var manualUtxos: [UTXO]?
    @State private var showCoinControl = false
    /// Compound mode only: true when this address holds more UTXOs than one KasSigner transaction
    /// can merge at once (`KsptCodec.maxInputs`), so the user must run Compound again after this
    /// round. Drives the "repeat to finish" note.
    @State private var compoundHasMoreRounds = false
    /// Debounced live preview of what automatic selection would pick for the current amount/fee
    /// — see `schedulePreview()`. Non-nil only while it's still fresh for the current amount/fee;
    /// cleared immediately on any change so a stale preview never gets shown or built with.
    @State private var previewSelection: ColdStorageSendEngine.AutomaticSelectionPreview?
    @State private var previewTask: Task<Void, Never>?
    /// The quantum address this flow reserved for its change (or, compounding a quantum address,
    /// as the destination), handed back if the send never goes out.
    @State private var reservedChange: String?

    /// Sending from a KasSigner quantum-resistant (KCC-3) address: every coin goes, the change
    /// (or a compound) goes to another quantum address, and the request is KSPT 0x06.
    private var isQuantumSource: Bool { ColdStorageManager.isScriptHashAddress(fromAddress) }

    /// Compound into the address itself; a quantum address compounds into a fresh one instead.
    private var compoundsIntoItself: Bool { isCompoundMode && !isQuantumSource }

    /// The send's steps, as in Send Kaspa: who to, how much (on the app's keypad), and the
    /// review, where only the fee and coin control change before Build. Compound opens on the
    /// review (its recipient and amount are set).
    private enum FormStep: Int { case recipient, amount, review, fee }
    @State private var formStep: FormStep?
    @State private var formForward = true
    /// A step slide in progress (`StepSlideState`).
    @State private var stepSlide = StepSlideState()
    @State private var feeDraft = ""
    private var currentFormStep: FormStep {
        formStep ?? (isCompoundMode ? .review : .recipient)
    }

    private func go(to next: FormStep) {
        stepSlide.begin()
        dismissSystemKeyboard()
        formForward = next.rawValue > currentFormStep.rawValue
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { formStep = next }
        }
    }

    private var formTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: formForward ? .trailing : .leading),
                    removal: .move(edge: formForward ? .leading : .trailing))
    }

    private var amountSompi: UInt64? {
        guard let sompi = KaspaUnit.sompi(fromUserText: amountText), sompi > 0 else { return nil }
        return sompi
    }

    private var canBuild: Bool {
        hasValidRecipient && amountSompi != nil
    }

    /// Reference-mass fee shown/edited here, matching Android's ColdSendFlow: a fixed
    /// 1-input/2-standard-output mass when the input count isn't known yet (automatic selection,
    /// not resolved until build time) — good enough to reason about "pay more to confirm faster"
    /// without an extra network round trip just to populate this label. When coin control has
    /// fixed a UTXO set, though, the real count IS already known, so this uses that exact input
    /// count instead of guessing — otherwise the preview shown here could understate the real fee
    /// for a multi-UTXO selection, which then only became visible after tapping Build.
    private var referenceMass: UInt64 {
        guard let manualUtxos, !manualUtxos.isEmpty else {
            return ColdStorageSendEngine.referenceMassForFeeEditor
        }
        return ColdStorageSendEngine.calculateMass(numInputs: manualUtxos.count, outputScriptLens: [34, 34], payloadSize: 0)
    }

    /// Same live-or-minimum rate `ColdStorageSendEngine`'s own default falls back to — using it
    /// here too (instead of always assuming the bare protocol minimum) means the "Normal" preview
    /// matches what a nil-override build would actually charge whenever the network's live quote
    /// is currently above the minimum.
    private var baseFeeRateSompiPerGram: UInt64 {
        liveFeeRateSompiPerGram ?? KaspaFeePolicy.minimumRelayFeePerGramSompi
    }

    private var defaultFeeSompi: UInt64 {
        ColdStorageSendEngine.calculateFee(mass: referenceMass, rateSompiPerGram: baseFeeRateSompiPerGram)
    }

    /// Normal/Fast/Priority multiplier system, same inline (no separate screen) pattern as the
    /// main-address withdraw flow and Manage Addresses' consolidate flow — see
    /// `WithdrawFeeTier` and `WithdrawKaspaView`.
    private var extraFeeSompi: UInt64 {
        if let customExtraFeeSompi { return customExtraFeeSompi }
        return defaultFeeSompi * (feeTier.multiplier - 1)
    }

    /// The live preview (when fresh and automatic selection is in play — coin control already
    /// knows its exact count another way) takes priority over the reference-mass guess, since it
    /// reflects the real number of inputs this amount+fee will actually need.
    private var effectiveFeeSompi: UInt64 {
        if manualUtxos == nil, let previewSelection {
            return previewSelection.feeSompi
        }
        return defaultFeeSompi + extraFeeSompi
    }

    /// Converts the tier/custom-fee total back into the sompi-per-mass-gram rate
    /// `ColdStorageSendEngine` actually builds with. Always an explicit value now (never nil, even
    /// for plain Normal) — passing nil let the engine do its own separate live-quote fetch at
    /// build time, which could return a slightly different number than whatever this screen's own
    /// fetch showed moments earlier, and that drift was exactly why the fee after Build didn't
    /// match the one shown beforehand.
    private var feeRateOverride: UInt64? {
        guard feeTier != .normal || customExtraFeeSompi != nil else { return baseFeeRateSompiPerGram }
        return UInt64((Double(effectiveFeeSompi) / Double(referenceMass)).rounded(.up))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                switch step {
                case .form, .building:
                    formView
                case .showingQR(let unsignedTx, let frames), .scanning(let unsignedTx, let frames):
                    // the scanner is its own sheet below, over the QR
                    qrStep(unsignedTx: unsignedTx, frames: frames)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                case .signed(let unsignedTx, let frames, let decoded):
                    signedStep(unsignedTx: unsignedTx, frames: frames, decoded: decoded)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                case .failed(let message):
                    failedView(message: message)
                }
            }
            // Every screen draws its own header.
            .toolbar(.hidden, for: .navigationBar)
            .task {
                liveFeeRateSompiPerGram = await ColdStorageSendEngine.fetchQuotedFeeRateSompiPerGram()
                if isCompoundMode {
                    if isQuantumSource {
                        // Compounding reveals the key, so the merged coin must not stay here.
                        guard let fresh = await ColdStorageSendEngine.shared.freshQuantumChangeAddress(for: fromAddress) else {
                            step = .failed(ColdStorageSendEngine.ColdSendError.quantumCompoundNeedsFreshAddress.localizedDescription)
                            return
                        }
                        reservedChange = fresh
                        toAddress = fresh
                    } else {
                        toAddress = fromAddress
                    }
                    isValidAddress = true
                    await setupCompoundInputs()
                }
            }
            // Closed before the send went out: the change address goes back to the pool.
            .onDisappear {
                if sentTransaction == nil {
                    ColdStorageSendEngine.shared.releaseQuantumChange(reservedChange)
                    reservedChange = nil
                }
            }
            .sheet(isPresented: $showRecipientScanner) {
                QRScannerView { code in
                    handleScannedRecipient(code)
                }
            }
            .sheet(isPresented: isScanningSignedResponse) {
                if case .scanning(let unsignedTx, _) = step {
                    MultiFrameQRScannerView(isComplete: { KsptCodec.looksLikeKspt($0) }) { data in
                        handleScannedSignedResponse(data, unsignedTx: unsignedTx)
                    }
                }
            }
            .sheet(isPresented: $showCoinControl) {
                // the build leaves out immature mining rewards and coins a send just spent
                CoinControlView(fromAddress: fromAddress, initialSelection: manualUtxos,
                                unavailableReason: CoinControlView.hotWalletReason(chatting: false)) { selection in
                    manualUtxos = selection
                    schedulePreview()
                }
            }
        }
    }

    private var isScanningSignedResponse: Binding<Bool> {
        Binding(
            get: { if case .scanning = step { return true } else { return false } },
            // closed without a scan: back on the QR
            set: { if !$0, case .scanning(let tx, let frames) = step { step = .showingQR(tx, frames) } }
        )
    }

    private var formView: some View {
        ZStack {
            switch currentFormStep {
            case .recipient: recipientStep.transition(formTransition)
            case .amount: amountStep.transition(formTransition)
            case .review: reviewStep.transition(formTransition)
            case .fee: feeStep.transition(formTransition)
            }
        }
        .ignoresKeyboardWhileSliding(stepSlide)
        // The recipient card only shows the lookup; this screen runs it.
        .onChange(of: toAddress) { handleInputChange($0) }
        .onChange(of: amountText) { _ in schedulePreview() }
        .onChange(of: feeTier) { _ in
            customExtraFeeSompi = nil
            isEditingFee = false
            schedulePreview()
        }
        .onChange(of: customExtraFeeSompi) { _ in schedulePreview() }
        .onChange(of: liveFeeRateSompiPerGram) { _ in schedulePreview() }
    }

    private var screenTitle: LocalizedStringKey {
        isCompoundMode ? "Compound UTXOs" : "Send from Cold Storage"
    }

    private var exceedsBalance: Bool {
        guard let amountSompi else { return false }
        return amountSompi > availableBalanceSompi
    }

    private var recipientStep: some View {
        SendStepScreen(title: Text(screenTitle), onCancel: { dismiss() }, canContinue: hasValidRecipient) {
            go(to: .amount)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SendStepQuestion(text: "Who are you sending to?")
                    SendRecipientCard(
                        input: $toAddress,
                        isResolving: isResolvingKNS,
                        resolvedAddress: resolvedAddress,
                        resolvedName: resolvedDomain,
                        lookupError: knsError,
                        isValidAddress: isValidAddress,
                        onScan: { showRecipientScanner = true },
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

    private var amountStep: some View {
        SendStepScreen(title: Text(screenTitle), onBack: { go(to: .recipient) }, onCancel: { dismiss() },
                       continueTitle: "Review", canContinue: canBuild && !exceedsBalance && !isEstimatingMax) {
            go(to: .review)
        } content: {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    SendStepChip(label: "To", value: resolvedDomain ?? effectiveAddress, isAddress: resolvedDomain == nil)
                    SendStepChip(label: "From", value: AppLocalization.string("Cold Storage"))
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                KaspaKeypadAmountEntry(
                    fiatAmountState: fiatAmountState,
                    onAmountChange: { amountText = $0 },
                    isEstimatingMax: isEstimatingMax,
                    maxEnabled: hasValidRecipient,
                    footnote: exceedsBalance
                        ? AppLocalization.string("This is more than the address you're sending from holds.")
                        : KaspaUnit.label(String(format: AppLocalization.string("Available: %@ KAS"),
                                                 locale: AppLocalization.locale, formatKasExact(availableBalanceSompi))),
                    footnoteIsError: exceedsBalance,
                    onMax: setMaxAmount
                )
            }
        }
    }

    private var reviewStep: some View {
        let isBuilding: Bool = { if case .building = step { return true } else { return false } }()
        // A tap, not a swipe: this only builds the transaction for KasSigner to sign.
        return SendStepScreen(title: Text(isCompoundMode ? "Compound UTXOs" : "Review"),
                              onBack: isCompoundMode ? nil : { go(to: .amount) },
                              onCancel: { dismiss() },
                              continueTitle: isBuilding ? "Building..." : "Build Unsigned Transaction",
                              canContinue: canBuild && !isBuilding) {
            buildTransaction()
        } content: {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Text(isCompoundMode ? "Consolidating" : "You're sending")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if let amountSompi {
                            Text(verbatim: "\(KaspaUnit.plain(amountSompi)) \(KaspaUnit.symbol)")
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

                    VStack(alignment: .leading, spacing: 14) {
                        reviewRow("To") {
                            if compoundsIntoItself {
                                Text("This address (consolidating)")
                            } else {
                                VStack(alignment: .trailing, spacing: 2) {
                                    if let resolvedDomain {
                                        Text(verbatim: resolvedDomain).fontWeight(.semibold)
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
                                Text("Cold Storage").fontWeight(.semibold)
                                Text(verbatim: "\(fromAddress.prefix(14))...\(fromAddress.suffix(6))")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }
                        }
                        Divider()
                        reviewRow("Total") {
                            if let amountSompi {
                                Text(verbatim: "~\(KaspaUnit.plain(amountSompi + effectiveFeeSompi)) \(KaspaUnit.symbol)")
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                            } else {
                                Text(verbatim: "—").foregroundColor(.secondary)
                            }
                        }
                    }
                    .font(.subheadline)
                    .padding(14)
                    .background(sendKaspaGlass(cornerRadius: 20))

                    if isCompoundMode {
                        Group {
                            if isQuantumSource {
                                Text("Moves all of this address's coins into one, at an unused quantum-resistant address of this account: this transaction puts this address's key on chain.")
                            } else if compoundHasMoreRounds {
                                Text("This address has more than \(KsptCodec.maxInputs) UTXOs. KasSigner can sign at most \(KsptCodec.maxInputs) inputs per transaction, so this merges the largest \(KsptCodec.maxInputs) into one. Run Compound again afterward to keep combining the rest.")
                            } else {
                                Text("Merges all of this address's UTXOs into a single one, so future sends need fewer inputs.")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    }

                    // Compound auto-manages its own input set (largest <=8, KasSigner's per-tx limit),
                    // so manual coin control is hidden there - it only applies to a normal send.
                    SendFeeControls(
                        feeTier: $feeTier,
                        isEditingFee: $isEditingFee,
                        customFeeText: $feeEditorText,
                        isEstimatingFee: false,
                        feeText: "~\(KaspaUnit.plain(effectiveFeeSompi)) \(KaspaUnit.symbol)",
                        onStartEditing: {},
                        onCommit: {},
                        // A quantum source spends every coin (none may stay behind its revealed key),
                        // so there is nothing to pick there either.
                        showsCoinControl: !isCompoundMode && !isQuantumSource,
                        coinControlSummary: coinControlSummary(manualUtxos),
                        onCoinControl: { showCoinControl = true },
                        onEditFee: {
                            feeDraft = KaspaUnit.plain(effectiveFeeSompi)
                            go(to: .fee)
                        }
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
    }

    private var feeStep: some View {
        SendFeeEditorScreen(draft: $feeDraft, minimumSompi: defaultFeeSompi,
                            onCancel: { go(to: .review) }) { typed in
            // never under the network's minimum
            customExtraFeeSompi = typed > defaultFeeSompi ? typed - defaultFeeSompi : 0
            go(to: .review)
        }
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

    /// Commits the manually-typed total fee. Values below the tier-computed baseline are clamped
    /// up to zero extra rather than rejected outright, matching the main-address withdraw
    /// flow's identical `commitCustomFee()`.
    private func commitCustomFee() {
        defer { isEditingFee = false }
        guard let totalSompi = KaspaUnit.sompi(fromUserText: feeEditorText) else { return }
        customExtraFeeSompi = totalSompi > defaultFeeSompi ? totalSompi - defaultFeeSompi : 0
    }

    /// Sign: the unsigned transaction as an animated QR for KasSigner, on literal white
    /// regardless of dark mode - a dark surround gives a camera photographing this screen far
    /// less contrast around the code (see ChattingAddressQRView/ColdStorageAddressQRView).
    /// Continue opens the scanner for the signed transaction.
    private func qrStep(unsignedTx: ColdStorageSendEngine.UnsignedColdTx, frames: [Data]) -> some View {
        SendStepScreen(title: Text("Sign with KasSigner"), onBack: { withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { step = .form } },
                       onCancel: { dismiss() }, continueTitle: "Scan Signed Transaction", canContinue: true) {
            step = .scanning(unsignedTx, frames)
        } content: {
            ScrollView {
                VStack(spacing: 18) {
                    SendStepQuestion(text: "Scan this on your KasSigner")
                    // its own white card (a QR needs the contrast in dark mode too)
                    AnimatedQRDisplayView(frames: frames, displaySize: 280)
                    Text("KasSigner shows what it is signing. Check it matches, sign, then scan the signed transaction it shows.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    summaryCard(amountSompi: builtAmount(unsignedTx), feeSompi: unsignedTx.feeSompi)
                    if unsignedTx.isQuantumSource {
                        quantumSendNote(unsignedTx)
                        if unsignedTx.quantumUnitIndex != nil {
                            signWithoutNumberButton(unsignedTx)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
    }

    /// What is different about a send from a quantum-resistant address: the unit must know KCC-3,
    /// every coin goes (this spend puts the address's key on chain), and where the change goes -
    /// named here, since KasSigner marks it as change only for its change addresses #0-4.
    private func quantumSendNote(_ unsignedTx: ColdStorageSendEngine.UnsignedColdTx) -> some View {
        // A quantum compound's only output is the fresh address it moves to.
        let ownOutput: String? = isCompoundMode ? effectiveAddress : unsignedTx.changeAddress
        return VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Needs KasSigner v1.1 or later, which signs quantum-resistant (KCC-3) addresses.")
            } icon: {
                Image(systemName: "shield")
            }
            if unsignedTx.coinsLeftBehind > 0 {
                Label {
                    Text(String(format: AppLocalization.string("This address holds more coins than one transaction can spend: %lld stay behind the key this send puts on chain. Send them on in another transaction right after."),
                                locale: AppLocalization.locale, Int64(unsignedTx.coinsLeftBehind)))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
            }
            if let ownOutput {
                let record = ColdStorageManager.shared.quantumAddressRecord(ownOutput)?.entry
                let marked = record?.unitMarksAsChange ?? false
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isCompoundMode ? "The coins move to your quantum address:" : "The change goes to your quantum address:")
                        Text(verbatim: ColdStorageManager.shared.quantumDisplayLabel(of: ownOutput) ?? AppLocalization.string("Quantum Address"))
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        Text(verbatim: "\(ownOutput.prefix(14))...\(ownOutput.suffix(8))")
                            .font(.caption.monospaced())
                        if marked {
                            Text("KasSigner shows this output as change.")
                        } else {
                            Text("KasSigner will show this output as an ordinary payment, not as change: check it is this address before you sign.")
                                .foregroundColor(.orange)
                        }
                    }
                } icon: {
                    Image(systemName: "arrow.uturn.down")
                }
            }
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(glassBackground(cornerRadius: 14))
    }

    /// The request names the address's number on the unit. A wrong one (or the wrong chain)
    /// makes the unit refuse it; this shows the same transaction again with no number, and the
    /// unit searches its quantum addresses itself.
    private func signWithoutNumberButton(_ unsignedTx: ColdStorageSendEngine.UnsignedColdTx) -> some View {
        VStack(spacing: 6) {
            Button {
                var withoutHint = unsignedTx
                withoutHint.quantumUnitIndex = nil
                do {
                    let frames = try QrFrameChunker.chunk(ColdStorageSendEngine.shared.toKspt(withoutHint))
                    step = .showingQR(withoutHint, frames)
                } catch {
                    step = .failed(error.localizedDescription)
                }
            } label: {
                Text("Sign Without the Address Number")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundColor(.accentColor)
                    .background(glassBackground(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            Text("If KasSigner refuses this request, the address number may be wrong. Without it, the unit looks for the address itself. Edit Address Number puts it right for next time.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// Signed and scanned back: the last look, then swipe up to send it - the BlockDAG, then Sent
    /// with the transaction, or Failed with Try Again (back here, still signed).
    private func signedStep(unsignedTx: ColdStorageSendEngine.UnsignedColdTx, frames: [Data],
                            decoded: KsptCodec.Decoded) -> some View {
        SwipeUpToSendScrollView(
            screenTitle: isCompoundMode ? "Compound UTXOs" : "Send from Cold Storage",
            onCancel: { dismiss() },
            onBack: { step = .showingQR(unsignedTx, frames) },
            title: isCompoundMode ? "Swipe up to Consolidate" : "Swipe up to Send",
            isBusy: isBroadcasting,
            isEnabled: !isBroadcasting && sentTransaction == nil,
            amountSompi: builtAmount(unsignedTx),
            recipient: isCompoundMode ? nil : (resolvedDomain ?? effectiveAddress),
            sent: sentTransaction,
            failureMessage: broadcastError,
            onDone: {
                onDone()
                dismiss()
            },
            action: { broadcast(unsignedTx: unsignedTx, decoded: decoded) }
        ) {
            VStack(spacing: 18) {
                Label("Signed by KasSigner", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.green)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
                    .padding(.top, 8)
                VStack(spacing: 6) {
                    Text(isCompoundMode ? "Consolidating" : "You're sending")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if let amountSompi = builtAmount(unsignedTx) {
                        Text(verbatim: "\(KaspaUnit.plain(amountSompi)) \(KaspaUnit.symbol)")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                }
                .frame(maxWidth: .infinity)
                summaryCard(amountSompi: builtAmount(unsignedTx), feeSompi: unsignedTx.feeSompi)
                Text("Nothing can change now: this is the transaction KasSigner signed.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    /// What the built transaction pays the recipient: its first output, which a Max or a
    /// near-Max amount may have trimmed below what was typed.
    private func builtAmount(_ unsignedTx: ColdStorageSendEngine.UnsignedColdTx) -> UInt64? {
        unsignedTx.transaction.outputs.first?.value ?? amountSompi
    }

    /// To, From, the fee and the total, as built.
    private func summaryCard(amountSompi: UInt64?, feeSompi: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            reviewRow("To") {
                if compoundsIntoItself {
                    Text("This address (consolidating)")
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let resolvedDomain {
                            Text(verbatim: resolvedDomain).fontWeight(.semibold)
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
                    Text("Cold Storage").fontWeight(.semibold)
                    Text(verbatim: "\(fromAddress.prefix(14))...\(fromAddress.suffix(6))")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
            }
            Divider()
            reviewRow("Network Fee") {
                Text(verbatim: "\(KaspaUnit.plain(feeSompi)) \(KaspaUnit.symbol)")
                    .monospacedDigit()
            }
            if let amountSompi {
                Divider()
                reviewRow("Total") {
                    Text(verbatim: "\(KaspaUnit.plain(amountSompi + feeSompi)) \(KaspaUnit.symbol)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            }
        }
        .font(.subheadline)
        .padding(14)
        .background(sendKaspaGlass(cornerRadius: 20))
    }

    /// Building failed (or the compound inputs couldn't be read): what went wrong, and Try Again
    /// back to the form as it was.
    private func failedView(message: String) -> some View {
        SendStepScreen(title: Text(screenTitle), onCancel: { dismiss() }, continueTitle: "Try Again", canContinue: true) {
            step = .form
        } content: {
            VStack(spacing: 16) {
                Spacer(minLength: 40)
                Image(systemName: "xmark.circle.fill")
                    .font(.scaled(size: 56))
                    .foregroundColor(.red)
                Text("Something Went Wrong")
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func handleScannedRecipient(_ code: String) {
        var address = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.lowercased().hasPrefix("kaspa:") || address.lowercased().hasPrefix("kaspatest:") {
            if let queryIndex = address.firstIndex(of: "?") {
                address = String(address[..<queryIndex])
            }
        }
        toAddress = address
        handleInputChange(address)
    }

    private func handleInputChange(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

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

        if trimmed.hasPrefix("kaspa:") || trimmed.hasPrefix("kaspatest:") {
            isValidAddress = KaspaAddress.isValid(trimmed)
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
        guard let address = resolution.address else { return }
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

            guard toAddress.trimmingCharacters(in: .whitespacesAndNewlines) == domain else {
                return
            }

            // Every name service, in priority: the ending typed, else .kachat only (the others wait under Other domains)
            // (see NameServicesClient). The resolved line names which one answered; the others
            // are offered under "Other domains".
            let results = await NameServicesClient.shared.resolveEverywhere(domain)
            await MainActor.run {
                guard toAddress.trimmingCharacters(in: .whitespacesAndNewlines) == domain else { return }
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

    /// Debounced (400ms) live preview of what automatic selection would pick for the current
    /// amount + fee rate — cancels and restarts on every relevant change so a burst of typing
    /// doesn't fire a network call per keystroke, and clears the stale preview immediately (rather
    /// than leaving the last one showing) so the fee display never claims to be exact when it
    /// isn't anymore. No-ops entirely once coin control is active — that already knows its exact
    /// count without needing a preview fetch.
    private func schedulePreview() {
        previewTask?.cancel()
        previewSelection = nil
        guard manualUtxos == nil, let amountSompi else { return }
        let rate = feeRateOverride ?? baseFeeRateSompiPerGram
        let recipient = effectiveAddress
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let preview = await ColdStorageSendEngine.shared.previewAutomaticSelection(
                fromAddress: fromAddress,
                toAddress: recipient,
                amountSompi: amountSompi,
                feeRateSompiPerGram: rate
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                previewSelection = preview
            }
        }
    }

    /// Compound mode: fix the input set to the largest <=8 UTXOs — the most one KasSigner-signable
    /// transaction can hold — then Max the amount for exactly that set. Without this cap, Max spans
    /// every UTXO at the address and the build fails with `tooManyInputs` the moment it holds more
    /// than 8. `compoundHasMoreRounds` records whether another round is needed afterward.
    private func setupCompoundInputs() async {
        do {
            let (utxos, hasMore) = try await ColdStorageSendEngine.shared.compoundInputs(fromAddress: fromAddress)
            manualUtxos = utxos
            compoundHasMoreRounds = hasMore
            setMaxAmount()
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    private func setMaxAmount() {
        guard hasValidRecipient else { return }
        isEstimatingMax = true
        let overrideRate = feeRateOverride
        let utxos = manualUtxos
        let recipient = effectiveAddress
        Task {
            do {
                let maxSompi = try await ColdStorageSendEngine.shared.estimateMaxAmount(fromAddress: fromAddress, toAddress: recipient, feeRateOverride: overrideRate, manualUtxos: utxos)
                await MainActor.run {
                    amountText = fiatAmountState.setMaxKas(Double(maxSompi) / 100_000_000.0, priceInCurrency: portfolioViewModel.currentPriceUsd)
                    isEstimatingMax = false
                }
            } catch {
                await MainActor.run {
                    isEstimatingMax = false
                }
            }
        }
    }

    private func buildTransaction() {
        guard let amountSompi else { return }
        step = .building

        let recipient = effectiveAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let overrideRate = feeRateOverride
        // Real coin control (explicit user selection) wins if set; otherwise, if a fresh
        // automatic-selection preview is available, pass its exact UTXO set through as the
        // build's `manualUtxos` too — guaranteeing the fee just shown on this screen and the fee
        // the real build produces are the same number, not just close. Re-resolved against a
        // fresh fetch inside buildUnsignedTransaction either way, so this is never stale-unsafe.
        let utxos = manualUtxos ?? previewSelection?.utxos
        let previewed = manualUtxos == nil && previewSelection != nil
        let quantumRecord = ColdStorageManager.shared.quantumAddressRecord(fromAddress)
        let compound = isCompoundMode
        let engine = ColdStorageSendEngine.shared
        Task {
            do {
                // A quantum source's change goes to a fresh quantum address of the account: this
                // spend makes the source's key public, and the build refuses change back to it.
                // A rebuild hands the earlier pick back and chooses again. (A quantum compound's
                // destination was reserved when the flow opened and stays.)
                var changeAddress: String?
                if quantumRecord != nil && !compound {
                    engine.releaseQuantumChange(reservedChange)
                    changeAddress = await engine.freshQuantumChangeAddress(for: fromAddress)
                    reservedChange = changeAddress
                }
                let unsignedTx = try await engine.buildUnsignedTransaction(
                    fromAddress: fromAddress,
                    toAddress: recipient,
                    amountSompi: amountSompi,
                    feeRateOverride: overrideRate,
                    manualUtxos: utxos,
                    previewed: previewed,
                    changeAddress: changeAddress,
                    quantumUnitIndex: quantumRecord?.entry.unitIndex,
                    quantumUnitChain: quantumRecord?.entry.chain ?? .receive
                )
                // No change after all (a Max send): the address isn't taken.
                if !compound, let changeAddress, unsignedTx.changeAddress == nil {
                    engine.releaseQuantumChange(changeAddress)
                    reservedChange = nil
                }
                let kspt = try engine.toKspt(unsignedTx)
                let frames = try QrFrameChunker.chunk(kspt)
                await MainActor.run {
                    step = .showingQR(unsignedTx, frames)
                }
            } catch {
                if !compound {
                    engine.releaseQuantumChange(reservedChange)
                    reservedChange = nil
                }
                await MainActor.run {
                    step = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func handleScannedSignedResponse(_ data: Data, unsignedTx: ColdStorageSendEngine.UnsignedColdTx) {
        guard case .scanning(_, let frames) = step else { return }
        do {
            let decoded = try KsptCodec.decode(data)
            broadcastError = nil
            sentTransaction = nil
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                step = .signed(unsignedTx, frames, decoded)
            }
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    /// The swipe let go: the signed transaction goes out.
    private func broadcast(unsignedTx: ColdStorageSendEngine.UnsignedColdTx, decoded: KsptCodec.Decoded) {
        isBroadcasting = true
        broadcastError = nil
        Task {
            do {
                try await SendFailureSimulation.failIfEnabled()
                let txId = try await ColdStorageSendEngine.shared.broadcastSigned(unsignedTx: unsignedTx, decoded: decoded)
                // The quantum address that took the change (or the compound) is used now.
                if unsignedTx.isQuantumSource {
                    ColdStorageSendEngine.shared.noteQuantumChangeSent(isCompoundMode ? reservedChange : unsignedTx.changeAddress)
                }
                await MainActor.run {
                    isBroadcasting = false
                    sentTransaction = SentTransaction(
                        txId: txId,
                        amountSompi: isCompoundMode ? nil : builtAmount(unsignedTx),
                        recipient: isCompoundMode ? nil : (resolvedDomain ?? effectiveAddress)
                    )
                }
            } catch {
                await MainActor.run {
                    isBroadcasting = false
                    broadcastError = error.localizedDescription
                }
            }
        }
    }
}

/// Coin control — lets the user fix the exact UTXO set a send spends from instead of the
/// automatic largest-first selector. Reachable from a send form's "UTXO Selection" card - shared by
/// `ColdSendFlowView` and `SpendingAddressWithdrawView` (not Cold-Storage-specific: it fetches
/// via the generic `NodePoolService.shared.getUtxosByAddresses`, keyed only by `fromAddress`).
/// Passes the selection back as a plain `[UTXO]?` (nil = automatic) rather than owning any state
/// itself, since the actual spendable set needs re-resolving against a fresh fetch at build time
/// anyway (see `ColdStorageSendEngine.buildUnsignedTransaction`'s `manualUtxos` handling).
struct CoinControlView: View {
    let fromAddress: String
    let initialSelection: [UTXO]?
    /// Why a send can't spend a coin, nil when it can: the same coins the send leaves out, listed
    /// greyed out and never picked, so a selection can't be made of coins the send would refuse.
    /// The second value is the network's virtual DAA score, when known, for mining-reward maturity.
    var unavailableReason: ((UTXO, UInt64?) -> LocalizedStringKey?)? = nil
    let onDone: ([UTXO]?) -> Void

    /// A hot-wallet send's rule (`ChatService.withdrawalSpendable` for the chatting address;
    /// `spendableUtxos` and `unreservedUtxos` for a spending address, which can spend a mining
    /// reward once it's mature).
    static func hotWalletReason(chatting: Bool) -> (UTXO, UInt64?) -> LocalizedStringKey? {
        { utxo, virtualDaaScore in
            if utxo.covenantId != nil { return "Locked by a covenant" }
            if chatting, utxo.isCoinbase { return "Mining reward, not spendable here" }
            if chatting, utxo.blockDaaScore == 0 { return "Not confirmed yet" }
            if !chatting, ChatService.spendableUtxos([utxo], virtualDaaScore: virtualDaaScore).isEmpty {
                return "Not spendable yet"
            }
            if ChatService.shared.unreservedUtxos([utxo]).isEmpty { return "Just spent by a send" }
            return nil
        }
    }
    @State private var virtualDaaScore: UInt64?

    @Environment(\.dismiss) private var dismiss
    @State private var utxos: [UTXO] = []
    @State private var selectedKeys: Set<String> = []
    @State private var isLoading = false
    /// The node could not be asked. Shown in place of "no coins": an outage must never read as
    /// an empty address when the coins here are about to be spent.
    @State private var loadError: String?
    @State private var utxoLabels: [String: String] = [:]

    private func loadUtxos() async {
        isLoading = true
        do {
            let fetched = try await NodePoolService.shared.getUtxosByAddresses([fromAddress])
            // only needed to tell a mature mining reward from one that isn't yet
            if fetched.contains(where: \.isCoinbase) {
                virtualDaaScore = await NodePoolService.shared.currentVirtualDaaScore()
            }
            utxos = fetched
            loadError = nil
        } catch {
            loadError = UserFacingError.message(for: error)
        }
        isLoading = false
    }

    private func key(_ utxo: UTXO) -> String {
        "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)"
    }

    private var availableUtxos: [UTXO] {
        guard let unavailableReason else { return utxos }
        return utxos.filter { unavailableReason($0, virtualDaaScore) == nil }
    }

    private var selectedTotalSompi: UInt64 {
        availableUtxos.filter { selectedKeys.contains(key($0)) }.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading && utxos.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if utxos.isEmpty {
                    if let loadError {
                        UtxoLoadFailureRow(detail: loadError) {
                            Task { await loadUtxos() }
                        }
                    } else {
                        Text("No UTXOs found at this address.")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section {
                        ForEach(Array(utxos.enumerated()), id: \.offset) { _, utxo in
                            let k = key(utxo)
                            let isSelected = selectedKeys.contains(k)
                            let unavailable = unavailableReason?(utxo, virtualDaaScore)
                            Button {
                                if isSelected {
                                    selectedKeys.remove(k)
                                } else {
                                    selectedKeys.insert(k)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(isSelected ? .accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        if let label = utxoLabels[k], !label.isEmpty {
                                            Text(label)
                                                .font(.caption)
                                                .fontWeight(.bold)
                                                .foregroundColor(.accentColor)
                                        }
                                        Text(verbatim: "\(formatKasExact(utxo.amount)) \(KaspaUnit.symbol)")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.primary)
                                        Text("\(utxo.outpoint.transactionId.prefix(10))...:\(utxo.outpoint.index)")
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(.secondary)
                                        if let unavailable {
                                            Text(unavailable)
                                                .font(.caption2)
                                                .foregroundColor(.orange)
                                        }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(unavailable != nil)
                            .opacity(unavailable == nil ? 1 : 0.5)
                        }
                    } footer: {
                        if !selectedKeys.isEmpty {
                            let amount = "\(formatKasExact(selectedTotalSompi)) \(KaspaUnit.symbol)"
                            Text(verbatim: selectedKeys.count == 1
                                 ? String(format: AppLocalization.string("Selected: %@ (1 UTXO)"), locale: AppLocalization.locale, amount)
                                 : String(format: AppLocalization.string("Selected: %@ (%lld UTXOs)"), locale: AppLocalization.locale, amount, selectedKeys.count))
                        }
                    }
                }
            }
            .navigationTitle("UTXO Selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Select All") { selectedKeys = Set(availableUtxos.map(key)) }
                        Button("Automatic (Clear Selection)") { selectedKeys.removeAll() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    let selected = availableUtxos.filter { selectedKeys.contains(key($0)) }
                    onDone(selected.isEmpty ? nil : selected)
                    dismiss()
                } label: {
                    Text(selectedKeys.isEmpty ? "Use Automatic Selection" : "Confirm Selection")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .task {
                // a spending address's labels (Manage Addresses) or a KasSigner address's
                utxoLabels = WalletManager.shared.loadSpendingUtxoLabels(address: fromAddress)
                    .merging(ColdStorageManager.shared.loadUtxoLabels(address: fromAddress)) { spending, _ in spending }
                await loadUtxos()
                if let initialSelection {
                    // coins spent since they were picked drop out of the selection
                    selectedKeys = Set(initialSelection.map(key)).intersection(Set(availableUtxos.map(key)))
                }
            }
        }
    }
}

/// Transaction history for a single Cold Storage address, opening each transaction directly on
/// whichever block explorer is selected in Settings > Connection > Kaspa Explorer.
struct ColdStorageAddressTransactionHistoryView: View {
    let entry: ColdStorageAddressEntry

    /// The tapped transaction, while its action chooser is up.
    @State private var transactionActionTarget: KaspaFullTransactionResponse?
    @State private var pendingPortfolioCandidate: PortfolioCandidateTransaction?
    /// The transaction being filed into a portfolio, if any - see `AddToPortfolioSheet`.
    @State private var portfolioCandidate: PortfolioCandidateTransaction?
    /// Name of the portfolio just added to, for the confirmation capsule.
    @State private var addedPortfolioName: String?

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
    @State private var showCompoundSheet = false
    @State private var showAddressActions = false
    @State private var showPublicKeySheet = false
    /// What the Address Actions row picked opens, once that sheet has finished closing.
    @State private var afterAddressActions: (() -> Void)?
    @State private var utxoLabels: [String: String] = [:]
    @State private var renamingUtxo: UTXO?
    @State private var renameUtxoText = ""
    /// This account's addresses (lowercased), for telling change to its own addresses apart
    /// from what was sent; loaded once, not per row.
    @State private var accountAddresses: Set<String> = []

    private func outpointKey(_ utxo: UTXO) -> String {
        "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)"
    }

    /// Compound on a quantum address moves its coins to another quantum address of the account
    /// (the merge puts its key on chain), so it's offered only when the account has another.
    private var canCompound: Bool {
        guard entry.isQuantum else { return true }
        return (ColdStorageManager.shared.quantumAddressRecord(entry.address)?.account.quantumAddresses.count ?? 0) > 1
    }

    /// Plain names - History, UTXOs, Domains - the way the user asked for them.
    /// The .kachat page is called Usernames (owner, 2026-11-24), like the Wallet's card.
    private func tabLabel(_ tab: Tab) -> String {
        tab == .kachatDomains ? "Usernames" : tab.rawValue
    }

    var body: some View {
        VStack(spacing: 0) {
            // The same balance card as a Manage Addresses address's page (owner, 2026-11-22):
            // the address's name, its balance large, and its worth in your currency.
            // The full address on the card (owner, 2026-11-27, as Manage Addresses' pages): the
            // account's cards no longer show it.
            KaspaAddressBalanceCard(label: entry.displayLabel, address: entry.address, sompi: entry.balanceSompi)

            // The app's page switch (`PageCycleBar`), not a segmented control.
            PageCycleBar(
                tabs: Tab.allCases.map { (tab: $0, title: tabLabel($0)) },
                selection: $selectedTab
            )
            .padding(.top, 4)

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
            // no View Private Key: a cold address's key stays on the signer
            let sheet = AddressActionsSheet(
                explorerURL: settingsViewModel.settings.kaspaExplorer.addressURL(for: entry.address),
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
                .fittedSheetDetents(sheet.height)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPublicKeySheet) {
            AddressPublicKeyView(address: entry.address, note: "This is the public half of this address. It cannot spend anything.")
        }
        // Send and Receive are on the account's card for this address (owner, 2026-11-27), as on
        // Manage Addresses.
        .sheet(isPresented: $showCompoundSheet) {
            ColdSendFlowView(fromAddress: entry.address, availableBalanceSompi: entry.balanceSompi, isCompoundMode: true) {
                Task {
                    await loadTransactions()
                    await loadUtxos()
                }
            }
            .sendKaspaSheetSizing()
        }
        .sheet(item: $renamingUtxo) { utxo in
            RenameSheet(
                title: "Rename UTXO",
                subtitle: outpointKey(utxo),
                text: $renameUtxoText
            ) { newName in
                ColdStorageManager.shared.setUtxoLabel(
                    address: entry.address,
                    outpointKey: outpointKey(utxo),
                    label: newName
                )
                utxoLabels = ColdStorageManager.shared.loadUtxoLabels(address: entry.address)
            }
        }
        // not on every Hub tab selection while Cold Storage is kept hidden (audit 2026-11-24 #23)
        .onScreenPresence(appear: {
            Task {
                utxoLabels = ColdStorageManager.shared.loadUtxoLabels(address: entry.address)
                accountAddresses = await ColdStorageManager.shared.accountAddresses(containing: entry.address)
                await loadTransactions()
                await loadUtxos()
            }
        }, disappear: {})
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
                        // Tapping a transaction asks what to do with it. It used to open the
                        // explorer outright, which left "Add to Portfolio" on a swipe and a long
                        // press - both invisible until you already knew they were there.
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
        .sheet(item: $transactionActionTarget, onDismiss: {
            // Handing the portfolio sheet over only once this one is fully gone. Presenting a
            // sheet from inside a sheet that is still dismissing drops it on the floor.
            if let pending = pendingPortfolioCandidate {
                pendingPortfolioCandidate = nil
                portfolioCandidate = pending
            }
        }) { tx in
            TransactionActionsSheet(
                transaction: tx,
                address: entry.address,
                onOpenExplorer: { openInExplorer(tx) },
                onAddToPortfolio: { pendingPortfolioCandidate = $0 }
            )
        }
        .sheet(item: $portfolioCandidate) { candidate in
            AddToPortfolioSheet(candidate: candidate) { portfolio in
                addedPortfolioName = portfolio.name
            }
        }
        .overlay(alignment: .bottom) {
            if let addedPortfolioName {
                PortfolioAddedCapsule(portfolioName: addedPortfolioName) {
                    self.addedPortfolioName = nil
                }
            }
        }
        .refreshable {
            await loadTransactions()
        }
    }

    private var utxosList: some View {
        List {
            if utxos.count > 1, canCompound {
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
                    if entry.isQuantum {
                        Text("Combines all UTXOs at this address into one at an unused quantum-resistant address of this account, since this puts this address's key on chain.")
                    } else {
                        Text("Combines all UTXOs at this address into a single one, to reduce the number of inputs a future send needs.")
                    }
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
                Text(verbatim: "\(KaspaUnit.groupedExact(utxo.amount)) \(KaspaUnit.symbol)")
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

    private func transactionRow(_ tx: KaspaFullTransactionResponse) -> some View {
        var info = tx.direction(for: entry.address)
        // What left the account, not every output to others: change to another of the account's
        // addresses (a quantum send's change goes to a fresh quantum address) is its own, and a
        // swap also spends a pool's coins. All of it to the account's own addresses is Moved.
        var moved = false
        if info?.isOutgoing == true {
            let this = entry.address.lowercased()
            let own = accountAddresses
            var toOthers: UInt64 = 0
            var ownChange: UInt64 = 0
            for output in tx.outputs {
                let to = output.scriptPublicKeyAddress?.lowercased() ?? this
                if to == this { continue }
                if own.contains(to) { ownChange &+= output.amount } else { toOthers &+= output.amount }
            }
            if let result = tx.ownHistoryAmount(for: entry.address, toOthers: toOthers, ownChange: ownChange,
                                                isOwnAddress: { own.contains($0) }) {
                info = (result.isOutgoing, result.amountSompi)
            }
            if info?.isOutgoing == true, toOthers == 0, ownChange > 0 {
                moved = true
                info = (true, ownChange)
            }
        }
        let tint: Color = info == nil || moved ? .secondary : (info!.isOutgoing ? .red : .green)
        return HStack(spacing: 12) {
            Image(systemName: moved ? "arrow.left.arrow.right.circle.fill"
                  : (info?.isOutgoing == true ? "arrow.up.circle.fill" : "arrow.down.circle.fill"))
                .font(.title2)
                .foregroundColor(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(info == nil ? "Transaction" : (moved ? "Moved" : (info!.isOutgoing ? "Sent" : "Received")))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(tint)
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
                    Text(verbatim: "\(moved ? "" : (info.isOutgoing ? "-" : "+"))\(KaspaUnit.groupedExact(info.amountSompi)) \(KaspaUnit.symbol)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(tint)
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
        let result = await ChatService.shared.fetchFullTransactionsResult(for: entry.address, pageSize: 200, maxTransactions: 200)
        // block rewards the chain never accepted paid nothing: not history
        transactions = result.transactions.filter(\.belongsInHistory)
        historyIncomplete = !result.complete
        isLoading = false
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

    private func openInExplorer(_ tx: KaspaFullTransactionResponse) {
        guard let url = settingsViewModel.settings.kaspaExplorer.txURL(for: tx.transactionId) else { return }
        UIApplication.shared.open(url)
    }
}

/// Bulk address-visibility checklist for one cold storage account: a paged list of EVERY
/// derived address (and, past the derived set, future indices derived on the fly) with a
/// whole-row check toggle. Mirrors Manage Addresses' SpendingAddressVisibilityView minus
/// the primary-address concept, which cold storage doesn't have.
private struct ColdStorageAddressVisibilityView: View {
    let account: ColdStorageAccount

    @ObservedObject private var manager = ColdStorageManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ColdStorageAddressEntry] = []
    @State private var isLoading = true
    /// Lazily-filled history results for zero-balance addresses (address -> ever used).
    @State private var usedByAddress: [String: Bool] = [:]
    /// Pager: 50 addresses per page, endless - pages past the derived set derive future
    /// indices on the fly (checking one reveals it without flooding the main list).
    @State private var page = 0
    private let pageSize = 50
    private static let topAnchorID = "visibility_top"

    private var currentAccount: ColdStorageAccount {
        manager.accounts.first { $0.id == account.id } ?? account
    }

    /// The account's scanned quantum-resistant addresses, listed apart from the pager.
    private var quantumEntries: [ColdStorageAddressEntry] {
        entries.filter(\.isQuantum)
    }

    /// The rows for the current page, by raw index order. Derived indices come from the
    /// loaded entries; anything beyond derives its address fresh (underived = unchecked).
    private var pageEntries: [ColdStorageAddressEntry] {
        // The kpub's chain only: quantum entries sit at 1,000,000+ and have their own section.
        let byIndex = Dictionary(uniqueKeysWithValues: entries.filter { !$0.isQuantum }.map { ($0.index, $0) })
        let start = page * pageSize
        return (start..<(start + pageSize)).compactMap { index in
            if let existing = byIndex[index] { return existing }
            guard let address = manager.address(for: currentAccount, at: index) else { return nil }
            return ColdStorageAddressEntry(index: index, address: address, balanceSompi: 0, hidden: true)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && entries.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        List {
                            // A zero-height anchor rather than scrolling to the first row: the
                            // row has its own insets, and scrolling to it left the list a few
                            // points down from the true top.
                            Color.clear
                                .frame(height: 0)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .id(Self.topAnchorID)
                            if page == 0, !quantumEntries.isEmpty {
                                Section {
                                    ForEach(quantumEntries) { entry in
                                        row(entry)
                                    }
                                } header: {
                                    Text("Quantum-Resistant Addresses")
                                }
                                Section {
                                    ForEach(pageEntries) { entry in
                                        row(entry)
                                    }
                                } header: {
                                    Text("Addresses")
                                }
                            } else {
                                ForEach(pageEntries) { entry in
                                    row(entry)
                                }
                            }
                        }
                        .listStyle(.plain)
                        // Turning the page keeps the scroll offset otherwise, so page 2 opened
                        // wherever page 1 was left - at the bottom, if that is where the pager
                        // was tapped from, which is the only place it can be tapped from.
                        .onChange(of: page) { _ in
                            proxy.scrollTo(Self.topAnchorID, anchor: .top)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                pagerBar
            }
            .navigationTitle("Address Visibility")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task { await load() }
        }
    }

    /// Bottom pager: "#start - #end" with arrows; the right arrow never runs out (pages past
    /// the derived set derive future addresses).
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
            Text("#\(page * pageSize) - #\(page * pageSize + pageSize - 1)")
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

    private func row(_ entry: ColdStorageAddressEntry) -> some View {
        let funded = entry.balanceSompi > 0
        let visible = !entry.hidden
        return HStack(spacing: 10) {
            Image(systemName: visible ? "checkmark.circle.fill" : "circle")
                .font(.scaled(size: 20))
                .foregroundColor(visible ? .accentColor : .secondary)
                .opacity(funded ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if entry.isQuantum {
                        Image(systemName: "shield.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                        Text(verbatim: ColdQuantumAddress.defaultLabel(chain: entry.quantumChain, unitIndex: entry.unitIndex))
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                    } else {
                        Text("#\(entry.index)")
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
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
    private func usedTag(_ entry: ColdStorageAddressEntry, funded: Bool) -> some View {
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

    private func load() async {
        entries = await manager.getAddressList(for: currentAccount)
        isLoading = false
    }

    /// One history lookup per zero-balance address, cached for the session of this sheet.
    /// A failed probe stores nothing, so the row keeps its neutral "…" badge (never a
    /// possibly-wrong "Unused") and the next appearance of the row retries.
    private func ensureUsedLoaded(_ entry: ColdStorageAddressEntry, funded: Bool) async {
        guard !funded, usedByAddress[entry.address] == nil else { return }
        if let used = await ChatService.shared.spendingAddressUsedState(entry.address) {
            usedByAddress[entry.address] = used
        }
    }

    private func toggle(_ entry: ColdStorageAddressEntry) {
        // Funded rows don't toggle - mirrors the manager-side guard.
        guard entry.balanceSompi == 0 else { return }
        Task {
            // The kpub chain's highest derived index; quantum entries (1,000,000+) aren't on it.
            let derivedMax = entries.filter { !$0.isQuantum }.map(\.index).max() ?? -1
            if entry.isQuantum {
                guard let index = manager.currentQuantumIndex(of: entry.address, in: currentAccount) else { return }
                let ok = await manager.setAddressHidden(account: currentAccount, index: index, hidden: !entry.hidden)
                guard ok else { return }
                if let position = entries.firstIndex(where: { $0.id == entry.id }) {
                    entries[position].hidden.toggle()
                }
            } else if entry.index > derivedMax {
                // A derived future index from the endless pager: reveal exactly this one
                // (indices in between stay hidden so the main list doesn't flood).
                manager.revealAddress(for: currentAccount, at: entry.index)
                entries = await manager.getAddressList(for: currentAccount)
            } else {
                let ok = await manager.setAddressHidden(account: currentAccount, index: entry.index, hidden: !entry.hidden)
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


/// The kpub of one cold-storage account, as a QR for moving it to another device or a watch-only
/// wallet elsewhere.
///
/// Deliberately says what a kpub is. It holds no private key and cannot spend anything, which is
/// why it is safe to display at all - but it derives EVERY address in the account, so whoever
/// scans it can watch the whole balance and history forever. That is a privacy decision the
/// person holding the phone should get to make knowingly, not discover later.
private struct ColdStorageKpubQRView: View {
    let account: ColdStorageAccount
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: UIImage?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    /// Laid out as every receive screen (`AddressReceiveView`, owner 2026-11-27: "the new look for
    /// QR codes that hot wallet has"): an icon and title, the account's name, the QR on a white
    /// card, then what it means. No kpub text (owner, 2026-11-22): only the QR, for scanning.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.fill")
                            .font(.scaled(size: 15, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.accentColor))
                            .accessibilityHidden(true)
                        Text("Watch This Account")
                            .font(.title3.weight(.bold))
                    }
                    .padding(.top, 8)

                    Text(verbatim: account.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)

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

                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "eye.fill")
                            .foregroundColor(.orange)
                        Text("Watch-only. This cannot spend, but it reveals every address in this account.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 8)

                    Text("Tap anywhere to copy")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        note("checkmark.circle.fill", .green,
                             "Scan it into another device to watch this account there.")
                        note("xmark.octagon.fill", .red,
                             "Whoever scans it sees every address, balance and payment of this account. Show it only to devices you trust.")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sendKaspaGlass(cornerRadius: 18))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .contentShape(Rectangle())
                .onTapGesture { copyKpub() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { generateQR() }
            .toast(message: toastMessage)
        }
    }

    private func note(_ icon: String, _ color: Color, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func copyKpub() {
        ColdStorageClipboard.copyKpub(account.kpubString)
        Haptics.success()
        showToast("kpub copied to clipboard.")
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

    private func generateQR() {
        let kpub = account.kpubString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kpub.isEmpty, let data = kpub.data(using: .utf8) else { return }

        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        // "L" where the address QR uses "M": a kpub is several times longer, and at "M" the extra
        // error-correction pushes the symbol into a denser version that scans worse on screen
        // than the lower correction level does. Nothing is being transmitted over a lossy channel
        // here - it is one screen photographed by one camera.
        filter.setValue("L", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return }
        qrImage = UIImage(cgImage: cgImage)
    }
}


/// Adds one of a KasSigner's quantum-resistant (KCC-3) addresses to a Cold Storage account: scanned
/// from the unit's address screen or pasted, with the address's number on the unit when known.
/// The unit never hands over a kpub for these (it would show the keys the addresses hide), so
/// K watches each address it is given and the unit supplies the key's script when it signs.
private struct ColdQuantumAddressAddSheet: View {
    let account: ColdStorageAccount
    let onAdded: (ColdQuantumAddress) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var addressText = ""
    @State private var numberText = ""
    @State private var chain: ColdQuantumAddress.Chain = .receive
    @State private var showScanner = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField(AppLocalization.string("kaspa:pq..."), text: $addressText, axis: .vertical)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            showScanner = true
                        } label: {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .accessibilityLabel(Text("Scan QR"))
                    }
                    Button("Paste") {
                        if let text = UIPasteboard.general.string { addressText = text }
                    }
                } header: {
                    Text("Quantum-Resistant Address")
                } footer: {
                    Text("On KasSigner, open the KCC-3 address you want and scan its QR code. Its key stays on the unit until the address spends.")
                }
                ColdQuantumNumberFields(numberText: $numberText, chain: $chain)
                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(Text("Add Quantum Address"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .fontWeight(.semibold)
                        .disabled(addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    addressText = code
                    showScanner = false
                }
            }
        }
    }

    private func add() {
        let number: UInt32?
        switch ColdQuantumNumberFields.parse(numberText) {
        case .success(let value): number = value
        case .failure(let message):
            errorText = message.text
            return
        }
        switch ColdStorageManager.shared.addQuantumAddress(addressText, unitIndex: number, chain: chain, to: account) {
        case .success(let added):
            Haptics.success()
            onAdded(added)
            dismiss()
        case .failure(let error):
            errorText = error.localizedDescription
        }
    }
}

/// The unit's number for a quantum address and which of its KCC-3 chains it is on, shared by the
/// add and edit sheets.
private struct ColdQuantumNumberFields: View {
    @Binding var numberText: String
    @Binding var chain: ColdQuantumAddress.Chain

    struct Message: Error { let text: String }

    var body: some View {
        Section {
            Picker(selection: $chain) {
                Text("Receive Address").tag(ColdQuantumAddress.Chain.receive)
                Text("Change Address").tag(ColdQuantumAddress.Chain.change)
            } label: {
                Text("Chain")
            }
            .pickerStyle(.segmented)
            TextField(AppLocalization.string("Optional"), text: $numberText)
                .keyboardType(.numberPad)
        } header: {
            Text("Address Number on KasSigner")
        } footer: {
            Text("The number KasSigner shows for this address, and whether it is a receive or a change address. With it the unit finds the key at once when signing; without it the unit searches for it. KasSigner marks change sent to its change addresses #0 to #4 as change; any other address it shows as a payment.")
        }
    }

    /// The typed number: nil when empty, a message when it isn't one the unit can have (a KCC-3
    /// address number is below 2^31, since higher ones are hardened).
    static func parse(_ text: String) -> Result<UInt32?, Message> {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.isEmpty { return .success(nil) }
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return .failure(Message(text: AppLocalization.string("The address number must be a whole number.")))
        }
        guard let value = UInt32(digits), value < 0x8000_0000 else {
            return .failure(Message(text: AppLocalization.string("That number is too large: KasSigner's address numbers are below 2147483648.")))
        }
        return .success(value)
    }
}

/// Edit Address Number: sets, changes or clears a quantum address's number and chain on the unit.
private struct ColdQuantumAddressNumberSheet: View {
    let entry: ColdStorageAddressEntry
    let account: ColdStorageAccount
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var numberText: String
    @State private var chain: ColdQuantumAddress.Chain
    @State private var errorText: String?

    init(entry: ColdStorageAddressEntry, account: ColdStorageAccount, onSaved: @escaping () -> Void) {
        self.entry = entry
        self.account = account
        self.onSaved = onSaved
        // the stored record, not the row, which may be from before an earlier edit
        let stored = ColdStorageManager.shared.quantumAddressRecord(entry.address)?.entry
        _numberText = State(initialValue: (stored?.unitIndex ?? entry.unitIndex).map { String($0) } ?? "")
        _chain = State(initialValue: stored?.chain ?? entry.quantumChain)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: entry.address)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                ColdQuantumNumberFields(numberText: $numberText, chain: $chain)
                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(Text("Edit Address Number"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        switch ColdQuantumNumberFields.parse(numberText) {
        case .success(let number):
            ColdStorageManager.shared.updateQuantumAddress(entry.address, unitIndex: number, chain: chain, in: account)
            Haptics.success()
            onSaved()
            dismiss()
        case .failure(let message):
            errorText = message.text
        }
    }
}
