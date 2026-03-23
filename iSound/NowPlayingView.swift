import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) var dismiss

    // Needed for playlist list + download duplicate check
    @ObservedObject var library: AudioLibrary

    @State private var showingQueue            = false
    @State private var showingPlaylistPicker   = false
    @State private var isDownloading           = false
    @State private var isDownloaded            = false
    @State private var pendingFileURL: URL?    = nil   // triggers save picker
    @State private var toast: ToastState?      = nil
    @State private var toastTask: Task<Void, Never>?

    private struct ToastState {
        let message: String
        let isError: Bool
    }

    // The current track is a YouTube stream if its album == "YouTube"
    private var isYouTubeTrack: Bool {
        player.currentTrack?.album == "YouTube"
    }

    // Check if the current YouTube track is already saved locally
    private var isAlreadySaved: Bool {
        guard let track = player.currentTrack else { return false }
        return library.tracks.contains { $0.title == track.title }
    }

    var body: some View {
        VStack(spacing: 20) {

            // MARK: Header
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                Spacer()
                Text("Now Playing")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal)
            .padding(.top, 10)

            // MARK: Album Art
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.accentColor.gradient)
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 100))
                        .foregroundColor(.white)
                )
                .padding(40)
                .shadow(radius: 20)
                .scaleEffect(player.isPlaying ? 1.0 : 0.92)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: player.isPlaying)

            // MARK: Title & Artist
            VStack(spacing: 8) {
                Text(player.currentTrack?.title ?? "Unknown")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(player.currentTrack?.artist ?? "Unknown Artist")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            Spacer()

            // MARK: Progress
            VStack(spacing: 8) {
                Slider(value: Binding(
                    get: { player.duration > 0 ? player.currentTime / player.duration : 0 },
                    set: { player.seek(to: $0 * player.duration) }
                ))
                .tint(.primary)

                HStack {
                    Text(timeString(player.currentTime)).font(.caption.monospacedDigit())
                    Spacer()
                    Text(timeString(player.duration)).font(.caption.monospacedDigit())
                }
            }
            .padding(.horizontal, 30)

            // MARK: Main Controls
            HStack(spacing: 50) {
                Button { player.playPrevious() } label: {
                    Image(systemName: "backward.fill").font(.title)
                }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 80))
                }
                Button { player.playNext() } label: {
                    Image(systemName: "forward.fill").font(.title)
                }
            }
            .foregroundStyle(.primary)

            // MARK: Volume
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SystemVolumeSlider()
                    .frame(height: 30)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 30)

            // MARK: Action Row: Shuffle | Download | Add to Playlist | Queue
            HStack {
                Spacer()

                // Shuffle
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle")
                        .font(.title3)
                        .foregroundStyle(player.isShuffled ? Color.accentColor : .secondary)
                        .overlay(alignment: .bottom) {
                            if player.isShuffled {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 5, height: 5)
                                    .offset(y: 8)
                            }
                        }
                }

                Spacer()

                // Download — only visible for YouTube streams
                if isYouTubeTrack {
                    downloadButton
                    Spacer()
                }

                // Add to Playlist
                addToPlaylistButton

                Spacer()

                // Queue
                Button { showingQueue = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .foregroundStyle(player.upcomingTracks.isEmpty ? .secondary : .primary)
                }
                .sheet(isPresented: $showingQueue) {
                    QueueSheet()
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            Spacer()
        }
        .padding(.bottom, 40)
        .overlay(alignment: .bottom) { toastOverlay }
        // Reset download state whenever the track changes
        .onChange(of: player.currentTrack?.title) {
            isDownloading = false
            isDownloaded  = isAlreadySaved
        }
        .onAppear {
            isDownloaded = isAlreadySaved
        }
    }

    // MARK: - Download Button

    @ViewBuilder
    private var downloadButton: some View {
        Button {
            guard !isDownloading, !isDownloaded,
                  let track = player.currentTrack else { return }
            Task { await downloadCurrentTrack(track) }
        } label: {
            ZStack {
                if isDownloading {
                    ProgressView().controlSize(.small)
                } else if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.blue)
                }
            }
            .font(.title3)
            .frame(width: 28, height: 28)
            .animation(.spring(response: 0.3), value: isDownloading)
            .animation(.spring(response: 0.3), value: isDownloaded)
        }
        .disabled(isDownloading || isDownloaded)
        // Present save location picker once temp file is ready
        .sheet(item: Binding(
            get: { pendingFileURL.map { IdentifiableURL($0) } },
            set: { if $0 == nil { pendingFileURL = nil } }
        )) { identifiable in
            FileSaverPicker(sourceURL: identifiable.url) { result in
                pendingFileURL = nil
                switch result {
                case .success(let savedURL):
                    let fileName = identifiable.url.lastPathComponent
                    try? StreamService.copyToImportedAudio(from: savedURL, fileName: fileName)
                    Task { await library.reloadAfterDownload() }
                    isDownloaded = true
                    showToast("Saved to \"\(savedURL.deletingLastPathComponent().lastPathComponent)\"")
                case .failure(let error):
                    if (error as? FileSaverPicker.FileSaverError) != .cancelled {
                        showToast(error.localizedDescription, isError: true)
                    }
                }
                isDownloading = false
            }
        }
    }

    private func downloadCurrentTrack(_ track: Track) async {
        guard let videoID = track.youtubeVideoID else {
            showToast("Cannot determine video ID", isError: true)
            return
        }

        isDownloading = true
        do {
            let tempURL = try await StreamService.downloadAudioToTemp(for: videoID, title: track.title)
            isDownloading = false   // spinner stops; picker takes over
            pendingFileURL = tempURL
        } catch {
            isDownloading = false
            showToast(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Add to Playlist Button

    @ViewBuilder
    private var addToPlaylistButton: some View {
        Button { showingPlaylistPicker = true } label: {
            Image(systemName: "plus.circle")
                .font(.title3)
                .foregroundStyle(library.playlists.isEmpty ? .secondary : .primary)
        }
        .disabled(library.playlists.isEmpty || player.currentTrack == nil)
        .confirmationDialog(
            "Add to Playlist",
            isPresented: $showingPlaylistPicker,
            titleVisibility: .visible
        ) {
            ForEach(library.playlists) { playlist in
                Button(playlist.name) {
                    guard let track = player.currentTrack else { return }
                    // For YouTube streams, prefer the downloaded local version if it exists
                    let targetTrack = library.tracks.first { $0.title == track.title } ?? track
                    library.addTrack(targetTrack, to: playlist)
                    showToast("Added to \"\(playlist.name)\"")
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Toast

    private func showToast(_ message: String, isError: Bool = false) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.3)) {
            toast = ToastState(message: message, isError: isError)
        }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut) { toast = nil }
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let t = toast {
            HStack(spacing: 8) {
                Image(systemName: t.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(t.isError ? .red : .green)
                Text(t.message)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke((t.isError ? Color.red : Color.green).opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.bottom, 50)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Helpers

    private func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "0:00" }
        let total = Int(t.rounded()); let m = total / 60; let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Queue Sheet

private struct QueueSheet: View {
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if player.upcomingTracks.isEmpty {
                    ContentUnavailableView(
                        "No upcoming tracks",
                        systemImage: "list.bullet",
                        description: Text("Play a playlist to see the queue")
                    )
                } else {
                    List {
                        Section("Up Next") {
                            ForEach(Array(player.upcomingTracks.enumerated()), id: \.element.id) { index, track in
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title)
                                            .font(.headline)
                                            .lineLimit(1)
                                        Text(track.artist ?? "Unknown Artist")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
