import SwiftUI
import Charts

// The Explorer's full charts (owner, 2026-11-25): tapping Hashrate, KAS Price, Block Reward,
// Market Cap or Network Fee on the Explorer's home opens its history. Hashrate is kaspa.stream's
// history, price the feed Portfolio uses (CoinGecko, then Gate.io), market cap that price times
// the supply as it stood then, block reward Kaspa's emission schedule. Fee totals aren't in
// kaspa.stream's API: that chart is demo data and says so.

/// A number the Explorer can chart.
enum ExplorerChartMetric: String, CaseIterable, Hashable {
    case hashrate, price, blockReward, marketCap
    /// Total fees paid, a bar per hour, day or month (the tile shows the 24-hour average fee).
    case networkFees

    var title: LocalizedStringKey {
        switch self {
        case .hashrate: return "Hashrate"
        case .price: return "KAS Price"
        case .blockReward: return "Block Reward"
        case .marketCap: return "Market Cap"
        case .networkFees: return "Network Fees"
        }
    }

    /// The tile's icon: an SF Symbol, or "KaspaLogo" for the logo.
    var icon: String {
        switch self {
        case .hashrate: return "bolt.fill"
        case .price: return "KaspaLogo"
        case .blockReward: return "hammer.fill"
        case .marketCap: return "chart.bar.fill"
        case .networkFees: return "gauge.with.dots.needle.33percent"
        }
    }

    /// What the number is, under the chart.
    var explanation: LocalizedStringKey {
        switch self {
        case .hashrate:
            return "How many hashes a second miners point at Kaspa. More hashrate makes the network harder to attack."
        case .price:
            return "The price of one KAS in US dollars."
        case .blockReward:
            return "New KAS a block pays its miner. It drops a little every month and halves every year. In May 2025 blocks went from one to ten a second, so each block's reward became a tenth."
        case .marketCap:
            return "The price of KAS times every KAS mined so far."
        case .networkFees:
            return "Everything paid to get transactions into blocks, added up per day or month. The home screen shows the average fee one transaction paid yesterday."
        }
    }

    /// The reward changes in steps, the others move freely.
    var isStepped: Bool { self == .blockReward }

    /// Totals per hour, day or month, drawn as bars; the headline is the period's total.
    var isBars: Bool { self == .networkFees }

    func format(_ value: Double) -> String {
        switch self {
        case .hashrate: return ExplorerFormat.hashrate(value)
        case .price: return value < 0.01 ? String(format: "$%.5f", value) : String(format: "$%.4f", value)
        case .blockReward:
            return "\(value.formatted(.number.precision(.fractionLength(2...4)))) \(KaspaUnit.symbol)"
        case .marketCap: return ExplorerFormat.compactUSD(value)
        case .networkFees:
            // a single fee is tiny, a month's total is thousands
            let digits = value >= 1 ? 1...1 : 2...6
            return "\(value.formatted(.number.precision(.fractionLength(digits)))) \(KaspaUnit.symbol)"
        }
    }

    /// Shorter, for the chart's axis.
    func axisLabel(_ value: Double) -> String {
        if value == 0 { return (self == .price || self == .marketCap) ? "$0" : "0" }
        switch self {
        case .hashrate: return ExplorerFormat.hashrate(value)
        case .price: return String(format: value < 0.01 ? "$%.4f" : "$%.3f", value)
        case .blockReward: return value.formatted(.number.precision(.fractionLength(0...2)))
        case .marketCap: return ExplorerFormat.compactUSD(value)
        case .networkFees: return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        }
    }
}

struct ExplorerChartPoint: Identifiable, Hashable {
    let date: Date
    let value: Double
    var id: Date { date }
}

extension ExplorerDemo {
    /// Kaspa's mainnet launch, where All Time starts.
    static let mainnetLaunch = Date(timeIntervalSince1970: 1_636_329_600) // 2021-11-08
    /// Ten blocks a second from here (Crescendo).
    static let crescendo = Date(timeIntervalSince1970: 1_746_403_200) // 2025-05-05
    /// The chromatic emission phase: 440 KAS a second, falling every month to halve each year.
    static let chromaticStart = Date(timeIntervalSince1970: 1_651_536_000) // 2022-05-03

