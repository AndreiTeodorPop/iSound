import SwiftUI

struct PlaylistDetailView: View {
    // Store only the ID — never the struct itself — so we always read live data
    let playlistID: UUID
    @ObservedObject var library: AudioLibrary
    @EnvironmentObject var player: AudioPlayer

    @State private var showingAddSongs = false

    // MARK: - Live lookup (never stale)

    private var playlist: Playlist? {
        library.playlists.first { $0.id == playlistID }
    }

    private var tracksInPlaylist: [Track] {
        guard let playlist else { return [] }
        return library.tracks.filter { playlist.trackIDs.contains($0.id) }
    }

    private var tracksNotInPlaylist: [Track] {
        guard let playlist else { return [] }
        return library.tracks.filter { !playlist.trackIDs.contains($0.id) }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let playlist {
                List {
                    if !tracksInPlaylist.isEmpty {
                        headerSection(playlist: playlist)
                    }

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
                        HStack {
                            Button {
                                showingAddSongs = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            EditButton()
                        }
                    }
                }
                .overlay {
                    if tracksInPlaylist.isEmpty {
                        emptyStateView(playlistName: playlist.name)
                    }
                }
                .sheet(isPresented: $showingAddSongs) {
                    AddSongsSheet(
                        tracks: tracksNotInPlaylist,
                        onAdd: { track in library.addTrack(track, to: playlist) }
                    )
                }
            } else {
                // Playlist was deleted while this view was on screen
                ContentUnavailableView("Playlist not found", systemImage: "music.note.list")
            }
        }
    }

    // MARK: - Subviews

    private func headerSection(playlist: Playlist) -> some View {
        Section {
            VStack(spacing: 16) {
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
                .tint(.green)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    private func trackRow(for track: Track) -> some View {
        HStack(spacing: 12) {
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
            player.play(track: track, queue: tracksInPlaylist)
        }
    }

    private func emptyStateView(playlistName: String) -> some View {
        ContentUnavailableView {
            Label("No songs yet", systemImage: "music.note.list")
        } description: {
            Text("Add songs from your library to get started.")
        } actions: {
            Button {
                showingAddSongs = true
            } label: {
                Label("Add Songs", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func removeRows(at offsets: IndexSet) {
        guard let playlist else { return }
        for index in offsets {
            let track = tracksInPlaylist[index]
            library.removeTrack(track, from: playlist)
        }
    }
}

// MARK: - Add Songs Sheet

private struct AddSongsSheet: View {
    let tracks: [Track]
    let onAdd: @MainActor (Track) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var added: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List(tracks, id: \.id) { track in
                HStack(spacing: 12) {
                    TrackArtworkView(size: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.headline).lineLimit(1)
                        Text(track.artist ?? "Unknown Artist")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Spacer()

                    if added.contains(track.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            onAdd(track)
                            added.insert(track.id)
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if tracks.isEmpty {
                    ContentUnavailableView(
                        "No songs to add",
                        systemImage: "music.note",
                        description: Text("All saved songs are already in this playlist.")
                    )
                }
            }
        }
    }
}

private struct PlaylistDetailPreview: View {
    private let library = AudioLibrary()
    private let playlistID: UUID

    init() {
        playlistID = UUID()
    }

    var body: some View {
        NavigationStack {
            PlaylistDetailView(playlistID: playlistID, library: library)
                .environmentObject(AudioPlayer())
        }
    }
}

#Preview {
    PlaylistDetailPreview()
}
