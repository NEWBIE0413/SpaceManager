import AppKit
import WebKit

/// 유휴 뒤 첫 PTY 조각을 즉시 보낼지 한 프레임 모을지 판정한다.
///
/// 작은 일반 텍스트(셸의 타이핑 에코)는 즉시 보낸다. 반면 tmux의 화면 재도장은
/// cursor-hide/erase가 든 첫 조각과 실제 셀 재도장이 별도 read로 올 수 있다.
/// hide~show 중간 상태를 렌더하면 물리 커서가 다른 pane 위치로 튀고, xterm 커서를
/// 추적하는 한글 조합 미리보기도 함께 이동하므로 redraw 후보만 짧게 모은다.
enum TerminalOutputBatchPolicy {
    static let coalesceInterval: CFTimeInterval = 0.008
    static let cursorSpanRetryInterval: CFTimeInterval = 0.004
    static let maximumCursorSpanHold: CFTimeInterval = 0.032
    static let immediateByteLimit = 256

    private static let cursorHide = Data([0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x6C]) // ESC[?25l
    private static let cursorShow = Data([0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68]) // ESC[?25h
    private static let eraseDisplay = [
        Data([0x1B, 0x5B, 0x4A]),       // ESC[J
        Data([0x1B, 0x5B, 0x30, 0x4A]), // ESC[0J
        Data([0x1B, 0x5B, 0x31, 0x4A]), // ESC[1J
        Data([0x1B, 0x5B, 0x32, 0x4A]), // ESC[2J
        Data([0x1B, 0x5B, 0x33, 0x4A]), // ESC[3J
    ]
    private static let eraseLine = [
        Data([0x1B, 0x5B, 0x4B]),       // ESC[K
        Data([0x1B, 0x5B, 0x30, 0x4B]), // ESC[0K
        Data([0x1B, 0x5B, 0x31, 0x4B]), // ESC[1K
        Data([0x1B, 0x5B, 0x32, 0x4B]), // ESC[2K
    ]

    static func shouldFlushImmediately(_ data: Data, elapsedSinceLastFlush: CFTimeInterval) -> Bool {
        guard elapsedSinceLastFlush >= coalesceInterval else { return false }

        // hide와 show가 같은 조각에 있으면 재도장이 이미 완결돼 즉시 보내도 안전하다.
        if data.range(of: cursorHide) != nil {
            guard !hasUnclosedCursorHide(data) else { return false }
            return data.count <= immediateByteLimit
        }
        if endsWithCursorVisibilityPrefix(data) { return false }
        if eraseDisplay.contains(where: { data.range(of: $0) != nil }) { return false }
        if eraseLine.contains(where: { data.range(of: $0) != nil }) { return false }
        return data.count <= immediateByteLimit
    }

    /// 마지막 cursor visibility 명령이 hide면 redraw transaction이 아직 열려 있다.
    /// 여러 pane을 한 번에 다시 그릴 때 hide/show 쌍이 여러 개여도 마지막 상태만 보면 된다.
    static func hasUnclosedCursorHide(_ data: Data) -> Bool {
        let lastHide = data.range(of: cursorHide, options: .backwards)?.lowerBound
        let lastShow = data.range(of: cursorShow, options: .backwards)?.lowerBound
        guard let lastHide else { return false }
        guard let lastShow else { return true }
        return lastHide > lastShow
    }

    /// PTY read가 ESC[?25l/h 자체를 가른 경우 첫 절반을 즉시 보내지 않고 다음 read와 합친다.
    static func endsWithCursorVisibilityPrefix(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        for length in 1..<cursorHide.count {
            let suffix = data.suffix(length)
            if suffix.elementsEqual(cursorHide.prefix(length)) ||
                suffix.elementsEqual(cursorShow.prefix(length)) {
                return true
            }
        }
        return false
    }

    static func shouldHoldCursorSpan(_ data: Data, heldFor: CFTimeInterval) -> Bool {
        heldFor < maximumCursorSpanHold &&
            (hasUnclosedCursorHide(data) || endsWithCursorVisibilityPrefix(data))
    }
}

/// WKWebView에 번들된 xterm.js 페이지를 띄우고 PTY와 중계한다.
/// 출력은 8ms 코얼레싱 배칭 후 base64로 전달한다 (폭주 출력 시 브릿지 병목 방지).
final class TerminalWebView: NSView {
    var onUserInput: ((Data) -> Void)?
    var onResize: ((UInt16, UInt16) -> Void)?
    var onReady: (() -> Void)?
    var onWebProcessCrash: (() -> Void)?

