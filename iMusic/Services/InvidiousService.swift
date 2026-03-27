import Foundation
import UIKit

// MARK: - Models

struct YouTubeResult: Identifiable, Decodable {
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
            URLQueryItem(name: "videoEmbeddable", value: "true"),
            URLQueryItem(name: "videoCategoryId", value: "10"),
            URLQueryItem(name: "key",        value: apiKey),
        ]
        let (data, urlResponse) = try await URLSession.shared.data(from: c.url!)

        if let http = urlResponse as? HTTPURLResponse, http.statusCode != 200 {
            struct APIError: Decodable { struct Body: Decodable { let message: String }; let error: Body }
            let msg = (try? JSONDecoder().decode(APIError.self, from: data))?.error.message
                ?? "YouTube API error (\(http.statusCode))"
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: msg])
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

        return response.items.map { item in
            YouTubeResult(
                id:           item.id.videoId,
                title:        item.snippet.title.htmlDecoded,
                channelTitle: item.snippet.channelTitle.htmlDecoded,
                duration:     durations[item.id.videoId]
            )
        }
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
        let data = Data(utf8)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil))?.string ?? self
    }
}
