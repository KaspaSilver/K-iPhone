import SwiftUI

// Edit KaChat Profile (KaChat's own; KaPay never had it): the address profile editor and its
// social-link preview, kept from KaChat's earlier .kachat views when KaPay's full .kachat code came
// in (2026-11-21).

enum KachatSocialLookup: Equatable {
    case none, looking, found, empty, unreachable
}

/// One profile field's source (avatar, banner or bio) looked up on this device, showing exactly
/// the piece other people will see.
struct KachatSocialPreview: View {
    let link: String
    let kind: KachatNames.SocialSource.Kind
    @Binding var lookup: KachatSocialLookup

    @ObservedObject private var resolver = KachatSocialImageResolver.shared
    @State private var resolved: KachatNames.SocialProfile?
    @State private var attempt = 0
    /// The lookup whose answer may land: a newer one (edited link, Retry) supersedes it.
    @State private var activeKey = ""

    private var source: KachatNames.SocialSource? { KachatNames.SocialSource(link: link, for: kind) }

    private func piece(_ p: KachatNames.SocialProfile?) -> String? {
        switch kind {
        case .avatar: return p?.avatar
        case .banner: return p?.banner
        case .bio: return p?.bio
        }
    }

    var body: some View {
        // A VStack, not a Group: a Group hands its modifiers to each child, so `.task` below
        // would belong to whichever child shows - and switching from the spinner to the result
        // would cancel it and start the lookup again, endlessly. The VStack is one stable view.
        VStack(alignment: .leading, spacing: 0) {
            if let source {
                switch lookup {
                case .none, .looking:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking up the profile...").font(.footnote).foregroundColor(.secondary)
                    }
                case .found:
                    found(source)
                case .empty:
                    note("person.crop.circle.badge.exclamationmark", missingText(source.platform))
                case .unreachable:
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark").foregroundColor(.secondary)
                        Text(verbatim: String(format: AppLocalization.string("Couldn't reach %@."), source.platform.displayName))
                            .font(.footnote).foregroundColor(.secondary)
                        Spacer()
                        Button("Retry") { attempt += 1 }.font(.footnote.weight(.semibold))
                    }
                }
            }
        }
        // Debounced: one lookup once typing pauses. `attempt` reruns it for Retry. Whatever
        // happens - cancelled, restarted, failed - the state always lands somewhere final.
        .task(id: "\(source?.link ?? "")#\(attempt)") {
            let myKey = "\(source?.link ?? "")#\(attempt)"
            activeKey = myKey
            guard let source else { resolved = nil; lookup = .none; return }
            // The row scrolled back into view (a Form rebuilds its rows): the answer this
            // screen already got shows at once - no debounce, no "Looking up" flash, no
            // refetch. Retry (attempt > 0) still runs the full lookup.
            if attempt == 0, let cached = resolver.cachedProfile(source) {
                resolved = cached
                lookup = piece(cached) == nil ? .empty : .found
                // Still re-checked quietly (the resolver's own 5-minute freshness): a profile
                // changed on the platform lands here without the flash.
                let result = await resolver.resolve(source)
                guard activeKey == myKey, case .answered(let fresh) = result, fresh != cached else { return }
                resolved = fresh
                lookup = piece(fresh) == nil ? .empty : .found
                return
            }
            lookup = .looking
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard activeKey == myKey else { return }
            let result = await resolver.resolve(source)
            guard activeKey == myKey else { return }
            resolved = result.profile
            switch result {
            case .answered(let p):
                lookup = piece(p) == nil ? .empty : .found
            case .unreachable(let cached):
                lookup = piece(cached) == nil ? .unreachable : .found
            }
        }
    }

    @ViewBuilder
    private func found(_ source: KachatNames.SocialSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch kind {
            case .avatar:
                KNSAvatarView(avatarURLString: resolved?.avatar, fallbackText: "", size: 64)
            case .banner:
                KNSBannerImageView(bannerURLString: resolved?.banner, height: 90, cornerRadius: 8, fitsWidth: true)
            case .bio:
                Text(verbatim: resolved?.bio ?? "").font(.subheadline)
            }
            Text(verbatim: String(format: AppLocalization.string("From %@"), source.platform.displayName))
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func missingText(_ platform: KachatNames.SocialSource.Platform) -> String {
        let key: String
        switch kind {
        case .avatar: key = "No avatar on this %@ profile."
        case .banner: key = "No banner on this %@ profile."
        case .bio: key = "No bio on this %@ profile."
        }
        return String(format: AppLocalization.string(key), platform.displayName)
    }

    private func note(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(.secondary)
            Text(verbatim: text).font(.footnote).foregroundColor(.secondary)
        }
    }
}

