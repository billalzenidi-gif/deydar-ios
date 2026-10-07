// Écran principal : le site Deydar dans une WKWebView réglée comme une app native.
// Écran de démarrage, tirer pour actualiser, retour par balayage, liens externes ouverts dans Safari/l'app concernée,
// boîtes de dialogue JavaScript natives, écran hors ligne avec « Réessayer », photos (caméra/photothèque) gérées par iOS,
// pont natif (connexion Google, GPS) via NativeBridge.
import UIKit
import WebKit

final class WebViewController: UIViewController {
    private var webView: WKWebView!
    private let splash = SplashView()
    private let offline = OfflineView()
    private let refresh = UIRefreshControl()
    private let location = LocationBridge()
    private let google = GoogleSignIn()
    private var lastURL = AppConfig.baseURL
    private var splashHidden = false

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
        offline.isHidden = false
    }

    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

// MARK: - Navigation

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        if ["about", "blob", "data"].contains(scheme) {
            decisionHandler(.allow)
            return
        }
        if scheme == "http" || scheme == "https" {
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresh.endRefreshing()
        offline.isHidden = true
        if let url = webView.url { lastURL = url }
        hideSplashWhenRendered()
    }

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

// MARK: - Fenêtres, alertes, confirmations

extension WebViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Liens target="_blank" / window.open : nos pages dans l'app, le reste à l'extérieur.
        if let url = navigationAction.request.url {
            if let host = url.host?.lowercased(), AppConfig.appHosts.contains(host) {
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
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let id = (body["id"] as? NSNumber)?.intValue ?? 0
        switch type {
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
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = AppConfig.brown
        spinner.startAnimating()
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
        let icon = UIImageView(image: UIImage(systemName: "wifi.slash"))
        icon.tintColor = AppConfig.brown
        icon.contentMode = .scaleAspectFit
        let title = UILabel()
        title.text = L10n.t("offline.title")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = AppConfig.ink
        title.textAlignment = .center
        let text = UILabel()
        text.text = L10n.t("offline.text")
        text.font = .systemFont(ofSize: 16)
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
        NSLayoutConstraint.activate([
            icon.heightAnchor.constraint(equalToConstant: 54),
            icon.widthAnchor.constraint(equalToConstant: 64),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    @objc private func retryTapped() { onRetry?() }
}
