import SwiftUI

// Creating a group and adding members, as half sheets (owner, 2026-11-24): a confirmation sheet
// in place of the old alert, then a progress sheet that shows every transaction as it goes out
// (setting up, inviting each person, the recovery copy, the photo), so a slow network reads as
// "working", not "broken". The steps come from `GroupChatService`'s `GroupActionReport`.

/// The steps of one group action and how far each has got.
@MainActor
final class GroupActionProgress: ObservableObject, Identifiable {
    enum State: Equatable {
        case waiting
        case working
        case done
        case failed(String)
    }

    struct Step: Identifiable {
        let id: String
        let title: String
        var detail: String?
        var state: State = .waiting
    }

    let id = UUID()
    let headline: String
    @Published private(set) var steps: [Step]
    @Published private(set) var isFinished = false

    init(headline: String, steps: [Step]) {
        self.headline = headline
        self.steps = steps
    }

    var doneCount: Int { steps.filter { $0.state == .done }.count }
    var failedCount: Int { steps.filter { if case .failed = $0.state { return true } else { return false } }.count }
    var settledCount: Int { steps.filter { $0.state != .waiting && $0.state != .working }.count }

    func set(_ id: String, _ state: State, detail: String? = nil) {
        guard let index = steps.firstIndex(where: { $0.id.lowercased() == id.lowercased() }) else { return }
        steps[index].state = state
        if let detail { steps[index].detail = detail }
    }

    func setDetail(_ id: String, _ detail: String?) {
        guard let index = steps.firstIndex(where: { $0.id.lowercased() == id.lowercased() }) else { return }
        steps[index].detail = detail
    }

    /// A step's news from `GroupChatService` (its key is the step's id).
    func apply(_ key: String, _ phase: GroupChatService.GroupActionPhase) {
        switch phase {
        case .started: set(key, .working)
        case .finished: set(key, .done)
        case .failed(let error): set(key, .failed(error.localizedDescription))
        }
    }

    /// Anything still waiting or working when the action ends failed with it.
    func finish(failing message: String? = nil) {
        for index in steps.indices where steps[index].state == .waiting || steps[index].state == .working {
            steps[index].state = .failed(message ?? AppLocalization.string("Not sent"))
        }
        isFinished = true
    }
}

/// "Create group" / "Add members": what will happen and what it costs, with the button that does it.
struct GroupActionConfirmSheet: View {
    let title: LocalizedStringKey
    let message: String
    let feeLine: String?
    let confirmTitle: LocalizedStringKey
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.headline)
                .padding(.top, 20)
            Text(verbatim: message)
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let feeLine {
                Text(verbatim: feeLine)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Haptics.impact(.medium)
                onConfirm()
                dismiss()
            } label: {
                Text(confirmTitle)
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            Button("Cancel") { dismiss() }
                .font(.headline)
                .padding(.vertical, 6)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .fittedSheetDetent(estimate: 320)
    }
}

/// The steps of a group action as they happen, with Done once it's over. It can't be swiped
/// away while it works.
struct GroupActionProgressSheet: View {
    @ObservedObject var progress: GroupActionProgress
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: progress.headline)
                    .font(.title3.weight(.bold))
                ProgressView(value: Double(progress.settledCount), total: Double(max(progress.steps.count, 1)))
                    .tint(progress.failedCount > 0 ? .orange : .accentColor)
                    .animation(.easeInOut(duration: 0.25), value: progress.settledCount)
                Text(verbatim: String(format: AppLocalization.string("%lld of %lld"), progress.settledCount, progress.steps.count))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.top, 22)

            VStack(spacing: 0) {
                ForEach(progress.steps) { step in
                    row(step)
                    if step.id != progress.steps.last?.id { Divider().padding(.leading, 44) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))

            footer
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .background(Color(.systemGroupedBackground))
        .interactiveDismissDisabled(!progress.isFinished)
        .fittedSheetDetent(estimate: 420)
    }

    private func row(_ step: GroupActionProgress.Step) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch step.state {
                case .waiting:
                    Image(systemName: "circle").foregroundColor(.secondary.opacity(0.5))
                case .working:
                    ProgressView().controlSize(.small)
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                }
            }
            .font(.title3)
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: step.title)
                    .font(.subheadline.weight(step.state == .working ? .semibold : .regular))
                    .foregroundColor(step.state == .waiting ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .failed(let message) = step.state {
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let detail = step.detail, step.state == .working {
                    Text(verbatim: detail)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var footer: some View {
        if progress.isFinished {
            if progress.failedCount > 0 {
                Text("Some steps didn't go through. You can send them again from Group Info > Resend invites to all.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Haptics.impact(.light)
                onDone()
            } label: {
                Text("Done")
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        } else {
            Text("Each step is a transaction on Kaspa and can take a few seconds. Keep K open until it's done.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A membership line as the thread shows it: the stored English line ("<address> joined the group")
/// in the reader's language, with each address as that person's current name.
enum GroupSystemLine {
    private static let addressPattern = try? NSRegularExpression(pattern: "kaspa(?:test)?:[a-z0-9]{40,90}", options: [])
    private static let kinds: [(suffix: String, key: String)] = [
        (" joined the group", "%@ joined the group"),
        (" declined the invite", "%@ declined the invite"),
        (" was invited to the group chat", "%@ was invited to the group chat"),
        (" was removed from the group chat", "%@ was removed from the group chat"),
    ]

    @MainActor
    static func display(_ stored: String, name: (String) -> String) -> String {
        // "<who> joined the group" and the like: translated, with the name filled in
        for kind in kinds where stored.hasSuffix(kind.suffix) {
            let who = String(stored.dropLast(kind.suffix.count))
            return String(format: AppLocalization.string(kind.key), replacingAddresses(in: who, name: name))
        }
        return replacingAddresses(in: stored, name: name)
    }

    @MainActor
    private static func replacingAddresses(in text: String, name: (String) -> String) -> String {
        guard text.contains("kaspa"), let regex = addressPattern else { return text }
        let ns = text as NSString
        var out = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let address = ns.substring(with: match.range)
            if let range = Range(match.range, in: out) { out.replaceSubrange(range, with: name(address)) }
        }
        return out
    }
}
