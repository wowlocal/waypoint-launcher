import AppKit
import WaypointCore

/// The download speed limit, and optional hours for automatic updates; the
/// games themselves opt in from their menus.
@MainActor
final class DownloadSettings: SettingsPane {
    private let model: AppModel
    private let speedSlider = NSSlider(value: Double(DownloadSpeedLimit.choices.count - 1), minValue: 0,
                                       maxValue: Double(DownloadSpeedLimit.choices.count - 1), target: nil, action: nil)
    private let speedValue = NSTextField.label(.body, monospacedDigits: true)
    private var defaultsObserver: NSObjectProtocol?
    private let windowCheckbox = NSButton(checkboxWithTitle: "Only update automatically during these hours", target: nil, action: nil)
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let fromLabel = NSTextField(labelWithString: "From")
    private let toLabel = NSTextField(labelWithString: "to")

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func build() {
        speedSlider.numberOfTickMarks = DownloadSpeedLimit.choices.count
        speedSlider.allowsTickMarkValuesOnly = true
        speedSlider.isContinuous = true
        speedSlider.target = self
        speedSlider.action = #selector(speedChanged)
        speedSlider.setAccessibilityLabel("Download speed limit")
        speedValue.alignment = .right
        speedValue.widthAnchor.constraint(equalToConstant: 90).isActive = true
        speedSlider.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let speedRow = NSStackView(views: [speedSlider, speedValue])
        speedRow.spacing = 10
        section("Download Speed", [speedRow, note("Total for all game downloads. Changes apply immediately.")])

        windowCheckbox.target = self
        windowCheckbox.action = #selector(windowChanged)
        for (picker, label) in [(startPicker, "Automatic update start time"), (endPicker, "Automatic update end time")] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .hourMinute
            // The hours are wall-clock times with no zone of their own: the
            // picker shows them in a fixed zone, so a time-zone change can't
            // shift what it shows. The locale still picks 12- or 24-hour.
            picker.calendar = Self.calendar
            picker.timeZone = Self.calendar.timeZone
            picker.locale = .autoupdatingCurrent
            picker.dateValue = Self.date(minute: 0)
            picker.target = self
            picker.action = #selector(hoursChanged)
            picker.setAccessibilityLabel(label)
        }
        let hours = NSStackView(views: [fromLabel, startPicker, toLabel, endPicker])
        hours.spacing = 8
        hours.alignment = .centerY
        hours.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        section("Automatic Game Updates", [
            note("Turn on Update Automatically in a game’s … menu. Games update from the top of the library down, while Waypoint is open and your Mac is awake."),
            windowCheckbox, hours,
        ])

        observeChanges { [weak self] in self?.renderHours() }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderSpeed() }
        }
        renderSpeed()
    }

    // MARK: Speed

    private func renderSpeed() {
        let limit = DownloadSpeedLimit.load()
        speedSlider.integerValue = DownloadSpeedLimit.choices.firstIndex(of: limit)!
        speedValue.stringValue = limit.label
        speedSlider.setAccessibilityValueDescription(limit.label)
        DownloadBandwidthLimiter.shared.bytesPerSecond = limit.bytesPerSecond
    }

    @objc private func speedChanged() {
        let index = min(max(speedSlider.integerValue, 0), DownloadSpeedLimit.choices.count - 1)
        DownloadSpeedLimit.choices[index].save()
        renderSpeed()
    }

    // MARK: Hours

    private func renderHours() {
        let preferences = model.automaticUpdates
        windowCheckbox.state = preferences.usesTimeWindow ? .on : .off
        for label in [fromLabel, toLabel] {
            label.textColor = preferences.usesTimeWindow ? .labelColor : .disabledControlTextColor
        }
        for (picker, minute) in [(startPicker, preferences.startMinute), (endPicker, preferences.endMinute)] {
            picker.isEnabled = preferences.usesTimeWindow
            // Leave a picker that already shows the stored time alone, so a
            // re-render doesn't disturb typing in it.
            if Self.minute(of: picker) != minute { picker.dateValue = Self.date(minute: minute) }
        }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The time on a fixed date in a fixed zone, so neither a daylight-saving
    /// transition nor a time-zone change moves the hours the user chose.
    private static func date(minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2001, month: 1, day: 15,
                                           hour: minute / 60, minute: minute % 60)) ?? .distantPast
    }

    private static func minute(of picker: NSDatePicker) -> Int {
        let time = calendar.dateComponents([.hour, .minute], from: picker.dateValue)
        return (time.hour ?? 0) * 60 + (time.minute ?? 0)
    }

    @objc private func windowChanged() {
        var preferences = model.automaticUpdates
        preferences.usesTimeWindow = windowCheckbox.state == .on
        model.setAutomaticUpdates(preferences)
    }

    @objc private func hoursChanged() {
        var preferences = model.automaticUpdates
        preferences.startMinute = Self.minute(of: startPicker)
        preferences.endMinute = Self.minute(of: endPicker)
        model.setAutomaticUpdates(preferences)
    }
}
