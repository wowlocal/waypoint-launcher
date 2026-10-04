import AppKit

extension NSTextField {
    /// A one-line label in a system text style. It truncates rather than
    /// pushing its neighbors aside.
    static func label(_ style: NSFont.TextStyle, color: NSColor = .labelColor,
                      monospacedDigits: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        let font = NSFont.preferredFont(forTextStyle: style)
        label.font = monospacedDigits ? .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular) : font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

extension NSProgressIndicator {
    static func bar() -> NSProgressIndicator {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        return bar
    }

    static func spinner() -> NSProgressIndicator {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        return spinner
    }
}

extension NSStackView {
    /// Views stacked top to bottom, left-aligned; hidden ones take no space.
    static func column(_ views: [NSView], spacing: CGFloat = 2) -> NSStackView {
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = spacing
        column.detachesHiddenViews = true
        return column
    }
}

extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }
}

extension NSImage {
    static func symbol(_ name: String, pointSize: CGFloat? = nil) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        guard let pointSize else { return image }
        return image?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
    }
}
