import Foundation
import NaturalLanguage

struct LyricsResult {
    let original: String
    let translated: String?
    let language: String
    let source: String?

    var isEnglish: Bool { language == "en" || language == "unknown" }
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

        // Server: lrclib → lyrics.ovh → Genius (with translation)
        if let result = await fetchFromBackend(title: cleanedTitle, artist: cleanedArtist) {
            cache[key] = result
            return result
        }

        if let result = await fetchFromGenius(title: cleanedTitle, artist: cleanedArtist) {
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
            var translated = decoded.translated
            var language   = decoded.language
            // If server returned no translation (old deploy or detection failed), translate client-side
            if translated == nil && language != "en" && language != "unknown" {
                let (t, l) = await translateViaServer(text: decoded.lyrics)
                translated = t
                if let l { language = l }
            }
            return LyricsResult(
                original:   decoded.lyrics,
                translated: translated,
                language:   language,
                source:     decoded.source ?? "LrcLib"
            )
        } catch {
            return nil
        }
    }

    private func fetchFromGenius(title: String, artist: String) async -> LyricsResult? {
        let query = "\(artist) \(title)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        guard let searchUrl = URL(string: "https://genius.com/api/search?q=\(query)") else { return nil }

        var searchReq = URLRequest(url: searchUrl)
        searchReq.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: searchReq)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resp    = json["response"] as? [String: Any],
                  let hits    = resp["hits"] as? [[String: Any]] else { return nil }

            // Significant words from our title (≥3 chars, diacritics stripped) that
            // must appear in the Genius hit title — prevents scraping wrong pages.
            let titleWords = title
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }

            for hit in hits.prefix(5) {
                guard hit["type"] as? String == "song",
                      let result = hit["result"] as? [String: Any],
                      let path   = result["path"] as? String,
                      path.hasSuffix("-lyrics"),          // only actual song lyrics pages
                      let pageUrl = URL(string: "https://genius.com\(path)") else { continue }

                // Verify the hit title actually matches our song (avoid release-list pages)
                let hitTitle = (result["title"] as? String ?? "")
                    .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                guard titleWords.isEmpty || titleWords.contains(where: { hitTitle.contains($0) }) else { continue }

                var pageReq = URLRequest(url: pageUrl)
                pageReq.setValue(
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                    forHTTPHeaderField: "User-Agent"
                )
                let (pageData, pageResponse) = try await URLSession.shared.data(for: pageReq)
                guard (pageResponse as? HTTPURLResponse)?.statusCode == 200,
                      let html = String(data: pageData, encoding: .utf8) else { continue }

                guard let raw = extractGeniusLyrics(from: html), !raw.isEmpty else { continue }

                // Clean up: strip section markers [Verse 1], [Chorus], etc.
                // and any line that looks like page metadata (contains "Contributors",
                // or is an excessively long single line — descriptions, not lyrics)
                let lines = raw.components(separatedBy: "\n").filter { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { return false }
                    if t.hasPrefix("[") && t.hasSuffix("]") { return false }   // section markers
                    if t.count > 200 { return false }                          // metadata paragraphs
                    if t.localizedCaseInsensitiveContains("contributors") { return false }
                    return true
                }
                let lyrics = lines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // Require at least 3 non-empty lines — reject page metadata
                guard lines.count >= 3 else { continue }

                // Let the server auto-detect language (more accurate than on-device
                // NLLanguageRecognizer for mixed-language lyrics like French rap).
                let (translated, detectedLang) = await translateViaServer(text: lyrics)
                let lang = detectedLang ?? detectLanguage(lyrics)
                return LyricsResult(original: lyrics, translated: translated, language: lang, source: "Genius")
            }
        } catch {}
        return nil
    }

    /// Detects the dominant language of `text` using on-device NLP.
    nonisolated private func detectLanguage(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(500)))
        return recognizer.dominantLanguage?.rawValue ?? "unknown"
    }

    /// Asks the server to auto-detect language and translate `text` to English.
    /// Returns `(translation, detectedLanguage)` — translation may be nil if English or failed.
    private func translateViaServer(text: String) async -> (String?, String?) {
        guard let url = URL(string: "https://imusic-production-4e58.up.railway.app/translate") else { return (nil, nil) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let translated = json["translated"] as? String
        let lang = json["language"] as? String
        return (translated, lang)
    }

    private func extractGeniusLyrics(from html: String) -> String? {
        var parts: [String] = []
        var remaining = html[html.startIndex...]

        while let attrRange = remaining.range(of: "data-lyrics-container=\"true\"") {
            // Find the opening tag's closing >
            guard let tagClose = remaining.range(of: ">", range: attrRange.upperBound..<remaining.endIndex)
            else { break }

            // Walk forward counting <div>/<div> depth to find the matching </div>
            var depth = 1
            var cursor = tagClose.upperBound
            var buffer = ""

            while cursor < remaining.endIndex && depth > 0 {
                if remaining[cursor...].hasPrefix("<br") {
                    buffer += "\n"
                    if let end = remaining.range(of: ">", range: cursor..<remaining.endIndex) {
                        cursor = end.upperBound; continue
                    }
                } else if remaining[cursor...].hasPrefix("<div") {
                    depth += 1
                    if let end = remaining.range(of: ">", range: cursor..<remaining.endIndex) {
                        cursor = end.upperBound; continue
                    }
                } else if remaining[cursor...].hasPrefix("</div") {
                    depth -= 1
                    if depth == 0 { break }
                    if let end = remaining.range(of: ">", range: cursor..<remaining.endIndex) {
                        cursor = end.upperBound; continue
                    }
                } else if remaining[cursor] == "<" {
                    // skip any other tag
                    if let end = remaining.range(of: ">", range: cursor..<remaining.endIndex) {
                        cursor = end.upperBound; continue
                    }
                } else {
                    buffer.append(remaining[cursor])
                }
                cursor = remaining.index(after: cursor)
            }

            let cleaned = decodeHTMLEntities(buffer)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { parts.append(cleaned) }
            remaining = remaining[cursor...]
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    nonisolated private func decodeHTMLEntities(_ text: String) -> String {
        var s = text
        // Collapse raw HTML whitespace (indentation newlines) — real line breaks come from <br>
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        // Named entities
        let named: [(String, String)] = [
            ("&amp;",   "&"),  ("&lt;",    "<"),  ("&gt;",    ">"),
            ("&quot;",  "\""), ("&apos;",  "'"),  ("&nbsp;",  " "),
            ("&rsquo;", "'"),  ("&lsquo;", "'"),  ("&sbquo;", "'"),
            ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"),
            ("&hellip;","…"),  ("&ndash;", "–"),  ("&mdash;", "—"),
            ("&times;", "×"),  ("&copy;",  "©"),
        ]
        for (entity, replacement) in named {
            s = s.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        // Numeric hex entities &#xNNNN;
        if let regex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);") {
            let range = NSRange(s.startIndex..., in: s)
            let matches = regex.matches(in: s, range: range).reversed()
            for m in matches {
                if let hexRange = Range(m.range(at: 1), in: s),
                   let codePoint = UInt32(s[hexRange], radix: 16),
                   let scalar = Unicode.Scalar(codePoint) {
                    if let fullRange = Range(m.range, in: s) {
                        s.replaceSubrange(fullRange, with: String(scalar))
                    }
                }
            }
        }
        // Numeric decimal entities &#NNNN;
        if let regex = try? NSRegularExpression(pattern: "&#([0-9]+);") {
            let range = NSRange(s.startIndex..., in: s)
            let matches = regex.matches(in: s, range: range).reversed()
            for m in matches {
                if let numRange = Range(m.range(at: 1), in: s),
                   let codePoint = UInt32(s[numRange]),
                   let scalar = Unicode.Scalar(codePoint) {
                    if let fullRange = Range(m.range, in: s) {
                        s.replaceSubrange(fullRange, with: String(scalar))
                    }
                }
            }
        }
        return s
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
            return LyricsResult(original: lyrics, translated: nil, language: "en", source: "lyrics.ovh")
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
            return LyricsResult(original: lyrics, translated: nil, language: "en", source: "AZLyrics")
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

        // Primary search
        if let lines = await lrclibSyncedSearch(trackName: cleanedTitle, artistName: cleanedArtist),
           !lines.isEmpty {
            syncedCache[key] = lines
            return lines
        }

        // Retry: when artist is empty the title may be "Artist SongTitle" with no dash —
        // split on the last whitespace group so the first part becomes the artist.
        // Example: "いきものがかり ブルーバード" → artist="いきものがかり", track="ブルーバード"
        if cleanedArtist.isEmpty, let spaceIdx = cleanedTitle.lastIndex(of: " ") {
            let retryArtist = String(cleanedTitle[cleanedTitle.startIndex..<spaceIdx])
            let retryTitle  = String(cleanedTitle[cleanedTitle.index(after: spaceIdx)...])
            if !retryArtist.isEmpty && !retryTitle.isEmpty,
               let lines = await lrclibSyncedSearch(trackName: retryTitle, artistName: retryArtist),
               !lines.isEmpty {
                syncedCache[key] = lines
                return lines
            }
        }

        syncedCache[key] = []
        return nil
    }

    private func lrclibSyncedSearch(trackName: String, artistName: String) async -> [LyricLine]? {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [
            URLQueryItem(name: "track_name",  value: trackName),
            URLQueryItem(name: "artist_name", value: artistName),
        ]
        guard let url = comps.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let results = try JSONDecoder().decode([LRCLibResult].self, from: data)
            for result in results {
                guard let lrc = result.syncedLyrics, !lrc.isEmpty else { continue }
                let lines = parseLRC(lrc)
                if lines.count > 3 { return lines }
            }
            return []
        } catch {
            return nil
        }
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
        let source: String?
    }

    private struct OvhResponse: Decodable {
        let lyrics: String
    }

    private struct LRCLibResult: Decodable {
        let syncedLyrics: String?
    }
}
