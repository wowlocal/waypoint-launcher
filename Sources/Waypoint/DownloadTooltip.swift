import AppKit

/// A live download tooltip using AppKit's tooltip material and font size.
/// All interaction stays with the library window; the panel never takes focus.
@MainActor
final class DownloadTooltip {
    static let shared = DownloadTooltip()

    private weak var owner: DownloadDetailsView?
    private var delay: Timer?
    private var refresh: Timer?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var anchor = NSPoint.zero
    private var width: CGFloat = 0
    private var panel: TooltipPanel?
    private let text = NSTextField(labelWithString: "")

    func schedule(for view: DownloadDetailsView) {
        guard view.details != nil else { return }
        if owner === view, panel?.isVisible == true { return }
        if owner === view {
            delay?.invalidate()
        } else {
            dismiss()
            owner = view
            let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                self?.dismiss()
                return event
            }
        }
        delay = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        }
    }

    func dismiss(for view: DownloadDetailsView) {
        if owner === view { dismiss() }
    }

    private func dismiss() {
        delay?.invalidate()
        delay = nil
        refresh?.invalidate()
        refresh = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        owner = nil
        width = 0
    }

    private func show() {
        delay = nil
        guard let owner, let window = owner.window, canShow(over: owner) else {
            dismiss()
            return
        }
        if panel == nil { makePanel() }
        guard let panel else { return }
        guard let point = owner.hoverPoint else { return }
        anchor = window.convertPoint(toScreen: point)
        panel.appearance = owner.effectiveAppearance
        guard updateText() else { return }
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)

        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.willMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
        refresh = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.updateText() }
        }
    }

    private func canShow(over view: DownloadDetailsView) -> Bool {
        guard let window = view.window, window.isKeyWindow, window.isVisible,
              !view.isHiddenOrHasHiddenAncestor, view.details != nil else { return false }
        guard let hoverPoint = view.hoverPoint else { return false }
        // The key-window tracking area supplies enter/exit events, including
        // when another window covers the view. Use its point rather than
        // polling the global cursor independently of the event stream.
        return view.visibleRect.contains(view.convert(hoverPoint, from: nil))
    }

    @discardableResult
    private func updateText() -> Bool {
        guard let owner, canShow(over: owner), let value = owner.details?(), !value.isEmpty,
              let panel else {
            dismiss()
            return false
        }
        if text.stringValue != value { text.stringValue = value }
        let size = text.fittingSize
        // Hold the width for this hover, so unit changes never make it twitch.
        width = max(width, ceil(size.width) + 12)
        let panelSize = NSSize(width: width, height: ceil(size.height) + 8)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? owner.window?.screen
        var origin = NSPoint(x: anchor.x + 10, y: anchor.y - 18 - panelSize.height)
        if let visible = screen?.visibleFrame {
            if origin.y < visible.minY { origin.y = anchor.y + 18 }
            origin.x = max(visible.minX, min(origin.x, visible.maxX - panelSize.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - panelSize.height))
        }
        let frame = NSRect(origin: origin, size: panelSize)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        text.frame = NSRect(x: 6, y: 4, width: panelSize.width - 12, height: panelSize.height - 8)
        return true
    }

    private func makePanel() {
        let panel = TooltipPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.title = "Download details"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 5
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        text.font = .monospacedDigitSystemFont(ofSize: NSFont.toolTipsFont(ofSize: 0).pointSize, weight: .regular)
        text.textColor = .labelColor
        text.maximumNumberOfLines = 2
        background.addSubview(text)
        panel.contentView = background
        self.panel = panel
    }
}

@MainActor
private final class TooltipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
