import AppKit
import Foundation
import WebKit

enum TiboRSSHubError: LocalizedError {
    case notLoggedIn
    case runtimeMissing
    case nodeMissing
    case invalidResponse
    case service(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "需要先在 Tibo 窗口的 X 原页登录。"
        case .runtimeMissing:
            return "RSSHub 运行组件缺失，请重新安装 Codex Token Bar。"
        case .nodeMissing:
            return "Node.js 运行组件缺失，请重新安装 Codex Token Bar。"
        case .invalidResponse:
            return "RSSHub 返回了无法识别的结果。"
        case .service(let message):
            return message
        }
    }
}

final class TiboRSSHubClient {
    private let cookieStore: WKHTTPCookieStore
    private let cookieBootstrapWebView: WKWebView
    private let queue = DispatchQueue(label: "dev.333.codex-token-bar.rsshub", qos: .utility)
    private var process: Process?

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        cookieStore = configuration.websiteDataStore.httpCookieStore
        cookieBootstrapWebView = WKWebView(frame: .zero, configuration: configuration)
    }

    struct FetchResult {
        let posts: [TiboPost]
        let repliesAvailable: Bool
    }

    func fetch(completion: @escaping (Result<FetchResult, Error>) -> Void) {
        cookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            guard let authToken = cookies.first(where: {
                $0.name == "auth_token" && Self.isXDomain($0.domain)
            })?.value, !authToken.isEmpty else {
                DispatchQueue.main.async { completion(.failure(TiboRSSHubError.notLoggedIn)) }
                return
            }

            queue.async {
                let result = self.run(authToken: authToken)
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let process = self?.process, process.isRunning else { return }
            process.terminate()
        }
    }

    private func run(authToken: String) -> Result<FetchResult, Error> {
        guard let nodeURL = Self.nodeURL else {
            return .failure(TiboRSSHubError.nodeMissing)
        }
        guard let runnerURL = Bundle.main.url(
            forResource: "rsshub-runner",
            withExtension: "mjs"
        ) else {
            return .failure(TiboRSSHubError.runtimeMissing)
        }
        let moduleURL = Self.runtimeRoot
            .appendingPathComponent("node_modules/rsshub/dist-lib/pkg.mjs")
        guard FileManager.default.fileExists(atPath: moduleURL.path) else {
            return .failure(TiboRSSHubError.runtimeMissing)
        }

        let process = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        process.executableURL = nodeURL
        process.currentDirectoryURL = Self.workingRoot
        process.arguments = [
            runnerURL.path,
            moduleURL.path,
            "/twitter/user/thsottiaux/includeReplies=0&includeRts=0&readable=1",
            "/twitter/user/thsottiaux/includeReplies=1&includeRts=0&readable=1"
        ]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": nodeURL.deletingLastPathComponent().path + ":/usr/bin:/bin"
        ]

        do {
            self.process = process
            try process.run()
            let input = try JSONSerialization.data(withJSONObject: ["authToken": authToken])
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            self.process = nil
            guard let text = String(data: output, encoding: .utf8),
                  let markerRange = text.range(of: "CODEX_RSSHUB_RESULT:", options: .backwards)
            else {
                return .failure(TiboRSSHubError.invalidResponse)
            }
            let payload = text[markerRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = payload.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return .failure(TiboRSSHubError.invalidResponse)
            }
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return .failure(TiboRSSHubError.service("RSSHub：" + message))
            }
            let feeds = object["feeds"] as? [[String: Any]] ?? []
            var postsByURL: [String: TiboPost] = [:]
            var repliesAvailable = false
            for feed in feeds {
                guard let data = feed["data"] as? [String: Any] else { continue }
                let parsed = Self.parsePosts(data)
                if (feed["route"] as? String)?.contains("includeReplies=1") == true,
                   !parsed.isEmpty {
                    repliesAvailable = true
                }
                for post in parsed {
                    postsByURL[post.url.absoluteString] = post
                }
            }
            let posts = postsByURL.values.sorted {
                ($0.postedAt ?? $0.capturedAt) > ($1.postedAt ?? $1.capturedAt)
            }
            if posts.isEmpty {
                let keys = object.keys.sorted().joined(separator: ",")
                return .failure(TiboRSSHubError.service("RSSHub 没有返回消息（" + keys + "）"))
            }
            return .success(FetchResult(posts: posts, repliesAvailable: repliesAvailable))
        } catch {
            self.process = nil
            return .failure(error)
        }
    }

    private static func parsePosts(_ object: [String: Any]) -> [TiboPost] {
        let rawItems = (object["item"] as? [[String: Any]])
            ?? (object["items"] as? [[String: Any]])
            ?? ((object["data"] as? [String: Any])?["item"] as? [[String: Any]])
            ?? []
        let now = Date()

        return rawItems.compactMap { item in
            let linkText = (item["link"] as? String) ?? (item["url"] as? String)
            guard let linkText,
                  let url = URL(string: linkText),
                  url.path.contains("/status/")
            else { return nil }

            let content = item["content"] as? [String: Any]
            let html = (content?["html"] as? String)
                ?? (item["description"] as? String)
                ?? (item["content_html"] as? String)
            let plain = (content?["text"] as? String)
                ?? html.map(Self.plainText(fromHTML:))
                ?? (item["title"] as? String)
                ?? ""
            let text = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let dateValue = item["pubDate"] ?? item["date_published"] ?? item["published"]
            return TiboPost(
                text: text,
                url: url,
                postedAt: parseDate(dateValue),
                capturedAt: now,
                isPossiblyTruncated: false,
                isFromRSSHub: true
            )
        }
    }

    private static func plainText(fromHTML html: String) -> String {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              )
        else { return html }
        return attributed.string
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let seconds = value as? TimeInterval {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let string = value as? String else { return nil }
        if let number = TimeInterval(string) {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
        }
        for formatter in dateFormatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    private static func isXDomain(_ domain: String) -> Bool {
        let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == "x.com" || normalized.hasSuffix(".x.com") ||
            normalized == "twitter.com" || normalized.hasSuffix(".twitter.com")
    }

    private static let legacyRuntimeRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Codex Token Bar/rsshub-runtime")

    private static let workingRoot: URL = {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Token Bar/rsshub-work")
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }()

    private static let bundledRuntimeRoot = Bundle.main.resourceURL?
        .appendingPathComponent("rsshub-runtime", isDirectory: true)

    private static let runtimeRoot: URL = {
        if let bundledRuntimeRoot,
           FileManager.default.fileExists(
            atPath: bundledRuntimeRoot
                .appendingPathComponent("node_modules/rsshub/dist-lib/pkg.mjs")
                .path
           ) {
            return bundledRuntimeRoot
        }
        return legacyRuntimeRoot
    }()

    private static let nodeURL: URL? = {
        if let bundledNode = bundledRuntimeRoot?.appendingPathComponent("node"),
           FileManager.default.isExecutableFile(atPath: bundledNode.path) {
            return bundledNode
        }
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/node"),
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node"),
            URL(fileURLWithPath: "/usr/bin/node")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    private static let dateFormatters: [DateFormatter] = {
        let rfc822 = DateFormatter()
        rfc822.locale = Locale(identifier: "en_US_POSIX")
        rfc822.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return [rfc822, iso]
    }()
}
