//
//  Playlist.swift
//  iSound
//
//  Created by Pop Andrei on 16.03.2026.
//

import Foundation
import SwiftUI

struct Playlist: Identifiable, Hashable {
    let id: UUID
    var name: String
    var trackIDs: Set<UUID>

    // Senior Tip: Providing a default init value makes the call sites much cleaner
    init(id: UUID = UUID(), name: String, trackIDs: Set<UUID> = []) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
    }
}

// A high-end Card View for the Home Screen
struct TrackCard: View {
    let track: Track
    var body: some View {
        VStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 140, height: 140)
                .overlay(Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary))
            
            Text(track.title)
                .font(.subheadline).bold()
                .lineLimit(1)
            Text(track.artist ?? "Unknown Artist")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 140)
    }
}
