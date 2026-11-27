import SwiftUI
import UIKit
import CryptoKit

// Switching accounts (owner, 2026-11-24): hold the dock's Profile icon and a half sheet lists the
// accounts saved on this phone; tap one to switch. The sign-in screen shows each account's picture
// beside its name. The pictures are each account's own avatar, saved on the phone while that
// account was signed in (`SavedAccountAvatars`), so neither screen looks up another address.

/// Each saved account's picture, kept on the phone: written while the account is signed in (the
/// dock's avatar, `DockAvatar`), read by the sign-in screen and the account switcher. Filed by the
/// account's public key, which is the same on mainnet and testnet.
@MainActor
final class SavedAccountAvatars: ObservableObject {
    static let shared = SavedAccountAvatars()

    /// Bumped on every save or removal, so the rows showing a picture redraw.
    @Published private(set) var revision = 0
    private var memory: [String: UIImage] = [:]
    private var missing: Set<String> = []

    /// Saved at this size: big enough for a 48 pt row on a 3x screen.
    private static let pixelSide: CGFloat = 144

    private static var folder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent("AccountAvatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func key(_ publicKey: String) -> String {
        let digest = SHA256.hash(data: Data(publicKey.lowercased().utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileURL(_ publicKey: String) -> URL? {
        folder?.appendingPathComponent("\(key(publicKey)).png")
    }

    func image(publicKey: String) -> UIImage? {
        let key = Self.key(publicKey)
        if let cached = memory[key] { return cached }
        if missing.contains(key) { return nil }
        guard let url = Self.fileURL(publicKey), let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            missing.insert(key)
            return nil
        }
        memory[key] = image
        return image
    }

    /// The signed-in account's picture changed (or was first worked out).
    func save(_ source: UIImage, publicKey: String) {
        let side = Self.pixelSide
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let scale = max(side / max(source.size.width, 1), side / max(source.size.height, 1))
            let w = source.size.width * scale, h = source.size.height * scale
            source.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        guard let data = square.pngData(), let url = Self.fileURL(publicKey) else { return }
        let key = Self.key(publicKey)
        if let old = try? Data(contentsOf: url), old == data { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        memory[key] = square
        missing.remove(key)
        revision += 1
    }

    /// The account has no picture any more, or the account was deleted.
    func remove(publicKey: String) {
        let key = Self.key(publicKey)
        guard let url = Self.fileURL(publicKey), FileManager.default.fileExists(atPath: url.path) else {
            memory[key] = nil
            return
        }
        try? FileManager.default.removeItem(at: url)
        memory[key] = nil
        missing.insert(key)
        revision += 1
    }
}

/// A saved account's picture, or its initials until one is known.
struct SavedAccountAvatar: View {
    let publicKey: String
    let name: String
    var size: CGFloat = 40
    @ObservedObject private var avatars = SavedAccountAvatars.shared

    var body: some View {
        let _ = avatars.revision
        KNSAvatarView(avatarURLString: nil, fallbackText: name, size: size,
                      overrideImage: avatars.image(publicKey: publicKey))
            .accessibilityHidden(true)
    }
}

/// The half sheet behind a hold on the dock's Profile icon: every account saved on this phone, the
/// signed-in one checked; tap another to switch to it.
struct AccountSwitcherSheet: View {
    @ObservedObject private var walletManager = WalletManager.shared
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var switchingId: String?
    @State private var keysMissingFor: SavedAccountSummary?
    @State private var showLogOutConfirm = false

    private static let rowHeight: CGFloat = 64
    private static let visibleRows = 4

    private var currentAddress: String? { walletManager.currentWallet?.publicAddress }

    private func isCurrent(_ account: SavedAccountSummary) -> Bool {
        guard let currentAddress else { return false }
        return WalletManager.accountAddressVariants(account.publicAddress)
            .contains { $0.lowercased() == currentAddress.lowercased() }
    }

    /// The signed-in account first, then the rest as the sign-in screen lists them.
    private var accounts: [SavedAccountSummary] {
        let all = walletManager.savedAccounts
        return all.filter(isCurrent) + all.filter { !isCurrent($0) }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Accounts")
                .font(.headline)
                .padding(.top, 22)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(accounts) { account in
                        row(account)
                    }
                }
            }
            .frame(height: CGFloat(min(max(accounts.count, 1), Self.visibleRows)) * (Self.rowHeight + 8))
            .scrollDisabled(accounts.count <= Self.visibleRows)
            Button {
                showLogOutConfirm = true
            } label: {
                Label("Add Another Account", systemImage: "plus.circle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .disabled(switchingId != nil)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(switchingId != nil)
        .alert("Recovery Phrase Needed", isPresented: Binding(
            get: { keysMissingFor != nil },
            set: { if !$0 { keysMissingFor = nil } }
        )) {
            Button("OK", role: .cancel) { keysMissingFor = nil }
        } message: {
            Text("This account's keys aren't on this phone. Log out, then sign in to it from the accounts screen with its recovery phrase.")
        }
        .alert("Add Another Account?", isPresented: $showLogOutConfirm) {
            Button("Log Out") {
                dismiss()
                Task { await walletManager.logout() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll go to the accounts screen to create or import one. This account stays saved on this phone.")
        }
    }

    private var sheetHeight: CGFloat {
        let rows = CGFloat(min(max(accounts.count, 1), Self.visibleRows))
        return 22 + 24 + 12 + rows * (Self.rowHeight + 8) + 12 + 44 + 30
    }

    private func row(_ account: SavedAccountSummary) -> some View {
        let current = isCurrent(account)
        return Button {
            switchTo(account)
        } label: {
            HStack(spacing: 12) {
                SavedAccountAvatar(publicKey: account.publicKey, name: account.displayAlias, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: account.displayAlias)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(verbatim: account.formattedPublicAddress)
                        .font(.scaled(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if switchingId == account.id {
                    ProgressView()
                } else if current {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                        .accessibilityLabel(Text("Signed in"))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(current ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(switchingId != nil)
    }

    private func switchTo(_ account: SavedAccountSummary) {
        guard switchingId == nil else { return }
        guard !isCurrent(account) else {
            dismiss()
            return
        }
        guard walletManager.hasKeysOnThisPhone(account) else {
            keysMissingFor = account
            return
        }
        Haptics.selection()
        let go = {
            switchingId = account.id
            Task { @MainActor in
                // dismissed first: the tabs this sheet sits on are rebuilt for the new account
                dismiss()
                await walletManager.switchToSavedAccount(account)
            }
        }
        if settingsViewModel.settings.biometricAccountLoginEnabled {
            DeviceAuth.authenticate(reason: "Unlock to sign in to \(account.displayAlias)") {
                go()
            } onFailure: {}
        } else {
            go()
        }
    }
}

/// The account switcher at Profile's top left (owner, 2026-11-26): your picture with a switch
/// symbol (it was a chip with your username beside the title); a tap opens `AccountSwitcherSheet`.
/// VoiceOver reads your username or short address.
struct ProfileAccountChip: View {
    @ObservedObject private var walletManager = WalletManager.shared
    @ObservedObject private var registry = KachatNamesRegistry.shared
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var showSwitcher = false

    private var label: String {
        guard let address = walletManager.currentWallet?.publicAddress else { return "" }
        // a long username is cut in the middle, so the chip stays beside the title
        if let name = UsernameMention.handle(for: address) {
            guard name.count > 18 else { return name }
            return "\(name.prefix(9))…\(name.suffix(7))"
        }
        // the address, short: "qzvr…l9ug"
        let body = address.split(separator: ":", maxSplits: 1).last.map(String.init) ?? address
        guard body.count > 10 else { return body }
        return "\(body.prefix(4))…\(body.suffix(4))"
    }

    @ViewBuilder
    private var glass: some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.6))
        }
    }

    var body: some View {
        Button {
            Haptics.selection()
            showSwitcher = true
        } label: {
            HStack(spacing: 6) {
                KNSAvatarView(avatarURLString: nil, fallbackText: label, size: 26,
                              contactAddress: walletManager.currentWallet?.publicAddress)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.bold))
                    .foregroundColor(.accentColor)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .background(glass)
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Switch Account"))
        .sheet(isPresented: $showSwitcher) {
            AccountSwitcherSheet()
                .environmentObject(settingsViewModel)
        }
    }
}

/// Share Profile beside Profile's title (owner, 2026-11-26), in the same glass as the switcher.
struct ProfileShareChip: View {
    let action: () -> Void

    @ViewBuilder
    private var glass: some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.6))
        }
    }

    var body: some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.accentColor)
                Text("Share Profile")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(glass)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