/// One profile field's source as the editor holds it: the platform picked and the handle typed.
struct KachatSourceInput: Equatable {
    var platform: KachatNames.SocialSource.Platform = .x
    var handle = ""

    init(platform: KachatNames.SocialSource.Platform = .x, handle: String = "") {
        self.platform = platform
        self.handle = handle
    }

    /// From a stored profile link.
    init(stored link: String?, _ kind: KachatNames.SocialSource.Kind) {
        if let s = KachatNames.SocialSource(link: link ?? "", for: kind) {
            self.init(platform: s.platform, handle: s.displayHandle)
        } else {
            self.init()
        }
    }

    var isEmpty: Bool { handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func source(_ kind: KachatNames.SocialSource.Kind) -> KachatNames.SocialSource? {
        KachatNames.SocialSource.from(platform: platform, handle: handle, for: kind)
    }

    func isBad(_ kind: KachatNames.SocialSource.Kind) -> Bool { !isEmpty && source(kind) == nil }

    /// The source when the handle field holds a whole pasted link (rather than a handle).
    func pastedSource(_ kind: KachatNames.SocialSource.Kind) -> KachatNames.SocialSource? {
        let t = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased().hasPrefix("http") || (t.contains(".") && t.contains("/")) else { return nil }
        return source(kind)
    }
}

/// The address profile (KACHAT_NAMES.md section 7): where the avatar, banner and bio come from
/// (a social profile link each - they can be different accounts), a Linktree link, and which of
/// your names labels you - written as a `kchat:1:profile:` self-transfer. No free text and no
/// uploads: what shows comes from a platform that moderates it.
struct KachatLiveProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var registry = KachatNamesRegistry.shared

    /// Each piece's source: a platform from the picker plus the handle typed after its prefix.
    @State private var avatarIn = KachatSourceInput()
    @State private var bannerIn = KachatSourceInput()
    @State private var bioIn = KachatSourceInput()
    @State private var avatarLookup: KachatSocialLookup = .none
    @State private var bannerLookup: KachatSocialLookup = .none
    @State private var bioLookup: KachatSocialLookup = .none
    @State private var linktree = ""
    @State private var primary = ""
    @State private var activeNames: [String] = []
    @State private var loaded = false
    @State private var showSave = false
    @State private var showClear = false

    private typealias Kind = KachatNames.SocialSource.Kind

    private var profile: KachatNames.Profile {
        var p = KachatNames.Profile()
        p.avatar = avatarIn.source(.avatar)?.link
        p.banner = bannerIn.source(.banner)?.link
        p.bio = bioIn.source(.bio)?.link
        p.linktree = KachatNames.Profile.linktreeLink(username: linktree)
        p.primaryName = primary.isEmpty ? nil : primary
        return p.sanitized()
    }

    /// A filled-in field whose lookup hasn't found what it shows (still looking, unreachable, or
    /// nothing there). It doesn't block saving - a social site being slow or unreachable from
    /// this phone must never stop a profile (or a primary name) from saving; the link is saved
    /// as entered and every viewer's app looks it up itself. The editor just says so.
    private func notReviewed(_ input: KachatSourceInput, _ lookup: KachatSocialLookup) -> Bool {
        !input.isEmpty && lookup != .found
    }

