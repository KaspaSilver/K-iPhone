import SwiftUI
import CoreImage
import UIKit

struct ChatInfoView: View {
    /// The one screen for anyone's profile: a 1:1 chat header, a group roster row and a public
    /// chat sender all open this, with the same title and the same rows.
    @Binding var contact: Contact
    @Environment(\.dismiss) private var dismiss
    /// Revealed values for the Aliases section's rows (nil while hidden behind dots).
    @State private var revealedReceivingAlias: String?
    @State private var revealedSendingAlias: String?

    @EnvironmentObject var contactsManager: ContactsManager
    @ObservedObject private var addressBook = AddressBookManager.shared
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var walletManager: WalletManager
    /// The address's `.kachat` identity (testnet): its label and its profile record - your own
    /// straight from the registry, anyone else's through the names indexer once one is connected.
    @ObservedObject private var kachatRegistry = KachatNamesRegistry.shared
    @ObservedObject private var socialImages = KachatSocialImageResolver.shared
    @State private var kachatLabel: String?
    @State private var kachatProfile: KachatNames.Profile?

    @State private var editedAlias: String = ""
    @State private var notificationModeOverride: ContactNotificationMode? = nil
    /// Which section's half sheet is up.
    @State private var activeSheet: InfoSheet?

    private enum InfoSheet: String, Identifiable {
        case address, kachatNames, aliases, notifications
        var id: String { rawValue }
    }
    /// Add to Contacts, or the Contacts entry, full screen.
    @State private var showAddressBookEditor = false
    @State private var showAvatarPreview = false
    @State private var isBioExpanded = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var messageSent: Int = 0
    @State private var messageReceived: Int = 0
    @FocusState private var isEditing: Bool

    /// A KaChat bot's User Info is only its name and its address: nobody to share or manage.
    private var isBot: Bool { KaChatBot.isBot(contact.address) }

    /// Your own User Info - reached from your own profile link. Shows who you are (name, avatar,
    /// KNS profile, address, domains, share) and none of the per-contact settings, which have
    /// nothing to act on when the person is you.
    private var isSelf: Bool {
        guard let mine = walletManager.currentWallet?.publicAddress.lowercased() else { return false }
        return mine == contact.address.lowercased()
    }

    private var messages: [ChatMessage] {
        chatService.conversations.first(where: { $0.contact.address == contact.address })?.messages ?? []
    }

    /// nil hides the "Chess Stats" row entirely - only shown once this contact has actually played
    /// at least one chess game (an always-visible "0W - 0L" on every contact who's never played
    /// would just be clutter). See `ChessGameService.record`.
    /// Counted once per change of the conversation (`chessRecordKey`), not in `body`: it parses
    /// every message, and this screen redraws on each ChatService update.
    @State private var chessRecord: ChessRecordValue?

    struct ChessRecordValue: Equatable {
        let wins: Int
        let losses: Int
    }

    private var chessRecordKey: String {
        let all = messages
        return "\(all.count)|\(all.last?.txId ?? "")"
    }

    private func computeChessRecord() -> ChessRecordValue? {
        guard let myAddress = walletManager.currentWallet?.publicAddress else { return nil }
        let hasChessHistory = messages.contains {
            if case .invite = ChessCodec.parseAny(MessageReplyCodec.unwrappedText($0.content)) { return true }
            return false
        }
        guard hasChessHistory else { return nil }
        let record = ChessGameService.record(in: messages, myAddress: myAddress, contactAddress: contact.address)
        return ChessRecordValue(wins: record.wins, losses: record.losses)
    }

    /// The `.kachat` profile's pieces, each looked up from its social link on this device. They
    /// come first; the KNS ones are the fallback.
    private var kachatAvatar: String? { socialImages.openedProfile(for: kachatProfile?.avatar, address: contact.address)?.avatar }
    private var kachatBanner: String? { socialImages.openedProfile(for: kachatProfile?.banner, address: contact.address)?.banner }
    private var kachatBio: String? { socialImages.openedProfile(for: kachatProfile?.bio, address: contact.address)?.bio }

