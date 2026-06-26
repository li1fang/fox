import UIKit
import WebKit

final class FoxWebViewController: UIViewController, WKNavigationDelegate {
    private let urlDefaultsKey = "FoxWebURL"
    private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private let panel = UIStackView()
    private let urlField = UITextField()
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.06, alpha: 1)
        configureWebView()
        configurePanel()

        if let url = initialURL() {
            load(url)
        } else {
            showPanel(message: "输入 Mac 上的 fox Web 地址，例如 http://192.168.1.20:5177")
        }
    }

    private func configureWebView() {
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = true
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configurePanel() {
        panel.axis = .vertical
        panel.spacing = 18
        panel.alignment = .fill
        panel.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "fox"
        title.font = .systemFont(ofSize: 44, weight: .bold)
        title.textColor = .white
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "连接本机训练 runtime"
        subtitle.font = .systemFont(ofSize: 20, weight: .medium)
        subtitle.textColor = UIColor(white: 0.82, alpha: 1)
        subtitle.textAlignment = .center

        urlField.borderStyle = .roundedRect
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.clearButtonMode = .whileEditing
        urlField.placeholder = "http://<Mac IP>:5177"
        urlField.text = UserDefaults.standard.string(forKey: urlDefaultsKey)

        let loadButton = UIButton(type: .system)
        loadButton.setTitle("打开 fox", for: .normal)
        loadButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        loadButton.addTarget(self, action: #selector(loadFromField), for: .touchUpInside)

        statusLabel.textColor = UIColor(white: 0.7, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 15, weight: .regular)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        [title, subtitle, urlField, loadButton, statusLabel].forEach(panel.addArrangedSubview)
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            panel.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.55)
        ])
    }

    private func initialURL() -> URL? {
        if let envURL = ProcessInfo.processInfo.environment["FOX_WEB_URL"], let url = URL(string: envURL) {
            UserDefaults.standard.set(envURL, forKey: urlDefaultsKey)
            urlField.text = envURL
            return url
        }
        if let savedURL = UserDefaults.standard.string(forKey: urlDefaultsKey), let url = URL(string: savedURL) {
            return url
        }
        return nil
    }

    @objc private func loadFromField() {
        guard let text = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines), let url = URL(string: text) else {
            showPanel(message: "URL 无效。")
            return
        }
        UserDefaults.standard.set(text, forKey: urlDefaultsKey)
        load(url)
    }

    private func load(_ url: URL) {
        statusLabel.text = "正在打开 \(url.absoluteString)"
        panel.isHidden = true
        webView.isHidden = false
        webView.load(URLRequest(url: url))
    }

    private func showPanel(message: String) {
        statusLabel.text = message
        webView.isHidden = true
        panel.isHidden = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showPanel(message: "加载失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showPanel(message: "连接失败：\(error.localizedDescription)")
    }
}