    private(set) var lastCols: UInt16 = 80
    private(set) var lastRows: UInt16 = 24

    private let palette: TerminalPalette
    private let webView: WKWebView
    private var isReady = false
    private var pendingOutput = Data()
    private var pendingSince: CFTimeInterval?
    private var flushScheduled = false
    private var lastFlushTime: CFTimeInterval = 0

    override convenience init(frame: NSRect) {
        self.init(frame: frame, palette: .workspaceDark)
    }

    init(frame: NSRect, palette: TerminalPalette) {
        self.palette = palette
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: frame, configuration: config)
        super.init(frame: frame)

        config.userContentController.add(BridgeProxy(owner: self), name: "bridge")
        webView.navigationDelegate = navigationProxy
        webView.setValue(false, forKey: "drawsBackground")
        // AutoLayout 제약 대신 autoresizing: 로딩 중 재부모화를 겪는 WKWebView는
        // 제약 기반 리사이즈에서 웹 프로세스 뷰포트가 스테일해지는 사례가 있다
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
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
            let now = CACurrentMediaTime()
            if self.pendingOutput.isEmpty { self.pendingSince = now }
            self.pendingOutput.append(data)
            guard !self.flushScheduled else { return }
            // 어댑티브 플러시: 한가할 땐 즉시 전송(타이핑 에코 지연 0),
            // 직전 플러시 직후의 출력과 유휴 뒤 tmux redraw 후보만 8ms 모은다.
            if TerminalOutputBatchPolicy.shouldFlushImmediately(
                self.pendingOutput,
                elapsedSinceLastFlush: now - self.lastFlushTime
            ) {
                self.flushOutput()
            } else {
                self.scheduleFlush(after: TerminalOutputBatchPolicy.coalesceInterval)
            }
        }
    }

    private func scheduleFlush(after delay: CFTimeInterval) {
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flushWhenCursorSpanIsComplete()
        }
    }

    private func flushWhenCursorSpanIsComplete() {
        guard !pendingOutput.isEmpty else { return }
        let heldFor = pendingSince.map { CACurrentMediaTime() - $0 } ?? 0
        if TerminalOutputBatchPolicy.shouldHoldCursorSpan(pendingOutput, heldFor: heldFor) {
            scheduleFlush(after: TerminalOutputBatchPolicy.cursorSpanRetryInterval)
        } else {
            flushOutput()
        }
    }

    private func flushOutput() {
        guard isReady, !pendingOutput.isEmpty else { return }
        lastFlushTime = CACurrentMediaTime()
        let b64 = pendingOutput.base64EncodedString()
        pendingOutput.removeAll(keepingCapacity: true)
        pendingSince = nil
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

    // 뷰가 0x0으로 부착됐다가 나중에 커지는 경우(호스트 컨테이너 경유) 페이지 쪽
    // ResizeObserver가 초기 핏을 놓칠 수 있어, 네이티브 레이아웃 변경마다 명시적으로 핏한다
    override func layout() {
        super.layout()
        if isReady {
            webView.evaluateJavaScript("window.smFit && window.smFit()", completionHandler: nil)
        }
    }

    /// 워크스페이스는 기존 다크를 유지하고, tmux를 쓰지 않는 Quick만 전체
    /// 라이트 ANSI 팔레트를 쓴다. 색상 선택은 TerminalPalette 한 경로에 모은다.
    private func applyTheme() {
        guard let theme = palette.json else { return }
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
            if let p = dict["payload"] as? [String: Any],
               let cols = p["cols"] as? Int, let rows = p["rows"] as? Int, cols > 0, rows > 0 {
                lastCols = UInt16(cols)
                lastRows = UInt16(rows)
            }
            isReady = true
            applyTheme()
            flushOutput()
            webView.evaluateJavaScript("window.smFit && window.smFit()", completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.webView.evaluateJavaScript("window.smFit && window.smFit()", completionHandler: nil)
            }
            onReady?()
        case "input":
            if let s = dict["payload"] as? String {
                onUserInput?(Data(s.utf8))
            }
        case "resize":
            if let p = dict["payload"] as? [String: Any],
               let cols = p["cols"] as? Int, let rows = p["rows"] as? Int {
                lastCols = UInt16(cols)
                lastRows = UInt16(rows)
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
