import Foundation

// MARK: - Models

struct YouTubeResult: Identifiable, Codable {
    let id: String
    let title: String
    let channelTitle: String
    let duration: String?   // ISO 8601 from Details API e.g. "PT3M45S"

    // Parsed seconds for display
    var durationSeconds: TimeInterval {
        guard let d = duration else { return 0 }
        return parseISO8601Duration(d)
    }

    enum CodingKeys: String, CodingKey {
        case id = "videoId"
        case title
        case channelTitle
        case duration
    }
    
    init(id: String, title: String, channelTitle: String, duration: String?) {
        self.id           = id
        self.title        = title
        self.channelTitle = channelTitle
        self.duration     = duration
    }

    /// Channel title with the YouTube-generated " - Topic" suffix removed.
    var artistName: String {
        let t = channelTitle
        let suffix = " - Topic"
        if t.lowercased().hasSuffix(suffix.lowercased()) {
            return String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}

private func parseISO8601Duration(_ s: String) -> TimeInterval {
    var t: TimeInterval = 0
    let pattern = try! NSRegularExpression(pattern: #"(\d+)([HMS])"#)
    let matches = pattern.matches(in: s, range: NSRange(s.startIndex..., in: s))
    for m in matches {
        let val = TimeInterval(s[Range(m.range(at: 1), in: s)!]) ?? 0
        let unit = s[Range(m.range(at: 2), in: s)!]
        switch unit {
        case "H": t += val * 3600
        case "M": t += val * 60
        case "S": t += val
        default:  break
        }
    }
    return t
}

// MARK: - Channel & Playlist Models

struct YouTubeChannel: Identifiable {
    let id: String
    let title: String
    let description: String
    let thumbnailURL: String
    let subscriberCount: String
}

struct YouTubePlaylist: Identifiable {
    let id: String
    let title: String
    let description: String
    let thumbnailURL: String
    let itemCount: Int
    let channelTitle: String
}

// MARK: - YouTube Data API v3 Search

struct YouTubeService {
    private static let apiKey: String = {
        guard let key = Bundle.main.infoDictionary?["YoutubeAPIKey"] as? String, !key.isEmpty else {
            fatalError("YoutubeAPIKey not found in Info.plist")
        }
        return key
    }()
    private static let base   = "https://www.googleapis.com/youtube/v3"

    // Search returns up to 10 results with snippet
    static func search(_ query: String) async throws -> [YouTubeResult] {
        var c = URLComponents(string: "\(base)/search")!
        c.queryItems = [
            URLQueryItem(name: "part",       value: "snippet"),
            URLQueryItem(name: "q",          value: query),
            URLQueryItem(name: "type",       value: "video"),
            URLQueryItem(name: "maxResults", value: "10"),
            URLQueryItem(name: "videoEmbeddable",  value: "true"),
            URLQueryItem(name: "videoCategoryId",  value: "10"),
            URLQueryItem(name: "regionCode",       value: "RO"),
            URLQueryItem(name: "relevanceLanguage", value: "ro"),
            URLQueryItem(name: "key",              value: apiKey),
        ]
        let (data, urlResponse) = try await URLSession.shared.data(from: c.url!)

        if let http = urlResponse as? HTTPURLResponse, http.statusCode != 200 {
            throw youtubeAPIError(from: data, statusCode: http.statusCode)
        }

        struct SearchResponse: Decodable {
            struct Item: Decodable {
                struct Id: Decodable { let videoId: String }
                struct Snippet: Decodable {
                    let title: String
                    let channelTitle: String
                }
                let id: Id
                let snippet: Snippet
            }
            let items: [Item]
        }

        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        let videoIds = response.items.map { $0.id.videoId }.joined(separator: ",")
        let durations = try await fetchDurations(for: videoIds)

        let results = response.items.map { item in
            YouTubeResult(
                id:           item.id.videoId,
                title:        item.snippet.title.htmlDecoded,
                channelTitle: item.snippet.channelTitle.htmlDecoded,
                duration:     durations[item.id.videoId]
            )
        }

        // Filter out clips that are clearly too short to be a full song (previews, intros, shorts).
        let filtered = results.filter { $0.durationSeconds == 0 || $0.durationSeconds >= 60 }

        // De-duplicate: collapse results that are the same song uploaded by different channels.
        // YouTube titles use several patterns to differentiate re-uploads of the same track:
        //   "Song - Artist | Official Music Video"
        //   "Song - Artist | Official Lyric Video"
        //   "Song - Artist (Live Session)"
        //   "Song - Artist, Live 2025"
        // We strip those suffixes and compare the core title words.
        var seen = Set<String>()
        return filtered.filter { seen.insert(deduplicationKey($0.title)).inserted }
    }

    private static func deduplicationKey(_ title: String) -> String {
        var s = title.lowercased()
        // Strip pipe-separated suffixes: "Song | Official Music Video" → "Song"
        if let r = s.range(of: "|") { s = String(s[..<r.lowerBound]) }
        // Strip comma-separated suffixes: "Song, Live 2025" → "Song"
        if let r = s.range(of: ",") { s = String(s[..<r.lowerBound]) }
        // Remove parenthetical/bracketed content: (Official Video), [Lyrics], 【HD】, etc.
        s = s.replacingOccurrences(of: #"[\(\[\{【][^\)\]\}】]*[\)\]\}】]"#, with: " ", options: .regularExpression)
        // Remove featured artist markers
        s = s.replacingOccurrences(of: #"\b(feat\.?|ft\.?|featuring)\b.*"#, with: " ", options: .regularExpression)
        // Replace hyphens (artist–title separators) with spaces
        s = s.replacingOccurrences(of: "-", with: " ")
        // Extract alphanumeric words and take the first 5 as the key
        let words = s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return words.prefix(5).joined(separator: " ")
    }

    // MARK: - Channel Search

    static func searchChannels(_ query: String) async throws -> [YouTubeChannel] {
        var c = URLComponents(string: "\(base)/search")!
        c.queryItems = [
            URLQueryItem(name: "part",       value: "snippet"),
            URLQueryItem(name: "q",          value: query),
            URLQueryItem(name: "type",       value: "channel"),
            URLQueryItem(name: "maxResults", value: "20"),
            URLQueryItem(name: "key",        value: apiKey),
        ]
        let (data, urlResponse) = try await URLSession.shared.data(from: c.url!)

        if let http = urlResponse as? HTTPURLResponse, http.statusCode != 200 {
            throw youtubeAPIError(from: data, statusCode: http.statusCode)
        }

        struct SearchResponse: Decodable {
            struct Item: Decodable {
                struct Id: Decodable { let channelId: String }
                struct Snippet: Decodable {
                    let title: String
                    let description: String
                    struct Thumbnails: Decodable {
                        struct Thumb: Decodable { let url: String }
                        let medium: Thumb?
                        let high: Thumb?
                    }
                    let thumbnails: Thumbnails
                }
                let id: Id
                let snippet: Snippet
            }
            let items: [Item]
        }

        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        let channelIds = response.items.map { $0.id.channelId }.joined(separator: ",")
        let subscriberCounts = try await fetchSubscriberCounts(for: channelIds)

        return response.items.map { item in
            let thumb = item.snippet.thumbnails.high?.url
                     ?? item.snippet.thumbnails.medium?.url
                     ?? ""
            return YouTubeChannel(
                id:              item.id.channelId,
                title:           item.snippet.title.htmlDecoded,
                description:     item.snippet.description.htmlDecoded,
                thumbnailURL:    thumb,
                subscriberCount: subscriberCounts[item.id.channelId] ?? ""
            )
        }
    }

    private static func fetchSubscriberCounts(for ids: String) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        var c = URLComponents(string: "\(base)/channels")!
        c.queryItems = [
            URLQueryItem(name: "part", value: "statistics"),
            URLQueryItem(name: "id",   value: ids),
            URLQueryItem(name: "key",  value: apiKey),
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)

        struct ChannelsResponse: Decodable {
            struct Item: Decodable {
                struct Statistics: Decodable { let subscriberCount: String? }
                let id: String
                let statistics: Statistics
            }
            let items: [Item]
        }

        let response = try JSONDecoder().decode(ChannelsResponse.self, from: data)
        return Dictionary(uniqueKeysWithValues: response.items.compactMap { item in
            guard let raw = item.statistics.subscriberCount,
                  let count = Int(raw) else { return nil }
            return (item.id, formatSubscriberCount(count))
        })
    }

    private static func formatSubscriberCount(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return "\(count / 1_000_000)M subscribers"
        case 1_000...:     return "\(count / 1_000)K subscribers"
        default:           return "\(count) subscribers"
        }
    }

    // MARK: - Channel Playlists

    static func getChannelPlaylists(channelID: String) async throws -> [YouTubePlaylist] {
        var allPlaylists: [YouTubePlaylist] = []
        var pageToken: String? = nil

        repeat {
            var c = URLComponents(string: "\(base)/playlists")!
            var items: [URLQueryItem] = [
                URLQueryItem(name: "part",       value: "snippet,contentDetails"),
                URLQueryItem(name: "channelId",  value: channelID),
                URLQueryItem(name: "maxResults", value: "50"),
                URLQueryItem(name: "key",        value: apiKey),
            ]
            if let token = pageToken {
                items.append(URLQueryItem(name: "pageToken", value: token))
            }
            c.queryItems = items

            let (data, urlResponse) = try await URLSession.shared.data(from: c.url!)
            if let http = urlResponse as? HTTPURLResponse, http.statusCode != 200 {
                throw youtubeAPIError(from: data, statusCode: http.statusCode)
            }

            struct PlaylistsResponse: Decodable {
                struct Item: Decodable {
                    struct Snippet: Decodable {
                        let title: String
                        let description: String
                        let channelTitle: String
                        struct Thumbnails: Decodable {
                            struct Thumb: Decodable { let url: String }
                            let medium: Thumb?
                            let high: Thumb?
                        }
                        let thumbnails: Thumbnails
                    }
                    struct ContentDetails: Decodable { let itemCount: Int }
                    let id: String
                    let snippet: Snippet
                    let contentDetails: ContentDetails
                }
                let items: [Item]
                let nextPageToken: String?
            }

            let response = try JSONDecoder().decode(PlaylistsResponse.self, from: data)
            let playlists = response.items.map { item -> YouTubePlaylist in
                let thumb = item.snippet.thumbnails.high?.url
                         ?? item.snippet.thumbnails.medium?.url
                         ?? ""
                return YouTubePlaylist(
                    id:           item.id,
                    title:        item.snippet.title.htmlDecoded,
                    description:  item.snippet.description.htmlDecoded,
                    thumbnailURL: thumb,
                    itemCount:    item.contentDetails.itemCount,
                    channelTitle: item.snippet.channelTitle.htmlDecoded
                )
            }
            allPlaylists.append(contentsOf: playlists)
            pageToken = response.nextPageToken
        } while pageToken != nil

        return allPlaylists
    }

    // MARK: - Playlist Items

    /// Fetches all videos in a playlist, paginating until all items are retrieved (max 200).
    static func getPlaylistItems(playlistID: String) async throws -> [YouTubeResult] {
        var allVideoIds: [String] = []
        var snippetMap: [String: (title: String, channelTitle: String)] = [:]
        var pageToken: String? = nil

        repeat {
            var c = URLComponents(string: "\(base)/playlistItems")!
            var items: [URLQueryItem] = [
                URLQueryItem(name: "part",       value: "snippet"),
                URLQueryItem(name: "playlistId", value: playlistID),
                URLQueryItem(name: "maxResults", value: "50"),
                URLQueryItem(name: "key",        value: apiKey),
            ]
            if let token = pageToken {
                items.append(URLQueryItem(name: "pageToken", value: token))
            }
            c.queryItems = items

            let (data, urlResponse) = try await URLSession.shared.data(from: c.url!)
            if let http = urlResponse as? HTTPURLResponse, http.statusCode != 200 {
                throw youtubeAPIError(from: data, statusCode: http.statusCode)
            }

            struct PlaylistItemsResponse: Decodable {
                struct Item: Decodable {
                    struct Snippet: Decodable {
                        let title: String
                        let videoOwnerChannelTitle: String?
                        struct ResourceId: Decodable { let videoId: String? }
                        let resourceId: ResourceId
                    }
                    let snippet: Snippet
                }
                let items: [Item]
                let nextPageToken: String?
            }

            let response = try JSONDecoder().decode(PlaylistItemsResponse.self, from: data)
            for item in response.items {
                guard let videoId = item.snippet.resourceId.videoId,
                      !videoId.isEmpty else { continue }
                allVideoIds.append(videoId)
                snippetMap[videoId] = (
                    title:        item.snippet.title.htmlDecoded,
                    channelTitle: (item.snippet.videoOwnerChannelTitle ?? "").htmlDecoded
                )
            }
            pageToken = response.nextPageToken
        } while pageToken != nil && allVideoIds.count < 200

        // Fetch durations in batches of 50 (API limit per call)
        var allDurations: [String: String] = [:]
        let batches = stride(from: 0, to: allVideoIds.count, by: 50).map {
            Array(allVideoIds[$0 ..< min($0 + 50, allVideoIds.count)])
        }
        for batch in batches {
            let durations = try await fetchDurations(for: batch.joined(separator: ","))
            allDurations.merge(durations) { _, new in new }
        }

        return allVideoIds.compactMap { videoId in
            guard let info = snippetMap[videoId] else { return nil }
            // Skip "Deleted video" / "Private video" placeholder titles
            guard info.title != "Deleted video", info.title != "Private video" else { return nil }
            return YouTubeResult(
                id:           videoId,
                title:        info.title,
                channelTitle: info.channelTitle,
                duration:     allDurations[videoId]
            )
        }
    }

    // MARK: - Shared Error Parsing

    private static func youtubeAPIError(from data: Data, statusCode: Int) -> Error {
        struct APIError: Decodable { struct Body: Decodable { let message: String }; let error: Body }
        var msg = (try? JSONDecoder().decode(APIError.self, from: data))?.error.message
            ?? "YouTube API error (\(statusCode))"
        msg = msg.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        if msg.lowercased().contains("quota") {
            msg = "YouTube API quota exceeded. Try again tomorrow or use a different API key."
        }
        return URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    // Fetch video durations (contentDetails) for a comma-separated list of IDs
    private static func fetchDurations(for ids: String) async throws -> [String: String] {
        var c = URLComponents(string: "\(base)/videos")!
        c.queryItems = [
            URLQueryItem(name: "part", value: "contentDetails"),
            URLQueryItem(name: "id",   value: ids),
            URLQueryItem(name: "key",  value: apiKey),
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)

        struct VideosResponse: Decodable {
            struct Item: Decodable {
                struct Details: Decodable { let duration: String }
                let id: String
                let contentDetails: Details
            }
            let items: [Item]
        }

        let response = try JSONDecoder().decode(VideosResponse.self, from: data)
        return Dictionary(uniqueKeysWithValues: response.items.map {
            ($0.id, $0.contentDetails.duration)
        })
    }
}

private extension String {
    var htmlDecoded: String {
        guard contains("&") else { return self }
        var s = self
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&ndash;", "–"), ("&mdash;", "—"),
        ]
        for (entity, char) in entities {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        // Decode numeric character references like &#123; or &#x7B;
        s = s.replacingOccurrences(
            of: #"&#x([0-9a-fA-F]+);"#,
            with: "$1",
            options: .regularExpression
        )
        return s
    }
}
