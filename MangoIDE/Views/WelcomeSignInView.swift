import SwiftUI

/// Friendly sign-in prompt: shown the first time the app opens, then again every 2 days while you're
/// signed out, until you sign in or tap "Don't ask again". Skipping never blocks anything.
enum WelcomePrompt {
    private static let lastShownKey = "welcomePrompt.lastShown"
    private static let neverKey = "welcomePrompt.never"
    static let interval: TimeInterval = 2 * 24 * 60 * 60

    static var isDue: Bool {
        if AccountManager.shared.isSignedIn { return false }
        if UserDefaults.standard.bool(forKey: neverKey) { return false }
        guard let last = UserDefaults.standard.object(forKey: lastShownKey) as? Date else { return true }
        return Date().timeIntervalSince(last) >= interval
    }

    static func markShown() { UserDefaults.standard.set(Date(), forKey: lastShownKey) }
    static func neverAgain() { UserDefaults.standard.set(true, forKey: neverKey) }

    /// Called on launch and whenever the app comes back to the front.
    static func showIfDue(_ router: Router) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard isDue, router.sheet == nil, router.busy == nil else { return }
            markShown()
            router.sheet = .welcome
        }
    }
}

struct WelcomeSignInView: View {
    @ObservedObject var account = AccountManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 92, height: 92)
                    .background(LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.top, 36)

                VStack(spacing: 8) {
                    Text("Welcome to MangoIDE").font(.title.bold())
                    Text("Everything in the editor is free. Signing in is optional.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 16) {
                    perk("square.and.pencil", "Free to code", "Editor, tabs, split view, projects and running code. No account needed.")
                    perk("arrow.down.circle", "Clone your GitHub repos", "Sign in with GitHub to bring your own repos into the app.")
                    perk("sparkles", "Pro and AI when you want them", "Extra features and the coding agent, only if you choose to pay.")
                    perk("lock.shield", "Private by design", "Your sign-in stays in this iPhone's Keychain. Payments happen on Stripe, never in the app.")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                if let m = account.message {
                    Text(m).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    Button {
                        account.message = nil
                        account.signIn()
                    } label: {
                        HStack {
                            if account.busy { ProgressView().tint(.white) } else { Image(systemName: "person.crop.circle.badge.checkmark") }
                            Text("Sign in with GitHub").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(account.busy)

                    Button("Not now") { dismiss() }
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)

                    Button("Don't ask again") { WelcomePrompt.neverAgain(); dismiss() }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                Text("You can always sign in later in Settings › Account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: account.profile) { p in if p != nil { dismiss() } }
    }

    private func perk(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
