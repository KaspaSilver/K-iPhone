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

/// The Public Chats customize sheet, opened from the Chats screen: every default room with a
/// switch. On means the room is in the list (switching it on joins it); off takes it out and
/// silences it. The Languages switch turns every language room off at once; while it is on, each
/// language has its own switch.
struct PublicChatsSettingsView: View {
    @EnvironmentObject var publicChatService: PublicChatService
    @Environment(\.dismiss) private var dismiss

    private func row(_ name: String) -> some View {
        Toggle(isOn: Binding(
            // on = in the list (joined, not switched off); switching on joins it
            get: { publicChatService.isCuratedChannelOn(name) },
            set: { publicChatService.setCuratedChannel(name, shown: $0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(name)")
                if let language = PublicChatService.languageDisplayName(for: name) {
                    Text(language)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(PublicChatService.featuredChannels, id: \.self) { row($0) }
                } header: {
                    Text("Popular")
                } footer: {
                    Text("A room that is switched off no longer appears in Public Chats and never sends a notification. Switch it back on at any time.")
                }
                Section {
                    Toggle("Languages", isOn: Binding(
                        get: { publicChatService.anyLanguageChannelOn },
                        set: { on in
                            withAnimation { publicChatService.setAllLanguageChannels(shown: on) }
                        }
                    ))
                    if publicChatService.anyLanguageChannelOn {
                        ForEach(PublicChatService.languageChannels, id: \.self) { row($0) }
                    }
                } footer: {
                    Text("Off takes every language room out of Public Chats. On, switch off the ones you don't want.")
                }
                // Rooms added on the indexer (`indexerDefaultChannels`): they come and go with it.
                let more = PublicChatService.indexerDefaultChannels
                if !more.isEmpty {
                    Section {
                        ForEach(more, id: \.self) { row($0) }
                    } header: {
                        Text("More Rooms")
                    } footer: {
                        Text("Rooms added on the indexer K reads public chats from.")
                    }
                }
            }
            // a room just added on the indexer shows here within a minute
            .onAppear { publicChatService.refreshIndexerTrackedRooms(maxAge: 60) }
            .navigationTitle("Public Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
