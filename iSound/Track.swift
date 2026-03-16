import Foundation

struct Track: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let title: String
    let artist: String?
    let album: String?
    let duration: TimeInterval?

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.artist = nil
        self.album = nil
        self.duration = nil
    }

    init(id: UUID = UUID(), url: URL, title: String, artist: String?, album: String?, duration: TimeInterval?) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}
