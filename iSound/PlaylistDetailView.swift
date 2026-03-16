import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist
    @ObservedObject var library: AudioLibrary
    @EnvironmentObject var player: AudioPlayer

    // MARK: - Computed Properties
    private var tracksInPlaylist: [Track] {
        // Filter the main library tracks based on the IDs stored in this playlist
        library.tracks.filter { playlist.trackIDs.contains($0.id) }
    }

    var body: some View {
        List {
            // MARK: - Header Section
            if !tracksInPlaylist.isEmpty {
                headerSection
            }

            // MARK: - Tracks List
            Section {
                ForEach(tracksInPlaylist) { track in
                    trackRow(for: track)
                }
                .onDelete(perform: removeRows)
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .overlay {
            if tracksInPlaylist.isEmpty {
                emptyStateView
            }
        }
    }

    // MARK: - Subviews
    
    private var headerSection: some View {
        Section {
            VStack(spacing: 16) {
                // Playlist Artwork Placeholder
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 160, height: 160)
                    .shadow(radius: 10)
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(.system(size: 60))
                            .foregroundColor(.white)
                    )
                
                VStack(spacing: 4) {
                    Text(playlist.name)
                        .font(.title2.bold())
                    
                    Text("\(tracksInPlaylist.count) songs")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    player.playAll(tracks: tracksInPlaylist)
                } label: {
                    Label("Play All", systemImage: "play.circle.fill")
                        .font(.headline)
                        .padding(.horizontal, 20)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green) // Spotify Green vibe
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    private func trackRow(for track: Track) -> some View {
        HStack(spacing: 12) {
            // Playing indicator or icon
            if player.currentTrack?.id == track.id {
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.green)
                    .frame(width: 24)
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }

            VStack(alignment: .leading) {
                Text(track.title)
                    .font(.headline)
                    .foregroundStyle(player.currentTrack?.id == track.id ? .green : .primary)
                
                Text(track.artist ?? "Unknown Artist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            player.play(track: track)
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No songs yet", systemImage: "music.note.list")
        } description: {
            Text("Find songs in the Search tab and long-press to add them to \(playlist.name).")
        }
    }

    // MARK: - Actions
    
    private func removeRows(at offsets: IndexSet) {
        for index in offsets {
            let trackToRemove = tracksInPlaylist[index]
            library.removeTrack(trackToRemove, from: playlist)
        }
    }
}

#Preview {
    NavigationStack {
        PlaylistDetailView(
            // Explicitly pass an empty set if you haven't added the default init above
            playlist: Playlist(name: "My Summer Hits", trackIDs: []),
            library: AudioLibrary()
        )
        .environmentObject(AudioPlayer())
    }
}
