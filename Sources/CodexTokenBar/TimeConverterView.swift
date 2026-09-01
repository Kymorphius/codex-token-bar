import AppKit
import CodexTokenCore

final class TimeConverterView: NSView {
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let datePicker = NSDatePicker(frame: .zero)
    private let resultLabel = NSTextField(labelWithString: "")
    private var currentSourceTimeZone = TimeZoneConversion.pacificTimeZone
    private let localTimeZone: TimeZone
    private let localName: String

    init(
        now: Date = Date(),
        localTimeZone: TimeZone = DisplayTimeZoneSettings.timeZone,
        localName: String = DisplayTimeZoneSettings.name
    ) {
        self.localTimeZone = localTimeZone
        self.localName = localName
        super.init(frame: NSRect(x: 0, y: 0, width: 430, height: 145))

        sourcePopup.addItems(withTitles: [
            "太平洋时间（自动 PST/PDT）",
            localName
        ])
        sourcePopup.selectItem(at: 0)
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceTimeZoneChanged)

        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        datePicker.locale = Locale(identifier: "zh_CN")
        datePicker.timeZone = currentSourceTimeZone
        datePicker.dateValue = now
        datePicker.target = self
        datePicker.action = #selector(conversionInputChanged)

        resultLabel.font = NSFont.systemFont(
            ofSize: NSFont.systemFontSize,
            weight: .semibold
        )
        resultLabel.textColor = .labelColor
        resultLabel.isSelectable = true
        resultLabel.maximumNumberOfLines = 2
        resultLabel.lineBreakMode = .byWordWrapping

        let grid = NSGridView(views: [
            [Self.caption("输入时区"), sourcePopup],
            [Self.caption("输入时间"), datePicker],
            [Self.caption("换算结果"), resultLabel]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        let note = NSTextField(labelWithString: "太平洋时间会自动处理夏令时：夏季为 PDT，冬季为 PST。")
        note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            sourcePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 275),
            datePicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 275),
            resultLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 275)
        ])

        updateResult()
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func sourceTimeZoneChanged() {
        let wallClockComponents = TimeZoneConversion.wallClockComponents(
            for: datePicker.dateValue,
            in: currentSourceTimeZone
        )
        let newTimeZone = sourceTimeZone

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newTimeZone
        datePicker.timeZone = newTimeZone
        if let date = calendar.date(from: wallClockComponents) {
            datePicker.dateValue = date
        }

        currentSourceTimeZone = newTimeZone
        updateResult()
    }

    @objc private func conversionInputChanged() {
        updateResult()
    }

    private var sourceTimeZone: TimeZone {
        sourcePopup.indexOfSelectedItem == 0
            ? TimeZoneConversion.pacificTimeZone
            : localTimeZone
    }

    private var destinationTimeZone: TimeZone {
        sourcePopup.indexOfSelectedItem == 0
            ? localTimeZone
            : TimeZoneConversion.pacificTimeZone
    }

    private var destinationName: String {
        sourcePopup.indexOfSelectedItem == 0 ? localName : "太平洋时间"
    }

    private func updateResult() {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = destinationTimeZone
        formatter.dateFormat = "yyyy年M月d日 EEEE HH:mm"

        let abbreviation = sourcePopup.indexOfSelectedItem == 0
            ? DisplayTimeZoneSettings.utcOffset(for: localTimeZone, at: datePicker.dateValue)
            : TimeZoneConversion.pacificAbbreviation(at: datePicker.dateValue)
        let suffix = " \(abbreviation)"
        resultLabel.stringValue = "\(destinationName)：\(formatter.string(from: datePicker.dateValue))\(suffix)"
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }
}
