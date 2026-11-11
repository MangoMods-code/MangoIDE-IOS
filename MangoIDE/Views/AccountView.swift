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
    @State private var sessions: [Device] = []

    struct Device { let id: Int; let device: String; let lastUsed: String; let current: Bool }

    private func deviceName(_ ua: String) -> String {
        if ua.contains("iPad") { return "iPad" }
        if ua.contains("iPhone") { return "iPhone" }
        if ua.contains("Mac") { return "Mac" }
        return ua.isEmpty ? "Unknown device" : String(ua.prefix(40))
    }

    private func loadSessions() {
        account.request("me/sessions") { r in
            guard case .success(let (data, http)) = r, http.statusCode == 200,
                  let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
            sessions = rows.map { Device(id: ($0["id"] as? NSNumber)?.intValue ?? 0, device: $0["device"] as? String ?? "",
                                         lastUsed: $0["last_used"] as? String ?? "", current: $0["current"] as? Bool ?? false) }
        }
    }

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
                    NavigationLink { ProView().settingsPage() } label: {
                        LabeledContent("MangoIDE Pro", value: p.pro ? (p.proStatus == "owner pass" ? "Owner Pass" : "Active") : "Free")
                    }
                    NavigationLink { CreditView().settingsPage() } label: {
                        LabeledContent("AI Credit", value: String(format: "$%.2f", p.credits))
                    }
                } header: { Text("Plan") }

                Section {
                    if sessions.isEmpty { Text("Loading…").foregroundStyle(.secondary) }
                    ForEach(sessions, id: \.id) { d in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(deviceName(d.device) + (d.current ? " (this device)" : "")).lineLimit(1)
                            Text("Last used \(CloudSync.shortDate(d.lastUsed))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Signed-In Devices") }

                Section {
                    Button("Sign Out") { account.signOut(everywhere: false) }
                    Button("Sign Out on All Devices", role: .destructive) { confirmEverywhere = true }
                } header: { Text("Security") } footer: {
                    Text("Payments happen on Stripe's secure checkout page; card details never pass through MangoIDE. Your sign-in is kept in this iPhone's Keychain.")
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sign in to clone your GitHub repos, join live sessions, and get Pro or AI credit if you want them. Everything that's free stays free.")
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
        .onAppear { account.refresh(); if account.isSignedIn { loadSessions() } }
        .refreshable { account.refresh(); loadSessions() }
        .alert("Account", isPresented: Binding(get: { account.message != nil }, set: { if !$0 { account.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(account.message ?? "") }
        .confirmationDialog("Sign out on every device?", isPresented: $confirmEverywhere, titleVisibility: .visible) {
            Button("Sign Out Everywhere", role: .destructive) { account.signOut(everywhere: true) }
        }
    }
}
