import SwiftUI
import AppKit

/// Terminal view for a single session
struct AgentTerminalView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let error = session.startError {
            VStack(spacing: 12) {
                Text(error)
                    .foregroundColor(.secondary)
                Button("다시 시도") {
                    session.restartIfDead()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 재연결 중에도 터미널을 그대로 둔다 — 끊기기 전 마지막 화면 위에 문구만 얹는다.
            SessionTerminalWrapper(session: session)
                .overlay(alignment: .topTrailing) {
                    if session.isReconnecting {
                        ReconnectingBadge(detail: session.lastConnectionFailure) {
                            session.reconnectIfNeeded()
                        }
                    }
                }
        }
    }
}

/// 터미널 우상단의 재연결 표시. 터미널과 같은 글꼴·셀 높이로 tmux 메시지 줄처럼 그려
/// 화면의 일부로 읽히게 한다. 애니메이션은 없다 — 호스트가 잠든 동안 몇 시간이고 떠 있을
/// 수 있어, 프레임마다 메인 스레드를 깨우는 표시는 그 시간 내내 CPU를 쓴다.
private struct ReconnectingBadge: View {
    let detail: String?
    let retryNow: () -> Void

    /// terminal.html의 xterm 설정(D2Coding 우선, 13pt)과 맞춘다.
    private static let font = Font(NSFont(name: "D2Coding", size: 13)
        ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))

    var body: some View {
        Text(" 연결 재시도 중… ")
            .font(Self.font)
            .foregroundColor(Color(red: 0x1e / 255, green: 0x1e / 255, blue: 0x1e / 255))
            .background(Color.reconnectAmber)
            .padding(.top, 2)
            // 카드의 둥근 모서리에 끝 글자가 잘리지 않게 곡선 안쪽으로 들인다.
            .padding(.trailing, 16)
            .onTapGesture(perform: retryNow)
            .help(detail.map { "\($0)\n클릭하면 바로 다시 연결합니다" } ?? "클릭하면 바로 다시 연결합니다")
            .accessibilityLabel("원격 연결 재시도 중")
            .accessibilityAddTraits(.isButton)
    }
}

/// 세션 소유 터미널 뷰를 SwiftUI에 안전하게 호스팅한다.
///
/// 선택 변경에도 컨테이너는 유지하고 캐시된 터미널만 교체한다. 화면 밖의
/// SwiftUI 계층이 실제 창의 터미널을 빼앗지 않도록 창에 붙은 호스트만 claim한다.
struct SessionTerminalWrapper: NSViewRepresentable {
    let session: TerminalSession
    @EnvironmentObject private var terminalLayout: TerminalLayoutTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        terminalLayout.attach(host)
        host.animatesTransitions = !reduceMotion
        host.show(session.getOrCreateTerminal())
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        terminalLayout.attach(host)
        host.animatesTransitions = !reduceMotion
        let changed = host.show(session.getOrCreateTerminal())
        // 포커스는 실제 화면에 있는 계층에서만
        if changed && host.window != nil {
            session.focusTerminal()
        }
    }
}

/// One coordinator per window; a stale animation completion cannot release a
/// newer transition. No timer or per-frame observation is needed.
final class TerminalLayoutTransition: ObservableObject {
    private weak var host: TerminalHostView?
    private var generation = 0
    private var isActive = false

    func attach(_ host: TerminalHostView) {
        self.host = host
        host.setResizeDeferred(isActive)
    }

    @discardableResult
    func begin() -> Int {
        generation += 1
        isActive = true
        host?.setResizeDeferred(true)
        return generation
    }

    func finish(_ transition: Int) {
        guard transition == generation else { return }
        // Even a nil (Reduce Motion) animation must commit its SwiftUI layout
        // before the terminal receives the final size.
        DispatchQueue.main.async { [weak self] in
            guard let self, transition == self.generation else { return }
            self.isActive = false
            self.host?.window?.contentView?.layoutSubtreeIfNeeded()
            self.host?.setResizeDeferred(false)
        }
    }
}