    private var hasUncheckedLinks: Bool {
        notReviewed(avatarIn, avatarLookup) || notReviewed(bannerIn, bannerLookup) || notReviewed(bioIn, bioLookup)
    }

    /// Only a malformed handle or Linktree username stops a save.
    private var blocked: Bool {
        avatarIn.isBad(.avatar) || bannerIn.isBad(.banner) || bioIn.isBad(.bio) || badLinktree
    }

    /// The Linktree field holds just the username (`linktr.ee/` is shown in front of it).
    private var badLinktree: Bool {
        let t = linktree.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && KachatNames.Profile.linktreeLink(username: t) == nil
    }

    /// Once one field's account is found, the empty fields take the same account where its
    /// platform can fill them - one handle sets up the whole profile, and each stays editable.
    private func fillEmpty(from input: KachatSourceInput) {
        let fits = { (kind: Kind) in KachatNames.SocialSource.Platform.choices(for: kind).contains(input.platform) }
        if avatarIn.isEmpty, fits(.avatar) { avatarIn = input }
        if bannerIn.isEmpty, fits(.banner) { bannerIn = input }
        if bioIn.isEmpty, fits(.bio) { bioIn = input }
    }

    /// Platform picker, the handle after the platform's prefix, and the preview of what it shows.
    private func sourceField(_ input: Binding<KachatSourceInput>, _ kind: Kind, _ lookup: Binding<KachatSocialLookup>) -> some View {
        Group {
            Picker("Account on", selection: input.platform) {
                ForEach(KachatNames.SocialSource.Platform.choices(for: kind), id: \.self) { p in
                    Text(verbatim: p.displayName).tag(p)
                }
            }
            .pickerStyle(.menu)
            HStack(spacing: 0) {
                Text(verbatim: input.wrappedValue.platform.prefix).foregroundColor(.secondary)
                TextField(input.wrappedValue.platform == .discord ? LocalizedStringKey("invite") : LocalizedStringKey("handle"), text: input.handle)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: input.wrappedValue.handle) { _ in
                        // A whole pasted link: switch the picker to its platform, keep the handle.
                        if let pasted = input.wrappedValue.pastedSource(kind) {
                            input.wrappedValue = KachatSourceInput(platform: pasted.platform, handle: pasted.displayHandle)
                        }
                    }
                // One tap empties the field; saving then writes the profile without it.
                if !input.wrappedValue.handle.isEmpty {
                    Button {
                        input.wrappedValue = KachatSourceInput()
                        lookup.wrappedValue = .none
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear"))
                }
            }
            // Only while the handle names an account: no empty row, and the lookup starts when it
            // appears.
            if let link = input.wrappedValue.source(kind)?.link {
                KachatSocialPreview(link: link, kind: kind, lookup: lookup)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    sourceField($avatarIn, .avatar, $avatarLookup)
                } header: { Text("Avatar") } footer: {
                    if avatarIn.isBad(.avatar) { invalidHandleNote }
                }
                Section {
                    sourceField($bannerIn, .banner, $bannerLookup)
                } header: { Text("Banner") } footer: {
                    if bannerIn.isBad(.banner) { invalidHandleNote }
                }
                Section {
                    sourceField($bioIn, .bio, $bioLookup)
                } header: { Text("Bio") } footer: {
                    if bioIn.isBad(.bio) { invalidHandleNote }
                }
                Section {
                    HStack(spacing: 0) {
                        Text(verbatim: "linktr.ee/").foregroundColor(.secondary)
                        TextField("username", text: $linktree)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if !linktree.isEmpty {
                            Button {
                                linktree = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Clear"))
                        }
                    }
                } header: { Text("Links") } footer: {
                    if badLinktree {
                        Text("Enter your Linktree username: letters, numbers, dots, dashes or underscores.").foregroundColor(.red)
                    }
                }
                Section {
                    // The primary name needs the registry: until it launches on this network
                    // (mainnet) there's no name to pick, so the profile saves without one.
                    if KachatNamesService.isLaunched {
                        Picker("Primary name", selection: $primary) {
                            Text("None").tag("")
                            ForEach(activeNames, id: \.self) { n in Text(verbatim: KachatNameLabel.display(n)).tag(n) }
                        }
                    } else {
                        HStack {
                            Text("Primary name")
                            Spacer()
                            Text("Coming soon").foregroundColor(.secondary)
                        }
                    }
                    // names are claimed right here in KaChat now (2026-11-21): this sheet closes and
                    // the .kachat tab opens, wherever it lives (dock or Kaspa Hub)
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            NotificationCenter.default.post(name: .openKachatName, object: nil)
                        }
                    } label: {
                        Label("Get a .kachat name", systemImage: "at")
                    }
                } header: {
                    Text(".kachat Name")
                }
                Section {
                    Button {
                        showSave = true
                    } label: {
                        HStack { Spacer(); Text("Save Profile").font(.headline); Spacer() }
                    }
                    // Saves on every network: a profile is a self-send, with no registry behind it.
                    .disabled(!loaded || blocked || !KachatNamesService.profilesEnabled)
                } footer: {
                    if hasUncheckedLinks {
                        Text("Some links couldn't be checked from this phone right now. They're saved as entered, and people's apps load them when they can.")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        showClear = true
                    } label: {
                        HStack { Spacer(); Text("Clear Profile").font(.headline); Spacer() }
                    }
                    // Same gate as saving: a clear IS a save, of the empty record.
                    .disabled(!loaded || !KachatNamesService.profilesEnabled)
                }
            }
            .sheet(isPresented: $showSave) {
                KachatProfileSaveSheet(title: "Save Profile", confirmTitle: "Save Profile", doneTitle: "Profile saved",
                                       makeProfile: { profile }, onSaved: { dismiss() })
            }
            // The newest record is the whole profile, so the empty record IS "this address has
            // nothing": the indexer and every app show nothing for it from then on.
            .sheet(isPresented: $showClear) {
                KachatProfileSaveSheet(title: "Clear Profile", confirmTitle: "Clear Profile", doneTitle: "Profile cleared",
                                       makeProfile: { KachatNames.Profile() }, onSaved: { dismiss() })
            }
            .onChange(of: avatarLookup) { v in if v == .found { fillEmpty(from: avatarIn) } }
            .onChange(of: bannerLookup) { v in if v == .found { fillEmpty(from: bannerIn) } }
            .onChange(of: bioLookup) { v in if v == .found { fillEmpty(from: bioIn) } }
            .navigationTitle("Edit KaChat Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var invalidHandleNote: some View {
        Text("That doesn't look like a handle on this platform.").foregroundColor(.red)
    }

    private func load() async {
        guard let address = KachatNamesActions.shared.myAddress else { loaded = true; return }
        await registry.refreshIfStale()
        // start from the newest profile, wherever it was saved (another device included)
        await registry.syncOwnProfile(address: address)
        var p = registry.ownProfile(for: address)?.profile
        if p == nil { p = try? await registry.identity(address: address).profile }
        if let p {
            avatarIn = KachatSourceInput(stored: p.avatar, .avatar)
            bannerIn = KachatSourceInput(stored: p.banner, .banner)
            bioIn = KachatSourceInput(stored: p.bio, .bio)
            linktree = KachatNames.Profile.linktreeUsername(p.linktree)
        }
        if let key = KachatNamesRegistry.keyOf(address),
           let held = try? await registry.names(owner: key, includeInactive: false) {
            activeNames = held.map(\.name)
        } else if let pn = p?.primaryName {
            // the names can't be read right now: saving must not drop the primary name
            activeNames = [pn]
        }
        if let pn = p?.primaryName, activeNames.contains(pn) { primary = pn }
        loaded = true
    }

}

