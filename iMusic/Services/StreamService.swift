import Foundation

struct StreamService {

    static let baseURL = "https://imusic-production-4e58.up.railway.app"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 15
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 120
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    struct StreamResponse: Decodable {
        let url: String
        let title: String
        let artist: String
        let duration: TimeInterval
    }

    // MARK: - Get Stream URL

    static func getStreamURL(for videoId: String) async throws -> StreamResponse {
        guard let url = URL(string: "\(baseURL)/stream?id=\(videoId)") else {
            throw StreamError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw StreamError.serverError
        }
        return try JSONDecoder().decode(StreamResponse.self, from: data)
    }

    // MARK: - Download

    static func downloadAudioToTemp(for videoId: String, title: String) async throws -> URL {
        guard let url = URL(string: "\(baseURL)/download?id=\(videoId)") else {
            throw StreamError.invalidURL
        }

        let (tempURL, response) = try await downloadSession.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw StreamError.downloadFailed
        }

        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let ext: String
        if contentType.contains("mpeg") || contentType.contains("mp3") {
            ext = "mp3"
        } else if contentType.contains("mp4") {
            ext = "m4a"
        } else {
            ext = "mp3"
        }

        let sanitized = title
            .replacingOccurrences(of: "/",  with: "-")
            .replacingOccurrences(of: ":",  with: "-")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "?",  with: "")
            .replacingOccurrences(of: "*",  with: "")

        let namedURL = tempURL.deletingLastPathComponent()
                              .appendingPathComponent("\(sanitized).\(ext)")

        if FileManager.default.fileExists(atPath: namedURL.path) {
            try FileManager.default.removeItem(at: namedURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: namedURL)

        return namedURL
    }

    // MARK: - Errors

    enum StreamError: LocalizedError {
        case invalidURL
        case serverError
        case downloadFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL:     return "Invalid server URL."
            case .serverError:    return "Server returned an error."
            case .downloadFailed: return "Download failed."
            }
        }
    }
}
