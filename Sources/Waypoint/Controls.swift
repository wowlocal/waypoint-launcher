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
        label.maximumNumberOfLines = 1
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

extension NSButton {
    /// A library row's main action (Play, Update, Resume): a capsule on
    /// macOS 26 and later, a large push button before. Wide enough that
    /// changing its title doesn't move its neighbors.
    static func rowAction(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.controlSize = .large
        if #available(macOS 26.0, *) { button.borderShape = .capsule }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        return button
    }

    /// An icon-only button for a row's other actions: round on macOS 26 and
    /// later, a square push button before. `label` is what VoiceOver reads;
    /// set the tooltip where it's used.
    static func rowIcon(_ symbol: String, label: String) -> NSButton {
        let button = NSButton(image: .rowIcon(symbol) ?? NSImage(), target: nil, action: nil)
        button.controlSize = .large
        if #available(macOS 26.0, *) { button.borderShape = .circle }
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(label)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    /// Changes an icon button's symbol, with `label` as its tooltip and
    /// VoiceOver label. Does nothing when it already shows that.
    func showSymbol(_ name: String, label: String) {
        guard toolTip != label else { return }
        image = .rowIcon(name)
        setAccessibilityLabel(label)
        toolTip = label
    }

    /// On is a filled cup on the accent color. VoiceOver reads it as a
    /// switch, which is what it is.
    static func downloadKeepAwake() -> NSButton {
        let button = rowIcon("cup.and.saucer", label: "Keep Mac awake during this download")
        button.setAccessibilityRole(.checkBox)
        button.setAccessibilitySubrole(.toggle)
        button.toolTip = "Keep Mac awake until this download finishes. The display can still turn off."
        button.showKeepAwake(false)
        return button
    }

    func showKeepAwake(_ enabled: Bool) {
        image = .rowIcon(enabled ? "cup.and.saucer.fill" : "cup.and.saucer")
        bezelColor = enabled ? .controlAccentColor : nil
        setAccessibilityValue(NSNumber(value: enabled))
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
    /// A symbol sized for `NSButton.rowIcon`'s circle, whatever its shape.
    static func rowIcon(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    }

    static func symbol(_ name: String, pointSize: CGFloat? = nil) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        guard let pointSize else { return image }
        return image?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
    }
}
