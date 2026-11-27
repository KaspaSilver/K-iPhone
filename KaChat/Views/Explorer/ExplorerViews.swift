import SwiftUI
import UIKit

// The Explorer tab (Kaspa Hub): search, the network live, the newest blocks and transactions, and a
// page for every transaction, block and address, all from kaspa.stream's API (`ExplorerAPI`,
// owner 2026-11-25). K Activity and the fee totals aren't in that API: they stay demo data and say so.

// MARK: - Explorer home

/// True where the Explorer's live pieces (the BlockDAG card, the live dot, the DAA counter, the
/// rows' ages) must stand still: the Explorer isn't showing, its Hub section is hidden or the app
/// isn't active (audit 2026-11-25 B2, E3).
private struct ExplorerPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var explorerPaused: Bool {
        get { self[ExplorerPausedKey.self] }
        set { self[ExplorerPausedKey.self] = newValue }
    }
}

struct ExplorerView: View {
    @ObservedObject private var walletManager = WalletManager.shared
    @ObservedObject private var live = ExplorerLive.shared
    @ObservedObject private var kStats = ExplorerKStats.shared
    @State private var searching = false
    /// What the text typed so far matches, looked up as you type.
    @State private var typedMatch: TypedMatch = .none
    enum TypedMatch: Equatable {
        case none, lookingUp
        case username(name: String, address: String)
        case noUsername(String)
        /// A valid address, with its .kachat name and balance once known.
        case address(String, name: String?, balance: UInt64?)
        case notAnAddress
        case transaction(String, kind: ExplorerTxKind)
        case block(String)
        case notFound
        /// kaspa.stream couldn't be asked, so it isn't known whether the id exists.
        case unreachable
        /// A 64-character id: asked about only on Search or a tap, never as you type, since it
        /// could be a pasted private key (audit 2026-11-27 L5).
        case idToLookUp(String)
        /// One of this wallet's own private keys: never sent anywhere.
        case privateKey
    }
    @State private var path: [ExplorerRoute] = []
    @State private var query = ""
    @State private var recentSearches: [String] = []
    @State private var notFound = false
    @State private var page: Page = .blocks
    /// The K activity card's window (its cycle button).
    @State private var kPeriod: ExplorerKPeriod = .day
    /// On screen with its Hub section showing (`onScreenPresence`).
    @State private var onScreen = false
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var searchFocused: Bool

