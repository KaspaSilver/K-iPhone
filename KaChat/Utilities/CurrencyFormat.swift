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
    return "\(sign)\(currencySymbol(for: currency))\(String(format: "%.\(decimals)f", abs(value)))"
}

/// Trimmed 8-decimal KAS amount (e.g. "12.5" rather than "12.50000000").
/// Exact plain KAS text for a sompi amount, by integer math (no Double rounding at large
/// balances): "12.5", "0.00000001", "90000000.12345678".
func formatKasAmountPlain(sompi: UInt64) -> String {
    let whole = sompi / 100_000_000
    var fraction = String(sompi % 100_000_000)
    fraction = String(repeating: "0", count: 8 - fraction.count) + fraction
    while fraction.hasSuffix("0") { fraction.removeLast() }
    return fraction.isEmpty ? String(whole) : "\(whole).\(fraction)"
}

func formatKasAmountPlain(_ value: Double) -> String {
    var text = String(format: "%.8f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}
