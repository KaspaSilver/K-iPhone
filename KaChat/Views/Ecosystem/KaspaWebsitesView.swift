import SwiftUI

// Kaspa Websites (back 2026-11-21, phase 5): restored from before it left on 2026-10-24.
// `InAppBrowserScreen` (ContactsView.swift) is the browser it opens.

// MARK: - Profile Apps screen (Kaspa ecosystem quick links)

/// Bubble-style launchers for Kaspa ecosystem sites, each opening in an IN-APP browser
/// (SFSafariViewController) rather than kicking the user out to Safari.
struct ProfileAppsView: View {
    struct EcosystemApp: Identifiable {
        let name: String
        let icon: String
        let usesKaspaLogo: Bool
        let url: URL
        var id: String { name }
    }

    private let apps: [EcosystemApp] = [
        EcosystemApp(name: "Kaspa.org", icon: "", usesKaspaLogo: true, url: URL(string: "https://kaspa.org")!),
        EcosystemApp(name: "Kaspa Stream", icon: "waveform.path.ecg", usesKaspaLogo: false, url: URL(string: "https://kaspa.stream")!),
        EcosystemApp(name: "Kaspa Explorer", icon: "magnifyingglass", usesKaspaLogo: false, url: URL(string: "https://explorer.kaspa.org")!),
        EcosystemApp(name: "KasMap", icon: "map", usesKaspaLogo: false, url: URL(string: "https://kasmap.org")!),
        EcosystemApp(name: "Kaspa News", icon: "newspaper", usesKaspaLogo: false, url: URL(string: "https://kaspa.news")!),
        EcosystemApp(name: "KasPlay", icon: "gamecontroller", usesKaspaLogo: false, url: URL(string: "https://kasplay.fun")!),
        EcosystemApp(name: "KasMart", icon: "cart", usesKaspaLogo: false, url: URL(string: "https://kasmart.org")!),
        EcosystemApp(name: "KasMedia", icon: "doc.text.image", usesKaspaLogo: false, url: URL(string: "https://kasmedia.com")!),
        EcosystemApp(name: "Kaspalytics", icon: "chart.bar", usesKaspaLogo: false, url: URL(string: "https://www.kaspalytics.com")!),
        EcosystemApp(name: "Kas-Smiths", icon: "hammer", usesKaspaLogo: false, url: URL(string: "https://kas-smiths.org")!),
        EcosystemApp(name: "Kaspa Core R&D", icon: "atom", usesKaspaLogo: false, url: URL(string: "https://t.me/kasparnd")!),
        // Free testnet-10 KAS for the app's testnet mode (Settings > Testnet uses TN10).
        EcosystemApp(name: "TN10 Faucet", icon: "drop.fill", usesKaspaLogo: false, url: URL(string: "https://faucet-tn10.kaspanet.io")!)
    ]

    @State private var browserURL: URL?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 20)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(apps) { app in
                    Button {
                        Haptics.impact(.light)
                        browserURL = app.url
                    } label: {
                        VStack(spacing: 8) {
                            Group {
                                if app.usesKaspaLogo {
                                    Image("KaspaLogo")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 34, height: 34)
                                } else {
                                    Image(systemName: app.icon)
                                        .font(.scaled(size: 28, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .frame(width: 68, height: 68)
                            .background(
                                Circle()
                                    .fill(.regularMaterial)
                                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                                    .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
                            )
                            Text(app.name)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .navigationTitle("Kaspa Websites")
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(isPresented: Binding(
            get: { browserURL != nil },
            set: { if !$0 { browserURL = nil } }
        )) {
            if let browserURL {
                InAppBrowserScreen(url: browserURL) {
                    self.browserURL = nil
                }
            }
        }
    }
}
