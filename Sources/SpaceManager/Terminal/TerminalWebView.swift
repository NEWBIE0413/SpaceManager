import AppKit
import WebKit

/// WKWebView에 번들된 xterm.js 페이지를 띄우고 PTY와 중계한다.
/// 출력은 8ms 코얼레싱 배칭 후 base64로 전달한다 (폭주 출력 시 브릿지 병목 방지).
final class TerminalWebView: NSView {
    var onUserInput: ((Data) -> Void)?
    var onResize: ((UInt16, UInt16) -> Void)?
    var onReady: (() -> Void)?
    var onWebProcessCrash: (() -> Void)?

    private let webView: WKWebView
    private var isReady = false
    private var pendingOutput = Data()
    private var flushScheduled = false

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: frame, configuration: config)
        super.init(frame: frame)

        config.userContentController.add(BridgeProxy(owner: self), name: "bridge")
        webView.navigationDelegate = navigationProxy
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        loadPage()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private lazy var navigationProxy = NavigationProxy(owner: self)

    private func loadPage() {
        guard let html = Bundle.module.url(forResource: "terminal", withExtension: "html", subdirectory: "Resources") else {
            assertionFailure("terminal.html missing from bundle")
            return
        }
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    func reloadPage() {
        isReady = false
        loadPage()
    }

    // MARK: - PTY → JS (배칭)

    func feed(_ data: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingOutput.append(data)
            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) {
                self.flushScheduled = false
                self.flushOutput()
            }
        }
    }

    private func flushOutput() {
        guard isReady, !pendingOutput.isEmpty else { return }
        let b64 = pendingOutput.base64EncodedString()
        pendingOutput.removeAll(keepingCapacity: true)
        webView.evaluateJavaScript("window.smWrite('\(b64)')", completionHandler: nil)
    }

    // MARK: - 포커스/테마

    func focusTerminal() {
        window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.smFocus()", completionHandler: nil)
    }

    override func mouseDown(with event: NSEvent) {
        focusTerminal()
        super.mouseDown(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme: String
        if dark {
            theme = "{\"background\":\"#1e1e1e\",\"foreground\":\"#d4d4d4\",\"cursor\":\"#d4d4d4\",\"selectionBackground\":\"#264f78\"}"
        } else {
            theme = "{\"background\":\"#ffffff\",\"foreground\":\"#1e1e1e\",\"cursor\":\"#1e1e1e\",\"selectionBackground\":\"#b5d5ff\"}"
        }
        webView.evaluateJavaScript("window.smSetTheme(\(theme))", completionHandler: nil)
    }

    // MARK: - 클립보드 (네이티브 단일 경로, 스펙 §4)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "c":
            webView.evaluateJavaScript("window.smGetSelection()") { result, _ in
                guard let text = result as? String, !text.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return true
        case "v":
            if let text = NSPasteboard.general.string(forType: .string),
               let data = try? JSONEncoder().encode([text]),
               let json = String(data: data, encoding: .utf8) {
                // 배열로 인코딩해 JS 문자열 이스케이프를 JSON에 위임
                webView.evaluateJavaScript("window.smPaste(\(json)[0])", completionHandler: nil)
            }
            return true
        case "a":
            webView.evaluateJavaScript("window.smSelectAll()", completionHandler: nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - JS → Swift

    fileprivate func handleBridgeMessage(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            applyTheme()
            flushOutput()
            onReady?()
        case "input":
            if let s = dict["payload"] as? String {
                onUserInput?(Data(s.utf8))
            }
        case "resize":
            if let p = dict["payload"] as? [String: Any],
               let cols = p["cols"] as? Int, let rows = p["rows"] as? Int {
                onResize?(UInt16(cols), UInt16(rows))
            }
        default:
            break
        }
    }

    fileprivate func handleWebProcessCrash() {
        isReady = false
        onWebProcessCrash?()
    }
}

/// WKUserContentController는 핸들러를 강참조하므로 weak 프록시로 순환 참조를 끊는다.
private final class BridgeProxy: NSObject, WKScriptMessageHandler {
    weak var owner: TerminalWebView?
    init(owner: TerminalWebView) { self.owner = owner }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.handleBridgeMessage(message.body)
    }
}

private final class NavigationProxy: NSObject, WKNavigationDelegate {
    weak var owner: TerminalWebView?
    init(owner: TerminalWebView) { self.owner = owner }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner?.handleWebProcessCrash()
    }
}
