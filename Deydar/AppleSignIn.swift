// « Se connecter avec Apple » natif (AuthenticationServices, feuille système d'Apple, Face ID / Touch ID).
// L'app crée un nonce aléatoire, en donne l'empreinte SHA-256 à Apple (elle revient dans le jeton d'identité signé),
// puis rend au site le jeton, le code d'autorisation et le nonce brut : le serveur Deydar vérifie la signature d'Apple,
// l'audience (com.deydar.app) et le nonce avant d'ouvrir la session (POST /api/auth/apple).
// Nom et e-mail ne sont fournis par Apple qu'à la PREMIÈRE autorisation ; l'e-mail peut être une adresse relais privée.
import UIKit
import AuthenticationServices
import CryptoKit
import Security

final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    enum Failure: Error, Equatable {
        case cancelled
        case failed(String)
    }

    /// Identifiant Apple (credential.user) du dernier compte connecté avec Apple dans l'app, pour détecter sa révocation.
    static let storedUserKey = "dd_apple_user"

    private var controller: ASAuthorizationController?
    private var rawNonce = ""
    private var completion: ((Result<[String: Any], Failure>) -> Void)?
    private weak var anchor: UIWindow?

    /// À appeler sur le fil principal. completion est toujours rappelée sur le fil principal, une seule fois.
    func signIn(from window: UIWindow?, completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        let finish: (Result<[String: Any], Failure>) -> Void = { result in DispatchQueue.main.async { completion(result) } }
        guard controller == nil else { finish(.failure(.failed("already_running"))); return }
        guard let nonce = Self.randomNonce() else { finish(.failure(.failed("nonce_failed"))); return }
        anchor = window
        rawNonce = nonce
        self.completion = finish

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256Hex(nonce)

        // Référence forte pendant toute la durée de la feuille (sinon le délégué n'est jamais rappelé).
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        controller.performRequests()
    }

    // MARK: ASAuthorizationControllerDelegate

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            done(.failure(.failed("bad_credential")))
            return
        }
        guard let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8), !token.isEmpty else {
            done(.failure(.failed("no_token")))
            return
        }
        let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let payload: [String: Any] = [
            "identityToken": token,
            "authorizationCode": code,
            "nonce": rawNonce,
            "user": credential.user,
            "email": credential.email ?? "",
            "givenName": credential.fullName?.givenName ?? "",
            "familyName": credential.fullName?.familyName ?? "",
        ]
        done(.success(payload))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard let authError = error as? ASAuthorizationError else {
            done(.failure(.failed("error")))
            return
        }
        switch authError.code {
        case .canceled:
            done(.failure(.cancelled))
        case .failed:
            done(.failure(.failed("failed")))
        case .invalidResponse:
            done(.failure(.failed("invalid_response")))
        case .notHandled:
            done(.failure(.failed("not_handled")))
        case .notInteractive:
            done(.failure(.failed("not_interactive")))
        case .unknown:
            // Souvent : aucun identifiant Apple connecté sur l'appareil (Réglages > [nom]).
            done(.failure(.failed("unknown")))
        default:
            done(.failure(.failed("error_\(authError.code.rawValue)")))
        }
    }

    // MARK: ASAuthorizationControllerPresentationContextProviding

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let anchor = anchor { return anchor }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first ?? ASPresentationAnchor()
    }

    // MARK: Révocation

    /// État de l'identifiant Apple auprès d'Apple (révoqué dans Réglages > Mot de passe et sécurité, etc.).
    /// completion(nil) si Apple n'a pas pu répondre (réseau…) : rien ne doit alors être déconnecté. Fil principal.
    static func checkCredential(userID: String, completion: @escaping (ASAuthorizationAppleIDProvider.CredentialState?) -> Void) {
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, error in
            DispatchQueue.main.async { completion(error == nil ? state : nil) }
        }
    }

    // MARK: Outils

    private func done(_ result: Result<[String: Any], Failure>) {
        let completion = self.completion
        self.completion = nil
        controller = nil
        rawNonce = ""
        completion?(result)
    }

    /// 32 octets aléatoires (générateur cryptographique du système), en hexadécimal.
    private static func randomNonce() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Empreinte SHA-256 en hexadécimal minuscule (valeur attendue dans la revendication « nonce » du jeton Apple).
    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
