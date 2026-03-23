//
//  SavedSongsView.swift
//  iSound
//
//  Created by Pop Andrei on 23.03.2026.
//


struct SavedSongsView: View {
    @ObservedObject var library: AudioLibrary
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        List {
            ForEach(library.tracks) { track in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundStyle(.secondary)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(track.artist ?? "Unknown Artist")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if player.currentTrack?.id == track.id {
                        Image(systemName: "waveform")
                            .foregroundStyle(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { player.play(track: track) }
                .contextMenu {
                    Menu("Add to Playlist") {
                        ForEach(library.playlists) { playlist in
                            Button(playlist.name) {
                                library.addTrack(track, to: playlist)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Saved Songs")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Play all button
            if !library.tracks.isEmpty {
                Button {
                    player.playAll(tracks: library.tracks)
                } label: {
                    Label("Play All", systemImage: "play.circle.fill")
                }
            }
        }
        .overlay {
            if library.tracks.isEmpty {
                ContentUnavailableView(
                    "No saved songs",
                    systemImage: "music.note",
                    description: Text("Tap the import button to add songs from your device")
                )
            }
        }
    }
}