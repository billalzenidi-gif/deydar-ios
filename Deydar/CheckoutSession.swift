// Paiement Stripe Checkout dans l'app : la page de paiement de Stripe s'ouvre dans une feuille sécurisée d'Apple
// (ASWebAuthenticationSession, moteur Safari : cartes, 3-D Secure, Apple Pay), jamais dans la vue web du site.
// Après le paiement, Stripe renvoie vers https://deydar.com/app-return.html?to=/trips/…, qui ouvre deydar://trips/… :
// la feuille se ferme et la page du voyage s'affiche dans l'app. Le paiement n'est « payé » que par le webhook signé
// de Stripe côté serveur ; l'app ne fait qu'afficher le résultat.
import UIKit
import AuthenticationServices

final class CheckoutSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private weak var anchor: UIWindow?

    /// Pages de paiement Stripe ouvertes dans la feuille (Checkout et ses domaines de paiement).
    static func handles(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "checkout.stripe.com" || host == "pay.stripe.com"
    }

    var isActive: Bool { session != nil }

    /// completion(lien deydar://… de retour) ou completion(nil) si la feuille a été fermée sans payer.
    func start(_ url: URL, from window: UIWindow?, completion: @escaping (URL?) -> Void) {
        guard session == nil else { return }
        anchor = window
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "deydar") { [weak self] callback, _ in
            self?.session = nil
            DispatchQueue.main.async { completion(callback) }
        }
        s.presentationContextProvider = self
        // Session éphémère : pas d'alerte « … veut utiliser … pour se connecter », aucun cookie partagé avec Safari.
        s.prefersEphemeralWebBrowserSession = true
        session = s
        if !s.start() {
            session = nil
            completion(nil)
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}
