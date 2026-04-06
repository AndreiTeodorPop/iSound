import Foundation
import SwiftUI

struct Playlist: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var trackIDs: Set<UUID>
    let createdAt: Date
    var isYouTubePlaylist: Bool
    var linkedYouTubePlaylist: LinkedYouTubePlaylist?

    struct LinkedYouTubePlaylist: Codable, Hashable {
        let playlistID: String
        let thumbnailURL: String
        let itemCount: Int
        let channelTitle: String
    }

    init(id: UUID = UUID(), name: String, trackIDs: Set<UUID> = [], createdAt: Date = .now,
         isYouTubePlaylist: Bool = false, linkedYouTubePlaylist: LinkedYouTubePlaylist? = nil) {
        self.id                    = id
        self.name                  = name
        self.trackIDs              = trackIDs
        self.createdAt             = createdAt
        self.isYouTubePlaylist     = isYouTubePlaylist
        self.linkedYouTubePlaylist = linkedYouTubePlaylist
    }

    // Custom decoder so existing playlists load without the new fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                    = try c.decode(UUID.self,      forKey: .id)
        name                  = try c.decode(String.self,    forKey: .name)
        trackIDs              = try c.decode(Set<UUID>.self,  forKey: .trackIDs)
        createdAt             = try c.decode(Date.self,      forKey: .createdAt)
        isYouTubePlaylist     = try c.decodeIfPresent(Bool.self,                    forKey: .isYouTubePlaylist)     ?? false
        linkedYouTubePlaylist = try c.decodeIfPresent(LinkedYouTubePlaylist.self,   forKey: .linkedYouTubePlaylist)
    }
}

