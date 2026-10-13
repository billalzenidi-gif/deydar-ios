// Écran principal : le site Deydar dans une WKWebView réglée comme une app native.
// Écran de démarrage, tirer pour actualiser, retour par balayage, liens externes ouverts dans Safari/l'app concernée,
// boîtes de dialogue JavaScript natives, écran hors ligne avec « Réessayer », photos (caméra/photothèque) gérées par iOS,
// pont natif (connexion Google, GPS, partage) via NativeBridge, fichiers téléchargés proposés à l'enregistrement (Fichiers),
// reconnexion automatique quand le réseau revient, taille du texte iOS (Dynamic Type) appliquée au site.
import UIKit
import WebKit
import Network

final class WebViewController: UIViewController {
    private var webView: WKWebView!
    private let splash = SplashView()
    private let offline = OfflineView()
    private let refresh = UIRefreshControl()
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let location = LocationBridge()
    private let google = GoogleSignIn()
    private let checkout = CheckoutSession()
    private let pathMonitor = NWPathMonitor()
    private var progressObservation: NSKeyValueObservation?
    private var downloads: [WKDownload: URL] = [:]
    private var lastURL = AppConfig.baseURL
    private var splashHidden = false
    private var textPercent = 100
    private var activatedOnce = false

    #if DEBUG
    private var selfTestDone = false
    #endif

