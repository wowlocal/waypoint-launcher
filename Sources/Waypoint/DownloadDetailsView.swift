import AppKit
import WaypointCore

/// One hover region for the progress bar and its counter. AppKit's built-in
/// tooltip snapshots its string; this uses a tooltip-material panel so the
/// numbers can update without dismissing it.
@MainActor
final class DownloadDetailsView: NSStackView {
    let label = NSTextField.label(.subheadline, color: .secondaryLabelColor, monospacedDigits: true)
    /// Made when progress is first shown: most rows never show any.
    private var progress: NSProgressIndicator?

    /// How much of the download is done, 0 to 1, on a bar above the label.
    /// nil: no bar.
    var fraction: Double? {
        didSet {
            guard let fraction else {
                progress?.isHidden = true
                return
            }
            let bar = progress ?? makeProgress()
            bar.doubleValue = fraction
            bar.isHidden = false
        }
    }

    var details: (() -> String)? {
        didSet {
            if details == nil { DownloadTooltip.shared.dismiss(for: self) }
        }
    }

    /// An error gets a second line before it truncates; the rest of the
    /// message is in the label's tooltip. Two lines still fit beside the icon.
    var showsError = false {
        didSet {
            guard showsError != oldValue else { return }
            label.maximumNumberOfLines = showsError ? 2 : 1
            // Set the mode itself: turning a cell's `wraps` off leaves it
            // clipping, with no ellipsis.
            label.lineBreakMode = showsError ? .byWordWrapping : .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = showsError
            label.invalidateIntrinsicContentSize()
        }
    }

    private var hoverTracking: NSTrackingArea?
    private(set) var hoverPoint: NSPoint?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 3
        detachesHiddenViews = true
        setViews([label], in: .center)
        setContentHuggingPriority(.init(1), for: .horizontal)
        // No taller than the bar and its line, or the line drifts from the name.
        setHuggingPriority(.defaultHigh, for: .vertical)
        label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
    }

    private func makeProgress() -> NSProgressIndicator {
        let bar = NSProgressIndicator.bar()
        insert(bar, before: label)
        // The bar is as wide as the row's text column (see `layOutRow`).
        bar.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        progress = bar
        return bar
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverTracking == nil else { return }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        hover(at: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        hover(at: event.locationInWindow)
    }

    func hover(at point: NSPoint) {
        hoverPoint = point
        DownloadTooltip.shared.schedule(for: self)
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        DownloadTooltip.shared.dismiss(for: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            hoverPoint = nil
            DownloadTooltip.shared.dismiss(for: self)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidHide() {
        super.viewDidHide()
        hoverPoint = nil
        DownloadTooltip.shared.dismiss(for: self)
    }
}

func downloadDetails(_ progress: UpdateProgress?, bytesPerSecond: Double?, status: String) -> String {
    guard let progress else { return status }
    // A fixed unit makes small advances visible even in a large download.
    let done = (Double(progress.completedBytes) / 1_000_000).formatted(.number.precision(.fractionLength(2)))
    let total = (Double(progress.totalBytes) / 1_000_000).formatted(.number.precision(.fractionLength(2)))
    let downloaded = "\(done) of \(total) MB"
    if let bytesPerSecond {
        return "\(preciseSize(UInt64(max(0, bytesPerSecond))))/s\n\(downloaded)"
    } else {
        return "\(status)\n\(downloaded)"
    }
}

private func preciseSize(_ bytes: UInt64) -> String {
    let units: [(UInt64, String)] = [(1_000_000_000_000, "TB"), (1_000_000_000, "GB"), (1_000_000, "MB"), (1_000, "KB")]
    guard let (divisor, unit) = units.first(where: { bytes >= $0.0 }) else { return "\(bytes) bytes" }
    return "\((Double(bytes) / Double(divisor)).formatted(.number.precision(.fractionLength(2)))) \(unit)"
}
