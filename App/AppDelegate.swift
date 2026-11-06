import UIKit
import WebKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = WebVC()
        window?.makeKeyAndVisible()
        return true
    }
}

final class WebVC: UIViewController, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    var web: WKWebView!
    var dark = false
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    func storeURL(_ key: String) -> URL { docs.appendingPathComponent("store-\(key).json") }

    func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
        let arr = String(data: data, encoding: .utf8)!
        return String(arr.dropFirst().dropLast())
    }

    override func loadView() {
        let cfg = WKWebViewConfiguration()
        let uc = WKUserContentController()
        var initial = "null"
        if let d = try? String(contentsOf: storeURL("diary"), encoding: .utf8) { initial = jsString(d) }
        let shim = """
        window.__iosData={diary:\(initial)};
        window.__iosStore={get:function(k){return window.__iosData[k]||null},set:function(k,v){window.__iosData[k]=v;window.webkit.messageHandlers.ios.postMessage({op:'set',k:k,v:v});return true}};
        window.Android={
          exportFile:function(n,d){window.webkit.messageHandlers.ios.postMessage({op:'export',name:n,data:d});return '分享面板'},
          shareText:function(t){window.webkit.messageHandlers.ios.postMessage({op:'share',text:t})},
          setBars:function(bg,nav,dk){window.webkit.messageHandlers.ios.postMessage({op:'bars',bg:bg,dark:!!dk})}
        };
        """
        uc.addUserScript(WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        uc.add(self, name: "ios")
        cfg.userContentController = uc
        cfg.allowsInlineMediaPlayback = true
        web = WKWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1)
        let root = UIView()
        root.backgroundColor = web.backgroundColor
        web.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(web)
        let g = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: g.topAnchor),
            web.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor)])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let dir = Bundle.main.url(forResource: "www", withExtension: nil)!
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { dark ? .lightContent : .darkContent }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let op = m["op"] as? String else { return }
        switch op {
        case "set":
            if let k = m["k"] as? String, let v = m["v"] as? String {
                let url = storeURL(k)
                DispatchQueue.global(qos: .utility).async { try? v.write(to: url, atomically: true, encoding: .utf8) }
            }
        case "export":
            let name = (m["name"] as? String) ?? "diary.txt"
            let data = (m["data"] as? String) ?? ""
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? data.write(to: url, atomically: true, encoding: .utf8)
            present(items: [url])
        case "share":
            present(items: [(m["text"] as? String) ?? ""])
        case "bars":
            dark = (m["dark"] as? Bool) ?? false
            if let bg = m["bg"] as? String, let c = UIColor(hex: bg) { web.backgroundColor = c; view.backgroundColor = c }
            setNeedsStatusBarAppearanceUpdate()
        default: break
        }
    }

    func present(items: [Any]) {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = view
        vc.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(vc, animated: true)
    }

    // JS alert/confirm/prompt
    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage msg: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }
    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage msg: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }
    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText: String?, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: p, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        present(a, animated: true)
    }
    // open external links in Safari
    func webView(_ w: WKWebView, decidePolicyFor nav: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = nav.request.url, let s = u.scheme, s == "http" || s == "https" {
            UIApplication.shared.open(u); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
