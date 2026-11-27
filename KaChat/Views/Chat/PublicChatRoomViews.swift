import SwiftUI

/// `.navigationDestination(item:)` (iOS 17+) rather than `isPresented:` + a synthetic get/set
/// boolean: popping back (native back button/swipe) and immediately pushing a different channel
/// both drive the same destination, and toggling a hand-rolled boolean true→false→true in quick
/// succession can race with UIKit's own pop animation/cleanup, leaving the next push silently
/// inert until the Chats list is torn down and recreated. Binding directly to the optional item is
/// the API SwiftUI provides specifically for this swap; iOS 16 falls back to the older, slightly
/// more race-prone pattern since `item:` isn't available there.
struct PublicChatChannelDestination: ViewModifier {
    @Binding var selectedChannel: String?

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.navigationDestination(item: $selectedChannel) { channel in
                // `.id` forces a fresh `PublicChatChannelView` (not just a `channelName` update to
                // the existing one) when switching rooms in place, so `onAppear`/`onDisappear`
                // re-fire to correctly swap the live-view acquire/release tracking, and per-room
                // state (draft text, reply-in-progress, etc.) resets instead of leaking across
                // channels.
                // No `.toolbar(.hidden, for: .tabBar)`: the dock stays visible in a room, as on
                // every KaPost screen.
                PublicChatChannelView(channelName: channel)
                    .id(channel)
            }
        } else {
            content.navigationDestination(isPresented: Binding(
                get: { selectedChannel != nil },
                set: { if !$0 { selectedChannel = nil } }
            )) {
                if let selectedChannel {
                    PublicChatChannelView(channelName: selectedChannel)
                        .id(selectedChannel)
                } else {
                    EmptyView()
                }
            }
        }
    }
}

/// Add Room (owner, 2026-11-26): the Public Chats page's + and its empty page's Add Room. Public
/// Chats starts empty, so this is how a room gets there: every room the indexer keeps (the
/// featured rooms, then whatever the indexer reports, so the list grows with it), each with Join;
/// the language rooms behind Other Languages; and Create at the top right, which first says how a
/// room nobody indexes works, then takes its name.
struct PublicRoomBrowserView: View {
    /// A room to open: Open on a joined one, or a room just created.
    let onOpenRoom: (String) -> Void
    let onClose: () -> Void

    @ObservedObject private var publicChats = PublicChatService.shared
    @State private var path: [Page] = []

    private enum Page: Hashable { case languages, createInfo, createName }

    /// The featured rooms, then the rooms the indexer lists.
    private var rooms: [String] {
        var list = PublicChatService.featuredChannels
        for name in PublicChatService.indexerDefaultChannels where !list.contains(name) {
            list.append(name)
        }
        return list
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(rooms, id: \.self) { name in
                        roomRow(name, subtitle: nil)
                    }
                } footer: {
                    Text("Rooms the indexer keeps: their history is saved and they can notify you even when K is closed.")
                }
                Section {
                    NavigationLink(value: Page.languages) {
                        Label("Other Languages", systemImage: "globe")
                    }
                }
            }
            .navigationTitle("Add Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") { path.append(.createInfo) }
                }
            }
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .languages:
                    List {
                        ForEach(PublicChatService.languageChannels, id: \.self) { name in
                            roomRow(name, subtitle: PublicChatService.languageDisplayName(for: name))
                        }
                    }
                    .navigationTitle("Other Languages")
                    .navigationBarTitleDisplayMode(.inline)
                case .createInfo:
                    PublicRoomCreateInfoView { path.append(.createName) }
                case .createName:
                    PublicRoomNameView(onCreated: onOpenRoom)
                }
            }
        }
        // a room just added on the indexer shows here within a minute
        .onAppear { publicChats.refreshIndexerTrackedRooms(maxAge: 60) }
    }

    /// "#name" (and its language), with Join, or Open once it's in the list. Join waits for the
    /// account's room store (right after launch a join would fail with nothing said, audit
    /// 2026-11-26).
    private func roomRow(_ name: String, subtitle: String?) -> some View {
        let joined = publicChats.channels.contains { $0.channelName == name }
        let ready = publicChats.isStoreReady
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "#\(name)")
                    .font(.body.weight(.semibold))
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button {
                Haptics.impact(.light)
                if joined {
                    onOpenRoom(name)
                } else if publicChats.joinChannel(name) {
                    Haptics.success()
                }
            } label: {
                Text(LocalizedStringKey(joined ? "Open" : "Join"))
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(joined ? .accentColor : .black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(joined ? Color.accentColor.opacity(0.15) : Color.accentColor))
            }
            .buttonStyle(.borderless)
            .disabled(!joined && !ready)
            .opacity(!joined && !ready ? 0.4 : 1)
        }
        .padding(.vertical, 2)
    }
}

/// Create, first: how a room nobody indexes works, said plainly before it's made.
private struct PublicRoomCreateInfoView: View {
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("How a Room You Create Works")
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                point("number", "Anyone who types the same name joins the same room. It has no owner and no invite.")
                point("tray", "No indexer keeps its history. K reads it from the Kaspa network while the room is open, and keeps up to 3 days on your phone.")
                point("bell.slash", "No notifications while K is closed. With its bell on, K notifies you only while it's open.")
                point("eye", "Everything said there is public: anyone can read it on the Kaspa network.")
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Haptics.impact(.light)
                onContinue()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundColor(.black)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .navigationTitle("Create")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func point(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Create, then: the room's name. A name the indexer keeps joins that room.
private struct PublicRoomNameView: View {
    let onCreated: (String) -> Void
    @ObservedObject private var publicChats = PublicChatService.shared
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var isEmpty: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                Text(verbatim: "#")
                    .font(.headline)
                    .foregroundColor(.secondary)
                TextField("channel-name", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.join)
                    .focused($focused)
                    .onSubmit(create)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Button(action: create) {
                Text("Create Room")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(.black)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(isEmpty ? 0.4 : 1))
                    )
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)

            Spacer(minLength: 0)
        }
        .padding(20)
        .navigationTitle("Name Your Room")
        .navigationBarTitleDisplayMode(.inline)
        // a turn later: the field doesn't exist yet on the push that showed it
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func create() {
        guard !isEmpty else { return }
        let typed = PublicChatChannelName.normalize(name)
        let normalized = PublicChatService.retiredChannels[typed] ?? typed
        guard PublicChatChannelName.isValid(normalized) else {
            error = String(format: AppLocalization.string("Channel names must be 1-%d characters with no spaces or colons."),
                           locale: AppLocalization.locale, PublicChatChannelName.maxLength)
            return
        }
        guard publicChats.joinChannel(normalized) else {
            error = AppLocalization.string("Something went wrong joining that channel.")
            return
        }
        Haptics.success()
        onCreated(normalized)
    }
}
