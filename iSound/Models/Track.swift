import Foundation

struct Track: Identifiable, Hashable {
    /// Derived from the file URL so the same file always gets the same ID across launches.
    /// This is critical for playlist membership to survive app restarts.
    let id: UUID
    let url: URL
    let title: String
    let artist: String?
    let album: String?
    let duration: TimeInterval?
    /// Stored only for YouTube stream tracks so NowPlayingView can pass the
    /// correct ID to StreamService.downloadAudio — the stream URL itself
    /// contains a signed token, not the original video ID.
    let youtubeVideoID: String?

    var isYouTubeTrack: Bool { youtubeVideoID != nil }

    init(url: URL) {
        self.id             = Self.stableID(for: url)
        self.url            = url
        self.title          = url.deletingPathExtension().lastPathComponent
        self.artist         = nil
        self.album          = nil
        self.duration       = nil
        self.youtubeVideoID = nil
    }

    init(id: UUID = UUID(), url: URL, title: String, artist: String?,
         album: String?, duration: TimeInterval?, youtubeVideoID: String? = nil) {
        let isLocalFile     = url.isFileURL
        self.id             = isLocalFile ? Self.stableID(for: url) : id
        self.url            = url
        self.title          = title
        self.artist         = artist
        self.album          = album
        self.duration       = duration
        self.youtubeVideoID = youtubeVideoID
    }

    /// Produces a deterministic UUID from the file's last path component (filename).
    /// Using just the filename (not full path) means tracks survive app reinstall
    /// as long as the filename is the same.
    private static func stableID(for url: URL) -> UUID {
        let name = url.lastPathComponent
        return UUID(uuidString: uuidString(from: name)) ?? UUID()
    }

    private static func uuidString(from string: String) -> String {
        // Simple deterministic UUID v5-style from a string hash
        var hash = string.utf8.reduce(UInt64(14695981039346656037)) { acc, byte in
            (acc ^ UInt64(byte)) &* 1099511628211
        }
        // Format as UUID string from 8 bytes of hash (repeated for length)
        let a = UInt32(hash & 0xFFFFFFFF)
        hash >>= 32
        let b = UInt16(hash & 0xFFFF)
        hash >>= 16
        let c = UInt16((hash & 0x0FFF) | 0x5000) // version 5
        let d = UInt16((hash & 0x3FFF) | 0x8000) // variant bits
        let e = string.utf8.prefix(6).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return String(format: "%08X-%04X-%04X-%04X-%012X", a, b, c, d, e)
    }
}

// MARK: - Time Formatting

extension TimeInterval {
    /// Formats a duration as "m:ss" (e.g. "3:07"). Returns "0:00" for non-finite values.
    var mmss: String {
        guard isFinite else { return "0:00" }
        let total = Int(rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