    /// `metric` over `period`, oldest first, ending on the home tile's number.
    static func series(_ metric: ExplorerChartMetric, period: ExplorerKPeriod, at now: Date) -> [ExplorerChartPoint] {
        if metric == .networkFees { return feeTotals(period: period, at: now) }
        let stats = stats(at: now)
        let (start, count): (Date, Int)
        switch period {
        case .day: (start, count) = (now.addingTimeInterval(-86_400), 96)
        case .week: (start, count) = (now.addingTimeInterval(-7 * 86_400), 168)
        case .month: (start, count) = (now.addingTimeInterval(-30 * 86_400), 120)
        case .allTime: (start, count) = (mainnetLaunch, 200)
        }
        let step = now.timeIntervalSince(start) / Double(count - 1)
        let dates = (0..<count).map { start.addingTimeInterval(Double($0) * step) }
        var r = Seeded("chart-\(metric.rawValue)-\(period.rawValue)")

        func walk(ending last: Double, wiggle: Double) -> [Double] {
            // a random walk built backwards from today's number
            var values = [last]
            for _ in 1..<count {
                let move = Double(r.int(-1000...1000)) / 1000 * wiggle
                values.append(max(values.last! * (1 + move), last * 0.2))
            }
            return values.reversed()
        }

        let values: [Double]
        switch metric {
        case .hashrate:
            if period == .allTime {
                // from a few TH/s at launch to today, mostly in 2023-2024
                values = dates.enumerated().map { index, date in
                    if index == count - 1 { return stats.hashrate }
                    let years = date.timeIntervalSince(mainnetLaunch) / (365 * 86_400)
                    let curve = 1 / (1 + exp(-(years - 2.3) * 2.6))
                    let noise = 1 + Double(r.int(-60...60)) / 1000
                    return max(2e12, stats.hashrate * curve * noise)
                }
            } else {
                values = walk(ending: stats.hashrate, wiggle: period == .day ? 0.006 : 0.012)
            }
        case .price:
            if period == .allTime {
                values = dates.enumerated().map { index, date in
                    if index == count - 1 { return stats.priceUSD }
                    let noise = 1 + Double(r.int(-80...80)) / 1000
                    return priceHistory(at: date) * noise
                }
            } else {
                values = walk(ending: stats.priceUSD, wiggle: period == .day ? 0.004 : 0.012)
            }
        case .blockReward:
            values = dates.map { rewardPerBlock(at: $0) }
        case .marketCap:
            let supplyNow = Double(stats.circulatingSupply) / 100_000_000
            if period == .allTime {
                values = dates.enumerated().map { index, date in
                    if index == count - 1 { return supplyNow * stats.priceUSD }
                    let share = min(1, date.timeIntervalSince(mainnetLaunch) / now.timeIntervalSince(mainnetLaunch))
                    let supply = supplyNow * (0.38 + 0.62 * sqrt(share))
                    return supply * priceHistory(at: date) * (1 + Double(r.int(-80...80)) / 1000)
                }
            } else {
                values = walk(ending: supplyNow * stats.priceUSD, wiggle: period == .day ? 0.004 : 0.012)
            }
        case .networkFees:
            return feeTotals(period: period, at: now) // handled above; kept for the switch
        }
        return zip(dates, values).map { ExplorerChartPoint(date: $0, value: $1) }
    }

