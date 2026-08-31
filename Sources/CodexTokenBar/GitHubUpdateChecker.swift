import Foundation
import CodexTokenCore

struct GitHubRelease {
    let version: String
    let pageURL: URL
    let downloadURL: URL?
}

enum GitHubUpdateState {
    case updateAvailable(GitHubRelease)
    case upToDate(latestVersion: String)
    case noPublishedRelease
}

final class GitHubUpdateChecker {
    private struct ReleaseResponse: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    private let latestReleaseURL = URL(
        string: "https://api.github.com/repos/Kymorphius/codex-token-bar/releases/latest"
    )!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func check(
        currentVersion: String,
        completion: @escaping (Result<GitHubUpdateState, Error>) -> Void
    ) {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexTokenBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            if httpResponse.statusCode == 404 {
                completion(.success(.noPublishedRelease))
                return
            }
            guard (200..<300).contains(httpResponse.statusCode), let data else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }

            do {
                let response = try JSONDecoder().decode(ReleaseResponse.self, from: data)
                let latestVersion = SemanticVersion.normalized(response.tagName)
                if SemanticVersion.isNewer(latestVersion, than: currentVersion) {
                    let preferredAsset = response.assets.first {
                        $0.name.lowercased().hasSuffix(".dmg")
                    } ?? response.assets.first {
                        $0.name.lowercased().hasSuffix(".zip")
                    }
                    completion(.success(.updateAvailable(GitHubRelease(
                        version: latestVersion,
                        pageURL: response.htmlURL,
                        downloadURL: preferredAsset?.browserDownloadURL
                    ))))
                } else {
                    completion(.success(.upToDate(latestVersion: latestVersion)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

}
