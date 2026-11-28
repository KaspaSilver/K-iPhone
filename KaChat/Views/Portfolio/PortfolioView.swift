import SwiftUI
import Charts

struct PortfolioView: View {
    @ObservedObject private var viewModel = PortfolioViewModel.shared
    @ObservedObject private var portfolioManager = PortfolioManager.shared
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var showPriceChart = false
    @State private var showValueChart = false

    private var currency: AppCurrency { settingsViewModel.settings.currency }

    var body: some View {
        NavigationStack {
            // One continuous page: portfolio picker cards, then the two launcher squares, then the
            // Transactions section - no Data/Transactions tabs. Everything lives in the
            // transactions view's List, so scrolling flows straight from cards into
            // transactions, and the picker cards scroll away (collapse) cleanly.
            PortfolioTransactionsView(viewModel: viewModel) {
                Section {
                    PortfolioPickerHeader(
                        portfolios: portfolioManager.portfolios,
                        activePortfolioId: portfolioManager.activePortfolioId,
                        cardModel: cardModel(for:),
                        formatCurrency: { viewModel.valuesHidden ? PortfolioFormat.masked : PortfolioFormat.currency($0, currency) },
                        onSelect: { portfolioManager.setActivePortfolio($0) },
                        onAdd: { portfolioManager.addPortfolio(name: $0) },
                        onRename: { portfolioManager.renamePortfolio($0, to: $1) },
                        onDelete: { portfolioManager.deletePortfolio($0) },
                        onReorder: { portfolioManager.reorderPortfolios($0) }
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    // Two tappable squares: KAS price (left) and portfolio value (right). Each
                    // opens its own full-screen chart screen. The old inline price/value
                    // sparkline sliders were removed - those views now live behind these squares.
                    launcherSquares
                }
                .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    realizedPLCard
                }
                .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    feesCard
                }
                .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .pinnedTabHeader("Portfolio")
            // Landing here after a while: a fresh price without the whole launch burst.
            .onAppear {
                // never an empty picker: "Portfolio 1" if this account has none
                viewModel.ensureActivePortfolio()
                viewModel.refreshSpotPriceIfStale()
            }
            // All three destinations live HERE, on the stack's root, not on the buttons that
            // present them. Those buttons sit inside the transactions List, and a lazy container
            // only builds a child when it is about to be drawn - so the navigation stack could
            // not see a destination until its row happened to be on screen, which is both what
            // the runtime warning is about ("it will be ignored in a future release") and why
            // opening a chart took a visible moment: the push had to wait for SwiftUI to realise
            // the row and evaluate the destination before it had anything to push.
            .navigationDestination(isPresented: $showPriceChart) {
                KasPriceChartScreen(viewModel: viewModel)
            }
            .navigationDestination(isPresented: $showValueChart) {
                PortfolioValueChartScreen(viewModel: viewModel)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if viewModel.valuesHidden {
                        HStack(spacing: 6) {
                            Image("KaspaLogo").resizable().scaledToFit().frame(width: 15, height: 15)
                            Text(verbatim: "\(PortfolioFormat.masked) \(KaspaUnit.symbol)")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        BalanceToolbarLabel()
                    }
                }
            }
        }
    }

    private func cardModel(for portfolio: Portfolio) -> PortfolioCardModel {
        let change = viewModel.todayChange(for: portfolio.id)
        return PortfolioCardModel(
            id: portfolio.id,
            name: portfolio.name,
            currentValue: viewModel.currentValue(for: portfolio.id),
            todayChangeAmount: change?.amount,
            todayChangePercent: change?.percent
        )
    }

    // MARK: - Launcher squares