    /// Fees paid per hour (24 hours), day (7 and 30 days) or month (all time), in KAS, oldest
    /// first; each point's date is its bucket's start, the last bucket still filling.
    static func feeTotals(period: ExplorerKPeriod, at now: Date) -> [ExplorerChartPoint] {
        var r = Seeded("fees-\(period.rawValue)")
        let calendar = Calendar.current
        let elapsed = max(0, now.timeIntervalSince(launchedAt))
        switch period {
        case .day:
            let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            return (0..<24).map { index in
                let start = hour.addingTimeInterval(Double(index - 23) * 3_600)
                let h = calendar.component(.hour, from: start)
                // quieter overnight (UTC), busier in the evening, as K's activity
                let curve = 0.55 + 0.45 * sin(Double(h - 6) / 24 * 2 * .pi)
                var kas = (26 + Double(r.int(0...80)) / 10) * curve + 6
                if index == 23 { kas = kas * min(1, now.timeIntervalSince(start) / 3_600) + elapsed * 0.0004 }
                return ExplorerChartPoint(date: start, value: kas)
            }
        case .week, .month:
            let days = period == .week ? 7 : 30
            let today = calendar.startOfDay(for: now)
            return (0..<days).map { index in
                let start = calendar.date(byAdding: .day, value: index - (days - 1), to: today) ?? today
                let weekday = calendar.component(.weekday, from: start)
                let weekend = (weekday == 1 || weekday == 7) ? 0.84 : 1
                var kas = (560 + Double(index * 4) + Double(r.int(-60...60))) * weekend
                if index == days - 1 { kas = kas * min(1, now.timeIntervalSince(start) / 86_400) + elapsed * 0.0004 }
                return ExplorerChartPoint(date: start, value: kas)
            }
        case .allTime:
            // monthly since mainnet: tiny at first, then the 2024 surge, then K's traffic
            var points: [ExplorerChartPoint] = []
            var month = calendar.dateInterval(of: .month, for: mainnetLaunch)?.start ?? mainnetLaunch
            while month <= now {
                let years = month.timeIntervalSince(mainnetLaunch) / (365 * 86_400)
                let surge = 1 / (1 + exp(-(years - 2.6) * 3))
                let kas = 40 + 15_500 * surge * (1 + Double(r.int(-120...120)) / 1000)
                points.append(ExplorerChartPoint(date: month, value: kas))
                month = calendar.date(byAdding: .month, value: 1, to: month) ?? now.addingTimeInterval(1)
            }
            if let last = points.popLast() {
                let share = min(1, now.timeIntervalSince(last.date) / (30.44 * 86_400))
                points.append(ExplorerChartPoint(date: last.date, value: last.value * share))
            }
            return points
        }
    }

    /// Market cap from a price history: each price times the supply as it stood then, worked back
    /// from today's supply along the emission schedule.
    static func marketCap(prices: [ExplorerChartPoint], supplyNow: Double) -> [ExplorerChartPoint] {
        guard supplyNow > 0, !prices.isEmpty else { return [] }
        var supply = supplyNow
        var result: [ExplorerChartPoint] = []
        var later = Date()
        for point in prices.reversed() {
            // KAS mined between this point and the next: the emission rate (reward x blocks a second)
            let mid = point.date.addingTimeInterval(later.timeIntervalSince(point.date) / 2)
            let perSecond = rewardPerBlock(at: mid) * (mid < crescendo ? 1 : 10)
            supply -= perSecond * max(0, later.timeIntervalSince(point.date))
            result.append(ExplorerChartPoint(date: point.date, value: point.value * max(supply, 0)))
            later = point.date
        }
        return result.reversed()
    }

    /// KAS a block pays: 500 a second before the chromatic phase, then 440 falling by 2^(1/12)
    /// every month; one block a second before Crescendo, ten after.
    static func rewardPerBlock(at date: Date) -> Double {
        let perSecond: Double
        if date < chromaticStart {
            perSecond = 500
        } else {
            let months = floor(date.timeIntervalSince(chromaticStart) / (30.44 * 86_400))
            perSecond = 440 * pow(0.5, months / 12)
        }
        return date < crescendo ? perSecond : perSecond / 10
    }

    /// A rough shape of KAS's price since launch, through a few known points.
    private static func priceHistory(at date: Date) -> Double {
        let points: [(TimeInterval, Double)] = [
            (1_636_329_600, 0.0003), (1_651_536_000, 0.0009), (1_672_531_200, 0.004),
            (1_690_848_000, 0.03), (1_704_067_200, 0.10), (1_722_470_400, 0.19),
            (1_735_689_600, 0.11), (1_746_403_200, 0.10), (1_767_225_600, 0.06),
            (1_795_000_000, 0.084),
        ]
        let t = date.timeIntervalSince1970
        guard let upper = points.firstIndex(where: { $0.0 >= t }) else { return points.last!.1 }
        guard upper > 0 else { return points[0].1 }
        let (t0, v0) = points[upper - 1], (t1, v1) = points[upper]
        // between two points the price moves evenly on a log scale
        let f = (t - t0) / (t1 - t0)
        return exp(log(v0) + (log(v1) - log(v0)) * f)
    }
}

