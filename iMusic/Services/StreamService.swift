import Foundation

struct StreamService {
    static let baseURL = "http://192.168.1.11:8080"

    struct StreamResponse: Decodable {
        let url: String
        let title: String
        let artist: String
        let duration: TimeInterval
    }

    static func getStreamURL(for videoId: String) async throws -> StreamResponse {
        let url = URL(string: "\(baseURL)/stream?id=\(videoId)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(StreamResponse.self, from: data)
    }

    /// Downloads audio to a temp file and returns its URL.
    /// The caller is responsible for presenting a save location picker
    /// and copying/moving the file to the chosen destination.
    static func downloadAudioToTemp(for videoId: String, title: String) async throws -> URL {
        let url = URL(string: "\(baseURL)/download?id=\(videoId)")!
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw StreamError.downloadFailed
        }

        // Rename the temp file to the proper title so the picker shows the right name
        let sanitized = title
            .replacingOccurrences(of: "/",  with: "-")
            .replacingOccurrences(of: ":",  with: "-")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "?",  with: "")
            .replacingOccurrences(of: "*",  with: "")
        let namedURL = tempURL.deletingLastPathComponent()
                              .appendingPathComponent("\(sanitized).m4a")

        if FileManager.default.fileExists(atPath: namedURL.path) {
            try FileManager.default.removeItem(at: namedURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: namedURL)

        return namedURL
    }

    enum StreamError: LocalizedError {
        case downloadFailed
        var errorDescription: String? {
            "Download failed. Make sure the server is running."
        }
    }
}