    deinit { pathMonitor.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppConfig.sand

        let contentController = WKUserContentController()
        contentController.addUserScript(WKUserScript(source: NativeBridge.script(geoState: location.state), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        contentController.add(WeakScriptMessageHandler(self), name: NativeBridge.handlerName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.applicationNameForUserAgent = AppConfig.userAgentSuffix

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = AppConfig.sand
        webView.scrollView.backgroundColor = AppConfig.sand
        webView.underPageBackgroundColor = AppConfig.sand
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        refresh.tintColor = AppConfig.brown
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        // Fine barre de chargement sous la barre d'état.
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = AppConfig.brown
        progress.trackTintColor = .clear
        progress.isAccessibilityElement = false
        progress.alpha = 0
        view.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
            DispatchQueue.main.async { self?.showProgress(web.estimatedProgress) }
        }

        for overlay in [offline, splash] as [UIView] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: view.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        offline.isHidden = true
        offline.onRetry = { [weak self] in self?.retry() }

        location.onAuthorizationChange = { [weak self] state in
            self?.runJS("window.__ddGeoState = '\(state)';")
        }
        location.deliver = { [weak self] id, position, failure in
            if let position = position {
                let c = position.coordinate
                self?.runJS("window.__ddGeo && window.__ddGeo(\(id), {lat: \(c.latitude), lng: \(c.longitude), acc: \(max(0, position.horizontalAccuracy))}, null);")
            } else {
                let f = failure ?? .unavailable
                self?.runJS("window.__ddGeo && window.__ddGeo(\(id), null, {code: \(f.code), message: 'location \(f)'});")
            }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(openDeepLink(_:)), name: .deydarOpenURL, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyTextSize), name: UIContentSizeCategory.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        applyTextSize()

        // Le réseau revient pendant que l'écran hors ligne est affiché : nouvel essai automatique.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async {
                guard let self = self, !self.offline.isHidden else { return }
                self.retry()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.deydar.app.network"))

        // Sécurité : l'écran de démarrage ne reste jamais plus de 10 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.hideSplash() }
        var start = AppConfig.baseURL
        #if DEBUG
        // Tests automatiques (simulateur) : « -DeydarStartPath /chemin » ouvre directement une page.
        if let path = UserDefaults.standard.string(forKey: "DeydarStartPath"),
           let url = URL(string: path, relativeTo: AppConfig.baseURL)?.absoluteURL {
            start = url
        }
        #endif
        load(start)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    /// Taille du texte choisie dans Réglages iOS (Dynamic Type) : le TEXTE du site est agrandi d'autant (jamais réduit),
    /// la largeur de la mise en page ne change pas (un zoom de page ferait déborder l'écran). Plafond 135 %.
    @objc private func applyTextSize() {
        guard isViewLoaded, webView != nil else { return }
        let percents: [UIContentSizeCategory: Int] = [
            .extraLarge: 106, .extraExtraLarge: 112, .extraExtraExtraLarge: 118,
            .accessibilityMedium: 124, .accessibilityLarge: 130, .accessibilityExtraLarge: 135,
            .accessibilityExtraExtraLarge: 135, .accessibilityExtraExtraExtraLarge: 135,
        ]
        let percent = percents[UIApplication.shared.preferredContentSizeCategory] ?? 100
        guard percent != textPercent else { return }
        textPercent = percent
        // Scripts injectés à chaque page : pont natif + taille du texte (recréés quand le réglage change).
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: NativeBridge.script(geoState: location.state), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: Self.textSizeScript(percent), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        runJS(Self.textSizeScript(percent))
    }

    static func textSizeScript(_ percent: Int) -> String {
        let css = percent > 100 ? "html{-webkit-text-size-adjust:\(percent)% !important}" : ""
        return "(function(){var s=document.getElementById('dd-text-size');if(!s){s=document.createElement('style');s.id='dd-text-size';(document.head||document.documentElement).appendChild(s);}s.textContent='\(css)';})();"
    }

    /// Retour au premier plan : iOS a pu suspendre la page (et son flux temps réel) ; le site se resynchronise tout de suite.
    @objc private func becameActive() {
        guard activatedOnce else { activatedOnce = true; return }
        #if DEBUG
        NSLog("DEYDAR-SELFTEST resync foreground")
        #endif
        runJS("window.__ddResync && window.__ddResync();")
    }

    private func showProgress(_ value: Double) {
        if value >= 1 {
            progress.setProgress(1, animated: true)
            UIView.animate(withDuration: 0.25, delay: 0.1, options: [], animations: { self.progress.alpha = 0 },
                           completion: { _ in if self.webView.estimatedProgress >= 1 { self.progress.setProgress(0, animated: false) } })
        } else {
            progress.alpha = 1
            progress.setProgress(Float(max(0.08, value)), animated: value > Double(progress.progress))
        }
    }

    // MARK: Chargement

    private func load(_ url: URL) {
        lastURL = url
        webView.load(URLRequest(url: url))
    }

    @objc private func pullToRefresh() {
        if webView.url == nil { load(lastURL) } else { webView.reload() }
    }

    private func retry() {
        offline.isHidden = true
        load(webView.url ?? lastURL)
    }

    /// deydar://stays/abc → https://<site>/stays/abc
    @objc private func openDeepLink(_ note: Notification) {
        guard let url = note.object as? URL else { return }
        if let host = url.host?.lowercased(), AppConfig.appHosts.contains(host) { load(url); return }
        guard url.scheme == "deydar" else { return }
        let path = ((url.host.map { "/" + $0 } ?? "") + url.path)
        var components = URLComponents(url: AppConfig.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path.isEmpty ? "/" : path
        components.query = url.query
        if let target = components.url { load(target) }
    }

    private func runJS(_ code: String) {
        guard isViewLoaded, webView != nil else { return }
        webView.evaluateJavaScript(code, completionHandler: nil)
    }

    private func resolve(_ id: Int, ok: Bool, payload: Any) {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8) {
            json = text
        } else {
            json = "null"
        }
        runJS("window.__ddNativeResolve && window.__ddNativeResolve(\(id), \(ok ? "true" : "false"), \(json));")
    }

    /// Cache l'écran de démarrage quand React a affiché la page (racine #root remplie), au plus tard après 3 s.
    private func hideSplashWhenRendered(attempt: Int = 0) {
        guard !splashHidden else { return }
        webView.evaluateJavaScript("(document.getElementById('root') || {}).childElementCount || 0") { [weak self] result, _ in
            guard let self = self else { return }
            if ((result as? NSNumber)?.intValue ?? 0) > 0 || attempt >= 20 {
                self.hideSplash()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.hideSplashWhenRendered(attempt: attempt + 1) }
            }
        }
    }

    private func hideSplash() {
        guard !splashHidden else { return }
        splashHidden = true
        UIView.animate(withDuration: 0.3, animations: { self.splash.alpha = 0 }, completion: { _ in self.splash.removeFromSuperview() })
    }

    private func showOffline() {
        refresh.endRefreshing()
        hideSplash()
        let wasHidden = offline.isHidden
        offline.isHidden = false
        // VoiceOver : l'écran hors ligne prend le focus, la page en dessous n'est plus lue.
        if wasHidden { UIAccessibility.post(notification: .screenChanged, argument: offline) }
    }

    /// Stripe Checkout dans la feuille Apple. Payé : la page du voyage s'ouvre (lien deydar://). Fermé sans payer : le site
    /// rejoint la page du voyage (paiement à reprendre) ou, à défaut, se resynchronise.
    private func openCheckout(_ url: URL) {
        checkout.start(url, from: view.window) { [weak self] callback in
            if let callback = callback {
                NotificationCenter.default.post(name: .deydarOpenURL, object: callback)
            } else {
                self?.runJS("(window.__ddCheckoutClosed || window.__ddResync || function () {})(); window.__ddCheckoutClosed = null;")
            }
        }
    }

    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    /// Contrôleur le plus haut affiché (feuille déjà ouverte, alerte…), pour y présenter la suivante.
    private func topPresenter() -> UIViewController {
        var top: UIViewController = self
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    /// Feuille de partage iOS : Messages, WhatsApp, Mail, Copier, « Enregistrer dans Fichiers »…
    private func presentShareSheet(_ items: [Any], completion: ((Bool) -> Void)? = nil) {
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, completed, _, _ in completion?(completed) }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        topPresenter().present(sheet, animated: true)
    }

    private func showMessage(_ text: String) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.t("ok"), style: .default))
        topPresenter().present(alert, animated: true)
    }

    /// Messages du pont acceptés seulement depuis la page principale de Deydar (jamais d'un cadre intégré tiers).
    private func isTrusted(_ message: WKScriptMessage) -> Bool {
        guard message.frameInfo.isMainFrame else { return false }
        return AppConfig.appHosts.contains(message.frameInfo.securityOrigin.host.lowercased())
    }
}

