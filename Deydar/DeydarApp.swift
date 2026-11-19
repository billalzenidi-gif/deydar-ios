// Point d'entrée de l'app iOS Deydar : une seule scène plein écran qui affiche le site Deydar du VPS.
import SwiftUI

@main
struct DeydarApp: App {
    // Notifications push (jeton APNs, notification touchée) : délégué UIKit classique.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WebScreen()
                .ignoresSafeArea()
                .background(Color(AppConfig.sand))
                // deydar://… et liens universels https://deydar.com/… (WhatsApp, Messages, Safari) : la page s'ouvre dans l'app.
                .onOpenURL { url in DeepLink.open(url) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { DeepLink.open(url) }
                }
        }
    }
}

struct WebScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebViewController { WebViewController() }
    func updateUIViewController(_ controller: WebViewController, context: Context) {}
}