/// The point under the finger. Its own object, observed only by the headline and the scrub
/// overlay (and the bars, which dim around it), so a drag doesn't rebuild the whole screen:
/// the 240-point chart, the summary and the Mining Estimate (smoothness audit L7).
@MainActor
final class ExplorerChartSelection: ObservableObject {
    @Published var point: ExplorerChartPoint?

    /// The point nearest `date`, by binary search (points are oldest first).
    static func nearest(_ points: [ExplorerChartPoint], to date: Date) -> ExplorerChartPoint? {
        guard !points.isEmpty else { return nil }
        var low = 0, high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].date < date { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return points[low] }
        let before = points[low - 1], after = points[low]
        return abs(before.date.timeIntervalSince(date)) <= abs(after.date.timeIntervalSince(date)) ? before : after
    }

    /// The last point at or before `date` (the bar whose span holds it), else the first.
    static func spanning(_ points: [ExplorerChartPoint], at date: Date) -> ExplorerChartPoint? {
        var low = 0, high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].date <= date { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? points[low - 1] : points.first
    }
}

/// One metric's history, full screen: the number (or the one under your finger), its change over
/// the range, the chart (drag to read any point), the range's high, low and average, and what the
/// number means.
struct ExplorerChartView: View {
    let metric: ExplorerChartMetric
    @State private var period: ExplorerKPeriod = .month

    /// Network Fees has no 24 Hours: Kaspalytics' totals are daily, and K's indexer doesn't count
    /// fees (owner, 2026-11-25: keep the indexer's work small).
    private var periods: [ExplorerKPeriod] {
        metric == .networkFees ? [.week, .month, .allTime] : ExplorerKPeriod.allCases
    }
    /// Held, not observed: only the views that show the selection watch it.
    @State private var selection = ExplorerChartSelection()
    @State private var points: [ExplorerChartPoint] = []
    @State private var loading = true
    @State private var failed = false
    /// Where the fees chart's points came from (the credit under it, or the demo pill).
    @State private var feeSource: ExplorerKStats.FeeSource?

