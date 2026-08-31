import Foundation

struct TiboPost: Codable, Equatable {
    let text: String
    let url: URL
    let postedAt: Date?
    let capturedAt: Date
    var translatedText: String?
    var translatedAt: Date?
    var isPossiblyTruncated: Bool?
    var isFromRSSHub: Bool?

    init(
        text: String,
        url: URL,
        postedAt: Date?,
        capturedAt: Date,
        translatedText: String? = nil,
        translatedAt: Date? = nil,
        isPossiblyTruncated: Bool? = nil,
        isFromRSSHub: Bool? = nil
    ) {
        self.text = text
        self.url = url
        self.postedAt = postedAt
        self.capturedAt = capturedAt
        self.translatedText = translatedText
        self.translatedAt = translatedAt
        self.isPossiblyTruncated = isPossiblyTruncated
        self.isFromRSSHub = isFromRSSHub
    }
}

final class TiboPostStore {
    private let defaults: UserDefaults
    private let key = "tibo-public-posts-v1"
    private let readKey = "tibo-read-post-urls-v1"
    private let readStateInitializedKey = "tibo-read-state-initialized-v1"
    private(set) var posts: [TiboPost]
    private var readURLStrings: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([TiboPost].self, from: data) {
            posts = decoded
        } else {
            posts = []
        }

        readURLStrings = Set(defaults.stringArray(forKey: readKey) ?? [])
        if !defaults.bool(forKey: readStateInitializedKey) {
            readURLStrings.formUnion(posts.map { $0.url.absoluteString })
            defaults.set(true, forKey: readStateInitializedKey)
            saveReadState()
        }
    }

    var unreadCount: Int {
        posts.reduce(into: 0) { count, post in
            if !readURLStrings.contains(post.url.absoluteString) {
                count += 1
            }
        }
    }

    @discardableResult
    func merge(_ newPosts: [TiboPost]) -> Bool {
        guard !newPosts.isEmpty else { return false }

        var byURL = Dictionary(uniqueKeysWithValues: posts.map { ($0.url.absoluteString, $0) })
        for var post in newPosts {
            if let existing = byURL[post.url.absoluteString] {
                let isFromRSSHub = existing.isFromRSSHub == true || post.isFromRSSHub == true
                if existing.text.count > post.text.count {
                    post = existing
                } else if existing.text == post.text {
                    post.translatedText = post.translatedText ?? existing.translatedText
                    post.translatedAt = post.translatedAt ?? existing.translatedAt
                    if existing.isPossiblyTruncated == false {
                        post.isPossiblyTruncated = false
                    }
                }
                post.isFromRSSHub = isFromRSSHub
            }
            byURL[post.url.absoluteString] = post
        }

        let merged = byURL.values.sorted { lhs, rhs in
            (lhs.postedAt ?? lhs.capturedAt) > (rhs.postedAt ?? rhs.capturedAt)
        }
        posts = Array(merged.prefix(20))

        save()
        return true
    }

    @discardableResult
    func setTranslation(_ translation: String, for url: URL, at date: Date = Date()) -> Bool {
        guard let index = posts.firstIndex(where: { $0.url == url }) else { return false }
        posts[index].translatedText = translation
        posts[index].translatedAt = date
        save()
        return true
    }

    @discardableResult
    func markRead(_ url: URL) -> Bool {
        let inserted = readURLStrings.insert(url.absoluteString).inserted
        if inserted { saveReadState() }
        return inserted
    }

    @discardableResult
    func markAllRead() -> Bool {
        let previousCount = readURLStrings.count
        readURLStrings.formUnion(posts.map { $0.url.absoluteString })
        guard readURLStrings.count != previousCount else { return false }
        saveReadState()
        return true
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(posts) else { return }
        defaults.set(data, forKey: key)
    }

    private func saveReadState() {
        defaults.set(Array(readURLStrings).sorted(), forKey: readKey)
    }
}
