// Connexion Google native. Google refuse sa page de connexion dans une vue web intégrée (« disallowed_useragent ») :
// l'app ouvre donc la feuille système sécurisée (ASWebAuthenticationSession, comme Safari), avec le client OAuth iOS
// et PKCE, échange le code contre un jeton d'accès et le rend au site, qui le fait vérifier par le serveur Deydar.
import UIKit
import AuthenticationServices
import CryptoKit
import Security

final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: Error, Equatable {
        case cancelled
        case failed(String)
    }

    private var session: ASWebAuthenticationSession?
    private weak var anchor: UIWindow?

    func signIn(from window: UIWindow?, completion: @escaping (Result<String, Failure>) -> Void) {
        let finish: (Result<String, Failure>) -> Void = { result in DispatchQueue.main.async { completion(result) } }
        guard session == nil else { finish(.failure(.failed("already_running"))); return }
        anchor = window

        let verifier = Self.randomString(bytes: 48)
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomString(bytes: 16)
        let redirectURI = AppConfig.googleRedirectScheme + ":/oauth2redirect"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.googleClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        guard let url = components.url else { finish(.failure(.failed("bad_url"))); return }

        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: AppConfig.googleRedirectScheme) { [weak self] callbackURL, error in
            self?.session = nil
            if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                finish(.failure(.cancelled))
                return
            }
            if let error = error {
                finish(.failure(.failed(error.localizedDescription)))
                return
            }
            guard let callbackURL = callbackURL,
                  let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems else {
                finish(.failure(.failed("no_callback")))
                return
            }
            func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
            guard value("state") == state else { finish(.failure(.failed("state_mismatch"))); return }
            if let oauthError = value("error") {
                finish(.failure(oauthError == "access_denied" ? .cancelled : .failed(oauthError)))
                return
            }
            guard let code = value("code") else { finish(.failure(.failed("no_code"))); return }
            Self.exchange(code: code, verifier: verifier, redirectURI: redirectURI, completion: finish)
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() {
            self.session = nil
            finish(.failure(.failed("start_failed")))
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let anchor = anchor { return anchor }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first ?? ASPresentationAnchor()
    }

    // Code d'autorisation → jeton d'accès (client iOS : pas de secret, la preuve PKCE suffit).
    private static func exchange(code: String, verifier: String, redirectURI: String, completion: @escaping (Result<String, Failure>) -> Void) {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "code": code,
            "client_id": AppConfig.googleClientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        request.httpBody = form.map { "\($0.key)=\(formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error { completion(.failure(.failed(error.localizedDescription))); return }
            guard let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(.failure(.failed("bad_response")))
                return
            }
            if let token = json["access_token"] as? String {
                completion(.success(token))
            } else {
                completion(.failure(.failed((json["error_description"] as? String) ?? (json["error"] as? String) ?? "token_error")))
            }
        }.resume()
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func randomString(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64url(Data(bytes))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
