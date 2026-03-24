import Foundation
import SwiftUI

struct Playlist: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var trackIDs: Set<UUID>

    init(id: UUID = UUID(), name: String, trackIDs: Set<UUID> = []) {
        self.id       = id
        self.name     = name
        self.trackIDs = trackIDs
    }
}

