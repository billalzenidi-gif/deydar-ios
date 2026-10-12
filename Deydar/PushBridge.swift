// Notifications push (APNs) de l'app Deydar. L'autorisation n'est JAMAIS demandée au lancement : seulement quand
// l'utilisateur active « Notifications sur cet iPhone » (Profil > Notifications). Le jeton de l'appareil est remis au
// site, qui l'inscrit pour le compte connecté (/api/push/devices) ; le serveur Deydar envoie ensuite les notifications.
// Toucher une notification ouvre la page indiquée (champ « link » du message, chemin interne du site).
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushBridge.shared.didRegister(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushBridge.shared.didFail(error)
    }

    // App ouverte : la notification s'affiche quand même (bannière), la page se met à jour par le flux temps réel.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        #if DEBUG
        NSLog("DEYDAR-SELFTEST push received link=%@", (notification.request.content.userInfo["link"] as? String) ?? "")
        #endif
        completionHandler([.banner, .list, .sound])
    }

    // Notification touchée : la page concernée s'ouvre dans l'app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let link = response.notification.request.content.userInfo["link"] as? String, let url = PushBridge.url(for: link) {
            NotificationCenter.default.post(name: .deydarOpenURL, object: url)
        }
        completionHandler()
    }
}

final class PushBridge {
    static let shared = PushBridge()
    private var waiting: [([String: Any]) -> Void] = []
    private var lastToken: String?

    /// Environnement APNs : sandbox pour les compilations de développement, production pour TestFlight et l'App Store.
    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// Chemin interne (« /trips/DD-123 ») → adresse du site ; tout autre lien est ignoré.
    static func url(for link: String) -> URL? {
        guard link.hasPrefix("/"), !link.hasPrefix("//") else { return nil }
        return URL(string: link, relativeTo: AppConfig.baseURL)?.absoluteURL
    }

    private static func name(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    /// action : « status » (rien n'est demandé), « refresh » (jeton si déjà autorisé), « register » (demande l'autorisation si besoin).
    func handle(action: String, completion: @escaping ([String: Any]) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                switch action {
                case "register" where status == .notDetermined:
                    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                        DispatchQueue.main.async {
                            if granted { self.register(status: "authorized", completion: completion) }
                            else { completion(["status": "denied"]) }
                        }
                    }
                case "register", "refresh":
                    if status == .authorized || status == .provisional || status == .ephemeral {
                        self.register(status: Self.name(status), completion: completion)
                    } else {
                        completion(["status": Self.name(status)])
                    }
                default:
                    completion(["status": Self.name(status)])
                }
            }
        }
    }

    private func register(status: String, completion: @escaping ([String: Any]) -> Void) {
        waiting.append { result in
            var out = result
            out["status"] = status
            completion(out)
        }
        UIApplication.shared.registerForRemoteNotifications()
        // Pas de réponse d'Apple (simulateur sans compte, réseau) : on répond quand même, sans jeton.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish(["error": "no_token"]) }
    }

    func didRegister(_ token: String) {
        lastToken = token
        finish(["token": token, "env": Self.environment])
    }

    func didFail(_ error: Error) {
        finish(["error": "registration_failed", "message": error.localizedDescription])
    }

    private func finish(_ result: [String: Any]) {
        let pending = waiting
        waiting.removeAll()
        pending.forEach { $0(result) }
    }
}
