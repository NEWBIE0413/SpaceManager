import AppKit
import SwiftUI

/// Hosts the actual NSWindow traffic-light buttons inside the glass sidebar.
/// Their native targets, hover glyphs, accessibility, and window actions remain intact.
struct IntegratedTrafficLights: NSViewRepresentable {
    func makeNSView(context: Context) -> IntegratedTrafficLightNSView {
        IntegratedTrafficLightNSView()
    }

    func updateNSView(_ view: IntegratedTrafficLightNSView, context: Context) {
        view.attachButtonsIfNeeded()
    }

    static func dismantleNSView(_ view: IntegratedTrafficLightNSView, coordinator: ()) {
        view.restoreButtons()
    }
}

final class IntegratedTrafficLightNSView: NSView {
    private weak var originalSuperview: NSView?
    private var originalFrames: [NSWindow.ButtonType: CGRect] = [:]
    private let buttonTypes: [NSWindow.ButtonType] = [
        .closeButton,
        .miniaturizeButton,
        .zoomButton,
    ]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachButtonsIfNeeded()
    }

    func attachButtonsIfNeeded() {
        guard let window else { return }
        let buttons = buttonTypes.compactMap { type in
            window.standardWindowButton(type).map { (type, $0) }
        }
        guard !buttons.isEmpty else { return }
        if originalSuperview == nil {
            originalSuperview = buttons[0].1.superview
            for (type, button) in buttons { originalFrames[type] = button.frame }
        }
        for (_, button) in buttons where button.superview !== self {
            button.removeFromSuperview()
            addSubview(button)
            button.isHidden = false
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let window else { return }
        let buttons = buttonTypes.compactMap { window.standardWindowButton($0) }
        var x: CGFloat = 0
        for button in buttons {
            let size = button.frame.size
            button.frame = CGRect(
                x: x,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            x += size.width + 8
        }
    }

    func restoreButtons() {
        guard let originalSuperview, let window else { return }
        for type in buttonTypes {
            guard let button = window.standardWindowButton(type),
                  button.superview === self else { continue }
            button.removeFromSuperview()
            originalSuperview.addSubview(button)
            if let frame = originalFrames[type] { button.frame = frame }
        }
    }

}
