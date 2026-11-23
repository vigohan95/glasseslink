// Login.swift — Meta OIDC inside the app.
//
// ASWebAuthenticationSession cannot intercept an `https://` redirect, and Meta's
// native redirect is https://accounts.meta.com/native/oidc/redirect/metaai.
// So we host the login page in a WKWebView and watch the navigation: the first
// URL that carries `code=` is ours.

import SwiftUI
import WebKit

struct LoginWebView: UIViewControllerRepresentable {
    let url: URL
    let onCode: (String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> WebLoginController {
        let c = WebLoginController(url: url)
        c.onCode = onCode
        c.onCancel = onCancel
        return c
    }

    func updateUIViewController(_ c: WebLoginController, context: Context) {}
}

final class WebLoginController: UIViewController, WKNavigationDelegate {
    private let start: URL
    private var web: WKWebView!
    var onCode: ((String) -> Void)?
    var onCancel: (() -> Void)?

    init(url: URL) {
        start = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // keep the Meta session between attempts
        cfg.allowsInlineMediaPlayback = true
        web = WKWebView(frame: view.bounds, configuration: cfg)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.navigationDelegate = self
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

        let bar = UINavigationBar(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 88))
        bar.autoresizingMask = [.flexibleWidth]
        let item = UINavigationItem(title: "登录 Meta")
        item.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel,
                                                 target: self, action: #selector(cancelTapped))
        bar.items = [item]
        view.addSubview(bar)

        web.frame = CGRect(x: 0, y: 88, width: view.bounds.width,
                           height: view.bounds.height - 88)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(web)
        web.load(URLRequest(url: start))
    }

    @objc private func cancelTapped() { onCancel?() }

    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = action.request.url {
            if let code = Meta.code(from: u) {
                decisionHandler(.cancel)
                onCode?(code)
                return
            }
            // Some builds hand the code back on a non-standard path; catch the raw query too.
            if let comps = URLComponents(url: u, resolvingAgainstBaseURL: false),
               let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
               comps.path.contains("redirect") {
                decisionHandler(.cancel)
                onCode?(code)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A cancelled redirect shows up here too — ignore it.
    }
}
