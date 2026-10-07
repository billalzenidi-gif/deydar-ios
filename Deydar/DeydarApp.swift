// Point d'entrée de l'app iOS Deydar : une seule scène plein écran qui affiche le site Deydar du VPS.
import SwiftUI

@main
struct DeydarApp: App {
    var body: some Scene {
        WindowGroup {
            WebScreen()
                .ignoresSafeArea()
                .background(Color(AppConfig.sand))
                .onOpenURL { url in
                    NotificationCenter.default.post(name: .deydarOpenURL, object: url)
                }
        }
    }
}

struct WebScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebViewController { WebViewController() }
    func updateUIViewController(_ controller: WebViewController, context: Context) {}
}