// MARK: - Navigation

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        // Lien <a download> (export des données du compte, pièce jointe…) : téléchargé puis proposé à l'enregistrement.
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if ["about", "blob", "data"].contains(scheme) {
            decisionHandler(.allow)
            return
        }
        if scheme == "http" || scheme == "https" {
            // Paiement Stripe : feuille sécurisée d'Apple, retour automatique dans l'app (CheckoutSession).
            if CheckoutSession.handles(url), navigationAction.targetFrame?.isMainFrame ?? true {
                decisionHandler(.cancel)
                openCheckout(url)
                return
            }
            // Cadres intégrés (cartes, Google…) : chargés normalement.
            if let frame = navigationAction.targetFrame, !frame.isMainFrame {
                decisionHandler(.allow)
                return
            }
            if let host = url.host?.lowercased(), AppConfig.appHosts.contains(host) {
                decisionHandler(.allow)
                return
            }
            openExternally(url)
            decisionHandler(.cancel)
            return
        }
        // tel:, mailto:, sms:, whatsapp:, maps:…
        openExternally(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame else { decisionHandler(.allow); return }
        // Fichier envoyé en pièce jointe, ou format que la vue web ne sait pas afficher : téléchargement.
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresh.endRefreshing()
        offline.isHidden = true
        if let url = webView.url { lastURL = url }
        hideSplashWhenRendered()
        #if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.runSelfTest() }
        #endif
    }

    #if DEBUG
    /// Tests automatiques du simulateur (CI) : « -DeydarSelfTest bridge|download|share|offline ».
    /// Écrit les résultats dans le journal (préfixe DEYDAR-SELFTEST) et ouvre l'écran à capturer. Jamais compilé en Release.
    private func runSelfTest() {
        guard !selfTestDone, let mode = UserDefaults.standard.string(forKey: "DeydarSelfTest") else { return }
        selfTestDone = true
        NSLog("DEYDAR-SELFTEST filename %@", Self.safeFilename("../a/b:c?.json"))
        NSLog("DEYDAR-SELFTEST textsize %@ text %ld%%", UIApplication.shared.preferredContentSizeCategory.rawValue, textPercent)
        let probe = #"JSON.stringify({share: typeof navigator.share, canShareUrl: !!(navigator.canShare && navigator.canShare({url: 'https://deydar.com'})), canShareFiles: !!(navigator.canShare && navigator.canShare({files: [1]})), native: !!window.DeydarNative, textAdjust: getComputedStyle(document.documentElement).webkitTextSizeAdjust, overflow: document.documentElement.scrollWidth > window.innerWidth + 1})"#
        webView.evaluateJavaScript(probe) { result, error in
            NSLog("DEYDAR-SELFTEST bridge %@", (result as? String) ?? String(describing: error))
        }
        switch mode {
        case "download":
            runJS(#"(function () { var u = URL.createObjectURL(new Blob(['{"selftest": true}'], {type: 'application/json'})); var a = document.createElement('a'); a.href = u; a.download = 'deydar-selftest.json'; document.body.appendChild(a); a.click(); a.remove(); })();"#)
        case "share":
            runJS(#"navigator.share({title: 'Deydar', url: location.href}).then(function () {}, function () {});"#)
        case "offline":
            showOffline()
        case "push":
            PushBridge.shared.handle(action: "status") { result in NSLog("DEYDAR-SELFTEST push status %@", (result["status"] as? String) ?? "?") }
        default:
            break
        }
    }
    #endif

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func handle(_ error: Error) {
        refresh.endRefreshing()
        let nsError = error as NSError
        // Navigations annulées volontairement (lien externe, nouvelle page avant la fin du chargement…).
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && (nsError.code == 102 || nsError.code == 204) { return }
        if let failing = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
           let host = failing.host?.lowercased(), !AppConfig.appHosts.contains(host) { return }
        showOffline()
    }
}

// MARK: - Téléchargements

extension WebViewController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        // Dossier temporaire propre à chaque fichier : jamais d'écrasement, iOS le vide lui-même.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("download-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            completionHandler(nil)
            return
        }
        let destination = folder.appendingPathComponent(Self.safeFilename(suggestedFilename))
        downloads[download] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloads.removeValue(forKey: download) else { return }
        presentShareSheet([file])
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: download)
        showMessage(L10n.t("download.failed"))
    }

    /// Nom proposé par le site, sans séparateurs de chemin ni caractères de contrôle.
    static func safeFilename(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        let cleaned = name.components(separatedBy: forbidden).joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "deydar-file" : String(cleaned.prefix(120))
    }
}