    enum Page: Hashable { case blocks, transactions, kActivity }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    searchBar
                    if live.failed {
                        Label("kaspa.stream can't be reached right now.", systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        liveResults
                    } else if searchFocused {
                        suggestions
                    } else {
                        Group {
                            liveCard
                            statsGrid
                        }
                        .redacted(reason: live.stats == nil ? .placeholder : [])
                        PageCycleBar(
                            tabs: [(tab: Page.blocks, title: "Blocks"),
                                   (tab: Page.transactions, title: "Transactions"),
                                   (tab: Page.kActivity, title: "K Activity")],
                            selection: $page
                        )
                        latestList
                        Text("Live blocks from K's node · data from kaspa.stream")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.bottom, 28)
                .animation(.easeInOut(duration: 0.2), value: searchFocused)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Explorer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
            }
            .navigationDestination(for: ExplorerRoute.self) { route in
                ExplorerPage(route: route)
            }
            .alert("Nothing Found", isPresented: $notFound) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Search for an address, a transaction or block ID, or a .kachat username.")
            }
            // the live numbers tick only while the Explorer shows (a hidden Hub section is gone)
            // and the app is active
            .onScreenPresence(appear: { onScreen = true; updateLive() },
                              disappear: { onScreen = false; updateLive() })
            .onChange(of: scenePhase) { _ in updateLive() }
            // a K Explorer link (`ExplorerDeepLink`): its transaction or address
            .onAppear { takeDeepLink() }
            .onReceive(NotificationCenter.default.publisher(for: .explorerDeepLink)) { _ in takeDeepLink() }
        }
        .environment(\.explorerPaused, !running)
    }

    private var running: Bool { onScreen && scenePhase == .active }

    /// The page a K Explorer link asked for, on top of the Explorer's home.
    private func takeDeepLink() {
        guard let route = ExplorerDeepLink.pending else { return }
        ExplorerDeepLink.pending = nil
        query = ""
        searchFocused = false
        path = [route]
    }

    private func updateLive() {
        if running { live.start() } else { live.stop() }
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search Kaspa", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { runSearch(query) }
            if searching {
                ProgressView()
            } else if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .accessibilityLabel(Text("Clear"))
            } else {
                Button {
                    if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !pasted.isEmpty {
                        query = pasted
                        runSearch(pasted)
                    }
                } label: {
                    Text("Paste")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .padding(.horizontal, 16)
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let own = walletManager.currentWallet?.publicAddress {
                ExplorerSectionTitle("Your Account")
                ExplorerCard {
                    Button {
                        open(.address(own))
                    } label: {
                        HStack(spacing: 12) {
                            ExplorerOwnAvatar(size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Chatting Address")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.primary)
                                ExplorerMonoText(own, middle: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            }
            if !recentSearches.isEmpty {
                HStack {
                    ExplorerSectionTitle("Recent")
                    Spacer()
                    Button("Clear") { recentSearches = [] }
                        .font(.footnote.weight(.semibold))
                        .padding(.trailing, 20)
                }
                ExplorerCard {
                    ForEach(Array(recentSearches.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Divider().padding(.leading, 46) }
                        Button {
                            query = item
                            runSearch(item)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundColor(.secondary)
                                    .frame(width: 22)
                                ExplorerMonoText(item, middle: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            Text("Search for an address, a transaction or block ID, or a .kachat username.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal, 20)
        }
    }

    /// Results for what's typed, as you type: a .kachat username's address, or the address,
    /// transaction or block id itself.
    private var liveResults: some View {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        return VStack(alignment: .leading, spacing: 10) {
            ExplorerCard {
                switch typedMatch {
                case .username(let name, let address):
                    matchRow(name: name, title: "@\(name)", detail: address, trailing: nil) {
                        openTyped(.address(address))
                    }
                case .address(let address, let name, let balance):
                    matchRow(name: name ?? "K", title: name.map { "@\($0)" } ?? AppLocalization.string("Address"),
                             detail: address, trailing: balance.map { KaspaUnit.amount($0) }) {
                        openTyped(.address(address))
                    }
                case .transaction(let id, let kind):
                    Button { openTyped(.transaction(id)) } label: {
                        HStack(spacing: 12) {
                            ExplorerKindBadge(kind: kind, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.primary)
                                ExplorerMonoText(id, middle: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                case .block(let hash):
                    resultRow(icon: "cube.fill", title: "Block", detail: hash) { openTyped(.block(hash)) }
                case .idToLookUp(let id):
                    resultRow(icon: "magnifyingglass", title: "Look Up This ID", detail: id) {
                        Task { await identifyTyped(id) }
                    }
                case .privateKey:
                    typedNote("That's one of your private keys. K never sends it anywhere: don't share it.")
                case .noUsername(let name):
                    typedNote("No username \(name)")
                case .notAnAddress:
                    typedNote("That isn't a valid Kaspa address.")
                case .notFound:
                    typedNote("No transaction or block with that ID.")
                case .unreachable:
                    typedNote("kaspa.stream can't be reached right now.")
                case .lookingUp, .none:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking up \(text)…")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(14)
                }
            }
            .padding(.horizontal, 16)
            Text("Search for an address, a transaction or block ID, or a .kachat username.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal, 20)
        }
        // looked up a moment after typing stops
        .task(id: lower) { await lookUpTyped(text) }
    }

    private func openTyped(_ route: ExplorerRoute) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        recentSearches.removeAll { $0 == text }
        recentSearches.insert(text, at: 0)
        if recentSearches.count > 6 { recentSearches.removeLast() }
        searchFocused = false
        query = ""
        open(route)
    }

    private func typedNote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A found address: its picture, name (or "Address"), the address, and its balance.
    private func matchRow(name: String, title: String, detail: String, trailing: String?,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                KNSAvatarView(avatarURLString: nil, fallbackText: name, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    ExplorerMonoText(detail, middle: true)
                }
                Spacer(minLength: 0)
                if let trailing {
                    Text(verbatim: trailing)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func resultRow(icon: String, title: LocalizedStringKey, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    ExplorerMonoText(detail, middle: true)
                }
                Spacer(minLength: 0)
                if searching { ProgressView() } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Works out what's typed, a moment after typing stops: an address (checked, with its name
    /// and balance), a transaction or block id, or a .kachat username.
    /// A Kaspa address anywhere in pasted text ("send to kaspa:qq…, thanks").
    static func addressIn(_ text: String) -> String? {
        let lower = text.lowercased()
        guard let range = lower.range(of: #"kaspa(test)?:[a-z0-9]{50,70}"#, options: .regularExpression) else { return nil }
        return String(lower[range])
    }

    private func lookUpTyped(_ text: String) async {
        var lower = text.lowercased()
        if let found = Self.addressIn(lower) { lower = found }
        guard !lower.isEmpty else { return }
        typedMatch = .lookingUp
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        let match: TypedMatch
        if lower.hasPrefix("kaspa:") || lower.hasPrefix("kaspatest:") {
            guard KaspaAddress.isValid(lower) else { typedMatch = .notAnAddress; return }
            typedMatch = .address(lower, name: KachatLive.identityName(lower), balance: nil)
            async let balance = try? ExplorerAPI.get(ExplorerAPI.BalanceAnswer.self, "/addresses/\(lower)/balance")
            async let identity = KachatNamesRegistry.shared.refreshIdentity(address: lower)
            let name = (await identity)?.label.map(KachatNameLabel.display) ?? KachatLive.identityName(lower)
            match = .address(lower, name: name, balance: (await balance)?.balance)
        } else if lower.count == 64, lower.allSatisfy(\.isHexDigit) {
            // nothing leaves the phone until it's asked for (Search, or the row's tap)
            match = Self.isOwnPrivateKey(lower) ? .privateKey : .idToLookUp(lower)
        } else {
            let found = await NameServicesClient.shared.resolveEverywhere(text).first
            if let found, let address = found.address {
                match = .username(name: found.display, address: address)
            } else {
                match = .noUsername(text)
            }
        }
        guard !Task.isCancelled else { return }
        typedMatch = match
    }

    /// What a 64-character id is (light calls: not the whole transaction or block), once asked.
    private func identifyTyped(_ id: String) async {
        guard !Self.isOwnPrivateKey(id) else { typedMatch = .privateKey; return }
        typedMatch = .lookingUp
        let match: TypedMatch
        do {
            switch try await ExplorerAPI.identify(id) {
            case .transaction(let kind): match = .transaction(id, kind: kind)
            case .block: match = .block(id)
            case .notFound: match = .notFound
            }
        } catch {
            match = .unreachable
        }
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == id else { return }
        typedMatch = match
    }

    /// The chatting key or a listed spending address's key, as hex.
    static func isOwnPrivateKey(_ hex: String) -> Bool {
        let wallet = WalletManager.shared
        let wanted = hex.lowercased()
        if wallet.getPrivateKey()?.hexString.lowercased() == wanted { return true }
        for entry in wallet.cachedSpendingAddressList() {
            if wallet.spendingPrivateKey(at: entry.index)?.hexString.lowercased() == wanted { return true }
        }
        return false
    }

    private func runSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !searching else { return }
        if trimmed.count == 64, trimmed.allSatisfy(\.isHexDigit), Self.isOwnPrivateKey(trimmed) {
            typedMatch = .privateKey
            Haptics.error()
            return
        }
        searching = true
        Task {
            let match = await ExplorerAPI.search(trimmed)
            searching = false
            switch match {
            case .route(let route):
                recentSearches.removeAll { $0 == trimmed }
                recentSearches.insert(trimmed, at: 0)
                if recentSearches.count > 6 { recentSearches.removeLast() }
                searchFocused = false
                query = ""
                open(route)
            case .notFound:
                Haptics.error()
                notFound = true
            }
        }
    }

    private func open(_ route: ExplorerRoute) {
        Haptics.selection()
        searchFocused = false
        path.append(route)
    }

    // MARK: Live network

    /// kaspa.stream's numbers; zeros (drawn as placeholders) until the first answer. The DAA
    /// score runs on in `ExplorerDAAScore`, which alone redraws every second (audit 2026-11-25 E3).
    private var stats: ExplorerNetworkStats { live.stats ?? .empty }

    private var liveCard: some View {
        let stats = stats
        return ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color.accentColor.opacity(0.55), Color(red: 0.02, green: 0.16, blue: 0.16)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            // 30 fps is plenty for the card; still while the Explorer doesn't show (audit B2)
            BlockDAGAnimationView(highlight: false, paused: !running, minimumInterval: 1.0 / 30)
                .frame(height: 118)
                .opacity(0.55)
            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.45)],
                           startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        ExplorerLiveDot()
                        Text("Live")
                            .font(.caption.weight(.bold))
                            .textCase(.uppercase)
                    }
                    ExplorerDAAScore()
                    Text("DAA Score")
                        .font(.caption)
                        .opacity(0.8)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(verbatim: String(format: "%.1f", stats.blocksPerSecond))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("blocks / second")
                        .font(.caption)
                        .opacity(0.8)
                }
            }
            .foregroundColor(.white)
            .padding(14)
        }
        .frame(height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
    }

    /// What the Network Fee tile's number is: K's indexer's rolling 24 hours, Kaspalytics' last
    /// full day, or the demo.
    private var feeTileDetail: LocalizedStringKey {
        switch kStats.averageFee?.source {
        case .indexer: return "average, last 24 hours"
        case .kaspalytics: return "average, yesterday"
        default: return "demo: not served yet"
        }
    }

    private var statsGrid: some View {
        let stats = stats
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return VStack(spacing: 12) {
            LazyVGrid(columns: columns, spacing: 12) {
                Button { open(.chart(.hashrate)) } label: {
                    ExplorerStatTile(icon: "bolt.fill", color: .accentColor, title: "Hashrate",
                                     value: ExplorerFormat.hashrate(stats.hashrate),
                                     detail: "whole network", showsChevron: true)
                }
                .buttonStyle(ChatHeaderChipButtonStyle())
                ExplorerStatTile(icon: "tray.full.fill", color: .accentColor, title: "Mempool",
                                 value: ExplorerFormat.grouped(UInt64(max(0, stats.mempoolSize))),
                                 detail: "transactions waiting")
                Button { open(.chart(.networkFees)) } label: {
                    ExplorerStatTile(icon: "gauge.with.dots.needle.33percent", color: .accentColor, title: "Network Fee",
                                     value: ExplorerChartMetric.networkFees.format(Double(kStats.averageFee?.sompi ?? stats.averageFee24h) / 100_000_000),
                                     detail: feeTileDetail,
                                     showsChevron: true)
                }
                .buttonStyle(ChatHeaderChipButtonStyle())
                Button { open(.chart(.price)) } label: {
                    ExplorerStatTile(icon: "KaspaLogo", color: .accentColor, title: "KAS Price",
                                     value: String(format: "$%.4f", stats.priceUSD),
                                     detail: "US dollars", showsChevron: true)
                }
                .buttonStyle(ChatHeaderChipButtonStyle())
                Button { open(.chart(.blockReward)) } label: {
                    ExplorerStatTile(icon: "hammer.fill", color: .accentColor, title: "Block Reward",
                                     value: ExplorerFormat.rewardKAS(stats.blockReward),
                                     detail: "per block, lower in \(ExplorerFormat.daysUntil(stats.nextRewardDrop, now: Date()))", showsChevron: true)
                }
                .buttonStyle(ChatHeaderChipButtonStyle())
                Button { open(.chart(.marketCap)) } label: {
                    ExplorerStatTile(icon: "chart.bar.fill", color: .accentColor, title: "Market Cap",
                                     value: ExplorerFormat.compactUSD(Double(stats.circulatingSupply) / 100_000_000 * stats.priceUSD),
                                     detail: "US dollars", showsChevron: true)
                }
                .buttonStyle(ChatHeaderChipButtonStyle())
            }
            supplyCard(stats)
            // K's indexer's numbers; the demo only until they first arrive
            let periods = kStats.periods
            let shown = periods.contains(kPeriod) ? kPeriod : (periods.first ?? .day)
            ExplorerKActivityCard(period: $kPeriod, periods: periods,
                                  activity: kStats.activity[shown] ?? ExplorerDemo.kActivity(shown, at: Date()))
        }
        .padding(.horizontal, 16)
    }

    private func supplyCard(_ stats: ExplorerNetworkStats) -> some View {
        let mined = Double(stats.circulatingSupply) / Double(max(stats.maxSupply, 1))
        return ExplorerCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label {
                        Text("Circulating Supply").foregroundColor(.primary)
                    } icon: {
                        Image(systemName: "circle.hexagongrid.fill").foregroundColor(.accentColor)
                    }
                    .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(verbatim: String(format: "%.2f%%", mined * 100))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: mined)
                    .tint(.accentColor)
                HStack {
                    Text(verbatim: ExplorerFormat.compactKAS(stats.circulatingSupply))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                    Spacer()
                    Text("of \(ExplorerFormat.compactKAS(stats.maxSupply))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(14)
        }
    }

    // MARK: Latest

    @ViewBuilder
    private var latestList: some View {
        switch page {
        case .blocks:
            ExplorerCard {
                if live.latestBlocks.isEmpty { ExplorerLoadingRow() }
                ForEach(Array(live.latestBlocks.enumerated()), id: \.element.id) { index, block in
                    if index > 0 { Divider().padding(.leading, 62) }
                    Button { open(.block(block.id)) } label: { ExplorerBlockRow(block: block) }
                        .buttonStyle(ExplorerRowStyle())
                }
            }
            .padding(.horizontal, 16)
        case .transactions, .kActivity:
            ExplorerCard {
                let txs = Array((page == .kActivity ? live.latestTransactions.filter { $0.kind.isK } : live.latestTransactions).prefix(25))
                if txs.isEmpty {
                    if page == .kActivity && !live.latestTransactions.isEmpty {
                        Text("No K transactions in the newest blocks yet. They show here as they land.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(16)
                    } else {
                        ExplorerLoadingRow()
                    }
                }
                ForEach(Array(txs.enumerated()), id: \.element.id) { index, tx in
                    if index > 0 { Divider().padding(.leading, 62) }
                    Button { open(.transaction(tx.id)) } label: { ExplorerTransactionRow(tx: tx) }
                        .buttonStyle(ExplorerRowStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Pages

/// Each route's page.
struct ExplorerPage: View {
    let route: ExplorerRoute

    var body: some View {
        switch route {
        case .transaction(let id):
            ExplorerLoader(title: "Transaction", load: { try await ExplorerAPI.transaction(id: id) }) {
                ExplorerTransactionView(transaction: $0)
            }
        case .block(let hash):
            ExplorerLoader(title: "Block", load: { try await ExplorerAPI.block(hash: hash) }) {
                ExplorerBlockView(block: $0)
            }
        case .address(let address):
            ExplorerLoader(title: "Address", load: { try await ExplorerAPI.address(address) }) {
                ExplorerAddressView(info: $0)
            }
        case .chart(let metric): ExplorerChartView(metric: metric)
        }
    }
}

/// Loads a page's data from kaspa.stream, with a spinner, and an error and Try Again if it fails.
struct ExplorerLoader<Value, Content: View>: View {
    let title: LocalizedStringKey
    let load: () async throws -> Value
    @ViewBuilder let content: (Value) -> Content
    @State private var value: Value?
    @State private var failure: String?

    var body: some View {
        Group {
            if let value {
                content(value)
            } else if let failure {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.magnifyingglass")
                        .font(.system(size: 38))
                        .foregroundColor(.accentColor)
                    Text(failure)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { Task { await run() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if value == nil { await run() } }
    }

    private func run() async {
        failure = nil
        do {
            value = try await load()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// A list still waiting for its first answer.
struct ExplorerLoadingRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(20)
    }
}

// MARK: Transaction

struct ExplorerTransactionView: View {
    let transaction: ExplorerTransaction
    @State private var toast: String?
    @State private var showPayload = false
    private var own: String? { WalletManager.shared.currentWallet?.publicAddress }

    var body: some View {
        let tx = transaction
        ScrollView {
            VStack(spacing: 16) {
                hero(tx)
                whatItIs(tx)
                details(tx)
                if !tx.inputs.isEmpty {
                    ioCard(title: "From", items: tx.inputs)
                }
                ioCard(title: "To", items: tx.outputs, marksChange: true)
                if !tx.payloadHex.isEmpty { payloadCard(tx) }
            }
            .padding(.bottom, 28)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ShareLink(item: tx.id) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .toast(message: toast)
    }

    private func hero(_ tx: ExplorerTransaction) -> some View {
        VStack(spacing: 8) {
            ExplorerKindBadge(kind: tx.kind, size: 58)
            Text(tx.kind.title)
                .font(.headline)
            Text(verbatim: ExplorerFormat.amountLine(tx))
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if tx.tokenUnits == nil, let moved = tx.movedAmount {
                Text(verbatim: ExplorerFormat.usd(moved))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            ExplorerStatusPill(confirmations: tx.confirmations, inMempool: tx.isInMempool, accepted: tx.isAccepted)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 6)
    }

    private func whatItIs(_ tx: ExplorerTransaction) -> some View {
        ExplorerCard {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(tx.kind.explanation)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(tx.kind.color)
                }
                if tx.isNotAccepted {
                    Label {
                        Text(tx.kind == .coinbase
                             ? "Not accepted, so it paid nothing. Every block that merges a found block carries a reward for it; only one of them is accepted."
                             : "Not accepted by the network, so it moved nothing.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "xmark.seal.fill")
                            .foregroundColor(.secondary)
                    }
                }
                if let decoded = tx.decoded {
                    Text(verbatim: decoded)
                        .font(tx.kind == .kapost ? .body : .system(.body, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tx.kind.color.opacity(0.12)))
                }
            }
            .padding(14)
        }
        .padding(.horizontal, 16)
    }

    private func details(_ tx: ExplorerTransaction) -> some View {
        ExplorerCard {
            ExplorerDetailRow(title: "Transaction ID") {
                ExplorerCopyValue(tx.id) { copied() }
            }
            Divider().padding(.leading, 14)
            if let block = tx.blockHash {
                NavigationLink(value: ExplorerRoute.block(block)) {
                    ExplorerDetailRow(title: "Block", chevron: true) { ExplorerMonoText(block, middle: true) }
                }
                .buttonStyle(ExplorerRowStyle())
                Divider().padding(.leading, 14)
            }
            ExplorerDetailRow(title: "Time") {
                Text(tx.time, format: .dateTime.day().month().year().hour().minute().second())
                    .font(.subheadline)
            }
            Divider().padding(.leading, 14)
            ExplorerDetailRow(title: "Network Fee") {
                Text(verbatim: tx.fee.map { KaspaUnit.amount($0) } ?? "–").font(.subheadline).monospacedDigit()
            }
            Divider().padding(.leading, 14)
            ExplorerDetailRow(title: "Mass") {
                Text(verbatim: ExplorerFormat.grouped(tx.mass)).font(.subheadline).monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
    }

    private func ioCard(title: LocalizedStringKey, items: [ExplorerIO], marksChange: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ExplorerSectionTitle(title)
            ExplorerCard {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, io in
                    if index > 0 { Divider().padding(.leading, 60) }
                    if io.address.isEmpty {
                        // not known (read off the node) or no address (a script): nothing to open
                        ExplorerUnknownIORow(label: marksChange ? "Output #\(io.index)" : "Input #\(io.index)",
                                             amount: marksChange ? io.amount : nil)
                    } else {
                        NavigationLink(value: ExplorerRoute.address(io.address)) {
                            ExplorerAddressRow(address: io.address, amount: io.amount,
                                               isYou: io.address.lowercased() == own?.lowercased(),
                                               isChange: marksChange && io.index > 0 && io.address == transaction.inputs.first?.address)
                        }
                        .buttonStyle(ExplorerRowStyle())
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func payloadCard(_ tx: ExplorerTransaction) -> some View {
        ExplorerCard {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showPayload.toggle() }
                } label: {
                    HStack {
                        Text("Payload")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        Text("\(tx.payloadHex.count / 2) bytes")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(showPayload ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showPayload {
                    Text(verbatim: tx.payloadHex)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = tx.payloadHex
                        copied()
                    } label: {
                        Label("Copy Payload", systemImage: "doc.on.doc")
                            .font(.footnote.weight(.semibold))
                    }
                }
            }
            .padding(14)
        }
        .padding(.horizontal, 16)
    }

    private func copied() {
        Haptics.success()
        toast = AppLocalization.string("Copied")
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            toast = nil
        }
    }
}

// MARK: Block

struct ExplorerBlockView: View {
    let block: ExplorerBlock
    @State private var toast: String?
    @State private var page: Page = .transactions

    enum Page: Hashable { case transactions, parents, children }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                details
                PageCycleBar(
                    tabs: [(tab: Page.transactions, title: AppLocalization.string("Transactions") + " · \(block.transactionIds.count)"),
                           (tab: Page.parents, title: AppLocalization.string("Parents") + " · \(block.parents.count)"),
                           (tab: Page.children, title: AppLocalization.string("Children") + " · \(block.children.count)")],
                    selection: $page
                )
                list
            }
            .padding(.bottom, 28)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Block")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ShareLink(item: block.id) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .toast(message: toast)
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Image(systemName: "cube.transparent.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 58, height: 58)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor))
            Text(verbatim: ExplorerFormat.grouped(block.blueScore))
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .monospacedDigit()
            Text("Blue Score")
                .font(.subheadline)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                ExplorerPill(text: block.isChainBlock ? "Chain Block" : "Merged Block",
                             icon: block.isChainBlock ? "link" : "arrow.triangle.merge",
                             color: block.isChainBlock ? .accentColor : .secondary)
                ExplorerPill(text: ExplorerFormat.ago(block.time, now: Date()), icon: "clock", color: .secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private var details: some View {
        ExplorerCard {
            ExplorerDetailRow(title: "Block Hash") {
                ExplorerCopyValue(block.id) { copied() }
            }
            Divider().padding(.leading, 14)
            ExplorerDetailRow(title: "DAA Score") {
                Text(verbatim: ExplorerFormat.grouped(block.daaScore)).font(.subheadline).monospacedDigit()
            }
            Divider().padding(.leading, 14)
            ExplorerDetailRow(title: "Time") {
                Text(block.time, format: .dateTime.day().month().year().hour().minute().second())
                    .font(.subheadline)
            }
            Divider().padding(.leading, 14)
            ExplorerDetailRow(title: "Merge Set") {
                Text("\(block.mergeSetBlues) blue · \(block.mergeSetReds) red")
                    .font(.subheadline)
            }
            Divider().padding(.leading, 14)
            ExplorerDetailRow(title: "Difficulty") {
                Text(verbatim: ExplorerFormat.difficulty(block.difficulty)).font(.subheadline).monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var list: some View {
        switch page {
        case .transactions:
            ExplorerCard {
                ForEach(Array(block.transactions.enumerated()), id: \.element.id) { index, tx in
                    if index > 0 { Divider().padding(.leading, 62) }
                    NavigationLink(value: ExplorerRoute.transaction(tx.id)) {
                        ExplorerTransactionRow(tx: tx, showsAge: false)
                    }
                    .buttonStyle(ExplorerRowStyle())
                }
            }
            .padding(.horizontal, 16)
        case .parents, .children:
            let hashes = page == .parents ? block.parents : block.children
            if hashes.isEmpty {
                Text(page == .children ? "No children yet: newer blocks will point to this one." : "No parents.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)
            } else {
                ExplorerCard {
                    ForEach(Array(hashes.enumerated()), id: \.element) { index, hash in
                        if index > 0 { Divider().padding(.leading, 52) }
                        NavigationLink(value: ExplorerRoute.block(hash)) {
                            HStack(spacing: 12) {
                                Image(systemName: "cube")
                                    .foregroundColor(.accentColor)
                                    .frame(width: 26)
                                ExplorerMonoText(hash, middle: true)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(ExplorerRowStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func copied() {
        Haptics.success()
        toast = AppLocalization.string("Copied")
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            toast = nil
        }
    }
}

// MARK: Address

struct ExplorerAddressView: View {
    let info: ExplorerAddress
    @State private var toast: String?
    @State private var page: Page = .history
    @State private var showQR = false

    /// History and Assets (owner, 2026-11-25: the Coins page is gone).
    enum Page: Hashable { case history, assets }

    private var isYou: Bool {
        info.address.lowercased() == WalletManager.shared.currentWallet?.publicAddress.lowercased()
    }

    /// Pages of history loaded after the first.
    @State private var morePages: [ExplorerTransaction] = []
    @State private var nextBefore: Int64??
    @State private var loadingMore = false

    /// Unaccepted mining rewards are left out (owner, 2026-11-25): every block merging a found
    /// block carries one, and only one counts. Other unaccepted transactions stay, marked.
    private var history: [ExplorerTransaction] {
        (info.transactions + morePages).filter { !($0.kind == .coinbase && $0.isNotAccepted) }
    }
    private var cursor: Int64? { nextBefore ?? info.nextPageBefore }

    /// The transaction count, and Load More while there's older history.
    @ViewBuilder
    private var historyFooter: some View {
        VStack(spacing: 10) {
            if cursor != nil {
                Button {
                    loadMore()
                } label: {
                    if loadingMore {
                        ProgressView()
                    } else {
                        Text("Load More")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                .padding(.horizontal, 16)
                .disabled(loadingMore)
            }
            if let total = info.transactionCount {
                Text("\(history.count) of \(total) transactions")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func loadMore() {
        guard let before = cursor, !loadingMore else { return }
        loadingMore = true
        Task {
            if let (txs, next) = try? await ExplorerAPI.addressPage(info.address, before: before) {
                let known = Set(history.map(\.id))
                morePages += txs.filter { !known.contains($0.id) }
                nextBefore = .some(next)
            }
            loadingMore = false
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                balanceCard
                summaryRow
                PageCycleBar(
                    tabs: [(tab: Page.history, title: AppLocalization.string("History")),
                           (tab: Page.assets, title: AppLocalization.string("Assets"))],
                    selection: $page
                )
                list
                if page == .history {
                    historyFooter
                }
            }
            .padding(.bottom, 28)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Address")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ShareLink(item: info.address) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .sheet(isPresented: $showQR) { qrSheet }
        .toast(message: toast)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            if isYou {
                ExplorerOwnAvatar(size: 72)
            } else {
                KNSAvatarView(avatarURLString: nil, fallbackText: info.username ?? "K", size: 72)
            }
            if let name = info.username {
                Text(verbatim: "@\(name)")
                    .font(.title3.weight(.bold))
            } else if isYou {
                Text("Your Chatting Address")
                    .font(.title3.weight(.bold))
            }
            // two even lines, never hyphenated
            Text(verbatim: ExplorerFormat.twoLines(info.address))
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                ExplorerActionChip(title: "Copy", icon: "doc.on.doc") {
                    UIPasteboard.general.string = info.address
                    Haptics.success()
                    toast = AppLocalization.string("Copied")
                    Task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        toast = nil
                    }
                }
                ExplorerActionChip(title: "QR Code", icon: "qrcode") { showQR = true }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private var balanceCard: some View {
        ExplorerCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Balance")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Text(verbatim: KaspaUnit.amount(info.balance))
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(verbatim: ExplorerFormat.usd(info.balance))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if let kusdt = info.kusdtUnits {
                    Divider().padding(.vertical, 4)
                    HStack {
                        TokenIcon(token: .kusdt, size: 20)
                        Text(verbatim: TokenAmount.amount(kusdt, token: .kusdt))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .padding(.horizontal, 16)
    }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            // complete when the first page of history reaches back 30 days
            ExplorerStatTile(icon: "arrow.down.left", color: .accentColor, title: "Received",
                             value: ExplorerFormat.compactKAS(info.received30d),
                             detail: info.summaryCoversMonth ? "last 30 days" : "newest \(info.transactions.count) transactions")
            ExplorerStatTile(icon: "arrow.up.right", color: .accentColor, title: "Sent",
                             value: ExplorerFormat.compactKAS(info.sent30d),
                             detail: info.summaryCoversMonth ? "last 30 days" : "newest \(info.transactions.count) transactions")
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var list: some View {
        switch page {
        case .history:
            ExplorerCard {
                if history.isEmpty {
                    Text("No transactions yet.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(16)
                }
                ForEach(Array(history.enumerated()), id: \.element.id) { index, tx in
                    if index > 0 { Divider().padding(.leading, 62) }
                    NavigationLink(value: ExplorerRoute.transaction(tx.id)) {
                        ExplorerTransactionRow(tx: tx, perspective: info.address)
                    }
                    .buttonStyle(ExplorerRowStyle())
                }
            }
            .padding(.horizontal, 16)
        case .assets:
            // Kaspa and kUSDT, always both: kUSDT shows at 0 too (owner, 2026-11-25)
            ExplorerCard {
                assetRow(name: "Kaspa", detail: "Kaspa's own coin",
                         amount: KaspaUnit.amount(info.balance), value: ExplorerFormat.usd(info.balance)) {
                    Image("KaspaLogo").resizable().scaledToFit().frame(width: 36, height: 36)
                }
                Divider().padding(.leading, 62)
                let units = info.kusdtUnits ?? 0
                assetRow(name: "kUSDT", detail: "A dollar token on Kaspa",
                         amount: TokenAmount.amount(units, token: .kusdt),
                         value: (Double(units) / 1_000_000).formatted(.currency(code: "USD"))) {
                    TokenIcon(token: .kusdt, size: 36)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// One asset the address holds: its logo, name, amount and dollar value.
    private func assetRow<Icon: View>(name: String, detail: LocalizedStringKey, amount: String, value: String,
                                      @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 12) {
            icon()
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: amount)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(verbatim: value)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var qrSheet: some View {
        VStack(spacing: 18) {
            Text("Address")
                .font(.headline)
                .padding(.top, 24)
            if let image = AddressReceiveView<EmptyView, EmptyView>.qrImage(for: info.address) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
            }
            Text(verbatim: info.address)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer(minLength: 0)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Rows

struct ExplorerBlockRow: View {
    let block: ExplorerBlock

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cube.transparent.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: ExplorerFormat.grouped(block.blueScore))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(.primary)
                ExplorerMonoText(block.id, middle: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(block.transactionIds.count == 1 ? "1 transaction" : "\(block.transactionIds.count) transactions")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                ExplorerAgoText(date: block.time)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct ExplorerTransactionRow: View {
    let tx: ExplorerTransaction
    var showsAge = true
    /// An address page: the amount is what the transaction did to that address, in (+) or
    /// out (-): its outputs to it less its inputs from it (audit 2026-11-25 C4).
    var perspective: String? = nil

    private var outgoing: Bool {
        guard let perspective else { return false }
        return !tx.net(for: perspective).isIncoming
    }

    var body: some View {
        HStack(spacing: 12) {
            ExplorerKindBadge(kind: tx.kind, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tx.kind.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    if tx.isInMempool {
                        Text("Pending")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }
                }
                HStack(spacing: 6) {
                    ExplorerMonoText(tx.id, middle: true)
                    // beside the id, so the title keeps one line
                    if tx.isNotAccepted {
                        Text("Not Accepted")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(verbatim: amountText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(perspective == nil || tx.isNotAccepted ? .primary : (outgoing ? .primary : .green))
                    .strikethrough(tx.isNotAccepted)
                    .lineLimit(1)
                if showsAge {
                    ExplorerAgoText(date: tx.time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // an unaccepted copy moved nothing: dimmed, its amount struck through
        .opacity(tx.isNotAccepted ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    private var amountText: String {
        guard let perspective, tx.tokenUnits == nil else { return ExplorerFormat.amountLine(tx, short: true) }
        let net = tx.net(for: perspective)
        return (net.isIncoming ? "+" : "−") + ExplorerFormat.shortKAS(net.amount)
    }
}

/// An input or output with no address to open: an input read off the node (its coin's address
/// isn't in the block) or an output to a script with none (audit 2026-11-25 C11).
struct ExplorerUnknownIORow: View {
    let label: String
    /// Nil when not known (an input read off the node).
    let amount: UInt64?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "questionmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
            Text(verbatim: label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(verbatim: amount.map { KaspaUnit.amount($0) } ?? "–")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// "12s ago", run on once a second while the Explorer shows; one small view per row, so the
/// home itself doesn't redraw every second (audit 2026-11-25 E3).
struct ExplorerAgoText: View {
    let date: Date
    @Environment(\.explorerPaused) private var paused

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: paused)) { context in
            Text(verbatim: ExplorerFormat.ago(date, now: context.date))
        }
    }
}

/// The live card's DAA score, run on from the newest block at the measured rate, once a second.
struct ExplorerDAAScore: View {
    @ObservedObject private var live = ExplorerLive.shared
    @Environment(\.explorerPaused) private var paused

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: paused)) { context in
            let score = live.stats == nil ? 0 : live.daaScore(at: context.date)
            Text(verbatim: ExplorerFormat.grouped(score))
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.35), value: score)
        }
    }
}

struct ExplorerAddressRow: View {
    let address: String
    let amount: UInt64
    let isYou: Bool
    /// An output back to the sender.
    var isChange = false

    var body: some View {
        HStack(spacing: 12) {
            if isYou {
                ExplorerOwnAvatar(size: 34)
            } else {
                KNSAvatarView(avatarURLString: nil, fallbackText: String(address.suffix(2)).uppercased(), size: 34)
            }
            VStack(alignment: .leading, spacing: 3) {
                if isYou || isChange {
                    HStack(spacing: 6) {
                        if isYou {
                            Text("You")
                                .font(.caption.weight(.bold))
                                .foregroundColor(.accentColor)
                        }
                        if isChange {
                            Text("Change")
                                .font(.caption.weight(.bold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                // never cut: the amount beside it shrinks first
                ExplorerMonoText(address, middle: true)
                    .fixedSize()
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text(verbatim: KaspaUnit.amount(amount))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Pieces

/// This account's own picture, as the account switcher shows it.
struct ExplorerOwnAvatar: View {
    let size: CGFloat
    @ObservedObject private var walletManager = WalletManager.shared

    var body: some View {
        if let wallet = walletManager.currentWallet {
            SavedAccountAvatar(publicKey: wallet.publicKey, name: wallet.alias, size: size)
        } else {
            KNSAvatarView(avatarURLString: nil, fallbackText: "K", size: size)
        }
    }
}

/// Says the page shows made-up data, until real data is wired in.
struct ExplorerDemoPill: View {
    var body: some View {
        Label("Demo Data", systemImage: "paintbrush.pointed.fill")
            .font(.caption.weight(.semibold))
            .foregroundColor(.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.orange.opacity(0.14)))
            .padding(.top, 6)
    }
}

struct ExplorerCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ExplorerSectionTitle: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ExplorerStatTile: View {
    let icon: String
    let color: Color
    let title: LocalizedStringKey
    let value: String
    var detail: LocalizedStringKey? = nil
    /// A tile that opens its chart shows a chevron.
    var showsChevron = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if icon == "KaspaLogo" {
                    // the Kaspa logo is its own teal disc
                    Image("KaspaLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(color))
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if showsChevron {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(Color(.tertiaryLabel))
                }
            }
            Text(verbatim: value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// K's activity on the Explorer's home (it replaced the Stats tile, owner 2026-11-25): every
/// transaction K's protocols made in the window the cycle button picks (24 hours, 7 days, 30 days,
/// all time), how that compares with the window before, a bar per hour, day or month, and each
/// protocol's count.
struct ExplorerKActivityCard: View {
    @Binding var period: ExplorerKPeriod
    /// The periods there are numbers for.
    let periods: [ExplorerKPeriod]
    let activity: ExplorerKActivity

    var body: some View {
        ExplorerCard {
            VStack(alignment: .leading, spacing: 14) {
                header
                if activity.isDemo {
                    Label("Demo numbers until K's indexer answers", systemImage: "paintbrush.pointed.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.orange)
                }
                totals
                // the bars, active addresses and fees once K's indexer serves them
                if activity.bars != nil { hourlyBars }
                Divider()
                kinds
                if activity.activeAddresses != nil || activity.fees != nil {
                    Divider()
                    footer
                }
            }
            .padding(14)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image("KLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .clipShape(Circle())
            Text("K Activity")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            CycleCapsuleButton(options: periods, selection: Binding(
                get: { activity.period },
                set: { period = $0 }
            ), title: { $0.title }, hint: "Switches the time period")
        }
    }

    private var totals: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ExplorerFormat.grouped(UInt64(activity.total)))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("transactions")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let change = activity.change, let comparison = activity.period.comparison {
                VStack(alignment: .trailing, spacing: 2) {
                    Label {
                        Text(verbatim: String(format: "%.1f%%", abs(change)))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.accentColor)
                    Text(comparison)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var hourlyBars: some View {
        let bars = activity.bars ?? []
        let peak = max(bars.max() ?? 1, 1)
        return VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: bars.count > 24 ? 2 : 3) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, count in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.accentColor.opacity(index == bars.count - 1 ? 1 : 0.55))
                        .frame(height: max(3, 44 * CGFloat(count) / CGFloat(peak)))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 44, alignment: .bottom)
            HStack {
                Text(activity.period.chartStart)
                Spacer()
                Text(activity.period.chartEnd)
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .animation(.easeInOut(duration: 0.25), value: activity.period)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(activity.period.barMeaning))
    }

    private var kinds: some View {
        let ranked = activity.ranked
        let top = max(ranked.first?.count ?? 1, 1)
        return VStack(spacing: 10) {
            ForEach(ranked, id: \.kind) { item in
                HStack(spacing: 10) {
                    ExplorerKindBadge(kind: item.kind, size: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.kind.plural)
                                .font(.subheadline)
                            Spacer()
                            Text(verbatim: ExplorerFormat.grouped(UInt64(item.count)))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.accentColor.opacity(0.5))
                                .frame(width: max(4, geo.size.width * CGFloat(item.count) / CGFloat(top)))
                        }
                        .frame(height: 3)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let active = activity.activeAddresses {
                footerStat(icon: "person.2.fill", value: ExplorerFormat.grouped(UInt64(active)),
                           title: "active addresses")
            }
            Spacer()
            if let fees = activity.fees {
                footerStat(icon: "flame.fill", value: ExplorerFormat.compactKAS(fees), title: "paid in fees")
            }
        }
    }

    private func footerStat(icon: String, value: String, title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ExplorerKindBadge: View {
    let kind: ExplorerTxKind
    let size: CGFloat

    var body: some View {
        Image(systemName: kind.icon)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(kind.color))
            .accessibilityHidden(true)
    }
}

struct ExplorerStatusPill: View {
    let confirmations: Int
    let inMempool: Bool
    var accepted: Bool? = nil

    var body: some View {
        if accepted == false {
            ExplorerPill(text: AppLocalization.string("Not Accepted"), icon: "xmark.seal.fill", color: .secondary)
        } else if inMempool {
            ExplorerPill(text: AppLocalization.string("In the Mempool"), icon: "hourglass", color: .orange)
        } else if confirmations == 0 {
            // seconds old: in a block, not yet counted by kaspa.stream
            ExplorerPill(text: AppLocalization.string("In a Block"), icon: "checkmark.seal.fill", color: .green)
        } else {
            ExplorerPill(text: String(format: AppLocalization.string("Confirmed · %@ confirmations"),
                                      ExplorerFormat.grouped(UInt64(max(0, confirmations)))),
                         icon: "checkmark.seal.fill", color: .green)
        }
    }
}

struct ExplorerPill: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct ExplorerActionChip: View {
    let title: LocalizedStringKey
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    }
}

struct ExplorerDetailRow<Value: View>: View {
    let title: LocalizedStringKey
    var chevron = false
    @ViewBuilder let value: () -> Value

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            value()
                .foregroundColor(.primary)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// A long id cut in the middle, with a copy button.
struct ExplorerCopyValue: View {
    let value: String
    let onCopied: () -> Void
    init(_ value: String, onCopied: @escaping () -> Void) {
        self.value = value
        self.onCopied = onCopied
    }

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            onCopied()
        } label: {
            HStack(spacing: 6) {
                ExplorerMonoText(value, middle: true)
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Copies it"))
    }
}

struct ExplorerMonoText: View {
    let text: String
    var middle = false
    init(_ text: String, middle: Bool = false) {
        self.text = text
        self.middle = middle
    }

    var body: some View {
        Text(verbatim: middle ? ExplorerFormat.short(text) : text)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
    }
}

/// A green dot whose ring pulses every 1.2 s while the Explorer shows, and stands still (no
/// ring) while it doesn't: a timeline that pauses, not a `repeatForever` that runs on in a hidden
/// Hub section (audit 2026-11-25 B2).
struct ExplorerLiveDot: View {
    @Environment(\.explorerPaused) private var paused

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { context in
            // 0 to 1 over each 1.2 s, eased out as the old animation was
            let linear = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            let phase = paused ? 1 : 1 - (1 - linear) * (1 - linear)
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(Color.green.opacity(0.6), lineWidth: 2)
                        .scaleEffect(1 + 1.2 * phase)
                        .opacity(1 - phase)
                )
        }
    }
}

/// Rows that dim while pressed, as the Chats list's do.
struct ExplorerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.systemGray5) : Color.clear)
    }
}

// MARK: - Formatting

enum ExplorerFormat {
    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func grouped(_ value: UInt64) -> String {
        groupedFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// An address split into two even lines.
    static func twoLines(_ text: String) -> String {
        guard text.count > 30 else { return text }
        let half = text.index(text.startIndex, offsetBy: (text.count + 1) / 2)
        return "\(text[..<half])\n\(text[half...])"
    }

    /// "kaspa:qpzpfw…g75psp", "a805f2…9eb9ae".
    static func short(_ text: String) -> String {
        guard text.count > 18 else { return text }
        let body: Substring
        let prefix: String
        if let colon = text.firstIndex(of: ":") {
            prefix = String(text[...colon])
            body = text[text.index(after: colon)...]
        } else {
            prefix = ""
            body = Substring(text)
        }
        guard body.count > 14 else { return text }
        // an address reads "kaspa:qzkw...q6w9" (owner, 2026-11-25); ids keep six each side
        if !prefix.isEmpty { return "\(prefix)\(body.prefix(4))...\(body.suffix(4))" }
        return "\(prefix)\(body.prefix(6))…\(body.suffix(6))"
    }

    /// One formatter for every row, made again only when the app's language changes (audit
    /// 2026-11-25 E3).
    @MainActor private static var relative: (locale: Locale, formatter: RelativeDateTimeFormatter)?

    @MainActor static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 5 { return AppLocalization.string("just now") }
        let locale = AppLocalization.locale
        let formatter: RelativeDateTimeFormatter
        if let relative, relative.locale == locale {
            formatter = relative.formatter
        } else {
            formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.locale = locale
            relative = (locale, formatter)
        }
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func hashrate(_ hashesPerSecond: Double) -> String {
        let units = ["H/s", "kH/s", "MH/s", "GH/s", "TH/s", "PH/s", "EH/s", "ZH/s"]
        var value = hashesPerSecond
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return String(format: "%.2f %@", value, units[index])
    }

    static func difficulty(_ value: Double) -> String {
        String(format: "%.3e", value)
    }

    /// "26.18B KAS".
    /// A block reward: up to 4 decimals ("1.9446 KAS").
    static func rewardKAS(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000
        return "\(kas.formatted(.number.precision(.fractionLength(2...4)))) \(KaspaUnit.symbol)"
    }

    static func compactUSD(_ dollars: Double) -> String {
        "$" + dollars.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
    }

    /// "6 days", "1 day" or "hours" until `date`.
    static func daysUntil(_ date: Date, now: Date) -> String {
        let days = Int(max(0, date.timeIntervalSince(now)) / 86_400)
        switch days {
        case 0: return String(localized: "hours")
        case 1: return String(localized: "1 day")
        default: return String(localized: "\(days) days")
        }
    }

    static func compactKAS(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000
        return "\(kas.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))) \(KaspaUnit.symbol)"
    }

    @MainActor static func usd(_ sompi: UInt64) -> String {
        let value = Double(sompi) / 100_000_000 * (ExplorerLive.shared.stats?.priceUSD ?? 0)
        return value.formatted(.currency(code: "USD"))
    }

    /// What a transaction moved: kUSDT for a token transaction, else KAS; "–" when it can't be
    /// told (a transaction read off the node, whose change isn't known).
    static func amountLine(_ tx: ExplorerTransaction, short: Bool = false) -> String {
        if let units = tx.tokenUnits { return TokenAmount.amount(units, token: .kusdt) }
        guard let sompi = tx.movedAmount else { return "–" }
        return short ? shortKAS(sompi) : KaspaUnit.amount(sompi)
    }

    /// A row's amount: "1.25 KAS", "12.3K KAS".
    static func shortKAS(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000
        let text = kas >= 1000
            ? kas.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
            : kas.formatted(.number.precision(.fractionLength(0...2)))
        return "\(text) \(KaspaUnit.symbol)"
    }
}
