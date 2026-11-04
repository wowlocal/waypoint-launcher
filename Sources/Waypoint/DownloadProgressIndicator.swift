import AppKit
import WaypointCore

/// Resolve the native tooltip when it opens. Updating toolTip on every
/// progress report would continually restart AppKit's hover delay.
@MainActor
final class DownloadProgressIndicator: NSProgressIndicator, NSViewToolTipOwner {
    var details: (() -> String)? {
        didSet {
            if (oldValue == nil) != (details == nil) { updateTrackingAreas() }
        }
    }

    private var tooltipTag: NSView.ToolTipTag?
    private var tooltipBounds: NSRect?

    init() {
        super.init(frame: .zero)
        style = .bar
        isIndeterminate = false
        minValue = 0
        maxValue = 1
        controlSize = .small
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let rect = details == nil ? nil : bounds
        guard rect != tooltipBounds else { return }
        if let tooltipTag { removeToolTip(tooltipTag) }
        tooltipTag = rect.map { addToolTip($0, owner: self, userData: nil) }
        tooltipBounds = rect
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        details?() ?? ""
    }
}

func downloadDetails(_ progress: UpdateProgress?, bytesPerSecond: Double?, status: String) -> String {
    guard let progress else { return status }
    let done = progress.completedBytes
    let total = progress.totalBytes
    let remaining = total - min(done, total)
    var lines = [
        "\(preciseSize(done)) of \(preciseSize(total)) (\((progress.fraction * 100).formatted(.number.precision(.fractionLength(2))))%)",
        "\(done.formatted()) of \(total.formatted()) bytes",
        "Remaining: \(preciseSize(remaining))",
    ]
    if let bytesPerSecond {
        lines.append("Download speed: \(preciseSize(UInt64(max(0, bytesPerSecond))))/s")
    } else {
        lines.insert(status, at: 0)
    }
    return lines.joined(separator: "\n")
}

private func preciseSize(_ bytes: UInt64) -> String {
    let units: [(UInt64, String)] = [(1_000_000_000_000, "TB"), (1_000_000_000, "GB"), (1_000_000, "MB"), (1_000, "KB")]
    guard let (divisor, unit) = units.first(where: { bytes >= $0.0 }) else { return "\(bytes) bytes" }
    return "\((Double(bytes) / Double(divisor)).formatted(.number.precision(.fractionLength(2)))) \(unit)"
}
