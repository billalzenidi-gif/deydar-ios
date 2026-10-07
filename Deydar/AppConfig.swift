// Réglages de l'app iOS Deydar : adresse du site (VPS « brazil »), domaines ouverts dans l'app, client Google iOS.
import UIKit

enum AppConfig {
    /// Site Deydar hébergé sur le VPS. L'app affiche ce site : chaque mise en production du VPS
    /// (`bash deploy/vps.sh`) arrive dans l'app immédiatement, sans republier sur l'App Store.
    static let baseURL = URL(string: "https://deydar.191-215-43-242.sslip.io")!

    /// Domaines ouverts DANS l'app. Les autres liens (WhatsApp, cartes, sites externes…) s'ouvrent dans l'app concernée ou Safari.
    static let appHosts: Set<String> = ["deydar.191-215-43-242.sslip.io", "deydar.vercel.app"]

    /// Client OAuth « Deydar iOS » du projet Google Cloud « deydar » (identifiant public, ce n'est pas un secret).
    static let googleClientID = "908429571449-5ssdpbhv2epfhoqn2231rcj2ucmljg34.apps.googleusercontent.com"
    static var googleRedirectScheme: String {
        "com.googleusercontent.apps." + googleClientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    /// Ajouté à l'agent du navigateur : le site sait qu'il tourne dans l'app (pas de cadre « ordinateur », connexion Google native).
    static var userAgentSuffix: String { "DeydarApp/\(version) Mobile/15E148" }

    /// Langues de l'app web ; au premier lancement, l'app prend celle du téléphone si elle existe.
    static let supportedLanguages: Set<String> = ["en", "fr", "ar", "es", "pt", "de", "it", "nl"]
    static var deviceLanguage: String {
        let code = Locale.preferredLanguages.first.map { String($0.prefix(2)).lowercased() } ?? "en"
        return supportedLanguages.contains(code) ? code : "en"
    }

    static let sand = UIColor(red: 0xFC / 255, green: 0xF4 / 255, blue: 0xE9 / 255, alpha: 1)
    static let brown = UIColor(red: 0x80 / 255, green: 0x52 / 255, blue: 0x38 / 255, alpha: 1)
    static let ink = UIColor(red: 0x24 / 255, green: 0x1A / 255, blue: 0x14 / 255, alpha: 1)
    static let muted = UIColor(red: 0x8A / 255, green: 0x79 / 255, blue: 0x6B / 255, alpha: 1)
}

/// Quelques textes natifs (écran hors ligne, boîtes de dialogue), dans la langue du téléphone.
enum L10n {
    private static let table: [String: [String: String]] = [
        "offline.title": ["en": "No connection", "fr": "Pas de connexion", "ar": "لا يوجد اتصال", "es": "Sin conexión", "pt": "Sem ligação", "de": "Keine Verbindung", "it": "Nessuna connessione", "nl": "Geen verbinding"],
        "offline.text": ["en": "Check your internet connection and try again.", "fr": "Vérifiez votre connexion internet et réessayez.", "ar": "تحقّق من اتصالك بالإنترنت وحاول مرة أخرى.", "es": "Revisa tu conexión a internet e inténtalo de nuevo.", "pt": "Verifique a ligação à internet e tente novamente.", "de": "Prüfe deine Internetverbindung und versuch es erneut.", "it": "Controlla la connessione a internet e riprova.", "nl": "Controleer je internetverbinding en probeer het opnieuw."],
        "retry": ["en": "Try again", "fr": "Réessayer", "ar": "إعادة المحاولة", "es": "Reintentar", "pt": "Tentar novamente", "de": "Erneut versuchen", "it": "Riprova", "nl": "Opnieuw proberen"],
        "ok": ["en": "OK", "fr": "OK", "ar": "حسنًا", "es": "Aceptar", "pt": "OK", "de": "OK", "it": "OK", "nl": "OK"],
        "cancel": ["en": "Cancel", "fr": "Annuler", "ar": "إلغاء", "es": "Cancelar", "pt": "Cancelar", "de": "Abbrechen", "it": "Annulla", "nl": "Annuleren"],
    ]
    static func t(_ key: String) -> String {
        table[key]?[AppConfig.deviceLanguage] ?? table[key]?["en"] ?? key
    }
}

extension Notification.Name {
    /// Lien profond « deydar://chemin » reçu par l'app → la page correspondante s'ouvre.
    static let deydarOpenURL = Notification.Name("deydarOpenURL")
}
