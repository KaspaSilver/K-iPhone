import SwiftUI

/// The Terms of Use (App Store guideline 1.2), from KaPost (2026-11-21: KaChat has KaPosts and
/// Public Chats again): everyone agrees before using the app, and they stay readable in Settings >
/// About. Bump `currentVersion` when the text changes, and everyone is asked again. The text is
/// KaPost's with the app's name changed, so the translations carry over.
enum KaChatTerms {
    static let currentVersion = 1
    static let acceptedVersionKey = "kachat_terms_accepted_version"

    static let sections: [(title: String, text: String)] = [
        (
            "No objectionable content or abuse",
            "K has no tolerance for objectionable content or abusive users. You may not post anything that is illegal, sexual content involving children, hate speech, threats, harassment, content that encourages violence or self-harm, or scams. Accounts that do can be removed from what K shows, without notice."
        ),
        (
            "Your posts are public and permanent",
            "Posts, replies, likes and room messages are public transactions on the Kaspa network. You are responsible for what you post. Deleting a post removes it from K, but nobody can erase a transaction from the network."
        ),
        (
            "Reporting and blocking",
            "Use Report on a post or room message to tell us about objectionable content; a person reads every report. Use Block to stop seeing an account's posts and room messages. We can remove content and accounts from the K indexer, which K reads by default."
        ),
        (
            "Your account and your funds",
            "Your account is 12 or 24 words kept on your device. We never have them, so we can't recover lost ones or reverse a transaction. Posting pays a network fee in KAS, and you are responsible for the funds you hold and send."
        ),
        (
            "No warranty",
            "K is provided as it is, without warranty, and to the extent the law allows we are not liable for losses from using it or from what other users post. These terms are between you and K's developer, not Apple."
        ),
        (
            "Contact",
            "Questions and reports: \(ContentReport.supportEmail)"
        )
    ]
}

/// The terms' text, shared by the first-launch screen and Settings.
private struct KaChatTermsText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(KaChatTerms.sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey(section.title))
                        .font(.headline)
                    Text(LocalizedStringKey(section.text))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

/// Settings > About > Terms of Use.
struct TermsOfUseView: View {
    var body: some View {
        ScrollView {
            KaChatTermsText()
        }
        .navigationTitle("Terms of Use")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The first thing the app shows until the current terms are agreed to.
struct TermsAcceptanceView: View {
    let onAgree: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Terms of Use")
                .font(.largeTitle.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 6)
            Divider()
            ScrollView {
                KaChatTermsText()
            }
            Divider()
            VStack(spacing: 10) {
                Text("You need to agree to use K.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button(action: onAgree) {
                    Text("I Agree")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(16)
        }
    }
}
