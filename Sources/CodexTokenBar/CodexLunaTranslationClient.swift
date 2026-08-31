import Foundation

final class CodexLunaTranslationClient {
    struct Input {
        let url: URL
        let text: String
    }

    enum TranslationError: LocalizedError {
        case codexUnavailable
        case launchFailed(String)
        case processFailed
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .codexUnavailable:
                return "未找到可用的 Codex。"
            case .launchFailed(let detail):
                return "无法启动 Codex 翻译：\(detail)"
            case .processFailed:
                return "Codex Luna 暂时没有完成翻译。"
            case .invalidResponse:
                return "Codex Luna 返回了无法识别的翻译结果。"
            }
        }
    }

    private let queue = DispatchQueue(label: "dev.333.codex-token-bar.luna-translation")

    func translate(
        _ inputs: [Input],
        completion: @escaping (Result<[URL: String], Error>) -> Void
    ) {
        guard !inputs.isEmpty else {
            completion(.success([:]))
            return
        }

        queue.async {
            let result = self.run(inputs)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func run(_ inputs: [Input]) -> Result<[URL: String], Error> {
        guard let executable = CodexAppServerClient.findCodexExecutable() else {
            return .failure(TranslationError.codexUnavailable)
        }

        let payload = inputs.map {
            ["url": $0.url.absoluteString, "text": $0.text]
        }
        guard
            let payloadData = try? JSONSerialization.data(withJSONObject: payload),
            let payloadText = String(data: payloadData, encoding: .utf8)
        else { return .failure(TranslationError.invalidResponse) }

        let prompt = """
        Translate every item's text into natural Simplified Chinese.
        Preserve product names, people's names, URLs, emoji, paragraph breaks, and technical meaning.
        Do not add explanations or omit content.
        Return ONLY a valid JSON array in the same order. Each object must have exactly two string fields: "url" copied unchanged and "translation".

        INPUT JSON:
        \(payloadText)
        """

        let process = Process()
        let inputPipe = Pipe()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-token-bar-translation-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        process.executableURL = executable
        process.arguments = [
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "--model", "gpt-5.6-luna",
            "-c", "model_reasoning_effort=\"high\"",
            "--sandbox", "read-only",
            "--cd", NSTemporaryDirectory(),
            "--output-last-message", outputURL.path,
            "-"
        ]
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(Data(prompt.utf8))
            try? inputPipe.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {
            return .failure(TranslationError.launchFailed(error.localizedDescription))
        }

        guard process.terminationStatus == 0 else {
            return .failure(TranslationError.processFailed)
        }
        guard let data = try? Data(contentsOf: outputURL) else {
            return .failure(TranslationError.invalidResponse)
        }
        guard let output = String(data: data, encoding: .utf8) else {
            return .failure(TranslationError.invalidResponse)
        }
        return Self.parse(output, expectedURLs: Set(inputs.map(\.url)))
    }

    private static func parse(
        _ output: String,
        expectedURLs: Set<URL>
    ) -> Result<[URL: String], Error> {
        guard
            let start = output.firstIndex(of: "["),
            let end = output.lastIndex(of: "]"),
            start <= end,
            let data = String(output[start...end]).data(using: .utf8),
            let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return .failure(TranslationError.invalidResponse) }

        var translations: [URL: String] = [:]
        for object in objects {
            guard
                let urlText = object["url"] as? String,
                let url = URL(string: urlText),
                expectedURLs.contains(url),
                let translation = object["translation"] as? String
            else { continue }
            let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { translations[url] = trimmed }
        }

        return translations.isEmpty
            ? .failure(TranslationError.invalidResponse)
            : .success(translations)
    }
}
