import Foundation

/// Name services K reads: only `.kachat`, KaChat's own names (Kaspa covenants, KACHAT_NAMES.md),
/// read through `KachatNamesRegistry` (the names indexer, or the chain itself). Every other
/// Kaspa name service (KNS's .kas, dotk's .k, Kaspa Names' .kaspa) was removed on 2026-11-23
/// (owner's call): K resolves, shows and manages .kachat names only.
enum NameServiceTLD: String, CaseIterable, Identifiable {
    case kachat

    var id: String { rawValue }

    /// ".kachat" - the display suffix.
    var suffix: String { ".\(rawValue)" }

    /// Who runs it, for empty states.
    var serviceName: String { "KaChat Names" }

    /// Whether the app can read this service on the current network.
    var isLive: Bool { KachatNamesService.isLaunched }
}

/// What a typed name points to.
struct NameResolution: Identifiable, Equatable {
    let tld: NameServiceTLD
    /// The name as shown (with or without its ending, per Show .kachat Endings).
    let display: String
    /// Where it points; nil when the name is not registered (or has no address to pay).
    let address: String?
    /// The registry could not be asked (network or server failure), so "not registered" is unknown.
    let failed: Bool
    /// The registry isn't live on this network: nothing can resolve.
    var notLive: Bool = false

    var id: String { tld.rawValue }

    /// The registry's answer is outside data: an address that isn't a valid one on the network
    /// the app runs on is dropped here, so no name can put it into a send or the Address Book.
    init(tld: NameServiceTLD, display: String, address: String?, failed: Bool, notLive: Bool = false) {
        self.tld = tld
        self.display = display
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let trimmed, !trimmed.isEmpty, !KaspaAddress.isValidOnActiveNetwork(trimmed) {
            AppLog.log("[NameServices] %@ answered an address that isn't valid here; ignored", display)
        }
        self.address = trimmed.flatMap { KaspaAddress.isValidOnActiveNetwork($0) ? $0 : nil }
        self.failed = failed
        self.notLive = notLive
    }

    /// The name with its ending always, for text other people read later (a KaPosts @mention):
    /// a bare name there wouldn't say what it is, whatever this phone shows.
    var fullName: String {
        display.hasSuffix(tld.suffix) ? display : display + tld.suffix
    }
}

extension NameServiceTLD {
    /// Splits typed input into its label and the ".kachat" ending, if typed.
    static func splitTypedName(_ input: String) -> (label: String, tld: NameServiceTLD?) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix(NameServiceTLD.kachat.suffix) {
            return (String(trimmed.dropLast(NameServiceTLD.kachat.suffix.count)), .kachat)
        }
        return (trimmed, nil)
    }
}

/// One .kachat name an address holds.
struct OwnedServiceName: Identifiable, Equatable {
    /// The bare canonical name, without the suffix.
    let name: String
    /// The display form.
    let display: String
    let tld: NameServiceTLD
    let isProvisional: Bool

    var id: String { display }
}

@MainActor
final class NameServicesClient {
    static let shared = NameServicesClient()

    private init() {}

    /// The .kachat names each of `addresses` holds (active or in grace), where the registry is
    /// live; empty elsewhere.
    func kachatNames(of addresses: [String]) async -> [String: [OwnedServiceName]] {
        guard NameServiceTLD.kachat.isLive, !addresses.isEmpty else { return [:] }
        await KachatNamesRegistry.shared.refreshIfStale()
        var result: [String: [OwnedServiceName]] = [:]
        for address in addresses {
            guard let key = KachatNamesRegistry.keyOf(address),
                  let held = try? await KachatNamesRegistry.shared.heldNames(owner: key), !held.isEmpty else { continue }
            result[address] = held.map { OwnedServiceName(name: $0.name, display: KachatNameLabel.display($0.name), tld: .kachat, isProvisional: false) }
        }
        return result
    }

    /// Whether `address` holds a .kachat name. Account discovery asks this so an address that
    /// holds only a name, and no KAS, is still found.
    func ownsAnyName(_ address: String) async -> Bool {
        guard NameServiceTLD.kachat.isLive, let key = KachatNamesRegistry.keyOf(address) else { return false }
        await KachatNamesRegistry.shared.refreshIfStale()
        return !((try? await KachatNamesRegistry.shared.names(owner: key, includeInactive: true)) ?? []).isEmpty
    }

    // MARK: - Forward resolution (typed name -> address)

    /// Whether typed input could be a .kachat name (and is not an address): a bare label, or a
    /// label ending in ".kachat".
    static func looksLikeName(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.hasPrefix("kaspa:"), !trimmed.hasPrefix("kaspatest:") else { return false }
        let label = NameServiceTLD.splitTypedName(trimmed).label
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !label.isEmpty && label.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// What `input` points to as a .kachat name: one answer, or none when the label isn't a
    /// valid name.
    func resolveEverywhere(_ input: String) async -> [NameResolution] {
        let label = NameServiceTLD.splitTypedName(input).label
        guard !label.isEmpty, let kachat = await resolveKachat(label) else { return [] }
        return [kachat]
    }

    /// The answer a typed name gets: its .kachat owner, if it has one.
    static func primary(of results: [NameResolution], typed input: String) -> NameResolution? {
        results.first { $0.tld == .kachat && $0.address != nil }
    }

    /// Why a typed name has no answer: no such .kachat name, the registry couldn't be asked, or
    /// there's no .kachat registry on this network.
    static func notFoundMessage(typed input: String, results: [NameResolution]) -> String {
        if results.contains(where: { $0.notLive }) || !NameServiceTLD.kachat.isLive {
            return AppLocalization.string(".kachat names aren't live on this network yet")
        }
        // Couldn't be checked is not "no such name".
        if let failed = results.first(where: { $0.failed }) {
            return String(format: AppLocalization.string("Couldn't look up %@ right now. Try again in a moment."), failed.display)
        }
        return AppLocalization.string("No username found")  // audit 2026-11-24 #36
    }

    /// `.kachat`: the registry's owner of a name that is active or in its grace period - an owner
    /// stays reachable until the name is back on the market; only a lapsed name doesn't resolve
    /// (KACHAT_NAMES.md section 4). Same rules as the gap: a-z, 0-9, hyphen.
    private func resolveKachat(_ label: String) async -> NameResolution? {
        let canonical = KachatNames.Codec.normalize(label)
        guard KachatNames.Codec.isValid(canonical) else { return nil }
        let display = KachatNameLabel.display(canonical)
        guard NameServiceTLD.kachat.isLive else {
            return NameResolution(tld: .kachat, display: display, address: nil, failed: false, notLive: true)
        }
        let registry = KachatNamesRegistry.shared
        await registry.refreshIfStale()
        do {
            switch try await registry.lookup(canonical) {
            case .registered(let n) where n.status(graceMs: registry.graceMs) != .lapsed:
                guard n.name == canonical else { throw KachatNames.Failure("the indexer answered for another name") }
                try await registry.confirmOnChain(n)
                return NameResolution(tld: .kachat, display: display, address: KachatNamesRegistry.address(of: n.owner), failed: false)
            default:
                return NameResolution(tld: .kachat, display: display, address: nil, failed: false)
            }
        } catch {
            AppLog.log("[NameServices] .kachat lookup failed: %@", error.localizedDescription)
            return NameResolution(tld: .kachat, display: display, address: nil, failed: true)
        }
    }
}
