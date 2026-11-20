import SwiftUI

// Small shared pieces the kUSDT screens use, as KaPay has them (ported 2026-11-19).

/// A bare `kaspa:` / `kaspatest:` address in upper case ("KASPA:QR…", what a compact QR code
/// carries) in lower case: bech32 is case-insensitive, but only in one case, so mixed case stays
/// as typed and fails the check. Anything else (a name, a link with a query) is returned as is.
func lowercasedKaspaAddress(_ text: String) -> String {
    let lower = text.lowercased()
    guard lower.hasPrefix("kaspa:") || lower.hasPrefix("kaspatest:"), !text.contains("?"),
          let colon = text.firstIndex(of: ":") else { return text }
    let payload = text[text.index(after: colon)...]
    return payload == payload.uppercased() || payload == payload.lowercased() ? lower : text
}

extension SwipeUpLabels {
    /// A swipe-up that confirms a transaction other than a Kaspa send (Combine Coins).
    static func transaction(done: LocalizedStringKey) -> SwipeUpLabels {
        SwipeUpLabels(
            release: "Release to Confirm",
            working: "Sending",
            workingDetail: "Broadcasting to the Kaspa BlockDAG...",
            done: done,
            recipientWord: "for",
            failedFallback: "The transaction didn't go out."
        )
    }
}

// MARK: - Half sheets that follow the user's text size

extension View {
    /// A fixed-height half sheet that grows with larger text, and at the accessibility sizes
    /// becomes a full, scrolling sheet, so its rows are never cut off. `scrolls: false` for content
    /// that scrolls itself (a Form or List has no height inside a ScrollView).
    func fittedSheetDetents(_ height: CGFloat, scrolls: Bool = true) -> some View {
        modifier(FittedSheetDetents(height: height, scrolls: scrolls))
    }
}

private struct FittedSheetDetents: ViewModifier {
    let height: CGFloat
    let scrolls: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Roughly how much taller the rows get above the default size.
    private var scale: CGFloat {
        switch typeSize {
        case .xLarge: return 1.1
        case .xxLarge: return 1.2
        case .xxxLarge: return 1.3
        default: return 1
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize, scrolls {
            ScrollView { content }
                .presentationDetents([.large])
        } else if typeSize.isAccessibilitySize {
            content
                .presentationDetents([.large])
        } else {
            content
                .presentationDetents([.height(height * scale)])
        }
    }
}
