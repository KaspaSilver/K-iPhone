import Foundation

/// Resolves an `AppCurrency` to its display symbol (e.g. "$", "€") - Bitcoin isn't ISO 4217, so
/// it's spelled out rather than trusted to `NumberFormatter`'s fallback behavior for an
/// unrecognized code. See `KaspaFiatAmountState`.
func currencySymbol(for currency: AppCurrency) -> String {
    if currency == .bitcoin { return "₿" }
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency.code
    return formatter.currencySymbol ?? currency.code
}

/// Generic fiat total - symbol + 2 decimals unless asked for more, for a read-only display label (e.g. a live
/// KAS-to-fiat conversion next to a Max button). Not meant to be parsed back - see
/// `KaspaFiatAmountState`, which keeps its own plain (no symbol) edit buffer for that.
func formatFiatAmount(_ value: Double, currency: AppCurrency, decimals: Int = 2) -> String {
    let sign = value < 0 ? "-" : ""
    // Grouped the way the phone writes numbers ("$1,234.56"; owner, 2026-11-22).
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    formatter.minimumFractionDigits = decimals
    formatter.maximumFractionDigits = decimals
    let number = formatter.string(from: NSNumber(value: abs(value))) ?? String(format: "%.\(decimals)f", abs(value))
    return "\(sign)\(currencySymbol(for: currency))\(number)"
}

/// A plain amount in `currency` with its decimals (2, or 8 for bitcoin), no symbol: what a
/// currency-mode amount field shows and parses back (KaPosts' default tip, from KaPost).
func formatCurrencyAmountPlain(_ value: Double, currency: AppCurrency) -> String {
    String(format: "%.\(currency == .bitcoin ? 8 : 2)f", value)
}

/// Exact plain KAS text for a sompi amount, by integer math (no Double rounding at large
/// balances): "12.5", "0.00000001", "90000000.12345678".
func formatKasAmountPlain(sompi: UInt64) -> String {
    let whole = sompi / 100_000_000
    var fraction = String(sompi % 100_000_000)
    fraction = String(repeating: "0", count: 8 - fraction.count) + fraction
    while fraction.hasSuffix("0") { fraction.removeLast() }
    return fraction.isEmpty ? String(whole) : "\(whole).\(fraction)"
}

/// Trimmed 8-decimal KAS amount (e.g. "12.5" rather than "12.50000000").
func formatKasAmountPlain(_ value: Double) -> String {
    var text = String(format: "%.8f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}

/// A sompi amount as KAS with all 8 decimals ("12.50000000"). The one copy of what several
/// screens each used to define for themselves.
func formatKasExact(_ sompi: UInt64) -> String {
    String(format: "%.8f", Double(sompi) / 100_000_000.0)
}

/// A sompi amount as KAS, trailing zeros trimmed ("12.5"), through a Double as before
/// (`formatKasAmountPlain(sompi:)` is the integer-exact one).
func formatKasTrimmed(_ sompi: UInt64) -> String {
    formatKasAmountPlain(Double(sompi) / 100_000_000.0)
}