    var body: some View {
        let points = points
        ScrollView {
            VStack(spacing: 16) {
                if metric == .networkFees && feeSource == .demo { ExplorerDemoPill() }
                ExplorerChartHeadline(metric: metric, period: period, points: points, selection: selection)
                    .redacted(reason: points.isEmpty ? .placeholder : [])
                ExplorerCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Group {
                            if points.isEmpty && loading {
                                ProgressView()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else if points.isEmpty {
                                VStack(spacing: 10) {
                                    Text("This chart couldn't load.")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Button("Try Again") { Task { await load() } }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else if metric.isBars {
                                ExplorerBarPlot(metric: metric, period: period, points: points, selection: selection)
                                    .opacity(loading ? 0.4 : 1)
                            } else {
                                ExplorerLinePlot(metric: metric, period: period, points: points, selection: selection)
                                    .opacity(loading ? 0.4 : 1)
                            }
                        }
                        .frame(height: 260)
                        HStack {
                            Spacer()
                            CycleCapsuleButton(options: periods, selection: $period,
                                               title: { $0.title }, hint: "Switches the time period")
                            Spacer()
                        }
                    }
                    .padding(14)
                }
                .padding(.horizontal, 16)
                summary(points)
                    .redacted(reason: points.isEmpty ? .placeholder : [])
                if metric == .hashrate {
                    // moved here from Portfolio's hashrate screen (owner, 2026-11-25)
                    ExplorerMiningEstimate()
                        .padding(.horizontal, 16)
                }
                if metric == .networkFees, feeSource == .kaspalytics {
                    Text("Daily totals for all of Kaspa · Data: Kaspalytics")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                }
                Text(metric.explanation)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }
            .padding(.bottom, 28)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: period) { _ in selection.point = nil }
        .task(id: period) { await load() }
    }

    /// The points for `period`, from wherever this metric's history lives.
    private func load() async {
        loading = true
        let wanted = period
        var fresh: [ExplorerChartPoint] = []
        switch metric {
        case .hashrate:
            fresh = (try? await ExplorerAPI.hashrateHistory(wanted)) ?? []
        case .price:
            fresh = await ExplorerAPI.priceHistory(wanted)
        case .marketCap:
            let prices = await ExplorerAPI.priceHistory(wanted)
            let supplyNow = Double(ExplorerLive.shared.stats?.circulatingSupply ?? 0) / 100_000_000
            fresh = ExplorerDemo.marketCap(prices: prices, supplyNow: supplyNow)
        case .networkFees:
            // Kaspalytics' daily history or K's indexer (`ExplorerKStats.feeSeries`); the demo last
            await ExplorerKStats.shared.refresh()
            if let real = ExplorerKStats.shared.feeSeries(wanted) {
                fresh = real.points
                feeSource = real.source
            } else {
                // made-up numbers only in Debug builds; Release says the chart couldn't load
                #if DEBUG
                fresh = ExplorerDemo.series(metric, period: wanted, at: Date())
                feeSource = .demo
                #else
                fresh = []
                feeSource = nil
                #endif
            }
        case .blockReward:
            fresh = ExplorerDemo.series(metric, period: wanted, at: Date())
        }
        guard wanted == period else { return }
        points = fresh
        loading = false
    }

    /// What one bar covers.
    static func bucketUnit(_ period: ExplorerKPeriod) -> Calendar.Component {
        switch period {
        case .day: return .hour
        case .week, .month: return .day
        case .allTime: return .month
        }
    }

    private var bucketUnit: Calendar.Component { Self.bucketUnit(period) }

    /// A bar's name: "3 PM", "Mon, Nov 24", "Nov 2025".
    static func bucketName(_ date: Date, period: ExplorerKPeriod) -> String {
        switch period {
        case .day: return date.formatted(.dateTime.weekday(.abbreviated).hour())
        case .week, .month: return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .allTime: return date.formatted(.dateTime.month(.wide).year())
        }
    }

    /// "4.2%", "15.1%", "27,743%": big changes lose their decimals.
    static func percent(_ change: Double) -> String {
        let size = abs(change)
        let digits = size >= 100 ? 0...0 : 1...1
        return size.formatted(.number.precision(.fractionLength(digits))) + "%"
    }

    static func xFormat(_ period: ExplorerKPeriod) -> Date.FormatStyle {
        switch period {
        case .day: return .dateTime.hour()
        case .week: return .dateTime.weekday(.abbreviated)
        case .month: return .dateTime.month(.abbreviated).day()
        case .allTime: return .dateTime.year()
        }
    }

    private func summary(_ points: [ExplorerChartPoint]) -> some View {
        // the bar still filling (this hour, today, this month) would pull Low and Average down
        let values = (metric.isBars ? Array(points.dropLast()) : points).map(\.value)
        let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                summaryTile("High", values.max() ?? 0)
                summaryTile("Low", values.min() ?? 0)
                summaryTile("Average", average)
            }
            if metric.isBars {
                Text(bucketUnit == .hour ? "Per hour" : (bucketUnit == .day ? "Per day" : "Per month"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 16)
    }

    private func summaryTile(_ title: LocalizedStringKey, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Text(verbatim: metric.format(value))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}


/// The big number over the chart: the latest point, or the one under your finger.
private struct ExplorerChartHeadline: View {
    let metric: ExplorerChartMetric
    let period: ExplorerKPeriod
    let points: [ExplorerChartPoint]
    @ObservedObject var selection: ExplorerChartSelection

    var body: some View {
        let selected = selection.point
        let shown = selected ?? points.last
        let first = points.first?.value ?? 0
        let change = first > 0 ? ((shown?.value ?? first) - first) / first * 100 : 0
        // bars: the period's total, or the bar under your finger
        let total = points.reduce(0) { $0 + $1.value }
        let big: String = metric.isBars
            ? metric.format(selected?.value ?? total)
            : (shown.map { metric.format($0.value) } ?? "–")
        return VStack(spacing: 6) {
            Text(verbatim: big)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            if metric.isBars {
                HStack(spacing: 6) {
                    if let selected {
                        Text(verbatim: ExplorerChartView.bucketName(selected.date, period: period))
                    } else {
                        Text("Total")
                        Text(LocalizedStringKey(period.title))
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            } else {
            HStack(spacing: 6) {
                Label {
                    Text(verbatim: ExplorerChartView.percent(change))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                }
                .foregroundColor(.accentColor)
                .font(.subheadline.weight(.semibold))
                if let selected {
                    Text(verbatim: selected.date.formatted(date: .abbreviated, time: period == .allTime ? .omitted : .shortened))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text(LocalizedStringKey(period.title))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }
}

/// The area and line. Doesn't watch the selection: the rule and dot under the finger are drawn
/// by `ExplorerChartScrub` over it, so a drag never rebuilds the marks.
private struct ExplorerLinePlot: View {
    let metric: ExplorerChartMetric
    let period: ExplorerKPeriod
    let points: [ExplorerChartPoint]
    let selection: ExplorerChartSelection

    var body: some View {
        let values = points.map(\.value)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max((high - low) * 0.08, high * 0.0005)
        let interpolation: InterpolationMethod = metric.isStepped ? .stepEnd : .catmullRom
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Date", point.date),
                         yStart: .value("Floor", max(0, low - pad)),
                         yEnd: .value("Value", point.value))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
        }
        .chartYScale(domain: max(0, low - pad)...(high + pad))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(verbatim: metric.axisLabel(v)).font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: ExplorerChartView.xFormat(period), collisionResolution: .greedy).font(.caption2)
            }
        }
        // drag along the chart to read any point
        .chartOverlay { proxy in
            GeometryReader { geo in
                ExplorerChartScrub(proxy: proxy, plotFrame: geo[proxy.plotAreaFrame], points: points,
                                   bars: false, selection: selection)
            }
        }
        .accessibilityLabel(Text(metric.title))
    }
}

/// Totals as bars from zero (Network Fees), the one under your finger picked out. Watches the
/// selection to dim the other bars; there are only a few dozen.
private struct ExplorerBarPlot: View {
    let metric: ExplorerChartMetric
    let period: ExplorerKPeriod
    let points: [ExplorerChartPoint]
    @ObservedObject var selection: ExplorerChartSelection

    var body: some View {
        let high = points.map(\.value).max() ?? 1
        let selected = selection.point
        Chart {
            ForEach(points) { point in
                BarMark(x: .value("Date", point.date, unit: ExplorerChartView.bucketUnit(period)),
                        y: .value("Value", point.value))
                    .foregroundStyle(Color.accentColor.opacity(selected == nil || selected == point ? 1 : 0.35))
                    .cornerRadius(2)
            }
        }
        .chartYScale(domain: 0...(high * 1.08))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(verbatim: metric.axisLabel(v)).font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: ExplorerChartView.xFormat(period), collisionResolution: .greedy).font(.caption2)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                ExplorerChartScrub(proxy: proxy, plotFrame: geo[proxy.plotAreaFrame], points: points,
                                   bars: true, selection: selection)
            }
        }
        .accessibilityLabel(Text(metric.title))
    }
}

/// The drag that reads a point, and on a line chart the dashed rule and dot at it. Only this
/// redraws as the finger moves.
private struct ExplorerChartScrub: View {
    let proxy: ChartProxy
    let plotFrame: CGRect
    let points: [ExplorerChartPoint]
    let bars: Bool
    @ObservedObject var selection: ExplorerChartSelection

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard let date: Date = proxy.value(atX: drag.location.x - plotFrame.origin.x) else { return }
                            let hit = bars
                                ? ExplorerChartSelection.spanning(points, at: date)
                                : ExplorerChartSelection.nearest(points, to: date)
                            if hit != selection.point {
                                selection.point = hit
                                Haptics.selection()
                            }
                        }
                        .onEnded { _ in selection.point = nil }
                )
            if !bars, let selected = selection.point,
               let x = proxy.position(forX: selected.date),
               let y = proxy.position(forY: selected.value) {
                let px = plotFrame.minX + x
                Path { path in
                    path.move(to: CGPoint(x: px, y: plotFrame.minY))
                    path.addLine(to: CGPoint(x: px, y: plotFrame.maxY))
                }
                .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .allowsHitTesting(false)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .position(x: px, y: plotFrame.minY + y)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// "If I point this much hashrate at Kaspa, what do I earn?" (moved from Portfolio's hashrate
/// screen to the Explorer's hashrate chart, owner 2026-11-25). Straight proportional share: your
/// hashrate over the network's, times what the network pays out a day (block reward x 10 blocks a
/// second). Deliberately no pool fee, power cost or luck: those are the miner's own numbers.
struct ExplorerMiningEstimate: View {
    @ObservedObject private var live = ExplorerLive.shared

    /// Miners talk in TH/s (one KS5 Pro is about 21), so that is the default. The unit is part of
    /// the input because typing 21 and meaning PH/s is a thousandfold error.
    private enum Unit: String, CaseIterable, Identifiable {
        case gh = "GH/s"
        case th = "TH/s"
        case ph = "PH/s"
        var id: String { rawValue }
        /// Multiplier to H/s.
        var toHs: Double {
            switch self {
            case .gh: return 1e9
            case .th: return 1e12
            case .ph: return 1e15
            }
        }
    }

    /// Empty, not a sample figure: a prefilled number reads as YOUR earnings.
    @State private var amountText = ""
    @State private var unit: Unit = .th

    private var network: Double? { live.stats.map(\.hashrate).flatMap { $0 > 0 ? $0 : nil } }
    private var rewardKas: Double? {
        live.stats.map { Double($0.blockReward) / 100_000_000 }.flatMap { $0 > 0 ? $0 : nil }
    }

    private var dailyKas: Double? {
        guard let network, let rewardKas,
              let amount = DecimalInputFormat.value(amountText), amount > 0 else { return nil }
        return rewardKas * 10 * 86_400 * (amount * unit.toHs) / network
    }

    var body: some View {
        ExplorerCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mining Estimate")
                    .font(.headline)
                HStack(spacing: 10) {
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                        .numericKeyboardDoneButton()
                        // grouped as you type: "1200000" is a number you'd have to count
                        .onChange(of: amountText) { newValue in
                            let grouped = DecimalInputFormat.grouped(newValue)
                            if grouped != amountText { amountText = grouped }
                        }
                        .font(.system(size: 20, weight: .semibold))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
                    Picker("", selection: $unit) {
                        ForEach(Unit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }
                if let dailyKas {
                    VStack(spacing: 8) {
                        payoutRow("Per day", kas: dailyKas)
                        Divider()
                        payoutRow("Per week", kas: dailyKas * 7)
                        Divider()
                        // 30 days, not a calendar month: the reward steps down monthly anyway
                        payoutRow("Per month", kas: dailyKas * 30)
                    }
                    .padding(.top, 2)
                    Text(assumptions)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Enter your hashrate to estimate earnings.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding(14)
        }
    }

    private func payoutRow(_ title: LocalizedStringKey, kas: Double) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "\(kas.formatted(.number.precision(.fractionLength(0...4)))) \(KaspaUnit.symbol)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if let price = live.stats?.priceUSD, price > 0 {
                    Text(verbatim: (kas * price).formatted(.currency(code: "USD")))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// What the number rests on, so nobody mistakes it for a promise.
    private var assumptions: String {
        guard let network, let rewardKas else { return "" }
        return String(
            format: AppLocalization.string("At %@ network hashrate and a %@ block reward. Before pool fees, power and luck, and both figures move."),
            locale: AppLocalization.locale,
            ExplorerFormat.hashrate(network), "\(String(format: "%.4f", rewardKas)) \(KaspaUnit.symbol)"
        )
    }
}