// MARK: - Fenêtres, alertes, confirmations

extension WebViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Liens target="_blank" / window.open : nos pages dans l'app, le reste à l'extérieur.
        if let url = navigationAction.request.url {
            if CheckoutSession.handles(url) {
                openCheckout(url)
            } else if let host = url.host?.lowercased(), AppConfig.appHosts.contains(host) {
                webView.load(URLRequest(url: url))
            } else {
                openExternally(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.t("ok"), style: .default) { _ in completionHandler() })
        presentOrSkip(alert) { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.t("cancel"), style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: L10n.t("ok"), style: .default) { _ in completionHandler(true) })
        presentOrSkip(alert) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: L10n.t("cancel"), style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: L10n.t("ok"), style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        presentOrSkip(alert) { completionHandler(nil) }
    }

    /// Présente la boîte de dialogue ; si une autre feuille est déjà affichée, répond tout de suite (WebKit l'exige).
    private func presentOrSkip(_ alert: UIAlertController, fallback: () -> Void) {
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        if top.isBeingDismissed || top is UIAlertController {
            fallback()
        } else {
            top.present(alert, animated: true)
        }
    }
}

// MARK: - Pont natif

extension WebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard isTrusted(message), let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let id = (body["id"] as? NSNumber)?.intValue ?? 0
        switch type {
        case "share":
            // navigator.share du site → feuille de partage iOS.
            func field(_ key: String) -> String? {
                guard let value = (body[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
                return String(value.prefix(2000))
            }
            var items: [Any] = []
            if let text = field("text") ?? field("title") { items.append(text) }
            if let link = field("url"), let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { items.append(url) }
            guard !items.isEmpty else { resolve(id, ok: false, payload: "empty"); return }
            presentShareSheet(items) { [weak self] completed in
                self?.resolve(id, ok: completed, payload: completed ? NSNull() as Any : "cancelled")
            }
        case "google":
            google.signIn(from: view.window) { [weak self] result in
                switch result {
                case .success(let token):
                    self?.resolve(id, ok: true, payload: ["accessToken": token])
                case .failure(.cancelled):
                    self?.resolve(id, ok: false, payload: "cancelled")
                case .failure(.failed(let reason)):
                    self?.resolve(id, ok: false, payload: reason)
                }
            }
        case "geo":
            location.request(
                id: id,
                watch: (body["watch"] as? NSNumber)?.boolValue ?? false,
                highAccuracy: (body["highAccuracy"] as? NSNumber)?.boolValue ?? true,
                timeoutMs: (body["timeout"] as? NSNumber)?.intValue ?? 30000,
                maximumAgeMs: (body["maximumAge"] as? NSNumber)?.intValue ?? 0
            )
        case "geoClear":
            location.clear(id: id)
        case "push":
            PushBridge.shared.handle(action: (body["action"] as? String) ?? "status") { [weak self] result in
                self?.resolve(id, ok: true, payload: result)
            }
        case "haptic":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        default:
            break
        }
    }
}