    /// The address's active `.kachat` names, its primary (label) first.
    private var kachatNames: [String] {
        let names = kachatRegistry.cachedIdentity(for: contact.address)?.names ?? []
        guard let label = kachatLabel, names.contains(label) else { return names }
        return [label] + names.filter { $0 != label }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isBot {
                    Section {
                        shareButton
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                }

                Section {
                    if let kachatBanner {
                        KNSBannerImageView(bannerURLString: kachatBanner, height: 110, cornerRadius: 10, fitsWidth: true)
                    }

                    HStack {
                        Button {
                            showAvatarPreview = true
                        } label: {
                            KNSAvatarView(
                                avatarURLString: kachatAvatar,
                                fallbackText: contactsManager.displayName(for: contact),
                                size: 60,
                                contactAddress: contact.address
                            )
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 4) {
                            // A bare TextField styled like a heading reads as a label, not
                            // something you can change - the pencil is what says otherwise. It
                            // focuses the field too, so it works as the affordance it looks like
                            // rather than being decoration next to the real target.
                            if isSelf {
                                Text(verbatim: kachatLabel.map(KachatNameLabel.display) ?? contactsManager.displayName(for: contact))
                                    .font(.headline)
                                    .lineLimit(1)
                            } else {
                                HStack(spacing: 6) {
                                    TextField("Name", text: $editedAlias)
                                        .font(.headline)
                                        .focused($isEditing)
                                    Button {
                                        isEditing = true
                                    } label: {
                                        Image(systemName: "pencil")
                                            .font(.scaled(size: 13, weight: .semibold))
                                            .foregroundColor(.accentColor)
                                            .frame(width: 26, height: 26)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(Text("Edit name"))
                                }
                            }

                            // Matches Android: the plain contact-name card shows the address as a
                            // fallback caption; once the contact owns any KNS domain, the fancier
                            // profile card below takes over that spot with the bio instead.
                            if let kachatBio {
                                Text(verbatim: kachatBio)
                                    .font(.subheadline)
                                    .lineLimit(isBioExpanded ? nil : 5)
                                    .onTapGesture {
                                        withAnimation { isBioExpanded.toggle() }
                                    }
                                    .onLongPressGesture(minimumDuration: 0.45) {
                                        copyProfileFieldValue(kachatBio, fieldName: "Bio")
                                    }
                                if let linktree = kachatProfile?.linktree, let url = URL(string: linktree) {
                                    Link(destination: url) {
                                        Label {
                                            Text(verbatim: linktree.replacingOccurrences(of: "https://", with: ""))
                                        } icon: {
                                            Image(systemName: "link")
                                        }
                                        .font(.caption.weight(.semibold))
                                    }
                                }
                            } else {
                                Text(formatAddress(contact.address))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.leading, 8)
                    }
                    .padding(.vertical, 8)
                }

                if isBot {
                    addressSection
                } else {
                    Section {
                        // Each section is a card that opens a half sheet. The form had grown to
                        // seven stacked sections - a QR, a domain list, alias reveals, system
                        // contact linking, two pickers and a stats block - which is a lot of screen
                        // to scroll past to reach any one of them.
                        // Straight into the 1:1 thread. This screen is also reached from a group
                        // roster, where the person may be someone you have
                        // never messaged - and the only route to them was backing out and finding
                        // them on the chat list.
                        if !isSelf {
                            infoCard(
                                "Open Chat",
                                systemImage: "bubble.left.and.bubble.right"
                            ) { openChatWithContact() }
                        }

                        infoCard(
                            "Address",
                            systemImage: "qrcode"
                        ) { activeSheet = .address }

                        // On testnet: the address's .kachat names (its identity there, not KNS).
                        if KachatNamesService.isEnabled {
                            infoCard(
                                ".kachat Names",
                                systemImage: "at"
                            ) { activeSheet = .kachatNames }
                            .disabled(kachatNames.isEmpty)
                        }

                        // Per-contact settings: the chat's aliases, the Address Book entry and the
                        // notification choice. None of them has anything to act on in your own User
                        // Info.
                        if !isSelf {
                            infoCard(
                                "Aliases",
                                systemImage: "number"
                            ) { activeSheet = .aliases }

                            infoCard(
                                addressBook.entry(for: contact.address) == nil ? localized("Add to Contacts") : localized("Contacts"),
                                systemImage: addressBook.entry(for: contact.address) == nil ? "person.text.rectangle" : "person.text.rectangle.fill"
                            ) { showAddressBookEditor = true }

                            infoCard(
                                "Notifications",
                                systemImage: notificationModeOverride == .off ? "bell.slash" : "bell"
                            ) { activeSheet = .notifications }
                        }
                    }

                    if !isSelf {
                        infoSection
                    }
                }
            }
            .toast(message: toastMessage, style: toastStyle)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .address: addressSheet
                case .kachatNames: kachatNamesSheet
                case .aliases: aliasesSheet
                case .notifications: notificationsSheet
                }
            }
            .fullScreenCover(isPresented: $showAddressBookEditor) {
                AddressBookEntryEditor(
                    address: contact.address,
                    // the name in this screen's field, saved or just typed
                    presetName: editedAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil : editedAlias.trimmingCharacters(in: .whitespacesAndNewlines)
                ) { result in
                    // The editor gave them a name (or took it away) on the contact and the entry.
                    // Take it here too, or this screen's Save would write its older name back
                    // over both.
                    if let fresh = contactsManager.getContact(byAddress: contact.address) {
                        contact.alias = fresh.alias
                    }
                    editedAlias = contact.assignedName ?? addressBook.entry(for: contact.address)?.customName ?? ""
                    switch result {
                    case .saved: showToast(localized("Saved to Contacts."))
                    case .removed: showToast(localized("Removed from Contacts."))
                    }
                }
            }
            .navigationTitle("User Info")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showAvatarPreview) {
                KNSAvatarFullscreenView(
                    avatarURLString: kachatAvatar,
                    fallbackText: contactsManager.displayName(for: contact),
                    title: contactsManager.displayName(for: contact),
                    contactAddress: contact.address
                )
            }
            .toolbar {
                if isSelf {
                    // Nothing on your own User Info is editable, so nothing to save.
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saveChanges()
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                // the name you gave them, wherever you gave it (the chat or the Address Book)
                editedAlias = contact.assignedName ?? addressBook.entry(for: contact.address)?.customName ?? ""
                notificationModeOverride = contact.notificationModeOverride
            }
            .task {
                let stats = await MessageStore.shared.messageStats(contactAddress: contact.address)
                messageSent = stats.sent
                messageReceived = stats.received
            }
            .task(id: kachatRegistry.revision) { await loadKachatIdentity() }
            .task(id: chessRecordKey) {
                let record = computeChessRecord()
                if record != chessRecord { chessRecord = record }
            }
        }
    }

    /// The `.kachat` label and profile for this address (testnet only). Your own profile comes
    /// straight from the registry - the record you saved, even before any indexer has it.
    /// Someone else's comes from the names indexer; without one, only their label shows.
    private func loadKachatIdentity() async {
        guard KachatNamesService.isEnabled else {
            kachatLabel = nil
            kachatProfile = nil
            return
        }
        await kachatRegistry.refreshIfStale(maxAge: 300)
        let identity = try? await kachatRegistry.identity(address: contact.address)
        kachatLabel = identity?.label
        kachatProfile = (isSelf ? kachatRegistry.ownProfile(for: contact.address)?.profile : nil) ?? identity?.profile
    }

    private func formatAddress(_ address: String) -> String {
        guard address.count > 20 else { return address }
        let prefix = address.prefix(12)
        let suffix = address.suffix(8)
        return "\(prefix)...\(suffix)"
    }

    /// One reveal-then-copy alias row: dots + eye while hidden, first tap derives and reveals
    /// the monospaced value, tapping the revealed value copies it with the standard toast.
    private var addressSheet: some View {
        NavigationStack {
            Form {
                addressSection
            }
            .navigationTitle("Address")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// The QR code and full address, tap to copy, with View in Explorer.
    private var addressSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = contact.address
                Haptics.success()
                showToast(contact.address.addressCopiedToastText)
            } label: {
                VStack(spacing: 12) {
                    if let qrImage = AddressReceiveView<EmptyView, EmptyView>.qrImage(for: contact.address) {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                            .padding(12)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.accentColor, lineWidth: 2)
                            )
                    }
                    Text(contact.address)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        } header: {
            HStack {
                Text("Address")
                Spacer()
                if let url = settingsViewModel.settings.kaspaExplorer.addressURL(for: contact.address) {
                    Link("View in Explorer", destination: url)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    /// The address's `.kachat` names (testnet), its primary one marked.
    private var kachatNamesSheet: some View {
        NavigationStack {
            List {
                ForEach(kachatNames, id: \.self) { name in
                    HStack(spacing: 8) {
                        Text(verbatim: KachatNameLabel.display(name))
                            .lineLimit(1)
                        if name == kachatLabel {
                            Text("Primary")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.accentColor)
                        }
                        Spacer()
                        if !isSelf && !isBot {
                            setAsNameButton(for: name)
                        }
                    }
                    .contentShape(Rectangle())
                    .onLongPressGesture { copyProfileFieldValue("\(name).kachat", fieldName: "Domain") }
                }
            }
            .navigationTitle(".kachat Names")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Set as Name: puts this .kachat name, in full ("alice.kachat"), in this screen's name field.
    /// Nothing is saved until Save (top right); Cancel leaves their name as it was. Shown as set
    /// once it is what the field holds.
    @ViewBuilder
    private func setAsNameButton(for name: String) -> some View {
        let full = "\(name).kachat"
        if editedAlias.trimmingCharacters(in: .whitespacesAndNewlines) == full {
            Label("Their Name", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        } else {
            Button {
                Haptics.impact(.light)
                editedAlias = full
                activeSheet = nil
            } label: {
                Text("Set as Name")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
            .buttonStyle(.borderless)
        }
    }

    private var aliasesSheet: some View {
        NavigationStack {
            Form {
                // This conversation's deterministic pair aliases (DeterministicAlias, ECDH +
                // HKDF, 12 hex chars). Direction semantics match ChatService's routing state:
                // deriveMyAlias = deterministicMyAlias = incoming/watch (the alias messages
                // FROM this contact carry, what we watch for), deriveTheirAlias =
                // deterministicTheirAlias = outgoing/send (the alias OUR messages to them
                // carry). Hidden behind dots until tapped; keys are only touched on demand.
                Section {
                    aliasRow("Receiving alias", value: $revealedReceivingAlias) {
                        guard let key = walletManager.getPrivateKey() else { return nil }
                        return try? DeterministicAlias.deriveMyAlias(privateKey: key, theirAddress: contact.address)
                    }
                    aliasRow("Sending alias", value: $revealedSendingAlias) {
                        guard let key = walletManager.getPrivateKey() else { return nil }
                        return try? DeterministicAlias.deriveTheirAlias(privateKey: key, theirAddress: contact.address)
                    }
                } header: {
                    Text("Aliases")
                }
            }
            .navigationTitle("Aliases")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var notificationsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Incoming Notifications", selection: $notificationModeOverride) {
                        Text("Default (\(settingsViewModel.settings.defaultIncomingNotificationMode.displayName))")
                            .tag(ContactNotificationMode?.none)
                        Text("Off").tag(ContactNotificationMode?.some(.off))
                        Text("No Sound").tag(ContactNotificationMode?.some(.noSound))
                        Text("Sound").tag(ContactNotificationMode?.some(.sound))
                    }
                    .pickerStyle(.menu)
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var infoSection: some View {
        Section("Info") {
            LabeledContent("Added") {
                Text(contact.addedAt, style: .date)
            }
            if let lastMessage = contact.lastMessageAt {
                LabeledContent("Last Message") {
                    if Date().timeIntervalSince(lastMessage) < 86_400 {
                        Text(lastMessage, style: .relative)
                    } else {
                        let days = max(1, Int(Date().timeIntervalSince(lastMessage) / 86_400))
                        Text("\(days) day\(pluralS(days)) ago")
                    }
                }
            }
            if let chessRecord {
                LabeledContent("Chess Stats") {
                    Text("\(chessRecord.wins)W - \(chessRecord.losses)L")
                }
            }
            HStack {
                StatItem(label: AppLocalization.string("Sent"), value: messageSent)
                Divider().frame(height: 32)
                StatItem(label: AppLocalization.string("Received"), value: messageReceived)
                Divider().frame(height: 32)
                StatItem(label: AppLocalization.string("Total"), value: messageSent + messageReceived)
            }
            .padding(.vertical, 4)
        }
    }

    /// One section, as a row that opens its half sheet. Title only - the contents belong in the
    /// sheet, and a trailing value on every row turned the list back into the dense screen the
    /// cards were meant to replace.
    private func infoCard(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.scaled(size: 16, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 26)
                Text(title)
                    .foregroundColor(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Shares this person's kachat.app profile link, the same link your own Profile shares:
    /// it previews with their name and avatar, opens a chat with them in KaChat, and offers the
    /// download to anyone without the app. The link alone, no text around it.
    @ViewBuilder
    private var shareButton: some View {
        if let url = KaChatInternalLink.profileShareURL(for: contact.address) {
            ShareLink(
                item: url,
                preview: SharePreview(contactsManager.displayName(for: contact), image: Image("KaspaLogo"))
            ) {
                // the words are part of the button: tapping them shares too
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.scaled(size: 22, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 58, height: 58)
                        .background(
                            Circle()
                                .fill(.regularMaterial)
                                // a whole point, inside the edge: a 0.8pt stroke on the edge drew
                                // faint on whichever sides fell between pixels
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                        )
                    Text("Share Profile")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Share this profile"))
            .frame(maxWidth: .infinity)
        }
    }

    private func aliasRow(
        _ title: LocalizedStringKey,
        value: Binding<String?>,
        derive: @escaping () -> String?
    ) -> some View {
        Button {
            if let revealed = value.wrappedValue {
                UIPasteboard.general.string = revealed
                Haptics.success()
                showToast(localized("Alias copied to clipboard."))
            } else if let derived = derive() {
                value.wrappedValue = derived
            } else {
                showToast(localized("Alias unavailable."), style: .error)
            }
        } label: {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                if let revealed = value.wrappedValue {
                    Text(revealed)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text(String(repeating: "\u{2022}", count: 12))
                            .foregroundColor(.secondary)
                        Image(systemName: "eye")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func localized(_ key: String) -> String {
        AppLocalization.string(key)
    }

    private func localizedFormat(_ key: String, _ args: CVarArg...) -> String {
        String(format: AppLocalization.string(key), locale: AppLocalization.locale, arguments: args)
    }

    /// Ensures a contact row exists for this address (a group member may
    /// not be one yet), dismisses this sheet, and asks the router to open their thread.
    private func openChatWithContact() {
        let address = contact.address
        if contactsManager.getContact(byAddress: address) == nil {
            _ = try? contactsManager.addContact(address: address)
        }
        dismiss()
        // After the sheet's dismissal settles, so the router is not pushing underneath a
        // disappearing presentation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(
                name: .openChat,
                object: nil,
                userInfo: ["contactAddress": address]
            )
        }
    }

    private func saveChanges() {
        var updatedContact = contact
        let trimmedAlias = editedAlias.trimmingCharacters(in: .whitespaces)
        updatedContact.alias = trimmedAlias.isEmpty
            ? Contact.generateDefaultAlias(from: contact.address)
            : trimmedAlias
        updatedContact.notificationModeOverride = notificationModeOverride
        contactsManager.updateContact(updatedContact)
        contact = updatedContact
        // One name per person: the Address Book entry, if there is one, takes the same name - so
        // clearing it here really clears it, and they go by their .kachat name or their address.
        if let entry = addressBook.entry(for: contact.address), entry.customName != (trimmedAlias.isEmpty ? nil : trimmedAlias) {
            _ = try? addressBook.save(address: entry.address, name: trimmedAlias, note: entry.note)
        }
    }

    private func copyProfileFieldValue(_ value: String, fieldName: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        // The field's name is translated too, or "Bio copied" stayed half English.
        showToast(localizedFormat("%@ copied to clipboard.", localized(fieldName)))
    }
}

private struct StatItem: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
