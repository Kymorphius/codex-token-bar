import Foundation

enum TiboTranslationError: LocalizedError {
    case emptyText
    case textTooLong
    case invalidResponse
    case service(String)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "这条消息没有可翻译的文字。"
        case .textTooLong:
            return "这条消息过长，超过免费翻译接口的单次保护上限。"
        case .invalidResponse:
            return "翻译服务返回了无法识别的结果。"
        case .service(let message):
            return message
        }
    }
}

final class TiboTranslationClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func translateToChinese(_ text: String) async throws -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw TiboTranslationError.emptyText }
        guard normalized.utf8.count <= 4_000 else { throw TiboTranslationError.textTooLong }

        let prepared = Self.protectProductNames(normalized)
        let chunks = Self.makeChunks(prepared, maximumBytes: 450)
        var translations: [String] = []
        translations.reserveCapacity(chunks.count)

        for chunk in chunks {
            translations.append(try await translateChunk(chunk))
        }

        return Self.restoreProductNames(translations.joined(separator: " "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func translateChunk(_ text: String) async throws -> String {
        var components = URLComponents(string: "https://api.mymemory.translated.net/get")!
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "autodetect|zh-CN"),
            URLQueryItem(name: "mt", value: "1")
        ]
        guard let url = components.url else { throw TiboTranslationError.invalidResponse }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("CodexTokenBar/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TiboTranslationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw TiboTranslationError.service("今天的免费翻译额度可能已用完，请稍后再试。")
            }
            throw TiboTranslationError.service("翻译服务暂时不可用（HTTP \(http.statusCode)）。")
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TiboTranslationError.invalidResponse
        }

        if let status = object["responseStatus"] as? Int, status != 200 {
            let detail = object["responseDetails"] as? String
            throw TiboTranslationError.service(detail ?? "翻译服务暂时无法处理这条消息。")
        }

        guard let responseData = object["responseData"] as? [String: Any],
              let translated = responseData["translatedText"] as? String,
              !translated.isEmpty
        else {
            throw TiboTranslationError.invalidResponse
        }

        return Self.decodeBasicHTMLEntities(translated)
    }

    static func makeChunks(_ text: String, maximumBytes: Int) -> [String] {
        guard text.utf8.count > maximumBytes else { return [text] }

        var sentences: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            sentences.append(String(text[range]))
        }
        if sentences.isEmpty { sentences = [text] }

        var chunks: [String] = []
        var current = ""

        func flushCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
        }

        func appendOversized(_ sentence: String) {
            var part = ""
            for character in sentence {
                let candidate = part + String(character)
                if candidate.utf8.count > maximumBytes {
                    let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { chunks.append(trimmed) }
                    part = String(character)
                } else {
                    part = candidate
                }
            }
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
        }

        for sentence in sentences {
            if sentence.utf8.count > maximumBytes {
                flushCurrent()
                appendOversized(sentence)
                continue
            }

            let separator = current.isEmpty ? "" : " "
            let candidate = current + separator + sentence
            if candidate.utf8.count > maximumBytes {
                flushCurrent()
                current = sentence
            } else {
                current = candidate
            }
        }
        flushCurrent()
        return chunks
    }

    private static func decodeBasicHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func protectProductNames(_ text: String) -> String {
        text.replacingOccurrences(of: "Codex", with: "[Codex]")
    }

    private static func restoreProductNames(_ text: String) -> String {
        text.replacingOccurrences(of: "[Codex]", with: "Codex")
            .replacingOccurrences(of: "［Codex］", with: "Codex")
    }
}
