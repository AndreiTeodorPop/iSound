import Foundation

struct LyricsResult {
    let original: String
    let translated: String?
    let language: String

    var isEnglish: Bool { language == "en" || (translated == nil && language != "en") }
    var englishText: String { translated ?? original }
}

struct LyricLine: Identifiable {
    let id: Int
    let timestamp: TimeInterval
    let text: String
}

actor LyricsService {
    static let shared = LyricsService()

    private var cache: [String: LyricsResult] = [:]
    private var syncedCache: [String: [LyricLine]] = [:]

    /// Removes common YouTube/video platform suffixes from a track title so that
    /// lyrics APIs receive a clean song name.
    ///
    /// Examples:
    ///   "Believer (Official Music Video)" → "Believer"
    ///   "Believer - Imagine Dragons (Lyrics)" → "Believer"  (artist extracted separately)
    ///   "Something - Topic" → "Something"
    nonisolated func cleanTitle(_ title: String) -> String {
        // Parenthesized / bracketed suffixes to strip (case-insensitive).
        let suffixPattern = #"[\(\[]\s*(?:official\s+(?:music\s+)?(?:lyric\s+)?(?:audio\s+)?video|official\s+audio|official\s+lyric\s+video|music\s+video|lyric(?:s)?\s+video|lyrics|audio|hd|hq|4k|live\s+(?:performance|session|version)?|live|explicit|clean|version|visualizer|remaster(?:ed)?|feat\.?[^)\]]*)\s*[\)\]]"#

        var result = title
        let regex = try? NSRegularExpression(pattern: suffixPattern, options: .caseInsensitive)
        var prev = ""
        while result != prev {
            prev = result
            if let r = regex {
                let range = NSRange(result.startIndex..., in: result)
                result = r.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            }
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip trailing " - Topic" (YouTube auto-generated channel suffix).
        if let range = result.range(of: #"\s*-\s*Topic\s*$"#,
                                    options: [.regularExpression, .caseInsensitive]) {
            result.removeSubrange(range)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip bare "ft. Artist" / "feat. Artist" not enclosed in parens/brackets.
        if let range = result.range(of: #"\s+(?:ft\.?|feat\.?)\s+.+$"#,
                                    options: [.regularExpression, .caseInsensitive]) {
            result.removeSubrange(range)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }

    /// Splits a YouTube-style "Artist - Title" or "Title - Artist" compound
    /// string and returns `(title, artist)`. When the caller already provides a
    /// non-empty artist the compound split is skipped.
    nonisolated private func splitCompound(title: String, artist: String) -> (title: String, artist: String) {
        let cleanedTitle = cleanTitle(title)
        let resolvedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)

        // Always attempt "Artist - Title" split — YouTube titles routinely embed the
        // artist name this way, and the artist field is often a channel name (50CentVEVO)
        // that lyrics APIs won't recognise. The embedded name is more reliable.
        if let dashRange = cleanedTitle.range(of: " - ") {
            let left  = String(cleanedTitle[cleanedTitle.startIndex..<dashRange.lowerBound])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(cleanedTitle[dashRange.upperBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
            if !left.isEmpty && !right.isEmpty {
                return (title: right, artist: left)
            }
        }

        // No "Artist - Title" pattern — strip VEVO/channel suffixes from the artist field.
        let cleanedArtist = resolvedArtist
            .replacingOccurrences(of: #"(?i)(vevo|official|music|records?|tv|channel|entertainment)$"#,
                                  with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (title: cleanedTitle, artist: cleanedArtist.isEmpty ? resolvedArtist : cleanedArtist)
    }

    func fetch(title: String, artist: String) async -> LyricsResult? {
        let (cleanedTitle, cleanedArtist) = splitCompound(title: title, artist: artist)
        let key = "\(cleanedArtist)|\(cleanedTitle)".lowercased()
        if let hit = cache[key] { return hit }

        if let result = await fetchFromBackend(title: cleanedTitle, artist: cleanedArtist) {
            cache[key] = result
            return result
        }

        if let result = await fetchFromLyricsOvh(title: cleanedTitle, artist: cleanedArtist) {
            cache[key] = result
            return result
        }

        if let result = await fetchFromAZLyrics(title: cleanedTitle, artist: cleanedArtist) {
            cache[key] = result
            return result
        }

        return nil
    }

    private func fetchFromBackend(title: String, artist: String) async -> LyricsResult? {
        var comps = URLComponents(string: "https://imusic-production-4e58.up.railway.app/lyrics")!
        comps.queryItems = [
            URLQueryItem(name: "title",  value: title),
            URLQueryItem(name: "artist", value: artist),
        ]
        guard let url = comps.url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(PlainResponse.self, from: data)
            return LyricsResult(
                original:   decoded.lyrics,
                translated: decoded.translated,
                language:   decoded.language
            )
        } catch {
            return nil
        }
    }

    private func fetchFromLyricsOvh(title: String, artist: String) async -> LyricsResult? {
        let encodedArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artist
        let encodedTitle  = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        guard let url = URL(string: "https://api.lyrics.ovh/v1/\(encodedArtist)/\(encodedTitle)") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(OvhResponse.self, from: data)
            let lyrics = decoded.lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lyrics.isEmpty else { return nil }
            return LyricsResult(original: lyrics, translated: nil, language: "en")
        } catch {
            return nil
        }
    }

    private func fetchFromAZLyrics(title: String, artist: String) async -> LyricsResult? {
        let artistSlug = slugify(artist)
        let titleSlug  = slugify(title)
        guard let url = URL(string: "https://www.azlyrics.com/lyrics/\(artistSlug)/\(titleSlug).html") else { return nil }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return nil }
            guard let lyrics = extractAZLyricsText(from: html), !lyrics.isEmpty else { return nil }
            return LyricsResult(original: lyrics, translated: nil, language: "en")
        } catch {
            return nil
        }
    }

    private func slugify(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .joined()
    }

    private func extractAZLyricsText(from html: String) -> String? {
        // AZLyrics places lyrics in an uncommented div with no id/class after the comment "<!-- Usage of azlyrics.com content..."
        guard let commentRange = html.range(of: "<!-- Usage of azlyrics.com content") else { return nil }
        let afterComment = String(html[commentRange.upperBound...])
        guard let divStart = afterComment.range(of: "<div>") else { return nil }
        let fromDiv = String(afterComment[divStart.upperBound...])
        guard let divEnd = fromDiv.range(of: "</div>") else { return nil }
        let inner = String(fromDiv[fromDiv.startIndex..<divEnd.lowerBound])
        return stripHTML(inner).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripHTML(_ html: String) -> String {
        var result = html
        // Replace <br> variants with newlines
        result = result.replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "<br/>",  with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "<br>",   with: "\n", options: .caseInsensitive)
        // Strip remaining tags
        while let start = result.range(of: "<"),
              let end   = result.range(of: ">", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        // Decode common HTML entities
        result = result
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
        return result
    }

    func fetchSynced(title: String, artist: String) async -> [LyricLine]? {
        let (cleanedTitle, cleanedArtist) = splitCompound(title: title, artist: artist)
        let key = "\(cleanedArtist)|\(cleanedTitle)".lowercased()
        if let hit = syncedCache[key] { return hit.isEmpty ? nil : hit }

        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [
            URLQueryItem(name: "track_name",  value: cleanedTitle),
            URLQueryItem(name: "artist_name", value: cleanedArtist),
        ]
        guard let url = comps.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let results = try JSONDecoder().decode([LRCLibResult].self, from: data)

            // Pick the first result that has real per-line timestamps
            for result in results {
                guard let lrc = result.syncedLyrics, !lrc.isEmpty else { continue }
                let lines = parseLRC(lrc)
                if lines.count > 3 {
                    syncedCache[key] = lines
                    return lines
                }
            }
        } catch {}

        syncedCache[key] = []
        return nil
    }

    private func parseLRC(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var index = 0

        for rawLine in lrc.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            // Match [mm:ss.xx] or [mm:ss.xxx]
            guard line.hasPrefix("[") else { continue }

            var cursor = line.startIndex
            while cursor < line.endIndex, line[cursor] == "[" {
                guard let closeRange = line.range(of: "]", range: cursor..<line.endIndex) else { break }
                let tag = String(line[line.index(after: cursor)..<closeRange.lowerBound])
                cursor = closeRange.upperBound

                // Skip metadata tags like [ti:...], [ar:...], etc.
                if tag.contains(":") {
                    let parts = tag.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2,
                          let minutes = Double(parts[0]),
                          let secondsFull = Double(parts[1]) else { continue }
                    let timestamp = minutes * 60 + secondsFull
                    let text = String(line[cursor...]).trimmingCharacters(in: .whitespaces)
                    lines.append(LyricLine(id: index, timestamp: timestamp, text: text))
                    index += 1
                }
            }
        }

        return lines.sorted { $0.timestamp < $1.timestamp }
    }

    private struct PlainResponse: Decodable {
        let lyrics: String
        let translated: String?
        let language: String
    }

    private struct OvhResponse: Decodable {
        let lyrics: String
    }

    private struct LRCLibResult: Decodable {
        let syncedLyrics: String?
    }
}