/// Évite le cycle de rétention WKUserContentController → contrôleur.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - Écrans natifs

/// Même rendu que l'écran de lancement iOS (fond sable + logo), avec un indicateur d'activité.
final class SplashView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AppConfig.sand
        let logo = UIImageView(image: UIImage(named: "LaunchLogo"))
        logo.contentMode = .scaleAspectFit
        logo.isAccessibilityElement = false
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = AppConfig.brown
        spinner.startAnimating()
        isAccessibilityElement = true
        accessibilityLabel = L10n.t("loading")
        accessibilityTraits = .updatesFrequently
        for v in [logo, spinner] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
            logo.heightAnchor.constraint(equalToConstant: 110),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.topAnchor.constraint(equalTo: logo.bottomAnchor, constant: 36),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }
}

final class OfflineView: UIView {
    var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AppConfig.sand
        // Textes à la taille choisie dans Réglages iOS (Dynamic Type), lus par VoiceOver ; l'icône est décorative.
        accessibilityViewIsModal = true
        let icon = UIImageView(image: UIImage(systemName: "wifi.slash"))
        icon.tintColor = AppConfig.brown
        icon.contentMode = .scaleAspectFit
        icon.isAccessibilityElement = false
        let title = UILabel()
        title.text = L10n.t("offline.title")
        title.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 22, weight: .semibold))
        title.adjustsFontForContentSizeCategory = true
        title.accessibilityTraits = .header
        title.textColor = AppConfig.ink
        title.textAlignment = .center
        title.numberOfLines = 0
        let text = UILabel()
        text.text = L10n.t("offline.text") + "\n" + L10n.t("offline.auto")
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.textColor = AppConfig.muted
        text.textAlignment = .center
        text.numberOfLines = 0
        var config = UIButton.Configuration.filled()
        config.title = L10n.t("retry")
        config.baseBackgroundColor = AppConfig.brown
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 28, bottom: 14, trailing: 28)
        let button = UIButton(configuration: config)
        button.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [icon, title, text, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.setCustomSpacing(26, after: text)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let centered = stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            icon.heightAnchor.constraint(equalToConstant: 54),
            icon.widthAnchor.constraint(equalToConstant: 64),
            centered,
            stack.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    @objc private func retryTapped() { onRetry?() }
}
