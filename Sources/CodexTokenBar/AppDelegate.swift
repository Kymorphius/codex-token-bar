import AppKit
import ServiceManagement
import CodexTokenCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private let client = CodexAppServerClient()
    private let usageHistory = UsageHistoryStore()
    private let tiboPostStore = TiboPostStore()
    private let tiboRSSHubClient = TiboRSSHubClient()
    private let codexLunaTranslationClient = CodexLunaTranslationClient()
    private let githubUpdateChecker = GitHubUpdateChecker()
    private let tiboHoverPreview = TiboHoverPreviewController()
    private var snapshot: UsageSnapshot?
    private var tokenUsageSnapshot: TokenUsageSnapshot?
    private var lastError: String?
    private var refreshTimer: Timer?
    private var tiboRefreshTimer: Timer?
    private var githubUpdateTimer: Timer?
    private var tiboFeedWindowController: TiboFeedWindowController?
    private var usageHeatmapWindowController: UsageHeatmapWindowController?
    private var isRefreshingTiboRSS = false
    private var lastTiboRSSUpdate: Date?
    private var tiboRSSStatus = "本机 RSSHub 等待首次更新"
    private var latestTiboRSSPosts: [TiboPost] = []
    private var latestTiboRSSRepliesAvailable = false
    private var tiboHoverReadTimer: Timer?
    private var hoveredTiboURL: URL?
    private weak var tiboHeaderMenuItem: NSMenuItem?
    private var codexTranslatingURLs: Set<URL> = []
    private var isCheckingForUpdates = false

    private func setTiboRSSStatus(_ status: String) {
        tiboRSSStatus = status
        UserDefaults.standard.set(status, forKey: "tibo-rss-status-v1")
        tiboFeedWindowController?.updateRSSStatus(status)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Native menu-item tooltips impose an uncontrollable first-show delay, so
        // Tibo previews use an app-owned panel instead.
        UserDefaults.standard.removeObject(forKey: "NSInitialToolTipDelay")

        NSApp.setActivationPolicy(.accessory)
        configureEditCommands()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "dev.333.codex-token-bar.main-status-item"
        statusItem.isVisible = true
        statusMenu.autoenablesItems = false
        statusMenu.delegate = self

        if let button = statusItem.button {
            button.title = "--%"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.toolTip = Self.statusToolTip("正在读取 Codex 剩余额度…")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        client.onSnapshot = { [weak self] snapshot in
            self?.usageHistory.record(snapshot: snapshot)
            self?.snapshot = snapshot
            self?.lastError = nil
            self?.updateStatusItem()
            self?.rebuildMenu()
        }
        client.onTokenUsage = { [weak self] snapshot in
            self?.tokenUsageSnapshot = snapshot
            self?.lastError = nil
            self?.rebuildMenu()
        }
        client.onError = { [weak self] message in
            self?.lastError = message
            self?.updateStatusItem()
            self?.rebuildMenu()
        }

        usageHistory.onChange = { [weak self] in
            guard let self else { return }
            self.usageHeatmapWindowController?.update(entries: self.usageHistory.heatmapEntries)
            self.rebuildMenu()
        }
        usageHistory.start()

        client.start()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.client.refresh()
        }
        tiboRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.refreshTiboFromRSSHub()
        }
        configureAutomaticUpdateChecks(checkSoon: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.refreshTiboFromRSSHub()
        }
        rebuildMenu()
        scheduleCodexTranslationsIfNeeded()
    }

    private func configureEditCommands() {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Codex Token Bar")
        let quitItem = NSMenuItem(
            title: "退出 Codex Token Bar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationMenu.addItem(quitItem)
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(
            title: "撤销",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        ))
        let redoItem = NSMenuItem(
            title: "重做",
            action: Selector(("redo:")),
            keyEquivalent: "Z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: "剪切",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: "复制",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: "粘贴",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: "全选",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        tiboRefreshTimer?.invalidate()
        githubUpdateTimer?.invalidate()
        tiboRSSHubClient.stop()
        client.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        tiboFeedWindowController?.captureVisiblePosts()
        if lastTiboRSSUpdate.map({ Date().timeIntervalSince($0) > 10 * 60 }) ?? true {
            refreshTiboFromRSSHub()
        }
        rebuildMenu()
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        cancelTiboHoverRead()
        guard menu === statusMenu else { return }
        guard
            let url = item?.representedObject as? URL,
            let post = tiboPostStore.posts.first(where: { $0.url == url })
        else {
            tiboHoverPreview.hide()
            return
        }

        tiboHoverPreview.show(post: post, near: NSEvent.mouseLocation)
        guard
            tiboPostStore.isUnread(url)
        else { return }

        hoveredTiboURL = url
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            guard let self, self.hoveredTiboURL == url else { return }
            self.hoveredTiboURL = nil
            self.tiboHoverReadTimer = nil
            guard self.tiboPostStore.markRead(url) else { return }
            self.updateStatusItem()
            self.updateTiboHeaderMenuItem()
        }
        tiboHoverReadTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === statusMenu {
            cancelTiboHoverRead()
            tiboHoverPreview.hide()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        if let remaining = snapshot?.headlineBucket?.headlineWindow?.remainingPercent {
            let percent = Int(remaining.rounded())
            button.title = statusTitle(base: "\(percent)%")
            button.toolTip = Self.statusToolTip(statusToolTip(base: "Codex 剩余额度 \(percent)%"))
        } else {
            button.title = statusTitle(base: "--%")
            button.toolTip = Self.statusToolTip(
                statusToolTip(base: lastError ?? "正在读取 Codex 剩余额度…")
            )
        }
    }

    private func statusTitle(base: String) -> String {
        let unread = tiboPostStore.unreadCount
        return unread > 0 ? "\(base)  X\(unread)" : base
    }

    private func statusToolTip(base: String) -> String {
        let unread = tiboPostStore.unreadCount
        return unread > 0 ? "\(base) · X 有 \(unread) 条未读消息" : base
    }

    private func rebuildMenu() {
        let menu = statusMenu
        menu.removeAllItems()

        addDisabledItem("Codex 剩余额度", to: menu, bold: true)

        if let snapshot {
            let primaryBuckets = snapshot.buckets.filter { !Self.isSparkBucket($0) }
            for (index, bucket) in primaryBuckets.enumerated() {
                if index > 0 { menu.addItem(.separator()) }
                addBucket(bucket, to: menu)
            }

            addResetCredits(from: snapshot, to: menu)

            addUsageHistory(to: menu)

            menu.addItem(.separator())
            addDisabledItem("更新于 \(Self.updateTimeFormatter.string(from: snapshot.updatedAt))", to: menu)
        } else {
            addDisabledItem(lastError ?? "正在连接 Codex…", to: menu)
        }

        if let lastError, snapshot != nil {
            addDisabledItem("提示：\(lastError)", to: menu)
        }

        addTimeTools(to: menu)

        addTiboTools(to: menu)

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openCodexItem = NSMenuItem(title: "打开 Codex", action: #selector(openCodex), keyEquivalent: "")
        openCodexItem.target = self
        menu.addItem(openCodexItem)

        let launchItem = NSMenuItem(title: launchAtLoginTitle, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = launchAtLoginState
        menu.addItem(launchItem)

        let updateItem = NSMenuItem(
            title: isCheckingForUpdates ? "正在检查 GitHub 更新…" : "检查 GitHub 更新…",
            action: #selector(checkForGitHubUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        updateItem.isEnabled = !isCheckingForUpdates
        menu.addItem(updateItem)

        let automaticUpdateItem = NSMenuItem(
            title: "自动检查 GitHub 更新",
            action: #selector(toggleAutomaticUpdateChecks),
            keyEquivalent: ""
        )
        automaticUpdateItem.target = self
        automaticUpdateItem.state = automaticUpdateChecksEnabled ? .on : .off
        menu.addItem(automaticUpdateItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "关于 Codex Token Bar", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        if let sparkBucket = snapshot?.buckets.first(where: Self.isSparkBucket) {
            menu.addItem(.separator())
            addCollapsedSparkBucket(sparkBucket, to: menu)
        }
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp ||
            (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)

        if isRightClick {
            showTiboFeed()
        } else {
            rebuildMenu()
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        }
    }

    private func addTimeTools(to menu: NSMenu) {
        menu.addItem(.separator())

        let timeMenu = NSMenu(title: "时间")
        addNonInteractiveBrightItem(Self.pacificTimeDescription(), to: timeMenu)

        let converterItem = NSMenuItem(
            title: "太平洋时间 ↔ 本地时间换算…",
            action: #selector(showTimeConverter),
            keyEquivalent: ""
        )
        converterItem.target = self
        timeMenu.addItem(converterItem)

        let timeZoneItem = NSMenuItem(
            title: "显示时区：\(displayTimeZoneModeDescription)…",
            action: #selector(showTimeZoneSettings),
            keyEquivalent: ""
        )
        timeZoneItem.target = self
        timeMenu.addItem(timeZoneItem)

        let timeItem = NSMenuItem(
            title: Self.compactPacificTimeDescription(),
            action: nil,
            keyEquivalent: ""
        )
        timeItem.submenu = timeMenu
        menu.addItem(timeItem)
    }

    private func addTiboTools(to menu: NSMenu) {
        menu.addItem(.separator())
        let unread = tiboPostStore.unreadCount
        tiboHeaderMenuItem = addDisabledItem(
            unread > 0 ? "Tibo 动态 · \(unread) 条未读" : "Tibo 动态",
            to: menu,
            bold: true
        )

        for post in tiboPostStore.posts.prefix(4) {
            let item = NSMenuItem(
                title: Self.tiboPostMenuTitle(post),
                action: #selector(openTiboPost),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = post.url
            item.indentationLevel = 1
            menu.addItem(item)

            let anchorDate = post.postedAt ?? post.capturedAt
            for conversion in PacificTimeMentionConverter.conversions(
                in: post.text,
                anchoredAt: anchorDate
            ).prefix(2) {
                addTiboTimeConversion(conversion, to: menu)
            }
        }

        if tiboPostStore.posts.isEmpty {
            addDisabledItem("登录 X 后，将通过本机 RSSHub 显示最近发言", to: menu, indented: true)
        } else if let capturedAt = tiboPostStore.posts.map(\.capturedAt).max() {
            addDisabledItem(
                "已缓存公开帖子 · \(Self.updateTimeFormatter.string(from: capturedAt))",
                to: menu,
                indented: true
            )
        }

        addDisabledItem(tiboRSSStatus, to: menu, indented: true)

        let feedItem = NSMenuItem(
            title: "查看 Codex 负责人最新公开发言…",
            action: #selector(showTiboFeed),
            keyEquivalent: ""
        )
        feedItem.target = self
        feedItem.indentationLevel = 1
        menu.addItem(feedItem)

        let repliesItem = NSMenuItem(
            title: "查看他在不同帖子下的回复…",
            action: #selector(openTiboReplies),
            keyEquivalent: ""
        )
        repliesItem.target = self
        repliesItem.indentationLevel = 1
        menu.addItem(repliesItem)

        addDisabledItem("本机 RSSHub · Cookie 不上传 · 尝试包含回复", to: menu, indented: true)
    }

    private func addBucket(_ bucket: UsageBucket, to menu: NSMenu) {
        let name = bucket.name ?? (bucket.id == "codex" ? "Codex" : bucket.id)
        let emphasizeWindowDetails = bucket.id == "codex"

        if let primary = bucket.primary {
            addDisabledItem("\(name)：\(Self.formatPercent(primary.remainingPercent)) 剩余", to: menu, bold: true)
            addWindowDetail(
                Self.windowDescription(primary),
                to: menu,
                emphasized: emphasizeWindowDetails
            )
            if let allowance = Self.dailyAllowanceDescription(primary) {
                addWindowDetail(allowance, to: menu, emphasized: emphasizeWindowDetails)
            }
        } else {
            addDisabledItem(name, to: menu, bold: true)
        }

        if let secondary = bucket.secondary {
            addDisabledItem("次级窗口：\(Self.formatPercent(secondary.remainingPercent)) 剩余", to: menu)
            addWindowDetail(
                Self.windowDescription(secondary),
                to: menu,
                emphasized: emphasizeWindowDetails
            )
            if let allowance = Self.dailyAllowanceDescription(secondary) {
                addWindowDetail(allowance, to: menu, emphasized: emphasizeWindowDetails)
            }
        }

        if let plan = bucket.planType, bucket.id == "codex" {
            addDisabledItem("套餐：\(plan.capitalized)", to: menu, indented: true)
        }

        if let reachedType = bucket.rateLimitReachedType {
            addDisabledItem("额度已受限：\(reachedType)", to: menu, indented: true)
        }
    }

    private func addCollapsedSparkBucket(_ bucket: UsageBucket, to menu: NSMenu) {
        let name = bucket.name ?? "GPT-5.3-Codex-Spark"
        let remaining = bucket.headlineWindow.map {
            " · \(Self.formatPercent($0.remainingPercent)) 剩余"
        } ?? ""

        let detailMenu = NSMenu(title: name)
        addBucket(bucket, to: detailMenu)

        let item = NSMenuItem(
            title: "\(name)\(remaining)",
            action: nil,
            keyEquivalent: ""
        )
        item.submenu = detailMenu
        menu.addItem(item)
    }

    private func addWindowDetail(
        _ title: String,
        to menu: NSMenu,
        emphasized: Bool
    ) {
        if emphasized {
            addNonInteractiveBrightItem(title, to: menu, indented: true)
        } else {
            addDisabledItem(title, to: menu, indented: true)
        }
    }

    private func addUsageHistory(to menu: NSMenu) {
        menu.addItem(.separator())
        addDisabledItem("近 7 天用量", to: menu, bold: true)

        if usageHistory.isLoading {
            addDisabledItem("正在整理 Codex 历史快照…", to: menu, indented: true)
        }

        let today = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        let yesterday = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: today)

        for entry in usageHistory.entries.reversed() {
            let label: String
            if Calendar.autoupdatingCurrent.isDate(entry.date, inSameDayAs: today) {
                label = "今天（\(Self.historyDateFormatter.string(from: entry.date))）"
            } else if let yesterday,
                      Calendar.autoupdatingCurrent.isDate(entry.date, inSameDayAs: yesterday) {
                label = "昨天（\(Self.historyDateFormatter.string(from: entry.date))）"
            } else {
                label = Self.historyDateFormatter.string(from: entry.date)
            }

            let percentage = entry.usedPercent.map(Self.formatPercent) ?? "— 数据不足"
            let tokenCount = tokenCountDescription(for: entry.date)
            addDisabledItem("\(label)：\(percentage) · \(tokenCount)", to: menu, indented: true)
        }

        let heatmapItem = NSMenuItem(
            title: "查看全年使用热力图…",
            action: #selector(showUsageHeatmap),
            keyEquivalent: ""
        )
        heatmapItem.target = self
        heatmapItem.indentationLevel = 1
        menu.addItem(heatmapItem)

        addDisabledItem("历史永久保存在本机；百分比为快照增量", to: menu, indented: true)
    }

    private func addResetCredits(from snapshot: UsageSnapshot, to menu: NSMenu) {
        let availableDetails = snapshot.resetCredits.filter { credit in
            guard let status = credit.status?.lowercased() else { return true }
            return status == "available"
        }
        let availableCount = snapshot.availableResetCredits ?? availableDetails.count
        guard availableCount > 0 else { return }

        menu.addItem(.separator())
        addNonInteractiveBrightItem("可用额度重置：\(availableCount) 次", to: menu)

        for index in 0..<availableCount {
            let credit = index < availableDetails.count ? availableDetails[index] : nil
            addNonInteractiveBrightItem(
                Self.resetCreditValidityDescription(credit, number: index + 1),
                to: menu,
                indented: true
            )
        }
    }

    private func tokenCountDescription(for date: Date) -> String {
        let startDate = Self.tokenDateFormatter.string(from: date)
        guard let tokenUsageSnapshot else {
            return "tokens 正在读取…"
        }

        if let tokens = tokenUsageSnapshot.tokens(on: startDate) {
            return "\(Self.formatTokenCount(tokens)) tokens"
        }

        guard let latestStartDate = tokenUsageSnapshot.latestStartDate else {
            return "tokens 暂无数据"
        }

        return startDate > latestStartDate ? "tokens 待官方更新" : "0 tokens"
    }

    @discardableResult
    private func addDisabledItem(
        _ title: String,
        to menu: NSMenu,
        bold: Bool = false,
        indented: Bool = false
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = indented ? 1 : 0

        if bold {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                    .foregroundColor: NSColor.labelColor
                ]
            )
        }
        menu.addItem(item)
        return item
    }

    private func cancelTiboHoverRead() {
        tiboHoverReadTimer?.invalidate()
        tiboHoverReadTimer = nil
        hoveredTiboURL = nil
    }

    private func updateTiboHeaderMenuItem() {
        let unread = tiboPostStore.unreadCount
        let title = unread > 0 ? "Tibo 动态 · \(unread) 条未读" : "Tibo 动态"
        tiboHeaderMenuItem?.title = title
        tiboHeaderMenuItem?.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: NSFont.systemFontSize,
                    weight: .semibold
                ),
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    private func addNonInteractiveBrightItem(
        _ title: String,
        to menu: NSMenu,
        indented: Bool = false
    ) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = indented ? 1 : 0
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor
            ]
        )
        menu.addItem(item)
    }

    private func addTiboTimeConversion(
        _ conversion: PacificTimeMentionConversion,
        to menu: NSMenu
    ) {
        let local = Self.localMenuTimeFormatter().string(from: conversion.beijingDate)
        let title = "↳ \(DisplayTimeZoneSettings.name) \(local) ← \(conversion.sourceText)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = 2
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: NSFont.smallSystemFontSize,
                    weight: .medium
                ),
                .foregroundColor: NSColor.systemBlue
            ]
        )
        menu.addItem(item)
    }

    @objc private func refreshNow() {
        lastError = nil
        client.refresh(includeTokenUsage: true)
        refreshTiboFromRSSHub()
        rebuildMenu()
    }

    @objc private func showUsageHeatmap() {
        if usageHeatmapWindowController == nil {
            usageHeatmapWindowController = UsageHeatmapWindowController()
        }
        usageHeatmapWindowController?.update(entries: usageHistory.heatmapEntries)
        usageHeatmapWindowController?.show()
    }

    private func refreshTiboFromRSSHub() {
        guard !isRefreshingTiboRSS else { return }
        isRefreshingTiboRSS = true
        setTiboRSSStatus("本机 RSSHub 正在读取完整内容…")
        rebuildMenu()

        tiboRSSHubClient.fetch { [weak self] result in
            guard let self else { return }
            self.isRefreshingTiboRSS = false
            switch result {
            case .success(let feed):
                guard !feed.posts.isEmpty else {
                    self.setTiboRSSStatus("RSSHub 暂未返回公开消息")
                    self.rebuildMenu()
                    return
                }
                self.lastTiboRSSUpdate = Date()
                self.latestTiboRSSPosts = feed.posts
                self.latestTiboRSSRepliesAvailable = feed.repliesAvailable
                let suffix = feed.repliesAvailable ? " · 包含回复" : " · 回复源暂不可用"
                self.setTiboRSSStatus("RSSHub 已更新 \(feed.posts.count) 条" + suffix)
                _ = self.tiboPostStore.merge(feed.posts)
                self.scheduleCodexTranslationsIfNeeded()
                if self.tiboFeedWindowController?.window?.isVisible == true {
                    _ = self.tiboPostStore.markAllRead()
                }
                self.tiboFeedWindowController?.updatePosts(self.tiboPostStore.posts)
                self.updateStatusItem()
                self.tiboFeedWindowController?.updateRSSFeed(
                    posts: feed.posts,
                    repliesAvailable: feed.repliesAvailable,
                    status: self.tiboRSSStatus
                )
            case .failure(let error):
                self.setTiboRSSStatus(error.localizedDescription)
            }
            self.rebuildMenu()
        }
    }

    @objc private func openCodex() {
        let candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/Codex.app")
        ]

        guard let appURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            showAlert(title: "未找到 Codex", message: "请先安装 Codex 桌面应用。")
            return
        }

        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error {
                DispatchQueue.main.async { [weak self] in
                    self?.showAlert(title: "无法打开 Codex", message: error.localizedDescription)
                }
            }
        }
    }

    private func scheduleCodexTranslationsIfNeeded() {
        let pending = tiboPostStore.posts.prefix(4).filter {
            $0.codexTranslatedText == nil && !codexTranslatingURLs.contains($0.url)
        }
        guard !pending.isEmpty else { return }

        codexTranslatingURLs.formUnion(pending.map(\.url))
        let inputs = pending.map {
            CodexLunaTranslationClient.Input(url: $0.url, text: $0.text)
        }
        codexLunaTranslationClient.translate(inputs) { [weak self] result in
            guard let self else { return }
            self.codexTranslatingURLs.subtract(pending.map(\.url))
            if case .success(let translations) = result {
                for (url, translation) in translations {
                    _ = self.tiboPostStore.setCodexTranslation(translation, for: url)
                }
            }
            self.rebuildMenu()
        }
    }

    @objc private func showTimeConverter() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "本地时间 ↔ 太平洋时间"
        alert.informativeText = "选择输入时区和时间，换算结果会立即更新。"
        alert.alertStyle = .informational
        alert.accessoryView = TimeConverterView()
        alert.addButton(withTitle: "完成")
        alert.runModal()
    }

    @objc private func showTimeZoneSettings() {
        NSApp.activate(ignoringOtherApps: true)

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 430, height: 28))
        let systemZone = TimeZone.autoupdatingCurrent
        let systemItem = NSMenuItem(
            title: "跟随系统（\(DisplayTimeZoneSettings.displayName(for: systemZone))）",
            action: nil,
            keyEquivalent: ""
        )
        popup.menu?.addItem(systemItem)
        popup.menu?.addItem(.separator())

        for identifier in TimeZone.knownTimeZoneIdentifiers.sorted() {
            guard let zone = TimeZone(identifier: identifier) else { continue }
            let item = NSMenuItem(
                title: "\(identifier) · \(DisplayTimeZoneSettings.displayName(for: zone))",
                action: nil,
                keyEquivalent: ""
            )
            item.representedObject = identifier
            popup.menu?.addItem(item)
            if identifier == DisplayTimeZoneSettings.manualIdentifier {
                popup.select(item)
            }
        }
        if DisplayTimeZoneSettings.manualIdentifier == nil {
            popup.select(systemItem)
        }

        let alert = NSAlert()
        alert.messageText = "显示时区"
        alert.informativeText = "默认跟随 macOS 系统时区；也可以选择一个固定时区。"
        alert.alertStyle = .informational
        alert.accessoryView = popup
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DisplayTimeZoneSettings.manualIdentifier = popup.selectedItem?.representedObject as? String
        tiboFeedWindowController?.refreshDisplayedTimes()
        rebuildMenu()
    }

    private var displayTimeZoneModeDescription: String {
        DisplayTimeZoneSettings.manualIdentifier == nil
            ? "跟随系统"
            : DisplayTimeZoneSettings.name
    }

    @objc private func showTiboFeed() {
        _ = tiboPostStore.markAllRead()
        updateStatusItem()
        refreshTiboFromRSSHub()
        if tiboFeedWindowController == nil {
            let controller = TiboFeedWindowController()
            controller.updatePosts(tiboPostStore.posts)
            controller.onPostsCaptured = { [weak self] posts in
                guard let self, self.tiboPostStore.merge(posts) else { return }
                _ = self.tiboPostStore.markAllRead()
                self.tiboFeedWindowController?.updatePosts(self.tiboPostStore.posts)
                self.updateStatusItem()
                self.rebuildMenu()
            }
            controller.onTranslationCompleted = { [weak self] url, translation in
                guard let self,
                      self.tiboPostStore.setTranslation(translation, for: url)
                else { return }
                self.tiboFeedWindowController?.updatePosts(self.tiboPostStore.posts)
                self.rebuildMenu()
            }
            controller.onRSSRefreshRequested = { [weak self] in
                self?.refreshTiboFromRSSHub()
            }
            controller.updateRSSFeed(
                posts: latestTiboRSSPosts,
                repliesAvailable: latestTiboRSSRepliesAvailable,
                status: tiboRSSStatus
            )
            tiboFeedWindowController = controller
        }
        tiboFeedWindowController?.updatePosts(tiboPostStore.posts)
        tiboFeedWindowController?.show()
    }

    @objc private func openTiboPost(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        _ = tiboPostStore.markRead(url)
        updateStatusItem()
        rebuildMenu()
        NSWorkspace.shared.open(url)
    }

    @objc private func openTiboReplies() {
        var components = URLComponents(string: "https://x.com/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "from:thsottiaux is:reply"),
            URLQueryItem(name: "src", value: "typed_query"),
            URLQueryItem(name: "f", value: "live")
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notRegistered, .notFound:
                try SMAppService.mainApp.register()
            @unknown default:
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert(title: "无法更改登录项", message: error.localizedDescription)
        }
        rebuildMenu()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Codex Token Bar",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
            .credits: NSAttributedString(string: "在菜单栏显示 Codex 账号的实际剩余额度。")
        ])
    }

    @objc private func checkForGitHubUpdates() {
        performGitHubUpdateCheck(userInitiated: true)
    }

    @objc private func toggleAutomaticUpdateChecks() {
        let enabled = !automaticUpdateChecksEnabled
        UserDefaults.standard.set(enabled, forKey: "github-auto-update-checks-v1")
        configureAutomaticUpdateChecks(checkSoon: enabled)
        rebuildMenu()
    }

    private func configureAutomaticUpdateChecks(checkSoon: Bool) {
        githubUpdateTimer?.invalidate()
        githubUpdateTimer = nil
        guard automaticUpdateChecksEnabled else { return }

        githubUpdateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) {
            [weak self] _ in
            self?.performGitHubUpdateCheck(userInitiated: false)
        }

        if checkSoon {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard self?.automaticUpdateChecksEnabled == true else { return }
                self?.performGitHubUpdateCheck(userInitiated: false)
            }
        }
    }

    private func performGitHubUpdateCheck(userInitiated: Bool) {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        rebuildMenu()

        let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "1.0.0"

        githubUpdateChecker.check(currentVersion: currentVersion) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCheckingForUpdates = false
                self.rebuildMenu()

                switch result {
                case .success(.updateAvailable(let release)):
                    if !userInitiated,
                       UserDefaults.standard.string(forKey: "github-last-prompted-version-v1") == release.version {
                        return
                    }
                    UserDefaults.standard.set(
                        release.version,
                        forKey: "github-last-prompted-version-v1"
                    )
                    self.showAvailableUpdate(release, currentVersion: currentVersion)
                case .success(.upToDate(let latestVersion)):
                    if userInitiated {
                        self.showAlert(
                            title: "已经是最新版本",
                            message: "当前版本为 \(currentVersion)，GitHub 最新版本为 \(latestVersion)。"
                        )
                    }
                case .success(.noPublishedRelease):
                    if userInitiated {
                        self.showAlert(
                            title: "暂无 GitHub Release",
                            message: "仓库还没有发布可下载的版本，请稍后再试。"
                        )
                    }
                case .failure(let error):
                    if userInitiated {
                        self.showAlert(title: "检查更新失败", message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func showAvailableUpdate(_ release: GitHubRelease, currentVersion: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(release.version)"
        alert.informativeText = "当前版本为 \(currentVersion)。更新来自项目的 GitHub Releases。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: release.downloadURL == nil ? "打开 GitHub Release" : "下载更新")
        alert.addButton(withTitle: "查看发布说明")
        alert.addButton(withTitle: "稍后")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        default:
            break
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private var launchAtLoginTitle: String {
        SMAppService.mainApp.status == .requiresApproval
            ? "登录时自动启动（等待系统允许）"
            : "登录时自动启动"
    }

    private var automaticUpdateChecksEnabled: Bool {
        UserDefaults.standard.bool(forKey: "github-auto-update-checks-v1")
    }

    private var launchAtLoginState: NSControl.StateValue {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .mixed
        default: return .off
        }
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private static func formatPercent(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return "\(Int(value.rounded()))%"
        }
        return String(format: "%.1f%%", value)
    }

    private static func isSparkBucket(_ bucket: UsageBucket) -> Bool {
        let identity = "\(bucket.id) \(bucket.name ?? "")".lowercased()
        return identity.contains("spark")
    }

    private static func statusToolTip(_ detail: String) -> String {
        "\(detail)\n左键查看额度 · 右键打开 Tibo 动态"
    }

    private static func formatTokenCount(_ value: Int64) -> String {
        tokenCountFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func tiboPostMenuTitle(_ post: TiboPost, now: Date = Date()) -> String {
        let age: String
        if let postedAt = post.postedAt {
            let seconds = max(0, now.timeIntervalSince(postedAt))
            if seconds < 3_600 {
                age = "\(max(1, Int(seconds / 60))) 分钟前"
            } else if seconds < 86_400 {
                age = "\(Int(seconds / 3_600)) 小时前"
            } else {
                age = "\(Int(seconds / 86_400)) 天前"
            }
        } else {
            age = "最近"
        }

        let collapsed = post.text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        let limit = 48
        let summary = collapsed.count > limit
            ? String(collapsed.prefix(limit)) + "…"
            : collapsed
        return "\(age) · \(summary)"
    }

    private static func pacificTimeDescription(now: Date = Date()) -> String {
        let abbreviation = TimeZoneConversion.pacificAbbreviation(at: now)
        return "太平洋时间（\(abbreviation)）：\(pacificTimeFormatter.string(from: now))"
    }

    private static func compactPacificTimeDescription(now: Date = Date()) -> String {
        let abbreviation = TimeZoneConversion.pacificAbbreviation(at: now)
        return "时间 · \(abbreviation) \(compactPacificTimeFormatter.string(from: now))"
    }

    private static func resetCreditValidityDescription(
        _ credit: RateLimitResetCredit?,
        number: Int,
        now: Date = Date()
    ) -> String {
        guard let expiresAt = credit?.expiresAt else {
            return "第 \(number) 次：有效期暂未提供"
        }

        let expiry = resetCreditExpiryFormatter.string(from: expiresAt)
        guard expiresAt > now else {
            return "第 \(number) 次：有效期至 \(expiry)（已到期，等待刷新）"
        }

        let countdown = ResetCountdownFormatter.string(until: expiresAt, now: now)
        return "第 \(number) 次：有效期至 \(expiry)（\(countdown)）"
    }

    private static func windowDescription(_ window: UsageWindow) -> String {
        var components: [String] = []

        if let minutes = window.windowDurationMinutes {
            if minutes % 10_080 == 0 {
                components.append("\(minutes / 10_080) 周窗口")
            } else if minutes % 1_440 == 0 {
                components.append("\(minutes / 1_440) 天窗口")
            } else if minutes % 60 == 0 {
                components.append("\(minutes / 60) 小时窗口")
            } else {
                components.append("\(minutes) 分钟窗口")
            }
        }

        if let reset = window.resetsAt {
            let countdown = ResetCountdownFormatter.string(until: reset)
            components.append("距重置\(countdown)")
            components.append("\(resetTimeFormatter.string(from: reset)) 重置")
        }

        return components.isEmpty ? "额度窗口" : components.joined(separator: " · ")
    }

    private static func dailyAllowanceDescription(
        _ window: UsageWindow,
        now: Date = Date()
    ) -> String? {
        guard
            let windowMinutes = window.windowDurationMinutes,
            windowMinutes >= 1_440,
            let resetDate = window.resetsAt
        else {
            return nil
        }

        let remainingSeconds = resetDate.timeIntervalSince(now)
        guard remainingSeconds > 0 else { return nil }

        if remainingSeconds < 86_400 {
            return "距重置不足 1 天：尚可使用 \(formatPercent(window.remainingPercent))"
        }

        guard let dailyPercent = DailyAllowanceCalculator.percentPerDay(
            remainingPercent: window.remainingPercent,
            until: resetDate,
            now: now
        ) else {
            return nil
        }

        return "按剩余时间均分：每天约可用 \(formatPercent(dailyPercent))"
    }

    private static let updateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let resetTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let pacificTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZoneConversion.pacificTimeZone
        formatter.dateFormat = "M月d日 E HH:mm"
        return formatter
    }()

    private static let compactPacificTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZoneConversion.pacificTimeZone
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func localMenuTimeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = DisplayTimeZoneSettings.timeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }

    private static let resetCreditExpiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 E"
        return formatter
    }()

    private static let tokenDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let tokenCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.secondaryGroupingSize = 3
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}