    private var launcherSquares: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.impact(.light)
                showPriceChart = true
            } label: {
                priceSquare
            }
            .buttonStyle(.plain)

            Button {
                Haptics.impact(.light)
                showValueChart = true
            } label: {
                valueSquare
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Realized P&L and fees

    private func localizedFormat(_ key: String, _ args: CVarArg...) -> String {
        String(format: AppLocalization.string(key), locale: AppLocalization.locale, arguments: args)
    }

    /// This calendar year's realized profit or loss in the active portfolio: this year's sells
    /// against the cost of the KAS they sold, oldest buys first (FIFO -
    /// `PortfolioViewModel.computeRealizedPL`).
    private var realizedPLCard: some View {
        let pl = viewModel.realizedPLThisYear
        let hidden = viewModel.valuesHidden
        var notes: [String] = []
        if pl.sellCount == 0 {
            notes.append(AppLocalization.string("No sells yet this year."))
        } else {
            notes.append(localizedFormat("Sells: %lld. Oldest buys first (FIFO).", pl.sellCount))
            if pl.uncoveredKas > 0 {
                notes.append(localizedFormat(
                    "%@ sold with no buy on record, counted at zero cost.",
                    hidden ? PortfolioFormat.masked : PortfolioFormat.kas(pl.uncoveredKas)
                ))
            }
        }
        if pl.pendingPriceCount > 0 {
            notes.append(AppLocalization.string("Some prices are still loading."))
        }
        let valueText = hidden
            ? PortfolioFormat.masked
            : (pl.amount > 0 ? "+" : "") + PortfolioFormat.currency(pl.amount, currency)
        let valueColor: Color = hidden || pl.sellCount == 0 ? .primary : (pl.amount >= 0 ? .green : .red)

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(.scaled(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(localizedFormat("Realized P&L %@", String(pl.year)))
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Text(valueText)
                    .font(.scaled(size: 20, weight: .bold))
                    .foregroundColor(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(notes.joined(separator: " "))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(portfolioGlassBackground(cornerRadius: 18))
    }

    /// Network fees the active portfolio's imported addresses paid - in KAS, and in the app
    /// currency at each day's price. Fed by Add Chatting Address (and Add Kaspa Address).
    private var feesCard: some View {
        let fees = viewModel.feeSummary
        let hidden = viewModel.valuesHidden
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "fuelpump")
                .font(.scaled(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Fees Spent")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.secondary)
                if fees.count == 0 {
                    Text(verbatim: "—")
                        .font(.scaled(size: 20, weight: .bold))
                    Text("Add your chatting address with + to count the network fees it has paid.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(hidden ? PortfolioFormat.masked : Self.feeKas(fees.totalKas))
                        .font(.scaled(size: 20, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(hidden ? PortfolioFormat.masked : PortfolioFormat.currency(fees.totalFiat, currency))
                        .font(.subheadline.weight(.semibold))
                    Text(fees.unpricedCount > 0
                         ? localizedFormat("Transactions: %lld. Some prices are still loading.", fees.count)
                         : localizedFormat("Transactions: %lld, at each day's price.", fees.count))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(portfolioGlassBackground(cornerRadius: 18))
    }

    /// Fees are fractions of a KAS - up to eight places, so a month of messages doesn't read 0.
    private static func feeKas(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 8
        formatter.locale = Locale(identifier: "en_US")
        return (formatter.string(from: NSNumber(value: value)) ?? String(format: "%.8f", value)) + " " + KaspaUnit.symbol
    }

    private var priceSquare: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image("KaspaLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                Text("Kaspa")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Text(viewModel.currentPriceUsd.map { PortfolioFormat.price($0, currency: currency) } ?? "—")
                .font(.scaled(size: 22, weight: .bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let change = viewModel.priceChange24h {
                changeBadge(percent: change, positive: change >= 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 128)
        .padding(14)
        .background(portfolioGlassBackground(cornerRadius: 18))
    }

    private var valueSquare: some View {
        let summary = viewModel.summary
        let todayChange = PortfolioManager.shared.activePortfolioId
            .flatMap { viewModel.todayChange(for: $0) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Value")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Text(viewModel.valuesHidden ? PortfolioFormat.masked : PortfolioFormat.currency(summary.currentValue, currency))
                .font(.scaled(size: 22, weight: .bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            // The last 24 hours, not all-time P&L. A card showing a number that only ever grows
            // over the life of the portfolio says nothing about today, and it sat next to the
            // Kaspa card's 24h figure reading as though the two were comparable.
            if let change = todayChange {
                changeBadge(percent: change.percent, positive: change.amount >= 0)
            } else {
                // No sample 24h old yet - a fresh portfolio has no move to report, and 0.00%
                // would be a claim rather than an absence.
                Text("24h change not available yet")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 128)
        .padding(14)
        .background(portfolioGlassBackground(cornerRadius: 18))
    }

    private func changeBadge(percent: Double, positive: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: positive ? "arrow.up" : "arrow.down").font(.caption2)
            Text("\(String(format: "%.2f", abs(percent)))%")
                .font(.footnote).fontWeight(.semibold)
        }
        .foregroundColor(positive ? .green : .red)
    }
}

// MARK: - KAS price full-screen chart

private struct KasPriceChartScreen: View {
    @ObservedObject var viewModel: PortfolioViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    /// Held, not observed: only the header and the chart's marker watch a scrub.
    @State private var scrub = PortfolioChartScrub()

    @State private var showPairSettings = false

    private var currency: AppCurrency { settingsViewModel.settings.currency }
    /// What the chart and its readout count in - the pair once the price is tapped.
    private var chartUnit: ChartUnit { viewModel.chartUnit }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PortfolioScrubReader(scrub: scrub) { scrubbed, range in
                    header(scrubbed: scrubbed, range: range)
                }
                chart
                PortfolioRangePicker(viewModel: viewModel, onChange: { scrub.clear() })
                KasConverterCard(priceUsd: viewModel.currentPriceUsd, currency: currency)
                marketStatsCard
            }
            .padding(16)
        }
        .refreshable { await viewModel.refreshPriceAsync() }
        .navigationTitle("KAS Price")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ChartPairSettingsButton(isPresented: $showPairSettings) }
        .sheet(isPresented: $showPairSettings) {
            ChartPairSettingsSheet(viewModel: viewModel)
        }
        // A finger scrubbing along the line from near the left edge is not a swipe out.
        .swipeBackDisabled()
    }

    private func flip() {
        guard viewModel.canFlipChart else { return }
        Haptics.impact(.light)
        scrub.clear()
        viewModel.flipChart()
    }

    /// Where Kaspa sits against every other coin, and what the whole supply is worth at the
    /// price above. Both come from the same keyless CoinGecko client the chart already uses;
    /// CoinMarketCap's own API needs a key, and the two ranks agree.
    @ViewBuilder
    private var marketStatsCard: some View {
        if viewModel.marketCap != nil || viewModel.marketCapRank != nil {
            VStack(spacing: 10) {
                if let rank = viewModel.marketCapRank {
                    HStack {
                        Text("Rank").font(.subheadline).foregroundColor(.secondary)
                        Spacer()
                        Text("#\(rank)").font(.subheadline.weight(.semibold))
                    }
                }
                if viewModel.marketCapRank != nil && viewModel.marketCap != nil {
                    Divider()
                }
                if let cap = viewModel.marketCap {
                    HStack {
                        Text("Market Cap").font(.subheadline).foregroundColor(.secondary)
                        Spacer()
                        Text(PortfolioFormat.compactCurrency(cap, currency))
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(14)
            .background(portfolioGlassBackground(cornerRadius: 18))
        }
    }

    // The Kaspa logo + name stay put while scrubbing - only the date + scrubbed price change.
    private func header(scrubbed: PricePoint?, range: ChartRangeSelection?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image("KaspaLogo").resizable().scaledToFit().frame(width: 30, height: 30)
                Text("Kaspa").font(.title3).fontWeight(.semibold)
                Spacer()
            }
            if let scrub = scrubbed {
                Text(scrub.timestamp, format: .dateTime.month().day().year().hour().minute())
                    .font(.subheadline).foregroundColor(.secondary)
            }
            if let range {
                ChartRangeSummary(range: range, valueText: { PortfolioFormat.price($0, unit: chartUnit) })
            }
            // The change sits UNDER the price rather than beside it. A long price and a long
            // change figure on one line had no room left at larger text sizes or in a currency
            // with a wordy symbol, and something had to shrink or clip. Stacked, neither
            // constrains the other whatever they say. Tap the price: the same chart in the pair.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text((scrubbed?.value ?? viewModel.chartCurrentPrice).map { PortfolioFormat.price($0, unit: chartUnit) } ?? "—")
                    .font(.scaled(size: 34, weight: .bold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                ChartCurrencyChip(viewModel: viewModel)
            }
            .contentShape(Rectangle())
            .onTapGesture { flip() }
            // Read off the series the chart is drawing, so the number and the line can never
            // disagree - and so it answers whichever range button is selected. Percent only:
            // the move in currency is the price above minus itself a moment ago, which the chart
            // already draws, and a per-KAS amount at four decimal places says very little.
            if scrubbed == nil, range == nil, let change = viewModel.chartPriceRangeChange {
                HStack(spacing: 3) {
                    Image(systemName: change.amount >= 0 ? "arrow.up" : "arrow.down").font(.footnote)
                    Text("\(String(format: "%.2f", abs(change.percent)))%")
                        .font(.subheadline).fontWeight(.semibold)
                    Text(viewModel.priceRangeLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .foregroundColor(change.amount >= 0 ? .green : .red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var chart: some View {
        if viewModel.chartPriceHistory.count >= 2 {
            PortfolioAreaChart(points: viewModel.chartPriceHistory, preciseAxis: viewModel.chartFlipped, scrub: scrub)
                .frame(height: 260)
        } else {
            ProgressView()
                .frame(height: 260)
                .frame(maxWidth: .infinity)
        }
    }

}

// MARK: - Portfolio value full-screen chart + stats

private struct PortfolioValueChartScreen: View {
    @ObservedObject var viewModel: PortfolioViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    /// Held, not observed: only the header and the chart's marker watch a scrub.
    @State private var scrub = PortfolioChartScrub()

    @State private var showPairSettings = false

    private var currency: AppCurrency { settingsViewModel.settings.currency }
    /// What the chart and the big number count in - the pair once the value is tapped. The
    /// stats card below stays in the app currency: buys were recorded in it.
    private var chartUnit: ChartUnit { viewModel.chartUnit }

    /// Every amount on this screen goes through here, so the eye button masks all of them.
    private func money(_ value: Double) -> String {
        viewModel.valuesHidden ? PortfolioFormat.masked : PortfolioFormat.currency(value, currency)
    }

    private func chartMoney(_ value: Double) -> String {
        viewModel.valuesHidden ? PortfolioFormat.masked : PortfolioFormat.amount(value, unit: chartUnit)
    }

    private func flip() {
        guard viewModel.canFlipChart else { return }
        Haptics.impact(.light)
        scrub.clear()
        viewModel.flipChart()
    }

    var body: some View {
        let summary = viewModel.summary
        let history = viewModel.chartValueHistory

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PortfolioScrubReader(scrub: scrub) { scrubbed, range in
                    header(currentValue: viewModel.chartCurrentValue, scrubbed: scrubbed, range: range)
                }

                if history.count >= 2 {
                    PortfolioAreaChart(points: history, hideValues: viewModel.valuesHidden, preciseAxis: viewModel.chartFlipped, scrub: scrub)
                        .frame(height: 240)
                } else if viewModel.chartFlipped, viewModel.valueHistory.count >= 2 {
                    // The pair's series for this range is still on its way.
                    ProgressView()
                        .frame(height: 240)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Not enough history yet - check back after a few days of activity.")
                        .font(.subheadline).foregroundColor(.secondary)
                        .frame(height: 240)
                        .frame(maxWidth: .infinity)
                }

                PortfolioRangePicker(viewModel: viewModel, onChange: { scrub.clear() })

                statsCard(summary)
            }
            .padding(16)
        }
        .refreshable { await viewModel.refreshPriceAsync() }
        .navigationTitle("Value Over Time")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ChartPairSettingsButton(isPresented: $showPairSettings) }
        .sheet(isPresented: $showPairSettings) {
            ChartPairSettingsSheet(viewModel: viewModel)
        }
        // A finger scrubbing along the line from near the left edge is not a swipe out.
        .swipeBackDisabled()
    }

    private func header(currentValue: Double?, scrubbed: PricePoint?, range: ChartRangeSelection?) -> some View {
        // The move across the SELECTED range, so pressing 1W answers "how did this do this week"
        // rather than repeating the 24h figure under every button.
        let rangeChange = viewModel.chartValueRangeChange
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Portfolio Value").font(.title3).fontWeight(.semibold)
                Spacer()
            }
            if let scrub = scrubbed {
                Text(scrub.timestamp, format: .dateTime.month().day().year())
                    .font(.subheadline).foregroundColor(.secondary)
            }
            if let range {
                ChartRangeSummary(range: range, valueText: chartMoney)
            }
            // The change sits UNDER the value rather than beside it - see the note on the price
            // header. A six-figure portfolio and its change had nowhere to go on one line.
            // Tap the value: the same chart in the pair.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text((scrubbed?.value ?? currentValue).map(chartMoney) ?? "—")
                    .font(.scaled(size: 34, weight: .bold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                ChartCurrencyChip(viewModel: viewModel)
            }
            .contentShape(Rectangle())
            .onTapGesture { flip() }
            // Hidden while scrubbing: the big number is then a past value, and a change figure
            // for the range sitting under it would read as that point's own move.
            if scrubbed == nil, range == nil, let rangeChange {
                let isUp = rangeChange.amount >= 0
                HStack(spacing: 4) {
                    Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.bold))
                    Text(viewModel.valuesHidden
                         ? "\(String(format: "%.2f", abs(rangeChange.percent)))%"
                         : "\(PortfolioFormat.amount(abs(rangeChange.amount), unit: chartUnit)) (\(String(format: "%.2f", abs(rangeChange.percent)))%)")
                        .font(.subheadline.weight(.semibold))
                    Text(viewModel.priceRangeLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .foregroundColor(isUp ? .green : .red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statsCard(_ summary: PortfolioSummary) -> some View {
        VStack(spacing: 0) {
            statRow("Holdings", viewModel.valuesHidden ? "\(PortfolioFormat.masked) \(KaspaUnit.symbol)" : PortfolioFormat.kas(summary.holdingsKas))
            Divider()
            statRow("Current Value", money(summary.currentValue))
            Divider()
            statRow("Total Invested", money(summary.totalInvested))
            Divider()
            statRow(
                "Total P&L",
                viewModel.valuesHidden
                    ? "\(String(format: "%.1f", summary.totalPLPercent))%"
                    : "\(PortfolioFormat.currency(summary.totalPL, currency)) (\(String(format: "%.1f", summary.totalPLPercent))%)",
                color: summary.totalPL >= 0 ? .green : .red
            )
            if let averageBuyPriceUsd = summary.averageBuyPriceUsd {
                Divider()
                statRow("Avg. Buy Price", PortfolioFormat.price(averageBuyPriceUsd, currency: currency))
            }
        }
        .padding(.vertical, 4)
        .background(portfolioGlassBackground(cornerRadius: 18))
    }

    private func statRow(_ label: LocalizedStringKey, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.body).fontWeight(.semibold).foregroundColor(color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Chart currency chip + pair settings

/// Beside the big number on a chart: what it and the chart count in, and that a tap flips
/// it. Lit up while flipped to the pair; absent when no pair is picked.
private struct ChartCurrencyChip: View {
    @ObservedObject var viewModel: PortfolioViewModel

    var body: some View {
        if viewModel.canFlipChart {
            let flipped = viewModel.chartFlipped
            HStack(spacing: 4) {
                Text(viewModel.chartUnit.code)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(flipped ? .orange : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill((flipped ? Color.orange : Color.secondary).opacity(0.14)))
        }
    }
}

/// The gear at the top right of both chart screens.
private struct ChartPairSettingsButton: ToolbarContent {
    @Binding var isPresented: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                isPresented = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Chart settings")
        }
    }
}

/// What a tap on the big number flips the chart to: bitcoin, VOO, gold or silver. One at a
/// time - turning one on turns the others off - or none, and then the number is just a number.
private struct ChartPairSettingsSheet: View {
    @ObservedObject var viewModel: PortfolioViewModel

    var body: some View {
        VStack(spacing: 14) {
            Text("Compare Against")
                .font(.headline)
                .padding(.top, 24)
            Text("Tap the price or your value to see it in the pair you pick here. One at a time.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            VStack(spacing: 0) {
                ForEach(Array(ChartPair.allCases.enumerated()), id: \.element) { index, pair in
                    if index > 0 { Divider().padding(.leading, 56) }
                    row(pair)
                }
            }
            .background(portfolioGlassBackground(cornerRadius: 18))
            .padding(.horizontal, 16)
            Spacer(minLength: 0)
        }
        .fittedSheetDetents(440)
        .presentationDragIndicator(.visible)
    }

    private func row(_ pair: ChartPair) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(pair))
                .font(.title3)
                .foregroundColor(tint(pair))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(pair.title).font(.body.weight(.semibold))
                Text(pair.subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { viewModel.chartPair == pair },
                set: { on in
                    Haptics.selection()
                    viewModel.setChartPair(on ? pair : nil)
                }
            ))
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func icon(_ pair: ChartPair) -> String {
        switch pair {
        case .bitcoin: return "bitcoinsign.circle.fill"
        case .voo: return "chart.line.uptrend.xyaxis.circle.fill"
        case .gold, .silver: return "circle.hexagongrid.circle.fill"
        }
    }

    private func tint(_ pair: ChartPair) -> Color {
        switch pair {
        case .bitcoin: return .orange
        case .voo: return .accentColor
        case .gold: return .yellow
        case .silver: return .gray
        }
    }
}

// MARK: - Shared range picker (1D / 1W / 1M / 3M / 1Y)

/// Drives `PortfolioViewModel.priceRangeDays`, which both the KAS price history AND the derived
/// portfolio value-over-time series read from, so this one control ranges both charts.
private struct PortfolioRangePicker: View {
    @ObservedObject var viewModel: PortfolioViewModel
    var onChange: () -> Void = {}

    /// YTD is a day count that changes daily, so it is computed when the picker is built.
    /// "All" is `days == 0`: everything CoinGecko has (`days=max`) - Kaspa's whole listed life.
    private let ranges: [(label: String, days: Int)] = [
        ("1D", 1), ("1W", 7), ("1M", 30), ("3M", 90), ("YTD", PortfolioViewModel.yearToDateDays), ("1Y", 365), ("All", 0)
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ranges, id: \.label) { range in
                Button {
                    Haptics.impact(.light)
                    onChange()
                    viewModel.setPriceRangeDays(range.days)
                } label: {
                    Text(LocalizedStringKey(range.label))
                        .font(.subheadline).fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(viewModel.priceRangeDays == range.days ? Color.accentColor.opacity(0.2) : Color.clear)
                        .foregroundColor(viewModel.priceRangeDays == range.days ? .accentColor : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Shared formatting + styling

/// Currency/price/KAS formatting shared by the portfolio squares and both chart screens. Built
/// manually via `currencySymbol(for:)` rather than `.formatted(.currency(code:))` - the latter is
/// Foundation's ISO-4217-driven `FormatStyle`, whose behavior for a non-ISO-4217 code like
/// `.bitcoin`'s "BTC" isn't something to rely on sight-unseen.
enum PortfolioFormat {
    /// What every amount reads as while Portfolio's eye button is on.
    static let masked = "••••••"

    /// Looked up once per currency: rows and the chart header ask for it on every redraw.
    static func currencySymbol(for currency: AppCurrency) -> String {
        if currency == .bitcoin { return "₿" }
        if let known = symbols[currency.code] { return known }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.code
        let symbol = formatter.currencySymbol ?? currency.code
        symbols[currency.code] = symbol
        return symbol
    }

    private static var symbols: [String: String] = [:]

    /// Every price, bitcoin, pair and currency figure goes through here, so they all use the
    /// in-app language's decimal and grouping marks (with Latin digits, as KAS amounts have).
    /// One formatter per locale and digit count: rows ask on every redraw.
    private static func decimal(_ value: Double, digits: Int) -> String {
        var identifier = AppLocalization.locale.identifier
        if !identifier.contains("numbers=") {
            identifier += identifier.contains("@") ? ";numbers=latn" : "@numbers=latn"
        }
        let key = "\(identifier)|\(digits)"
        let formatter: NumberFormatter
        if let cached = decimalFormatters[key] {
            formatter = cached
        } else {
            formatter = NumberFormatter()
            formatter.locale = Locale(identifier: identifier)
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = digits
            formatter.maximumFractionDigits = digits
            formatter.usesGroupingSeparator = true
            decimalFormatters[key] = formatter
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    private static var decimalFormatters: [String: NumberFormatter] = [:]

    static func price(_ value: Double, currency: AppCurrency) -> String {
        if currency == .bitcoin { return bitcoin(value) }
        let decimals = value < 1 ? 5 : 2
        return currencySymbol(for: currency) + decimal(value, digits: decimals)
    }

    /// A bitcoin amount in full: eight decimals at the least (a satoshi is the smallest unit),
    /// and more for a figure as small as one KAS in bitcoin, so at least four digits of it
    /// show rather than a row of zeros. Rounded to two places it read ₿0.00 for everything.
    static func bitcoin(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)
        var decimals = 8
        if magnitude > 0, magnitude < 0.0001 {
            decimals = min(12, max(8, Int(ceil(-log10(magnitude))) + 3))
        }
        return sign + "₿" + decimal(magnitude, digits: decimals)
    }

    /// A per-KAS price in whatever a chart counts in.
    static func price(_ value: Double, unit: ChartUnit) -> String {
        switch unit {
        case .currency(let currency): return price(value, currency: currency)
        case .pair(let pair): return pairAmount(value, pair: pair)
        }
    }

    /// An amount in whatever a chart counts in.
    static func amount(_ value: Double, unit: ChartUnit) -> String {
        switch unit {
        case .currency(let currency): return self.currency(value, currency)
        case .pair(let pair): return pairAmount(value, pair: pair)
        }
    }

    /// Shares of VOO, ounces of gold or silver: four decimals at the least, more for a figure
    /// as small as one KAS in gold so at least four digits of it show.
    static func pairAmount(_ value: Double, pair: ChartPair) -> String {
        if pair == .bitcoin { return bitcoin(value) }
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)
        var decimals = 4
        if magnitude > 0, magnitude < 0.001 {
            decimals = min(12, max(4, Int(ceil(-log10(magnitude))) + 3))
        }
        return sign + decimal(magnitude, digits: decimals) + pair.unitSuffix
    }

    static func currency(_ value: Double, _ currency: AppCurrency) -> String {
        if currency == .bitcoin { return bitcoin(value) }
        let sign = value < 0 ? "-" : ""
        return sign + currencySymbol(for: currency) + decimal(abs(value), digits: 2)
    }

    private static let kasFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    /// Large money in the form people actually quote it: $2.4B, not $2,412,880,314.00. A market
    /// cap written out in full is a wall of digits that has to be counted to be understood.
    static func compactCurrency(_ value: Double, _ currency: AppCurrency) -> String {
        let symbol = currencySymbol(for: currency)
        let magnitude = abs(value)
        let (scaled, suffix): (Double, String)
        switch magnitude {
        case 1_000_000_000_000...: (scaled, suffix) = (magnitude / 1_000_000_000_000, "T")
        case 1_000_000_000...: (scaled, suffix) = (magnitude / 1_000_000_000, "B")
        case 1_000_000...: (scaled, suffix) = (magnitude / 1_000_000, "M")
        case 1_000...: (scaled, suffix) = (magnitude / 1_000, "K")
        default: (scaled, suffix) = (magnitude, "")
        }
        let decimals = scaled < 10 ? 2 : (scaled < 100 ? 1 : 0)
        let sign = value < 0 ? "-" : ""
        return sign + symbol + String(format: "%.\(decimals)f", scaled) + suffix
    }

    static func kas(_ value: Double) -> String {
        let text = kasFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.4f", value)
        return text + " " + KaspaUnit.symbol
    }
}

private func portfolioGlassBackground(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
}

// MARK: - Chart

/// Swift Charts area+line chart with gridlines/axes and drag-to-scrub. Replaces the old bare
/// sparkline so the full-screen views read like a real price/value graph. The scrub object holds
/// the nearest point (or nil on release) so the screen's header can show the selected value/date.
/// Two fingers on a chart: the points under them and how the value moved between them.
struct ChartRangeSelection: Equatable {
    let start: PricePoint
    let end: PricePoint

    var amount: Double { end.value - start.value }
    var percent: Double? {
        guard start.value != 0 else { return nil }
        return (end.value - start.value) / abs(start.value) * 100
    }
}

/// "Mar 3 → Mar 9 · ▲ 12.34% (+$1.23)": the return across a two-finger range on a chart. The
/// screen supplies how a value is written, so the money charts mask when the eye is on.
private struct ChartRangeSummary: View {
    let range: ChartRangeSelection
    let valueText: (Double) -> String

    private var sameDay: Bool { Calendar.current.isDate(range.start.timestamp, inSameDayAs: range.end.timestamp) }

    var body: some View {
        let up = range.amount >= 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(range.start.timestamp, format: sameDay ? .dateTime.month().day().hour().minute() : .dateTime.month().day().year())
                Image(systemName: "arrow.right").font(.caption2)
                Text(range.end.timestamp, format: sameDay ? .dateTime.month().day().hour().minute() : .dateTime.month().day().year())
            }
            .font(.subheadline).foregroundColor(.secondary)
            HStack(spacing: 4) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right").font(.caption.weight(.bold))
                if let percent = range.percent {
                    Text("\(String(format: "%.2f", abs(percent)))%").font(.subheadline.weight(.semibold))
                }
                Text("(\(up ? "+" : "-")\(valueText(abs(range.amount))))").font(.subheadline)
            }
            .foregroundColor(up ? .green : .red)
        }
    }
}

/// What a finger is reading on a chart: one point, or a two-finger range. Its own object, so a
/// scrub redraws only the header and the marker over the chart, not the whole screen and the
/// chart's marks (smoothness audit L7).
@MainActor
final class PortfolioChartScrub: ObservableObject {
    @Published var point: PricePoint?
    @Published var range: ChartRangeSelection?

    func clear() {
        if point != nil { point = nil }
        if range != nil { range = nil }
    }
}

/// Redraws `content` alone when the scrub moves.
private struct PortfolioScrubReader<Content: View>: View {
    @ObservedObject var scrub: PortfolioChartScrub
    @ViewBuilder let content: (PricePoint?, ChartRangeSelection?) -> Content

    var body: some View { content(scrub.point, scrub.range) }
}

/// The rule and dot at the scrubbed point, or the shaded two-finger range, drawn over the chart
/// so the marks underneath never rebuild during a scrub.
private struct PortfolioScrubMarkers: View {
    @ObservedObject var scrub: PortfolioChartScrub
    let proxy: ChartProxy
    let plot: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let point = scrub.point,
               let x = proxy.position(forX: point.timestamp),
               let y = proxy.position(forY: point.value) {
                rule(at: plot.minX + x, color: Color.secondary.opacity(0.35))
                dot(at: CGPoint(x: plot.minX + x, y: plot.minY + y), color: .accentColor)
            }
            if let range = scrub.range,
               let x1 = proxy.position(forX: range.start.timestamp),
               let x2 = proxy.position(forX: range.end.timestamp) {
                let color: Color = range.amount >= 0 ? .green : .red
                Rectangle()
                    .fill(color.opacity(0.10))
                    .frame(width: max(0, x2 - x1), height: plot.height)
                    .position(x: plot.minX + (x1 + x2) / 2, y: plot.midY)
                ForEach([range.start, range.end], id: \.timestamp) { edge in
                    if let x = proxy.position(forX: edge.timestamp), let y = proxy.position(forY: edge.value) {
                        rule(at: plot.minX + x, color: color.opacity(0.6))
                        dot(at: CGPoint(x: plot.minX + x, y: plot.minY + y), color: color)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func rule(at x: CGFloat, color: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        .stroke(color, lineWidth: 1)
    }

    private func dot(at point: CGPoint, color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .position(point)
    }
}

private struct PortfolioAreaChart: View {
    let points: [PricePoint]
    /// The eye button: no value labels down the axis either.
    var hideValues = false
    /// Bitcoin-scale numbers: the default axis label rounds every tick to "0.000001", so
    /// label by significant digits instead.
    var preciseAxis = false
    /// The finger's point and the two-finger range, live; nil once they lift. Written here,
    /// not observed: `PortfolioScrubMarkers` draws them.
    let scrub: PortfolioChartScrub

    var body: some View {
        let values = points.map(\.value)
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 1
        let span = (maxV - minV) > 0 ? (maxV - minV) : max(abs(maxV), 1)
        let pad = span * 0.10
        let lowerBound = minV - pad
        let upperBound = maxV + pad

        // For a short (intraday, e.g. 1D) span, default date+time labels are wide and collide.
        // Format those as hours ("3 PM") and longer spans as dates ("Mar 5") so labels stay short.
        let timeSpan = (points.last?.timestamp ?? Date()).timeIntervalSince(points.first?.timestamp ?? Date())
        let isIntraday = timeSpan <= 2 * 24 * 60 * 60

        Chart {
            ForEach(points, id: \.timestamp) { point in
                AreaMark(
                    x: .value("Time", point.timestamp),
                    yStart: .value("Min", lowerBound),
                    yEnd: .value("Value", point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Value", point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .chartYScale(domain: lowerBound...upperBound)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                AxisValueLabel(format: isIntraday
                    ? Date.FormatStyle().hour()
                    : Date.FormatStyle().month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                if !hideValues {
                    if preciseAxis {
                        AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(3)))
                    } else {
                        AxisValueLabel()
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack {
                    PortfolioScrubMarkers(scrub: scrub, proxy: proxy, plot: geo[proxy.plotAreaFrame])
                    // One finger scrubs; two fingers select a range and read the return across it.
                    ChartTouchOverlay(
                        onSingle: { x in
                            guard let x, let nearest = nearestPoint(atX: x, proxy: proxy, geo: geo) else {
                                if scrub.point != nil { scrub.point = nil }
                                return
                            }
                            if scrub.point?.timestamp != nearest.timestamp {
                                scrub.point = nearest
                            }
                        },
                        onPair: { pair in
                            guard let pair,
                                  let first = nearestPoint(atX: pair.0, proxy: proxy, geo: geo, clamped: true),
                                  let second = nearestPoint(atX: pair.1, proxy: proxy, geo: geo, clamped: true) else {
                                if scrub.range != nil { scrub.range = nil }
                                return
                            }
                            let ordered = first.timestamp <= second.timestamp ? (first, second) : (second, first)
                            let range = ChartRangeSelection(start: ordered.0, end: ordered.1)
                            if scrub.range != range {
                                scrub.range = range
                            }
                        }
                    )
                }
            }
        }
    }

    /// The data point nearest to an x in the overlay's coordinates. `clamped` snaps a finger
    /// resting beyond the plot's edge to that edge, so a range can reach the first and last point.
    private func nearestPoint(atX x: CGFloat, proxy: ChartProxy, geo: GeometryProxy, clamped: Bool = false) -> PricePoint? {
        let plot = geo[proxy.plotAreaFrame]
        var xInPlot = x - plot.minX
        if clamped {
            xInPlot = min(max(xInPlot, 0), plot.width)
        } else {
            guard xInPlot >= 0, xInPlot <= plot.width else { return nil }
        }
        guard let date: Date = proxy.value(atX: xInPlot) else { return nil }
        return Self.nearest(to: date, in: points)
    }

    /// The point nearest a date. The series run oldest first, so a scrub step is a binary
    /// search, not a walk through every point (audit 2026-11-21 #33).
    private static func nearest(to date: Date, in points: [PricePoint]) -> PricePoint? {
        guard !points.isEmpty else { return nil }
        var low = 0
        var high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].timestamp < date { low = mid + 1 } else { high = mid }
        }
        // `low` is the first point at or after the date; the one before may be nearer.
        guard low > 0 else { return points[low] }
        let after = points[low]
        let before = points[low - 1]
        return abs(before.timestamp.timeIntervalSince(date)) <= abs(after.timestamp.timeIntervalSince(date)) ? before : after
    }
}

// MARK: - KAS <-> fiat converter

/// Two-way converter, in the slot the static "About Kaspa" blurb used to hold.
///
/// The blurb was read once and never again; a converter is the thing people actually reach for on
/// a price screen. It uses the SELECTED currency, so it answers the question in the units the rest
/// of the portfolio is already denominated in.
private struct KasConverterCard: View {
    let priceUsd: Double?
    let currency: AppCurrency

    /// Which field the user is typing in. The other is derived, so only one is ever authoritative
    /// and a rounded value can never be fed back through the rate and drift.
    private enum Field { case kas, fiat }

    @State private var kasText = "1"
    @State private var fiatText = ""
    @State private var editing: Field = .kas
    @FocusState private var focused: Field?

    /// Price in the SELECTED currency. `currentPriceUsd` is already converted upstream (it is what
    /// every other figure on this screen is drawn from), so this is a rename, not a conversion.
    private var rate: Double? {
        guard let priceUsd, priceUsd > 0 else { return nil }
        return priceUsd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Converter")
                .font(.headline)

            row(
                title: "KAS",
                text: $kasText,
                field: .kas,
                trailing: "KAS"
            )
            row(
                title: currency.code,
                text: $fiatText,
                field: .fiat,
                trailing: PortfolioFormat.currencySymbol(for: currency)
            )

            if let rate {
                // Not PortfolioFormat.price: that rounds to 5 decimals under a dollar, which
                // for a sub-cent coin throws away most of the rate the converter is applying.
                Text("1 KAS = \(PortfolioFormat.currencySymbol(for: currency))\(Self.format(rate))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Waiting for a price...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(portfolioGlassBackground(cornerRadius: 18))
        .onAppear { recompute(from: .kas) }
        // A price refresh, or switching currency, has to move the derived side.
        .onChange(of: priceUsd) { _ in recompute(from: editing) }
        .onChange(of: currency) { _ in recompute(from: editing) }
    }

    private func row(title: String, text: Binding<String>, field: Field, trailing: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .numericKeyboardDoneButton()
                .multilineTextAlignment(.trailing)
                .font(.scaled(size: 20, weight: .semibold))
                .focused($focused, equals: field)
                // The text sits at the right, so a tap usually lands left of it and the cursor
                // started before the number ("|1"). Editing starts at the end instead. After a
                // runloop turn, so SwiftUI's focus names which field this is.
                .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { note in
                    guard let textField = note.object as? UITextField else { return }
                    DispatchQueue.main.async {
                        guard focused == field, textField.isFirstResponder else { return }
                        let end = textField.endOfDocument
                        textField.selectedTextRange = textField.textRange(from: end, to: end)
                    }
                }
                .onChange(of: text.wrappedValue) { newValue in
                    // Only the focused field drives; without this the derived write would bounce
                    // straight back and the two would fight each other keystroke for keystroke.
                    guard focused == field else { return }
                    // Group what was just typed. The assignment re-enters this handler, so it
                    // only happens when the text actually changes - otherwise it never settles.
                    let grouped = DecimalInputFormat.grouped(newValue)
                    if grouped != newValue {
                        text.wrappedValue = grouped
                        return
                    }
                    editing = field
                    recompute(from: field)
                }
            Text(trailing)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    /// Writes the OTHER field from the one being edited.
    private func recompute(from field: Field) {
        guard let rate else { return }
        switch field {
        case .kas:
            let kas = Self.number(from: kasText)
            fiatText = kas.map { Self.format($0 * rate) } ?? ""
        case .fiat:
            let fiat = Self.number(from: fiatText)
            kasText = fiat.map { Self.format($0 / rate) } ?? ""
        }
    }

    /// Accepts either separator, and strips grouping. A decimal keypad emits the device locale's
    /// decimal separator, which is a comma in much of the world, and parsing that as an integer
    /// silently multiplied the amount.
    private static func number(from text: String) -> Double? {
        DecimalInputFormat.value(text)
    }

    /// Full precision, with the padding trimmed off.
    ///
    /// Fixed decimals do not work in either direction here: two decimals on the fiat side rounds
    /// 1 KAS to "0.05" and throws the rate away, and four on the KAS side is coarser than the
    /// eight sompi actually carries. So this writes eight decimals - Kaspa's own precision - and
    /// then drops the trailing zeros, keeping two so a whole amount still reads as money.
    ///
    /// Grouped on the way out, since the derived side is read far more often than it is edited
    /// and "1200000" is a number you have to count digits on. Safe to write back into an
    /// editable field because `number(from:)` strips grouping again on the way in.
    private static func format(_ value: Double) -> String {
        var text = String(format: "%.8f", value)
        while text.hasSuffix("0"), text.split(separator: ".").last?.count ?? 0 > 2 {
            text.removeLast()
        }
        return DecimalInputFormat.groupedFromCanonical(text)
    }
}

extension View {
    /// A main tab's title drawn above its list, with `AccountBackupBanner` just above it (KaPay's).
    /// A system large title sat behind the strip. The bar runs inline, and the tab's principal item
    /// keeps it from showing the title a second time.
    func pinnedTabHeader(_ title: LocalizedStringKey) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.systemGroupedBackground))
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
