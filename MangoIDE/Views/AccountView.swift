import SwiftUI

struct AccountRow: View {
    @ObservedObject var account = AccountManager.shared
    var body: some View {
        HStack(spacing: 12) {
            Avatar(url: account.profile?.avatarURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.profile.map { "@" + $0.login } ?? "Sign in with GitHub").font(.headline)
                Text(account.profile.map { ($0.pro ? "Pro" : "Free") + String(format: " · $%.2f AI credit", $0.credits) } ?? "Free account · Pro and AI credit")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct Avatar: View {
    let url: String?
    let size: CGFloat
    var body: some View {
        Group {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.2) }
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct AccountView: View {
    @ObservedObject var account = AccountManager.shared
    @State private var confirmEverywhere = false

    var body: some View {
        Form {
            if let p = account.profile {
                Section {
                    HStack(spacing: 14) {
                        Avatar(url: p.avatarURL, size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.name ?? p.login).font(.title3.bold())
                            Text("@\(p.login)").foregroundStyle(.secondary)
                            Text(p.pro ? "MangoIDE Pro" : "Free").font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background((p.pro ? Color.accentColor : Color.secondary).opacity(0.2), in: Capsule())
                        }
                    }
                }

                Section {
                    if p.pro {
                        LabeledContent("Status", value: p.proStatus.capitalized)
                        Button("Manage Subscription") { account.manageBilling() }
                    } else {
                        Button { account.buyPro() } label: {
                            Label(String(format: "Get Pro · $%.2f/month", p.proPrice), systemImage: "star.fill")
                        }
                        .disabled(!p.payments || account.busy)
                    }
                } header: { Text("Pro") } footer: {
                    Text("Pro will unlock cloud sync and backup, GitHub push/pull/commits, cloning other people's repos, and sharing. Most of MangoIDE stays free.")
                }

                Section {
                    LabeledContent("Balance", value: String(format: "$%.2f", p.credits))
                    HStack {
                        ForEach(p.topups, id: \.self) { amount in
                            Button(String(format: "+$%.0f", amount)) { account.topUp(dollars: amount) }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!p.payments || account.busy)
                    if p.credits > 0 || !p.topups.isEmpty, p.payments {
                        Button("Receipts & Refunds") { account.manageBilling() }.font(.footnote)
                    }
                } header: { Text("AI Credit") } footer: {
                    Text("Prepaid, so you're never charged after the fact. The agent uses it when you haven't added your own Anthropic key. When it runs out, the agent just stops.")
                }

                if !p.payments {
                    Section { Label("Payments aren't switched on yet.", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                }

                Section {
                    Button("Sign Out") { account.signOut(everywhere: false) }
                    Button("Sign Out on All Devices", role: .destructive) { confirmEverywhere = true }
                } header: { Text("Security") } footer: {
                    Text("Payments happen on Stripe's secure checkout page; card details never pass through MangoIDE. Your sign-in is kept in this iPhone's Keychain.")
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sign in to get Pro and AI credit, and later sync your projects. Everything that's free now stays free.")
                            .foregroundStyle(.secondary)
                        Button {
                            account.signIn()
                        } label: {
                            HStack {
                                if account.busy { ProgressView().tint(.white) } else { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                                Text("Sign in with GitHub").bold()
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.black)
                        .disabled(account.busy)
                    }
                    .padding(.vertical, 6)
                } footer: {
                    Text("MangoIDE only sees your GitHub username and picture, plus access to your repos for the GitHub features. Your GitHub password never touches MangoIDE.")
                }
            }
        }
        .navigationTitle("Account")
        .onAppear { account.refresh() }
        .refreshable { account.refresh() }
        .alert("Account", isPresented: Binding(get: { account.message != nil }, set: { if !$0 { account.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(account.message ?? "") }
        .confirmationDialog("Sign out on every device?", isPresented: $confirmEverywhere, titleVisibility: .visible) {
            Button("Sign Out Everywhere", role: .destructive) { account.signOut(everywhere: true) }
        }
    }
}