/// 터미널 뷰를 담는 컨테이너. 윈도우에 붙은 컨테이너만 터미널을 소유한다.
final class TerminalHostView: NSView {
    private(set) weak var terminal: TerminalWebView?
    var animatesTransitions = true
    private var outgoing: TerminalWebView?
    private var swapGeneration = 0
    private var resizeDeferred = false
    private var liveResize = false
    private let preparePresentation: (TerminalWebView, @escaping () -> Void) -> Void

    override var isFlipped: Bool { true }

    init(frame: NSRect = .zero,
         preparePresentation: @escaping (TerminalWebView, @escaping () -> Void) -> Void = { view, completion in
             view.prepareForPresentation(completion)
         }) {
        self.preparePresentation = preparePresentation
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        autoresizesSubviews = false
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setResizeDeferred(_ deferred: Bool) {
        guard resizeDeferred != deferred else { return }
        resizeDeferred = deferred
        updateViewport()
    }

    @discardableResult
    func show(_ next: TerminalWebView) -> Bool {
        let changed = terminal !== next
        if changed, window != nil, outgoing === next {
            // A→B→A before B has painted: the visible A is already correct.
            swapGeneration += 1
            for view in subviews where view !== next {
                (view as? TerminalWebView)?.cancelPresentation()
                view.removeFromSuperview()
            }
            next.cancelPresentation()
            next.layer?.removeAllAnimations()
            next.alphaValue = 1
            outgoing = nil
        }
        terminal = next
        attachIfNeeded()
        updateViewport()
        return changed
    }

    func attachIfNeeded() {
        guard let terminal, window != nil else { return }
        guard terminal.superview !== self else { return }
        swapGeneration += 1
        let generation = swapGeneration
        // Keep at most two surfaces, including during rapid A→B→C selection.
        // The outgoing view stays opaque until WebKit acknowledges a new frame.
        let previous = outgoing ?? subviews.compactMap { $0 as? TerminalWebView }.first
        for view in subviews where view !== previous {
            (view as? TerminalWebView)?.cancelPresentation()
            view.removeFromSuperview()
        }
        previous?.cancelPresentation()
        previous?.layer?.removeAllAnimations()
        previous?.alphaValue = 1
        outgoing = previous
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.autoresizingMask = []
        // A tab selected midway through a panel animation uses the held viewport
        // too. Hidden sessions never receive intermediate sizes.
        terminal.frame = NSRect(origin: .zero, size: resizeDeferred ? (previous?.frame.size ?? bounds.size) : bounds.size)
        terminal.alphaValue = 1
        addSubview(terminal, positioned: .below, relativeTo: previous)
        terminal.layoutSubtreeIfNeeded()
        NSAnimationContext.endGrouping()
        preparePresentation(terminal) { [weak self, weak terminal] in
            guard let self, let terminal,
                  self.swapGeneration == generation, self.terminal === terminal else { return }
            guard let previous = self.outgoing else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = self.animatesTransitions ? 0.22 : 0
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                previous.animator().alphaValue = 0
            } completionHandler: { [weak self, weak previous] in
                guard let self, self.swapGeneration == generation else { return }
                previous?.removeFromSuperview()
                previous?.alphaValue = 1
                self.outgoing = nil
            }
        }
    }

    private func updateViewport() {
        guard !resizeDeferred, !liveResize, !inLiveResize,
              bounds.width > 0, bounds.height > 0,
              let terminal, terminal.superview === self else { return }
        if terminal.frame != bounds {
            terminal.frame = bounds
            terminal.layoutSubtreeIfNeeded()
        }
    }

    // Pointer input always belongs to the selected tab, even while the old
    // surface covers it during the fade. The old PTY cannot receive stray clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let terminal, terminal.superview === self else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return terminal.hitTest(local) ?? terminal
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
    }

    override func layout() {
        super.layout()
        attachIfNeeded()
        updateViewport()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        liveResize = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        liveResize = false
        // AppKit clears inLiveResize after delivering the end notification.
        DispatchQueue.main.async { [weak self] in self?.updateViewport() }
    }
}
