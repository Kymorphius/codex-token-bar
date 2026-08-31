import AppKit

final class TiboHoverPreviewController {
    private let panel: NSPanel
    private let contentView = TiboPreviewDrawingView(frame: .zero)

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.transient, .ignoresCycle]

        let background = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor

        contentView.autoresizingMask = [.width, .height]
        background.addSubview(contentView)
        contentView.frame = background.bounds
        panel.contentView = background
    }

    func show(post: TiboPost, near pointer: NSPoint) {
        let content = Self.attributedContent(for: post)
        let width: CGFloat = 560
        let textWidth = width - 32
        let bounds = content.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = min(430, max(96, ceil(bounds.height) + 28))

        contentView.content = content
        let frame = Self.panelFrame(
            size: NSSize(width: width, height: height),
            near: pointer
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private static func panelFrame(size: NSSize, near pointer: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let gap: CGFloat = 14

        let preferredLeft = pointer.x - size.width - gap
        let x = preferredLeft >= visible.minX + 8
            ? preferredLeft
            : min(pointer.x + gap, visible.maxX - size.width - 8)
        let top = min(pointer.y + 18, visible.maxY - 8)
        let y = max(visible.minY + 8, top - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private static func attributedContent(for post: TiboPost) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 3
        bodyParagraph.paragraphSpacing = 6

        func appendHeading(_ text: String, color: NSColor, size: CGFloat = 13) {
            result.append(NSAttributedString(
                string: text + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                    .foregroundColor: color,
                    .paragraphStyle: bodyParagraph
                ]
            ))
        }

        func appendBody(_ text: String, size: CGFloat, color: NSColor) {
            result.append(NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: size),
                    .foregroundColor: color,
                    .paragraphStyle: bodyParagraph
                ]
            ))
        }

        if let translation = post.codexTranslatedText, !translation.isEmpty {
            appendHeading("中文翻译  ·  Codex Luna / high", color: .systemBlue, size: 14)
            appendBody(
                compact(translation, limit: 520),
                size: 14,
                color: .labelColor
            )
            result.append(NSAttributedString(string: "\n\n"))
        }

        appendHeading("英文原文", color: .secondaryLabelColor, size: 12)
        appendBody(
            compact(post.text, limit: post.codexTranslatedText == nil ? 760 : 340),
            size: 12.5,
            color: .secondaryLabelColor
        )
        return result
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
            + "…\n（点击该动态查看完整内容）"
    }
}

private final class TiboPreviewDrawingView: NSView {
    var content = NSAttributedString() {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        content.draw(
            with: bounds.insetBy(dx: 16, dy: 14),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }
}
