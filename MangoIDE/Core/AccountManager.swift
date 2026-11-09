import Foundation
import UIKit
import AuthenticationServices

/// Your MangoIDE account: Sign in with GitHub, Pro, and AI credit.
/// The session token lives only in this iPhone's Keychain. Payments open Stripe's own checkout page in Safari,
/// so card details never pass through MangoIDE.
final class AccountManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AccountManager()
    static let server = URL(string: "https://accounts-production-bb9c.up.railway.app")!

    struct Profile: Codable, Equatable {
        var login: String
        var name: String?
        var avatarURL: String?
        var pro: Bool
        var proStatus: String
        var proUntil: String?
        var credits: Double
        var topups: [Double]
        var proPrice: Double
        var payments: Bool
        var aiCredits: Bool
    }

    @Published private(set) var profile: Profile?
    @Published private(set) var busy = false
    @Published var message: String?

    private var authSession: ASWebAuthenticationSession?
    private var pendingState: String?

    var token: String? { KeychainStore.get("accountToken") }
    var isSignedIn: Bool { token != nil }
    var isPro: Bool { profile?.pro ?? false }

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "account.profile"),
           let p = try? JSONDecoder().decode(Profile.self, from: data) { profile = p }
    }

    // MARK: Sign in with GitHub

    func signIn() {
        guard !busy else { return }
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.prefix(8)
        pendingState = state
        var comps = URLComponents(url: AccountManager.server.appendingPathComponent("auth/github/start"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "app_state", value: state)]
        guard let url = comps.url else { return }
        busy = true
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "mangoide") { [weak self] callback, error in
            DispatchQueue.main.async { self?.finishSignIn(callback, error) }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        if !session.start() { busy = false; message = "Couldn't open GitHub sign-in." }
    }

    private func finishSignIn(_ callback: URL?, _ error: Error?) {
        busy = false
        authSession = nil
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { return }
        guard let callback, let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value,
              let state = items.first(where: { $0.name == "app_state" })?.value else {
            message = "Sign-in didn't finish. Try again."
            return
        }
        // Only accept the session we asked for (stops another app or page from slipping in a token).
        guard let expected = pendingState, state == expected else { message = "Sign-in check failed. Try again."; return }
        pendingState = nil
        KeychainStore.set(token, for: "accountToken")
        refresh()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    // MARK: Requests

    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = 30,
                 completion: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void) {
        guard let token else { completion(.failure(ArchiveError.failed("Sign in first."))); return }
        var req = URLRequest(url: AccountManager.server.appendingPathComponent(path), timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            DispatchQueue.main.async {
                if let error { completion(.failure(error)); return }
                guard let data, let http = resp as? HTTPURLResponse else { completion(.failure(ArchiveError.failed("No response."))); return }
                if http.statusCode == 401 { self?.clearLocal() }
                completion(.success((data, http)))
            }
        }.resume()
    }

    private func errorText(_ data: Data) -> String {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? "Something went wrong."
    }

    func refresh() {
        guard isSignedIn else { return }
        request("me") { [weak self] r in
            guard let self else { return }
            if case .success(let (data, http)) = r, http.statusCode == 200, let p = try? JSONDecoder().decode(Profile.self, from: data) {
                self.profile = p
                UserDefaults.standard.set(data, forKey: "account.profile")
            }
        }
    }

    func updateCredits(_ value: Double) {
        guard var p = profile else { return }
        p.credits = value
        profile = p
    }

    private func clearLocal() {
        KeychainStore.set("", for: "accountToken")
        profile = nil
        UserDefaults.standard.removeObject(forKey: "account.profile")
    }

    func signOut(everywhere: Bool) {
        request(everywhere ? "auth/logout-all" : "auth/logout", method: "POST") { [weak self] _ in self?.clearLocal() }
    }

    // MARK: Payments (Stripe's checkout page in Safari)

    private func openCheckout(_ body: [String: Any], path: String = "billing/checkout") {
        busy = true
        request(path, method: "POST", body: body) { [weak self] r in
            guard let self else { return }
            self.busy = false
            switch r {
            case .success(let (data, http)):
                if http.statusCode == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let s = json["url"] as? String, let url = URL(string: s), url.host?.hasSuffix("stripe.com") == true {
                    UIApplication.shared.open(url)
                } else {
                    self.message = self.errorText(data)
                }
            case .failure(let e): self.message = e.localizedDescription
            }
        }
    }

    func buyPro() { openCheckout(["kind": "pro"]) }
    func topUp(dollars: Double) { openCheckout(["kind": "topup", "cents": Int((dollars * 100).rounded())]) }
    func manageBilling() { openCheckout([:], path: "billing/portal") }
}
