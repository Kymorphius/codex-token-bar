import AppKit
import CodexTokenCore
import WebKit

private final class TiboPostLinkButton: NSButton {
    var postURL: URL?
    var post: TiboPost?
}

private final class TiboOriginalToggleButton: NSButton {
    var originalViews: [NSView] = []
}

// Fibonacci steps keep adjacent spacing ratios close to the golden ratio while
// remaining aligned with native macOS control sizes.
private enum TiboLayout {
    static let xSmall: CGFloat = 5
    static let small: CGFloat = 8
    static let medium: CGFloat = 13
    static let large: CGFloat = 21
    static let xLarge: CGFloat = 34
}

final class TiboFeedWindowController: NSWindowController, WKNavigationDelegate {
    var onPostsCaptured: (([TiboPost]) -> Void)?
    var onTranslationCompleted: ((URL, String) -> Void)?
    var onRSSRefreshRequested: (() -> Void)?

    private let webView: WKWebView
    private let translationClient = TiboTranslationClient()
    private let feedScrollView = NSScrollView()
    private let feedStack = NSStackView()
    private let modeControl = NSSegmentedControl(
        labels: ["RSS", "资讯", "X 原页"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(labelWithString: "资讯视图只显示已整理的 Tibo 公开发言")
    private let batchTranslationButton = NSButton(title: "批量翻译", target: nil, action: nil)
    private let autoTranslationCheckbox = NSButton(
        checkboxWithTitle: "自动翻译新消息",
        target: nil,
        action: nil
    )
    private var cachedPosts: [TiboPost] = []
    private var rssPosts: [TiboPost] = []
    private var rssStatus = "RSSHub 等待首次更新"
    private var rssRepliesAvailable = false
    private var translatingURLs: Set<String> = []
    private var automaticRetryBlockedURLs: Set<String> = []
    private var activeTranslationRuns = 0
    private var pendingFullTextURL: URL?

    private static let autoTranslationKey = "tibo-auto-translation-v1"
    private static let translationConsentKey = "tibo-mymemory-translation-consent-v1"

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .windowBackgroundColor
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tibo 消息"
        window.minSize = NSSize(width: 620, height: 560)
        window.center()

        super.init(window: window)

        webView.navigationDelegate = self
        configureContentView()
        renderCurrentMode()
        showRSSMode()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showRSSMode()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func updatePosts(_ posts: [TiboPost]) {
        cachedPosts = posts
        if rssPosts.isEmpty {
            rssPosts = posts.filter { $0.isFromRSSHub == true }
        }
        automaticRetryBlockedURLs.formIntersection(posts.map { $0.url.absoluteString })
        renderCurrentMode()
        updateTranslationControls()
        if !posts.isEmpty, modeControl.selectedSegment == 1 {
            statusLabel.stringValue = "已整理 \(posts.count) 条公开发言 · 点击正文可选择复制"
        }
        scheduleAutomaticTranslationIfNeeded()
    }

    func updateRSSFeed(
        posts: [TiboPost],
        repliesAvailable: Bool,
        status: String
    ) {
        rssPosts = posts
        rssRepliesAvailable = repliesAvailable
        rssStatus = status
        if modeControl.selectedSegment == 0 {
            renderRSSFeed()
            updateRSSStatusLabel()
        }
    }

    func updateRSSStatus(_ status: String) {
        rssStatus = status
        if modeControl.selectedSegment == 0 {
            updateRSSStatusLabel()
        }
    }

    func captureVisiblePosts() {
        guard let host = webView.url?.host?.lowercased(),
              host == "x.com" || host.hasSuffix(".x.com") ||
              host == "twitter.com" || host.hasSuffix(".twitter.com")
        else {
            return
        }

        webView.evaluateJavaScript(Self.capturePostsJavaScript) { [weak self] result, _ in
            guard let self,
                  let json = result as? String,
                  let data = json.data(using: .utf8),
                  let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else {
                return
            }

            let now = Date()
            var posts = objects.compactMap { object -> TiboPost? in
                guard let text = object["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let urlString = object["url"] as? String,
                      let url = URL(string: urlString),
                      url.path.contains("/status/")
                else {
                    return nil
                }

                let postedAt = (object["date"] as? String).flatMap(Self.iso8601Formatter.date)
                let isPossiblyTruncated = object["truncated"] as? Bool
                return TiboPost(
                    text: text,
                    url: url,
                    postedAt: postedAt,
                    capturedAt: now,
                    isPossiblyTruncated: isPossiblyTruncated,
                    isFromRSSHub: false
                )
            }

            guard !posts.isEmpty else { return }
            if let pendingURL = self.pendingFullTextURL,
               let refreshedIndex = posts.firstIndex(where: { $0.url == pendingURL }),
               let previous = self.cachedPosts.first(where: { $0.url == pendingURL }),
               Self.isLikelyTruncated(previous),
               posts[refreshedIndex].text.count <= previous.text.count {
                posts[refreshedIndex].isPossiblyTruncated = true
            }
            DispatchQueue.main.async {
                self.onPostsCaptured?(posts)
                if let pendingURL = self.pendingFullTextURL,
                   let refreshed = posts.first(where: { $0.url == pendingURL }) {
                    self.pendingFullTextURL = nil
                    self.statusLabel.stringValue = Self.isLikelyTruncated(refreshed)
                        ? "X 仍只提供了摘要；可点击“查看原帖”阅读完整内容"
                        : "全文已补全 · 如原文有变化，中文译文会自动重新生成"
                }
            }
        }
    }

    private func configureContentView() {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "Tibo 消息")
        titleLabel.font = .systemFont(ofSize: 21, weight: .semibold)

        let handleLabel = NSTextField(labelWithString: "@thsottiaux · Codex 负责人")
        handleLabel.textColor = .secondaryLabelColor
        handleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let identityStack = NSStackView(views: [titleLabel, handleLabel])
        identityStack.orientation = .vertical
        identityStack.alignment = .leading
        identityStack.spacing = TiboLayout.xSmall

        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setWidth(72, forSegment: 0)
        modeControl.setWidth(72, forSegment: 1)
        modeControl.setWidth(88, forSegment: 2)

        let titleRow = NSStackView(views: [identityStack, NSView(), modeControl])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = TiboLayout.medium

        let subtitleLabel = NSTextField(
            wrappingLabelWithString: "默认自动翻译新消息；也可按条或批量翻译，译文保存在本机。"
        )
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.font = .systemFont(ofSize: 13)

        let updateButton = NSButton(
            title: "从 X 更新消息",
            target: self,
            action: #selector(showLatestPosts)
        )
        updateButton.bezelStyle = .rounded

        let rssButton = NSButton(
            title: "刷新 RSS",
            target: self,
            action: #selector(refreshRSS)
        )
        rssButton.bezelStyle = .rounded

        let repliesButton = NSButton(
            title: "查看不同帖子下的回复",
            target: self,
            action: #selector(showReplies)
        )
        repliesButton.bezelStyle = .rounded

        let translationSettingsButton = NSButton(
            title: "X 翻译设置",
            target: self,
            action: #selector(showTranslationSettings)
        )
        translationSettingsButton.bezelStyle = .rounded

        let browserButton = NSButton(
            title: "用浏览器打开",
            target: self,
            action: #selector(openInBrowser)
        )
        browserButton.bezelStyle = .rounded

        batchTranslationButton.target = self
        batchTranslationButton.action = #selector(translateAllPosts)
        batchTranslationButton.bezelStyle = .rounded

        autoTranslationCheckbox.target = self
        autoTranslationCheckbox.action = #selector(autoTranslationChanged)
        autoTranslationCheckbox.state = isAutoTranslationEnabled ? .on : .off

        let sourceLabel = makeSectionLabel("来源")
        sourceLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let primaryButtonRow = NSStackView(views: [
            sourceLabel,
            rssButton,
            updateButton,
            repliesButton,
            NSView(),
            browserButton
        ])
        primaryButtonRow.orientation = .horizontal
        primaryButtonRow.spacing = TiboLayout.small
        primaryButtonRow.alignment = .centerY

        let translationLabel = makeSectionLabel("翻译")
        translationLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let secondaryButtonRow = NSStackView(views: [
            translationLabel,
            batchTranslationButton,
            autoTranslationCheckbox,
            NSView(),
            translationSettingsButton
        ])
        secondaryButtonRow.orientation = .horizontal
        secondaryButtonRow.spacing = TiboLayout.small
        secondaryButtonRow.alignment = .centerY

        let buttonRows = NSStackView(views: [primaryButtonRow, secondaryButtonRow])
        buttonRows.orientation = .vertical
        buttonRows.alignment = .width
        buttonRows.spacing = TiboLayout.small

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail

        let header = NSStackView(views: [titleRow, subtitleLabel, buttonRows, statusLabel])
        header.orientation = .vertical
        header.alignment = .width
        header.spacing = TiboLayout.small

        let separator = NSBox()
        separator.boxType = .separator

        configureFeedScrollView()
        webView.isHidden = true

        let stack = NSStackView(views: [header, separator, feedScrollView, webView])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = TiboLayout.medium
        stack.edgeInsets = NSEdgeInsets(
            top: TiboLayout.large,
            left: TiboLayout.large,
            bottom: TiboLayout.large,
            right: TiboLayout.large
        )

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            feedScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 440),
            feedScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
            webView.widthAnchor.constraint(greaterThanOrEqualToConstant: 440),
            webView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
    }

    private func configureFeedScrollView() {
        feedScrollView.hasVerticalScroller = true
        feedScrollView.autohidesScrollers = true
        feedScrollView.drawsBackground = false
        feedScrollView.borderType = .noBorder

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        feedScrollView.documentView = documentView

        feedStack.translatesAutoresizingMaskIntoConstraints = false
        feedStack.orientation = .vertical
        feedStack.alignment = .leading
        feedStack.spacing = TiboLayout.medium
        documentView.addSubview(feedStack)

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: feedScrollView.contentView.widthAnchor),
            feedStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            feedStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -TiboLayout.small),
            feedStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: TiboLayout.xSmall),
            feedStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -TiboLayout.medium)
        ])
    }

    private func makeSectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func renderFeed() {
        clearFeedStack()

        if cachedPosts.isEmpty {
            renderEmptyState()
            return
        }

        let heading = NSTextField(labelWithString: "最近消息 · \(cachedPosts.count) 条本机缓存")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        feedStack.addArrangedSubview(heading)

        for post in cachedPosts {
            let card = makePostCard(post)
            feedStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: feedStack.widthAnchor).isActive = true
        }
    }

    private func renderRSSFeed() {
        clearFeedStack()

        if rssPosts.isEmpty {
            let title = NSTextField(labelWithString: "RSS 暂无消息")
            title.font = .systemFont(ofSize: 17, weight: .semibold)

            let detail = NSTextField(
                wrappingLabelWithString: "RSSHub 会沿用 X 原页的本机登录状态。请先登录 X，然后刷新 RSS。"
            )
            detail.textColor = .secondaryLabelColor

            let button = NSButton(
                title: "刷新 RSS",
                target: self,
                action: #selector(refreshRSS)
            )
            button.bezelStyle = .rounded

            let emptyStack = NSStackView(views: [title, detail, button])
            emptyStack.orientation = .vertical
            emptyStack.alignment = .leading
            emptyStack.spacing = TiboLayout.medium
            emptyStack.edgeInsets = NSEdgeInsets(
                top: TiboLayout.xLarge,
                left: TiboLayout.large,
                bottom: TiboLayout.large,
                right: TiboLayout.large
            )
            feedStack.addArrangedSubview(emptyStack)
            emptyStack.widthAnchor.constraint(equalTo: feedStack.widthAnchor).isActive = true
            return
        }

        let replyText = rssRepliesAvailable ? "包含回复" : "仅主帖"
        let heading = NSTextField(labelWithString: "RSSHub · \(rssPosts.count) 条 · \(replyText)")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        feedStack.addArrangedSubview(heading)

        for post in rssPosts {
            let displayPost = cachedPosts.first(where: { $0.url == post.url }) ?? post
            let card = makePostCard(displayPost)
            feedStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: feedStack.widthAnchor).isActive = true
        }
    }

    private func clearFeedStack() {
        for view in feedStack.arrangedSubviews {
            feedStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func renderEmptyState() {
        let title = NSTextField(labelWithString: "还没有整理好的消息")
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let detail = NSTextField(
            wrappingLabelWithString: "点击下面的按钮打开已登录的 X 页面。页面加载后，少量 Tibo 公开发言会保存到资讯视图。"
        )
        detail.textColor = .secondaryLabelColor

        let button = NSButton(
            title: "打开 X 更新消息",
            target: self,
            action: #selector(showLatestPosts)
        )
        button.bezelStyle = .rounded

        let emptyStack = NSStackView(views: [title, detail, button])
        emptyStack.orientation = .vertical
        emptyStack.alignment = .leading
        emptyStack.spacing = TiboLayout.medium
        emptyStack.edgeInsets = NSEdgeInsets(
            top: TiboLayout.xLarge,
            left: TiboLayout.large,
            bottom: TiboLayout.large,
            right: TiboLayout.large
        )
        feedStack.addArrangedSubview(emptyStack)
        emptyStack.widthAnchor.constraint(equalTo: feedStack.widthAnchor).isActive = true
    }

    private func makePostCard(_ post: TiboPost) -> NSView {
        let metadata = NSTextField(labelWithString: Self.postMetadata(post))
        metadata.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        metadata.textColor = .secondaryLabelColor

        let originalText = makeBodyText(post.text, fontSize: 14)

        let originalButton = TiboPostLinkButton(
            title: "查看原帖",
            target: self,
            action: #selector(openPostInBrowser)
        )
        originalButton.postURL = post.url
        originalButton.bezelStyle = .inline

        let translateButton = TiboPostLinkButton(
            title: translatingURLs.contains(post.url.absoluteString)
                ? "正在翻译…"
                : (post.translatedText == nil ? "翻译成中文" : "重新翻译"),
            target: self,
            action: #selector(translatePost)
        )
        translateButton.postURL = post.url
        translateButton.post = post
        translateButton.bezelStyle = .inline
        translateButton.isEnabled = !translatingURLs.contains(post.url.absoluteString)

        var actionViews: [NSView] = [originalButton]
        if Self.isLikelyTruncated(post) {
            let completeButton = TiboPostLinkButton(
                title: pendingFullTextURL == post.url ? "正在补全…" : "补全全文",
                target: self,
                action: #selector(completePostText)
            )
            completeButton.postURL = post.url
            completeButton.bezelStyle = .inline
            completeButton.isEnabled = pendingFullTextURL != post.url
            actionViews.append(completeButton)
        }
        actionViews.append(contentsOf: [translateButton, NSView()])

        var cardViews: [NSView] = [metadata]
        let anchorDate = post.postedAt ?? post.capturedAt
        let timeConversions = PacificTimeMentionConverter.conversions(
            in: post.text,
            anchoredAt: anchorDate
        )
        if !timeConversions.isEmpty {
            let conversionLabel = NSTextField(
                wrappingLabelWithString: timeConversions
                    .map(Self.beijingTimeConversionText)
                    .joined(separator: "\n")
            )
            conversionLabel.font = .systemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: .semibold
            )
            conversionLabel.textColor = .systemBlue
            conversionLabel.isSelectable = true
            conversionLabel.maximumNumberOfLines = 0
            conversionLabel.lineBreakMode = .byWordWrapping
            cardViews.append(conversionLabel)
        }
        if let translatedText = post.translatedText, !translatedText.isEmpty {
            let translationHeading = NSTextField(labelWithString: "中文机翻 · MyMemory")
            translationHeading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            translationHeading.textColor = .systemBlue

            let translation = makeBodyText(translatedText, fontSize: 15)

            let originalHeading = NSTextField(labelWithString: "英文原文")
            originalHeading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            originalHeading.textColor = .secondaryLabelColor
            originalHeading.isHidden = true
            originalText.isHidden = true

            let originalToggle = TiboOriginalToggleButton(
                title: "显示原文",
                target: self,
                action: #selector(toggleOriginalText)
            )
            originalToggle.bezelStyle = .inline
            originalToggle.originalViews = [originalHeading, originalText]
            originalToggle.image = NSImage(
                systemSymbolName: "chevron.right",
                accessibilityDescription: "展开"
            )
            originalToggle.imagePosition = .imageLeading

            cardViews.append(contentsOf: [
                translationHeading,
                translation,
                originalToggle,
                originalHeading,
                originalText
            ])
        } else {
            let originalHeading = NSTextField(
                labelWithString: translatingURLs.contains(post.url.absoluteString)
                    ? "英文原文 · 正在生成中文机翻"
                    : "英文原文 · 暂无中文机翻"
            )
            originalHeading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            originalHeading.textColor = .secondaryLabelColor
            cardViews.append(contentsOf: [originalHeading, originalText])
        }

        let actionRow = NSStackView(views: actionViews)
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = TiboLayout.medium

        cardViews.append(actionRow)
        let card = NSStackView(views: cardViews)
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = TiboLayout.small
        card.edgeInsets = NSEdgeInsets(
            top: TiboLayout.medium,
            left: TiboLayout.large,
            bottom: TiboLayout.medium,
            right: TiboLayout.large
        )
        card.wantsLayer = true
        card.layer?.cornerRadius = TiboLayout.medium
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.78).cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        return card
    }

    private func makeBodyText(_ string: String, fontSize: CGFloat) -> NSTextField {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 1.38
        paragraph.paragraphSpacing = TiboLayout.small

        let text = NSTextField(wrappingLabelWithString: "")
        text.attributedStringValue = NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
        text.isSelectable = true
        text.maximumNumberOfLines = 0
        text.lineBreakMode = .byWordWrapping
        return text
    }

    @objc private func toggleOriginalText(_ sender: TiboOriginalToggleButton) {
        let shouldShow = sender.originalViews.contains { $0.isHidden }
        sender.originalViews.forEach { $0.isHidden = !shouldShow }
        sender.title = shouldShow ? "收起原文" : "显示原文"
        sender.image = NSImage(
            systemSymbolName: shouldShow ? "chevron.down" : "chevron.right",
            accessibilityDescription: shouldShow ? "收起" : "展开"
        )
    }

    private var isAutoTranslationEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.autoTranslationKey) != nil else { return true }
        return defaults.bool(forKey: Self.autoTranslationKey)
    }

    private func updateTranslationControls() {
        let pendingCount = cachedPosts.filter {
            $0.translatedText == nil && !translatingURLs.contains($0.url.absoluteString)
        }.count
        batchTranslationButton.title = pendingCount > 0
            ? "批量翻译未翻译消息（\(pendingCount)）"
            : "全部消息已翻译"
        batchTranslationButton.isEnabled = pendingCount > 0
        autoTranslationCheckbox.state = isAutoTranslationEnabled ? .on : .off
    }

    private func scheduleAutomaticTranslationIfNeeded() {
        guard isAutoTranslationEnabled,
              activeTranslationRuns == 0,
              onTranslationCompleted != nil
        else { return }

        let pending = cachedPosts.filter {
            $0.translatedText == nil &&
            !translatingURLs.contains($0.url.absoluteString) &&
            !automaticRetryBlockedURLs.contains($0.url.absoluteString)
        }
        guard !pending.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isAutoTranslationEnabled,
                  self.activeTranslationRuns == 0
            else { return }
            self.startTranslations(pending, showIndividualError: false)
        }
    }

    private func renderCurrentMode() {
        switch modeControl.selectedSegment {
        case 0:
            renderRSSFeed()
        case 1:
            renderFeed()
        default:
            break
        }
    }

    private func showRSSMode() {
        modeControl.selectedSegment = 0
        feedScrollView.isHidden = false
        webView.isHidden = true
        renderRSSFeed()
        updateRSSStatusLabel()
    }

    private func updateRSSStatusLabel() {
        statusLabel.stringValue = rssStatus
    }

    private func showFeedMode() {
        modeControl.selectedSegment = 1
        feedScrollView.isHidden = false
        webView.isHidden = true
        renderCurrentMode()
        statusLabel.stringValue = cachedPosts.isEmpty
            ? "暂无本机缓存 · 点击“从 X 更新消息”获取"
            : "已整理 \(cachedPosts.count) 条公开发言 · 点击正文可选择复制"
    }

    private func showWebMode() {
        modeControl.selectedSegment = 2
        feedScrollView.isHidden = true
        webView.isHidden = false
    }

    @objc private func modeChanged() {
        if modeControl.selectedSegment == 0 {
            showRSSMode()
        } else if modeControl.selectedSegment == 1 {
            showFeedMode()
        } else if webView.url == nil {
            loadTimeline()
        } else {
            showWebMode()
        }
    }

    @objc private func refreshRSS() {
        rssStatus = "RSSHub 正在更新…"
        updateRSSStatusLabel()
        onRSSRefreshRequested?()
    }

    private func loadTimeline() {
        load(Self.profileURL, description: "正在打开 Tibo 的 X 页面…")
    }

    private func load(_ url: URL, description: String) {
        showWebMode()
        statusLabel.stringValue = description
        setPreferredLanguageCookies { [weak self] in
            guard let self else { return }
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadRevalidatingCacheData,
                timeoutInterval: 30
            )
            request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            self.webView.load(request)
        }
    }

    private func setPreferredLanguageCookies(completion: @escaping () -> Void) {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let expiry = Date().addingTimeInterval(365 * 24 * 60 * 60)
        let domains = [".x.com", ".twitter.com"]
        let group = DispatchGroup()

        for domain in domains {
            guard let cookie = HTTPCookie(properties: [
                .domain: domain,
                .path: "/",
                .name: "lang",
                .value: "zh-cn",
                .secure: "TRUE",
                .expires: expiry
            ]) else {
                continue
            }
            group.enter()
            cookieStore.setCookie(cookie) {
                group.leave()
            }
        }

        group.notify(queue: .main, execute: completion)
    }

    @objc private func showLatestPosts() {
        load(Self.profileURL, description: "正在打开最新公开发言…")
    }

    @objc private func showReplies() {
        load(Self.repliesURL, description: "正在查询 Tibo 在不同帖子下的回复…")
    }

    @objc private func showTranslationSettings() {
        load(Self.translationSettingsURL, description: "正在打开 X 的语言与翻译设置…")
    }

    @objc private func openInBrowser() {
        NSWorkspace.shared.open(webView.url ?? Self.profileURL)
    }

    @objc private func openPostInBrowser(_ sender: TiboPostLinkButton) {
        guard let url = sender.postURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openPostInX(_ sender: TiboPostLinkButton) {
        guard let url = sender.postURL else { return }
        load(Self.withChineseLanguage(url), description: "正在打开原帖；可使用 X 的“翻译帖子”…")
    }

    @objc private func completePostText(_ sender: TiboPostLinkButton) {
        guard let url = sender.postURL, pendingFullTextURL == nil else { return }
        pendingFullTextURL = url
        statusLabel.stringValue = "正在使用已登录的 X 会话补全这一条正文…"
        renderCurrentMode()

        setPreferredLanguageCookies { [weak self] in
            guard let self else { return }
            var request = URLRequest(
                url: Self.withChineseLanguage(url),
                cachePolicy: .reloadRevalidatingCacheData,
                timeoutInterval: 30
            )
            request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            self.webView.load(request)
        }
    }

    @objc private func translatePost(_ sender: TiboPostLinkButton) {
        guard let post = sender.post else { return }
        startTranslations([post], showIndividualError: true, allowRetranslation: true)
    }

    @objc private func translateAllPosts() {
        let pending = cachedPosts.filter { $0.translatedText == nil }
        startTranslations(pending, showIndividualError: true)
    }

    @objc private func autoTranslationChanged() {
        let enabled = autoTranslationCheckbox.state == .on
        UserDefaults.standard.set(enabled, forKey: Self.autoTranslationKey)
        updateTranslationControls()
        if enabled {
            scheduleAutomaticTranslationIfNeeded()
        } else {
            statusLabel.stringValue = "已关闭自动翻译；仍可按条或批量翻译"
        }
    }

    private func startTranslations(
        _ posts: [TiboPost],
        showIndividualError: Bool,
        allowRetranslation: Bool = false
    ) {
        let candidates = posts.filter {
            (allowRetranslation || $0.translatedText == nil) &&
            !translatingURLs.contains($0.url.absoluteString)
        }
        guard !candidates.isEmpty else { return }
        guard confirmTranslationIfNeeded() else { return }

        candidates.forEach { translatingURLs.insert($0.url.absoluteString) }
        activeTranslationRuns += 1
        statusLabel.stringValue = candidates.count == 1
            ? "正在免费翻译这一条消息…"
            : "正在依次翻译 \(candidates.count) 条消息…"
        renderCurrentMode()
        updateTranslationControls()

        Task { [weak self] in
            guard let self else { return }
            var failureMessages: [String] = []

            for post in candidates {
                do {
                    let translation = try await self.translationClient.translateToChinese(post.text)
                    await MainActor.run {
                        self.translatingURLs.remove(post.url.absoluteString)
                        self.automaticRetryBlockedURLs.remove(post.url.absoluteString)
                        self.onTranslationCompleted?(post.url, translation)
                        self.renderCurrentMode()
                        self.updateTranslationControls()
                    }
                } catch {
                    await MainActor.run {
                        self.translatingURLs.remove(post.url.absoluteString)
                        self.automaticRetryBlockedURLs.insert(post.url.absoluteString)
                        failureMessages.append(error.localizedDescription)
                        self.renderCurrentMode()
                        self.updateTranslationControls()
                    }
                }
            }

            await MainActor.run {
                self.activeTranslationRuns = max(0, self.activeTranslationRuns - 1)
                if failureMessages.isEmpty {
                    self.statusLabel.stringValue = candidates.count == 1
                        ? "翻译完成 · 译文已保存到本机"
                        : "批量翻译完成 · 已保存 \(candidates.count) 条译文"
                } else {
                    let failed = failureMessages.count
                    self.statusLabel.stringValue = "翻译完成，但有 \(failed) 条失败"
                    if showIndividualError {
                        self.showTranslationErrorMessage(
                            failureMessages.first ?? "翻译服务暂时不可用。",
                            failedCount: failed
                        )
                    }
                }
                self.updateTranslationControls()
                self.scheduleAutomaticTranslationIfNeeded()
            }
        }
    }

    private func confirmTranslationIfNeeded() -> Bool {
        if UserDefaults.standard.bool(forKey: Self.translationConsentKey) { return true }

        let alert = NSAlert()
        alert.messageText = "使用免费翻译"
        alert.informativeText = "启用自动翻译，或点击按条、批量翻译时，公开帖子正文会发送给 MyMemory（Translated.net）。匿名免费额度每天约 5,000 字符，译文会缓存到本机。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "继续翻译")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(false, forKey: Self.autoTranslationKey)
            autoTranslationCheckbox.state = .off
            updateTranslationControls()
            statusLabel.stringValue = "已取消翻译，并关闭自动翻译"
            return false
        }
        UserDefaults.standard.set(true, forKey: Self.translationConsentKey)
        return true
    }

    private func showTranslationErrorMessage(_ message: String, failedCount: Int) {
        let alert = NSAlert()
        alert.messageText = failedCount > 1 ? "部分消息暂时无法翻译" : "暂时无法翻译"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusLabel.stringValue = pendingFullTextURL == nil
            ? "X 原页已打开 · 英文帖子下方可点“翻译帖子”"
            : "原帖已加载 · 正在读取完整正文…"
        scheduleCaptures()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        pendingFullTextURL = nil
        renderCurrentMode()
        statusLabel.stringValue = "加载失败；可用浏览器打开查看"
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        pendingFullTextURL = nil
        renderCurrentMode()
        statusLabel.stringValue = "加载失败；可用浏览器打开查看"
    }

    private static func postMetadata(_ post: TiboPost, now: Date = Date()) -> String {
        guard let postedAt = post.postedAt else {
            return "Tibo · @thsottiaux · 最近读取"
        }
        let absolute = postDateFormatter.string(from: postedAt)
        let relative = relativeDateFormatter.localizedString(for: postedAt, relativeTo: now)
        return "Tibo · @thsottiaux · \(absolute) · \(relative)"
    }

    private static func isLikelyTruncated(_ post: TiboPost) -> Bool {
        if let explicit = post.isPossiblyTruncated { return explicit }
        return post.text.count >= 270
    }

    private static func beijingTimeConversionText(
        _ conversion: PacificTimeMentionConversion
    ) -> String {
        let beijing = beijingTimeFormatter.string(from: conversion.beijingDate)
        let pacific = sourceTimeFormatter(
            abbreviation: conversion.sourceAbbreviation
        ).string(from: conversion.sourceDate)
        return "北京时间 · \(beijing)（原文 \(pacific) \(conversion.sourceAbbreviation)）"
    }

    private static func sourceTimeFormatter(abbreviation: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = abbreviation == "PST"
            ? TimeZone(secondsFromGMT: -8 * 3_600)
            : abbreviation == "PDT"
                ? TimeZone(secondsFromGMT: -7 * 3_600)
                : TimeZoneConversion.pacificTimeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }

    private static func withChineseLanguage(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "lang" }
        queryItems.append(URLQueryItem(name: "lang", value: "zh-cn"))
        components.queryItems = queryItems
        return components.url ?? url
    }

    private static let profileURL = URL(string: "https://x.com/thsottiaux?lang=zh-cn")!

    private static let repliesURL: URL = {
        var components = URLComponents(string: "https://x.com/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "from:thsottiaux is:reply"),
            URLQueryItem(name: "src", value: "typed_query"),
            URLQueryItem(name: "f", value: "live"),
            URLQueryItem(name: "lang", value: "zh-cn")
        ]
        return components.url!
    }()

    private static let translationSettingsURL = URL(
        string: "https://x.com/settings/language?lang=zh-cn"
    )!

    private func scheduleCaptures() {
        for delay in [1.5, 4.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.captureVisiblePosts()
            }
        }
    }

    private static let postDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let beijingTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZoneConversion.beijingTimeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let capturePostsJavaScript = #"""
    (async () => {
      const posts = [];
      const seen = new Set();
      const isTiboArticle = (article) => Array.from(article.querySelectorAll('a[href]')).some((link) => {
        const href = link.getAttribute('href');
        return href === '/thsottiaux' || href === 'https://x.com/thsottiaux';
      });
      const initialArticles = Array.from(
        document.querySelectorAll('article[data-testid="tweet"]')
      ).filter(isTiboArticle);

      let clickedInlineExpander = false;
      let clickedNavigationExpander = false;
      for (const article of initialArticles) {
        const directExpanders = Array.from(article.querySelectorAll(
          '[data-testid="tweet-text-show-more-link"], a, button, [role="button"], [role="link"]'
        )).filter((element) => {
          const label = (element.innerText || element.getAttribute('aria-label') || '').trim().toLowerCase();
          return element.getAttribute('data-testid') === 'tweet-text-show-more-link' ||
            label === 'show more' || label === '显示更多';
        });

        const textExpanders = Array.from(article.querySelectorAll('span, div')).flatMap((element) => {
          const label = (element.textContent || '').trim().toLowerCase();
          if (label !== 'show more' && label !== '显示更多') return [];
          return [
            element.closest(
              '[data-testid="tweet-text-show-more-link"], a, button, [role="button"], [role="link"]'
            ) || element
          ];
        });

        const expanders = Array.from(new Set([...directExpanders, ...textExpanders]));

        for (const expander of expanders) {
          const navigates =
            (expander.tagName === 'A' || expander.getAttribute('role') === 'link') &&
            Boolean(expander.getAttribute('href') || expander.closest('a[href]'));
          if (navigates && clickedNavigationExpander) continue;
          expander.dispatchEvent(new MouseEvent('click', {
            bubbles: true,
            cancelable: true,
            composed: true,
            view: window
          }));
          if (navigates) {
            clickedNavigationExpander = true;
          } else {
            clickedInlineExpander = true;
          }
        }
      }

      if (clickedInlineExpander || clickedNavigationExpander) {
        await new Promise((resolve) => setTimeout(resolve, 700));
      }

      const articles = document.querySelectorAll('article[data-testid="tweet"]');

      for (const article of articles) {
        if (!isTiboArticle(article)) continue;

        const textElement = article.querySelector('[data-testid="tweetText"]');
        const timeElement = article.querySelector('time');
        const statusLink = timeElement && timeElement.closest('a');
        const href = statusLink && statusLink.getAttribute('href');
        const text = textElement && textElement.innerText && textElement.innerText.trim();
        if (!text || !href || !href.includes('/status/')) continue;

        const url = new URL(href, 'https://x.com').href;
        if (seen.has(url)) continue;
        seen.add(url);
        posts.push({
          text,
          url,
          date: timeElement.getAttribute('datetime') || null,
          truncated: Boolean(
            article.querySelector('[data-testid="tweet-text-show-more-link"]') ||
            Array.from(article.querySelectorAll('a, button')).some((element) => {
              const label = (element.innerText || element.getAttribute('aria-label') || '').trim().toLowerCase();
              return label === 'show more' || label === '显示更多';
            })
          )
        });
        if (posts.length >= 10) break;
      }

      return JSON.stringify(posts);
    })();
    """#
}
