import SwiftUI

// MARK: - Row

private struct SavedTrackRow: View {
    let track: Track
    let isCurrent: Bool
    @ObservedObject var library: AudioLibrary
    let onTap: () -> Void
    let onAddToPlaylist: (Playlist) -> Void

    private var eligiblePlaylists: [Playlist] {
        library.playlists.filter { !$0.trackIDs.contains(track.id) }
    }

    @State private var showingPlaylistPicker = false

    var body: some View {
        HStack(spacing: 12) {
            TrackArtworkView(size: 44)

            // Title + artist
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(track.artist ?? "Unknown Artist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // Playing indicator
            if isCurrent {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
            }

            // Add to playlist button
            Button {
                showingPlaylistPicker = true
            } label: {
                Image(systemName: "plus.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36) // larger tap target
            }
            .buttonStyle(.plain) // prevents the whole row from highlighting
            .disabled(eligiblePlaylists.isEmpty)
            .confirmationDialog(
                "Add \"\(track.title)\" to playlist",
                isPresented: $showingPlaylistPicker,
                titleVisibility: .visible
            ) {
                ForEach(eligiblePlaylists) { playlist in
                    Button(playlist.name) {
                        onAddToPlaylist(playlist)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        // Context menu removed — use the + button instead
    }
}

// MARK: - Main View

struct SavedSongsView: View {
    @ObservedObject var library: AudioLibrary
    @EnvironmentObject private var player: AudioPlayer

    @State private var toast: ToastType?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        List {
            ForEach(library.tracks, id: \.id) { track in
                let isCurrent = (player.currentTrack?.id == track.id)
                SavedTrackRow(
                    track: track,
                    isCurrent: isCurrent,
                    library: library,
                    onTap: { player.play(track: track, queue: library.tracks) },
                    onAddToPlaylist: { playlist in
                        library.addTrack(track, to: playlist)
                        showToast(.success("Added to \"\(playlist.name)\""))
                    }
                )
            }
            .onDelete { indexSet in
                for index in indexSet {
                    let track = library.tracks[index]
                    if player.currentTrack?.id == track.id { player.stop() }
                    Task { await library.deleteTrack(track) }
                }
            }
        }
        .navigationTitle("Saved Songs")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
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
        .overlay(alignment: .bottom) {
            if let t = toast {
                ToastView(toast: t)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: toast != nil)
    }

    // MARK: - Toast

    private func showToast(_ type: ToastType) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.3)) { toast = type }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut) { toast = nil }
        }
    }
}

