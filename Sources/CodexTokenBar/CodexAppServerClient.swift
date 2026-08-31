import Foundation
import CodexTokenCore

final class CodexAppServerClient {
    var onSnapshot: ((UsageSnapshot) -> Void)?
    var onTokenUsage: ((TokenUsageSnapshot) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "dev.333.codex-token-bar.app-server")
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var nextID = 1
    private var initializeRequestID: Int?
    private var rateLimitRequestID: Int?
    private var tokenUsageRequestID: Int?
    private var lastTokenUsageUpdate: Date?
    private var initialized = false
    private var stopping = false
    private var restartScheduled = false

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func refresh(includeTokenUsage: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.process?.isRunning == true, self.initialized {
                self.requestRateLimitsOnQueue()
                if includeTokenUsage || self.shouldRefreshTokenUsageOnQueue {
                    self.requestTokenUsageOnQueue()
                }
            } else {
                self.startOnQueue()
            }
        }
    }

    func stop() {
        queue.sync {
            stopping = true
            tearDownOnQueue(terminate: true)
        }
    }

    private func startOnQueue() {
        guard process?.isRunning != true else { return }
        stopping = false
        restartScheduled = false
        tearDownOnQueue(terminate: false)

        guard let executableURL = Self.findCodexExecutable() else {
            emitError("未找到 Codex。请先安装 Codex，或设置 CODEX_TOKEN_BAR_CODEX_PATH。")
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.consumeOutputOnQueue(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.processDidTerminateOnQueue()
            }
        }

        do {
            try process.run()
            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            outputBuffer.removeAll(keepingCapacity: true)
            initialized = false

            let requestID = makeRequestID()
            initializeRequestID = requestID
            sendOnQueue([
                "method": "initialize",
                "id": requestID,
                "params": [
                    "clientInfo": [
                        "name": "codex_token_bar",
                        "title": "Codex Token Bar",
                        "version": Self.appVersion
                    ]
                ]
            ])
        } catch {
            tearDownOnQueue(terminate: false)
            emitError("无法启动 Codex：\(error.localizedDescription)")
            scheduleRestartOnQueue()
        }
    }

    private func requestRateLimitsOnQueue() {
        guard initialized, rateLimitRequestID == nil else { return }

        let requestID = makeRequestID()
        rateLimitRequestID = requestID
        sendOnQueue([
            "method": "account/rateLimits/read",
            "id": requestID
        ])

        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.rateLimitRequestID == requestID else { return }
            self.rateLimitRequestID = nil
            self.emitError("读取 Codex 额度超时，稍后会自动重试。")
        }
    }

    private var shouldRefreshTokenUsageOnQueue: Bool {
        guard let lastTokenUsageUpdate else { return true }
        return Date().timeIntervalSince(lastTokenUsageUpdate) >= 3_600
    }

    private func requestTokenUsageOnQueue() {
        guard initialized, tokenUsageRequestID == nil else { return }

        let requestID = makeRequestID()
        tokenUsageRequestID = requestID
        sendOnQueue([
            "method": "account/usage/read",
            "id": requestID
        ])

        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.tokenUsageRequestID == requestID else { return }
            self.tokenUsageRequestID = nil
            self.emitError("读取 Codex token 用量超时，稍后会自动重试。")
        }
    }

    private func consumeOutputOnQueue(_ data: Data) {
        outputBuffer.append(data)

        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            handleLineOnQueue(Data(line))
        }
    }

    private func handleLineOnQueue(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let id = Self.integer(message["id"]), id == initializeRequestID {
            initializeRequestID = nil
            if let errorMessage = Self.serverErrorMessage(message) {
                emitError("Codex 初始化失败：\(errorMessage)")
                scheduleRestartOnQueue()
                return
            }

            initialized = true
            sendOnQueue(["method": "initialized", "params": [:]])
            requestRateLimitsOnQueue()
            requestTokenUsageOnQueue()
            return
        }

        if let id = Self.integer(message["id"]), id == rateLimitRequestID {
            rateLimitRequestID = nil
            if let errorMessage = Self.serverErrorMessage(message) {
                emitError("无法读取 Codex 额度：\(errorMessage)")
                return
            }

            do {
                let snapshot = try RateLimitParser.parseResponse(data: data)
                emitSnapshot(snapshot)
            } catch {
                emitError(error.localizedDescription)
            }
            return
        }

        if let id = Self.integer(message["id"]), id == tokenUsageRequestID {
            tokenUsageRequestID = nil
            if let errorMessage = Self.serverErrorMessage(message) {
                emitError("无法读取 Codex token 用量：\(errorMessage)")
                return
            }

            do {
                let snapshot = try TokenUsageParser.parseResponse(data: data)
                lastTokenUsageUpdate = snapshot.updatedAt
                emitTokenUsage(snapshot)
            } catch {
                emitError(error.localizedDescription)
            }
            return
        }

        if message["method"] as? String == "account/rateLimits/updated" {
            requestRateLimitsOnQueue()
        }
    }

    private func processDidTerminateOnQueue() {
        let shouldRestart = !stopping
        tearDownOnQueue(terminate: false)
        guard shouldRestart else { return }
        emitError("Codex 连接已断开，正在重新连接…")
        scheduleRestartOnQueue()
    }

    private func scheduleRestartOnQueue() {
        guard !stopping, !restartScheduled else { return }
        restartScheduled = true
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.restartScheduled = false
            self.startOnQueue()
        }
    }

    private func tearDownOnQueue(terminate: Bool) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil

        if terminate, process?.isRunning == true {
            process?.terminationHandler = nil
            process?.terminate()
        }

        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        initializeRequestID = nil
        rateLimitRequestID = nil
        tokenUsageRequestID = nil
        initialized = false
        outputBuffer.removeAll(keepingCapacity: true)
    }

    private func sendOnQueue(_ message: [String: Any]) {
        guard let handle = inputPipe?.fileHandleForWriting else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            emitError("无法与 Codex 通信：\(error.localizedDescription)")
        }
    }

    private func makeRequestID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func emitSnapshot(_ snapshot: UsageSnapshot) {
        DispatchQueue.main.async { [weak self] in
            self?.onSnapshot?(snapshot)
        }
    }

    private func emitTokenUsage(_ snapshot: TokenUsageSnapshot) {
        DispatchQueue.main.async { [weak self] in
            self?.onTokenUsage?(snapshot)
        }
    }

    private func emitError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }

    static func findCodexExecutable() -> URL? {
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_CODEX_PATH"] {
            paths.append(override)
        }

        paths.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ])

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        for path in paths {
            let expanded = NSString(string: path).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return nil
    }

    private static func serverErrorMessage(_ message: [String: Any]) -> String? {
        guard let error = message["error"] as? [String: Any] else { return nil }
        return (error["message"] as? String) ?? "未知错误"
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }
}
