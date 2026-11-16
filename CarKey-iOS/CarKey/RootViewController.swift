import UIKit
import WebKit

/// 全屏 WKWebView 容器：加载包内 index.html，复刻小程序原型界面
final class RootViewController: UIViewController, WKNavigationDelegate {

    private var webView: WKWebView!

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()

        let bg = UIColor(red: 11.0 / 255.0, green: 12.0 / 255.0, blue: 14.0 / 255.0, alpha: 1.0)
        view.backgroundColor = bg

        // ---- WebView 配置 ----
        let contentController = WKUserContentController()
        contentController.add(CarKeyBridge.shared, name: "carkey")

        // 注入真机安全区数值，覆盖 CSS env() 兜底值
        let insetScript = WKUserScript(
            source: "window.__CARKEY_INSETS__ = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(insetScript)

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.dataDetectorTypes = []
        config.allowsInlineMediaPlayback = true
        if #available(iOS 13.0, *) {
            config.defaultWebpagePreferences.preferredContentMode = .mobile
        }

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = false
        wv.isOpaque = false
        wv.backgroundColor = bg
        wv.scrollView.backgroundColor = bg
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.showsVerticalScrollIndicator = false
        wv.scrollView.showsHorizontalScrollIndicator = false
        view.addSubview(wv)

        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: view.topAnchor),
            wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        webView = wv
        CarKeyBridge.shared.attach(wv)

        loadLocalPage()
    }

    private func loadLocalPage() {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html") else {
            showMissingResource()
            return
        }
        // 允许读取同目录下的其他资源
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func showMissingResource() {
        let label = UILabel()
        label.text = "未找到 index.html\n请确认已加入 Copy Bundle Resources"
        label.textColor = .lightGray
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    // MARK: - 安全区
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyInsets()
    }

    private func applyInsets() {
        let top = view.safeAreaInsets.top
        let bottom = view.safeAreaInsets.bottom
        let js = """
        (function(){
          var r = document.documentElement;
          r.style.setProperty('--top-inset', '\(top)px');
          r.style.setProperty('--bottom-inset', '\(bottom)px');
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyInsets()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 只加载本地内容；外部链接交给系统浏览器，避免在 App 内跳出
        if let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
