import AVFoundation
import UIKit
import WebKit

private enum NativeCaptureBridgeError: LocalizedError {
    case prepareFailed
    case recordFailed

    var errorDescription: String? {
        switch self {
        case .prepareFailed:
            return "AVAudioRecorder.prepareToRecord returned false"
        case .recordFailed:
            return "AVAudioRecorder.record returned false"
        }
    }
}

final class FoxWebViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {
    private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private let panel = UIStackView()
    private let urlField = UITextField()
    private let statusLabel = UILabel()
    private var audioRecorder: AVAudioRecorder?
    private var captureFileURL: URL?
    private var captureUploadURL: URL?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.06, alpha: 1)
        configureWebView()
        configurePanel()

        if let url = initialURL() {
            load(url)
        } else {
            showPanel(message: "输入 Mac 上的 \(appName) Web 地址，例如 http://192.168.1.20:5177")
        }
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "FoxAppName") as? String ?? "Fox"
    }

    private var appSubtitle: String {
        Bundle.main.object(forInfoDictionaryKey: "FoxAppSubtitle") as? String ?? "连接本机 runtime"
    }

    private var defaultWebPath: String {
        Bundle.main.object(forInfoDictionaryKey: "FoxDefaultWebPath") as? String ?? "/"
    }

    private var urlDefaultsKey: String {
        Bundle.main.object(forInfoDictionaryKey: "FoxURLDefaultsKey") as? String ?? "FoxWebURL"
    }

    private var isMainFoxApp: Bool {
        Bundle.main.bundleIdentifier == "com.whipa.fox"
    }

    private func configureWebView() {
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "foxPadAudioCapture")
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
        title.text = appName
        title.font = .systemFont(ofSize: 44, weight: .bold)
        title.textColor = .white
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = appSubtitle
        subtitle.font = .systemFont(ofSize: 20, weight: .medium)
        subtitle.textColor = UIColor(white: 0.82, alpha: 1)
        subtitle.textAlignment = .center

        urlField.borderStyle = .roundedRect
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.clearButtonMode = .whileEditing
        urlField.placeholder = "http://<Mac IP>:5177"
        urlField.text = normalizedSavedURLString()

        let loadButton = UIButton(type: .system)
        loadButton.setTitle("打开 \(appName)", for: .normal)
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
        if let savedURL = UserDefaults.standard.string(forKey: urlDefaultsKey), isMainFoxApp && isFoxSayURL(savedURL) {
            UserDefaults.standard.removeObject(forKey: urlDefaultsKey)
        }
        if let envURL = ProcessInfo.processInfo.environment["FOX_WEB_URL"], let url = normalizedAppURL(from: envURL) {
            let urlValue = url.absoluteString
            UserDefaults.standard.set(urlValue, forKey: urlDefaultsKey)
            urlField.text = urlValue
            return url
        }
        if let savedURL = normalizedSavedURLString(), let url = URL(string: savedURL) {
            return url
        }
        return nil
    }

    private func normalizedSavedURLString() -> String? {
        guard let savedURL = UserDefaults.standard.string(forKey: urlDefaultsKey) else {
            return nil
        }
        if isMainFoxApp && isFoxSayURL(savedURL) {
            UserDefaults.standard.removeObject(forKey: urlDefaultsKey)
            return nil
        }
        guard let url = normalizedAppURL(from: savedURL) else {
            return savedURL
        }
        let urlValue = url.absoluteString
        if urlValue != savedURL {
            UserDefaults.standard.set(urlValue, forKey: urlDefaultsKey)
        }
        return urlValue
    }

    private func normalizedAppURL(from urlValue: String) -> URL? {
        guard var components = URLComponents(string: urlValue) else {
            return URL(string: urlValue)
        }
        let shouldApplyDefaultPath = defaultWebPath != "/" &&
            (components.path.isEmpty || components.path == "/") &&
            (components.query?.isEmpty ?? true)
        if shouldApplyDefaultPath, let defaultComponents = URLComponents(string: defaultWebPath) {
            components.path = defaultComponents.path
            components.query = defaultComponents.query
        }
        return components.url
    }

    private func isFoxSayURL(_ urlValue: String) -> Bool {
        guard let components = URLComponents(string: urlValue) else {
            return urlValue.contains("mode=say")
        }
        return components.queryItems?.contains { item in
            item.name == "mode" && item.value == "say"
        } ?? false
    }

    @objc private func loadFromField() {
        guard let text = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = normalizedAppURL(from: text) else {
            showPanel(message: "URL 无效。")
            return
        }
        UserDefaults.standard.set(url.absoluteString, forKey: urlDefaultsKey)
        urlField.text = url.absoluteString
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

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "foxPadAudioCapture",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            sendCaptureEvent(["ok": false, "event": "error", "error": "invalid_native_capture_message"])
            return
        }

        switch action {
        case "start":
            guard let uploadURLValue = body["uploadUrl"] as? String,
                  let uploadURL = URL(string: uploadURLValue) else {
                sendCaptureEvent(["ok": false, "event": "error", "error": "invalid_upload_url"])
                return
            }
            startNativeCapture(uploadURL: uploadURL)
        case "stop":
            stopNativeCapture()
        default:
            sendCaptureEvent(["ok": false, "event": "error", "error": "unknown_native_capture_action"])
        }
    }

    private func startNativeCapture(uploadURL: URL) {
        if audioRecorder?.isRecording == true {
            sendCaptureEvent(["ok": false, "event": "error", "error": "native_capture_already_recording"])
            return
        }

        captureUploadURL = uploadURL
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.sendCaptureEvent(["ok": false, "event": "error", "error": "microphone_permission_denied"])
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("fox-say-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            guard recorder.prepareToRecord() else {
                throw NativeCaptureBridgeError.prepareFailed
            }
            guard recorder.record() else {
                throw NativeCaptureBridgeError.recordFailed
            }
            audioRecorder = recorder
            captureFileURL = fileURL
            sendCaptureEvent(["ok": true, "event": "started", "backend": "ios_native"])
        } catch {
            cleanupNativeCapture()
            sendCaptureEvent(nativeCaptureError("native_recording_start_failed", error: error, context: "beginRecording"))
        }
    }

    private func stopNativeCapture() {
        guard let recorder = audioRecorder, recorder.isRecording else {
            sendCaptureEvent(["ok": false, "event": "error", "error": "native_capture_not_recording"])
            return
        }
        recorder.stop()
        guard let fileURL = captureFileURL, let uploadURL = captureUploadURL else {
            cleanupNativeCapture()
            sendCaptureEvent(["ok": false, "event": "error", "error": "native_capture_missing_upload_context"])
            return
        }
        uploadNativeCapture(fileURL: fileURL, uploadURL: uploadURL)
    }

    private func uploadNativeCapture(fileURL: URL, uploadURL: URL) {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("audio/mp4", forHTTPHeaderField: "content-type")
        request.setValue("fox-say-ipad-native", forHTTPHeaderField: "x-fox-say-source")

        URLSession.shared.uploadTask(with: request, fromFile: fileURL) { [weak self] data, response, error in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: fileURL)
                self.cleanupNativeCapture()
            }
            if let error {
                self.sendCaptureEvent(self.nativeCaptureError("native_capture_upload_failed", error: error, context: "uploadTask"))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let data else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                self.sendCaptureEvent(self.nativeCaptureError("native_capture_upload_rejected", context: "uploadTask", statusCode: statusCode))
                return
            }
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            self.sendCaptureEvent(["ok": true, "event": "uploaded", "backend": "ios_native", "payload": payload])
        }.resume()
    }

    private func cleanupNativeCapture() {
        audioRecorder = nil
        captureFileURL = nil
        captureUploadURL = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func nativeCaptureError(_ code: String, error: Error? = nil, context: String? = nil, statusCode: Int? = nil) -> [String: Any] {
        var event: [String: Any] = ["ok": false, "event": "error", "error": code]
        if let context {
            event["context"] = context
        }
        if let statusCode {
            event["statusCode"] = statusCode
        }
        if let error {
            let nsError = error as NSError
            event["errorMessage"] = error.localizedDescription
            event["errorDomain"] = nsError.domain
            event["errorCode"] = nsError.code
        }
        return event
    }

    private func sendCaptureEvent(_ event: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript("window.__foxPadAudioCaptureResult && window.__foxPadAudioCaptureResult(\(json));")
        }
    }
}
