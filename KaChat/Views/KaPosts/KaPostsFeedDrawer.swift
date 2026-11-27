import SwiftUI
import UIKit

/// The feed's hamburger menu: a glass card that slides out from the left at the top of the
/// screen, only as tall as its rows (owner, 2026-11-27), with the feed dimmed around it. Tap
/// outside it, tap the close button or drag the card back to the left to close it.
///
/// It is a full-screen cover so it can sit above the dock; `KaPostsView` presents it through
/// `kaPostsPresent` (no cover animation), and the card draws its own slide over the picture of
/// the screen that `kaPostsPresent` took. Picking a row hands the item back through `onSelect`
/// and closes the card; the feed opens the item's screen once the card is gone, since a cover
/// cannot present the next one while it is still on screen.
struct KaPostsFeedDrawer: View {
    let items: [KaPostsView.SideMenuItem]
    let onSelect: (KaPostsView.SideMenuItem) -> Void
    /// Dismisses the cover; the card has already slid out.
    let onClose: () -> Void

    @State private var shown = false
    @State private var dragOffset: CGFloat = 0
    @State private var closing = false
    private let backdrop = KaPostsSlideSnapshot.image

    private let slideDuration: TimeInterval = 0.22

    var body: some View {
        GeometryReader { geo in
            // A glass card from the top, only as tall as its rows (owner, 2026-11-27: "top to
            // halfway down the screen enough to fit everything"), with the feed showing around it.
            let panelWidth = min(geo.size.width * 0.74, 340)
            let hidden = -(panelWidth + 32)
            let progress = shown ? 1 + min(0, dragOffset) / panelWidth : 0
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .accessibilityElement()
                    .accessibilityLabel("Close menu")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { close() }
                panel
                    .frame(width: panelWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(DrawerGlass(radius: 26))
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 18, x: 0, y: 8)
                    .padding(.leading, 12)
                    .padding(.top, 6)
                    .offset(x: shown ? min(0, dragOffset) : hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        guard !closing else { return }
                        dragOffset = min(0, value.translation.width)
                    }
                    .onEnded { value in
                        guard !closing else { return }
                        if -value.translation.width > panelWidth / 3
                            || value.predictedEndTranslation.width < -panelWidth / 2 {
                            close()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { dragOffset = 0 }
                        }
                    }
            )
            .background(backdropLayer(dim: 0.3 * progress))
        }
        .accessibilityAction(.escape) { close() }
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { shown = true }
        }
    }

    private func backdropLayer(dim: Double) -> some View {
        ZStack {
            if let backdrop {
                // Stretched to the screen, not scaled to fill: the picture IS the screen, and a
                // fill let the layout's proposal blow it up a few percent, so the strip of feed
                // beside the card no longer lined up with the real one.
                Image(uiImage: backdrop)
                    .resizable()
            } else {
                Color(.systemBackground)
            }
            Color.black.opacity(dim)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Posts")
                    .font(.title2.weight(.bold))
                Spacer(minLength: 0)
                Button {
                    Haptics.selection()
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.scaled(size: 14, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close menu")
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ForEach(items) { item in
                row(item)
            }
        }
        .padding(.bottom, 10)
    }

    private func row(_ item: KaPostsView.SideMenuItem) -> some View {
        Button {
            Haptics.impact(.light)
            onSelect(item)
            close()
        } label: {
            // As the Kaspa Hub menu draws its rows: the icon in a tinted circle, then the name.
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.scaled(size: 16, weight: .semibold))
                    .foregroundColor(Color("AccentColor"))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.accentColor.opacity(0.18)))
                Text(verbatim: item.rawValue)
                    .font(.body.weight(.medium))
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.rawValue))
    }

    private func close() {
        guard !closing else { return }
        closing = true
        withAnimation(.easeIn(duration: slideDuration)) {
            shown = false
            dragOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + slideDuration) { onClose() }
    }
}

/// The card's glass, as the Kaspa Hub menu's: Liquid Glass on iOS 26, a thin material before.
private struct DrawerGlass: View {
    let radius: CGFloat

    var body: some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
        }
    }
}
