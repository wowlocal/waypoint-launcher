import AppKit
import WaypointCore

/// Optional download hours; the games themselves opt in from their menus.
@MainActor
final class AutomaticUpdateSettings: SettingsPane {
    private let model: AppModel
    private let windowCheckbox = NSButton(checkboxWithTitle: "Only download during these hours", target: nil, action: nil)
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func build() {
        windowCheckbox.target = self
        windowCheckbox.action = #selector(windowChanged)
        for (picker, label) in [(startPicker, "Automatic update start time"), (endPicker, "Automatic update end time")] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .hourMinute
            picker.target = self
            picker.action = #selector(hoursChanged)
            picker.setAccessibilityLabel(label)
        }
        let hours = NSStackView(views: [NSTextField(labelWithString: "From"), startPicker,
                                      NSTextField(labelWithString: "to"), endPicker])
        hours.spacing = 8
        hours.alignment = .centerY
        section("Automatic Game Updates", [
            note("Turn on Keep Updated Automatically in a game’s … menu. Waypoint must be running and your Mac awake."),
            windowCheckbox, hours,
            note("Local time. Automatic downloads pause outside this window; manual downloads can run at any time. Matching start and end times allow downloads all day."),
        ])
        section("Download Priority", [note("Automatic updates run one at a time in library order. Drag a game higher in the library to update it sooner.")])
        observeChanges { [weak self] in self?.render() }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        render()
    }

    private func render() {
        let preferences = model.automaticUpdates
        windowCheckbox.state = preferences.usesTimeWindow ? .on : .off
        for (picker, minute) in [(startPicker, preferences.startMinute), (endPicker, preferences.endMinute)] {
            picker.calendar = .current
            picker.timeZone = .current
            picker.locale = .current
            // A fixed date keeps a daylight-saving transition today from
            // changing the wall-clock hours the user chose.
            if let date = Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15,
                                                                     hour: minute / 60, minute: minute % 60)) {
                picker.dateValue = date
            }
            picker.isEnabled = preferences.usesTimeWindow
        }
    }

    @objc private func windowChanged() {
        var preferences = model.automaticUpdates
        preferences.usesTimeWindow = windowCheckbox.state == .on
        model.setAutomaticUpdates(preferences)
    }

    @objc private func hoursChanged() {
        let calendar = Calendar.current
        var preferences = model.automaticUpdates
        preferences.startMinute = calendar.component(.hour, from: startPicker.dateValue) * 60
            + calendar.component(.minute, from: startPicker.dateValue)
        preferences.endMinute = calendar.component(.hour, from: endPicker.dateValue) * 60
            + calendar.component(.minute, from: endPicker.dateValue)
        model.setAutomaticUpdates(preferences)
    }
}
