import AppKit
import CodexTokenCore

final class UsageHeatmapWindowController: NSWindowController {
    private let heatmapView = UsageHeatmapView()
    private let summaryLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 255),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex 使用热力图"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        configureContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(entries: [DailyUsageEstimate]) {
        heatmapView.entries = entries

        let available = entries.compactMap(\.usedPercent)
        let activeDays = available.filter { $0 > 0.001 }.count
        let total = available.reduce(0, +)
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        let totalText = formatter.string(from: NSNumber(value: total)) ?? "0"
        summaryLabel.stringValue = "最近 52 周：有记录 \(available.count) 天 · 使用 \(activeDays) 天 · 累计约 \(totalText)% 主额度"
    }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func configureContent() {
        let title = NSTextField(labelWithString: "最近 52 周")
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let explanation = NSTextField(
            wrappingLabelWithString: "每格代表一个自然日，颜色越深表示当天消耗的主 Codex 长周期额度越多。灰色表示没有足够的本机快照。"
        )
        explanation.textColor = .secondaryLabelColor

        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor

        heatmapView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heatmapView.widthAnchor.constraint(equalToConstant: 812),
            heatmapView.heightAnchor.constraint(equalToConstant: 125)
        ])

        let stack = NSStackView(views: [title, explanation, heatmapView, summaryLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 18, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
        ])
        window?.contentView = content
    }
}

private final class UsageHeatmapView: NSView {
    var entries: [DailyUsageEstimate] = [] {
        didSet {
            rebuildToolTips()
            needsDisplay = true
        }
    }

    private let calendar: Calendar = {
        var calendar = Calendar.autoupdatingCurrent
        calendar.firstWeekday = 2
        return calendar
    }()
    private let cellSize: CGFloat = 10
    private let cellGap: CGFloat = 3
    private let gridOrigin = NSPoint(x: 52, y: 20)
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter
    }()

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        drawWeekdayLabels()
        drawMonthLabels()

        for entry in entries {
            guard let rect = rect(for: entry.date) else { continue }
            color(for: entry.usedPercent).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }

        drawLegend()
    }

    private func rect(for date: Date) -> NSRect? {
        guard let firstDate = entries.first?.date else { return nil }
        let firstWeekday = calendar.component(.weekday, from: firstDate)
        let daysFromSunday = firstWeekday - calendar.firstWeekday
        let normalizedOffset = (daysFromSunday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -normalizedOffset, to: firstDate) else {
            return nil
        }
        let dayOffset = calendar.dateComponents([.day], from: gridStart, to: date).day ?? 0
        let column = dayOffset / 7
        let row = dayOffset % 7
        return NSRect(
            x: gridOrigin.x + CGFloat(column) * (cellSize + cellGap),
            y: gridOrigin.y + CGFloat(6 - row) * (cellSize + cellGap),
            width: cellSize,
            height: cellSize
        )
    }

    private func color(for value: Double?) -> NSColor {
        guard let value else { return NSColor.tertiaryLabelColor.withAlphaComponent(0.16) }
        if value <= 0.001 { return NSColor.systemGreen.withAlphaComponent(0.12) }
        if value < 2 { return NSColor.systemGreen.withAlphaComponent(0.30) }
        if value < 5 { return NSColor.systemGreen.withAlphaComponent(0.50) }
        if value < 10 { return NSColor.systemGreen.withAlphaComponent(0.72) }
        return NSColor.systemGreen.withAlphaComponent(0.95)
    }

    private func drawWeekdayLabels() {
        let labels = [("一", 0), ("三", 2), ("五", 4)]
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        for (label, row) in labels {
            let y = gridOrigin.y + CGFloat(6 - row) * (cellSize + cellGap) - 1
            label.draw(at: NSPoint(x: 27, y: y), withAttributes: attributes)
        }
    }

    private func drawMonthLabels() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        var lastMonth = -1
        for entry in entries {
            let month = calendar.component(.month, from: entry.date)
            let day = calendar.component(.day, from: entry.date)
            guard month != lastMonth, day <= 7, let rect = rect(for: entry.date) else { continue }
            formatter.string(from: entry.date).draw(
                at: NSPoint(x: rect.minX, y: gridOrigin.y + 7 * (cellSize + cellGap) + 2),
                withAttributes: attributes
            )
            lastMonth = month
        }
    }

    private func drawLegend() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let startX: CGFloat = 690
        "少".draw(at: NSPoint(x: startX, y: 1), withAttributes: attributes)
        for index in 0..<5 {
            let rect = NSRect(x: startX + 20 + CGFloat(index) * 13, y: 2, width: 10, height: 10)
            let sampleValues: [Double?] = [0, 1, 3, 7, 12]
            color(for: sampleValues[index]).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
        "多".draw(at: NSPoint(x: startX + 88, y: 1), withAttributes: attributes)
    }

    private func rebuildToolTips() {
        removeAllToolTips()
        for entry in entries {
            guard let rect = rect(for: entry.date) else { continue }
            addToolTip(rect, owner: self, userData: nil)
        }
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let entry = entries.first(where: { rect(for: $0.date)?.contains(point) == true }) else {
            return ""
        }
        let value = entry.usedPercent.map { String(format: "%.1f%%", $0) } ?? "数据不足"
        return "\(dateFormatter.string(from: entry.date))：\(value)"
    }
}
