import SwiftUI

/// The balance at the top of an address's own page (Chatting Address, a Manage Addresses address,
/// a kUSDT address): the address's name, its balance large, and a line under it. The same card
/// KaPlay's Wallet tab shows its chatting balance in. Ported from KaPay (2026-11-20); keep in unison.
struct AddressBalanceCard<Footer: View>: View {
    let label: String
    /// The full address under the name, on an address's own page (owner, 2026-11-26): Manage
    /// Addresses' cards no longer show it.
    var address: String? = nil
    let amount: String
    /// Under the amount: worth in your currency, or what a kUSDT address holds with it.
    let detail: String?
    @ViewBuilder var footer: () -> Footer

    init(label: String, address: String? = nil, amount: String, detail: String?,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.label = label
        self.address = address
        self.amount = amount
        self.detail = detail
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
            if let address {
                Text(verbatim: address.wrappingAnywhere)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(verbatim: address))
                    .padding(.bottom, 4)
            }
            Text(verbatim: amount)
                .font(.largeTitle.weight(.bold))
                .foregroundColor(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let detail {
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            footer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BalanceCardBackground())
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

extension AddressBalanceCard where Footer == EmptyView {
    init(label: String, address: String? = nil, amount: String, detail: String?) {
        self.init(label: label, address: address, amount: amount, detail: detail) { EmptyView() }
    }
}

/// The balance card's teal gradient, also behind each address card on Manage Addresses.
struct BalanceCardBackground: View {
    var cornerRadius: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(
                colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 0.8)
            )
    }
}

/// An amount's worth in your currency on mainnet ("$1.91"); nothing on testnet or before the
/// price is known. Its own view so price updates redraw only this line.
struct KaspaFiatText: View {
    let sompi: UInt64
    @ObservedObject private var priceService = KasPriceModel.shared

    var body: some View {
        if let text = KaspaFiatText.text(sompi: sompi, priceService: priceService) {
            Text(verbatim: text)
        }
    }

    static func text(sompi: UInt64, priceService: KasPriceModel) -> String? {
        guard AppSettings.activeNetwork == .mainnet,
              let price = priceService.currentPriceUsd, price > 0 else { return nil }
        return formatFiatAmount(Double(sompi) / 100_000_000.0 * price, currency: priceService.currentCurrency)
    }
}

/// A Kaspa address's card, with its worth in your currency on mainnet (testnet coins aren't
/// worth anything). Its own view so price updates redraw only the card.
struct KaspaAddressBalanceCard: View {
    let label: String
    var address: String? = nil
    let sompi: UInt64
    @ObservedObject private var priceService = KasPriceModel.shared

    var body: some View {
        AddressBalanceCard(label: label, address: address,
                           amount: "\(KaspaUnit.groupedExact(sompi)) \(KaspaUnit.symbol)", detail: fiatText)
            .onAppear { priceService.refreshIfStale() }
    }

    private var fiatText: String? {
        KaspaFiatText.text(sompi: sompi, priceService: priceService)
    }
}

extension String {
    /// For showing an address on screen only: zero-width spaces between the characters, so it
    /// wraps anywhere with no hyphen. iOS hyphenated a long address ("jusm-"), which reads as part
    /// of it. Never copy or send this form.
    var wrappingAnywhere: String {
        map(String.init).joined(separator: "\u{200B}")
    }
}
