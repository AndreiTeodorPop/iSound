import SwiftUI
import AVKit
import Combine

struct NowPlayingView: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) var dismiss

    @ObservedObject var library: AudioLibrary

    @State private var showingQueue          = false
    @State private var showingPlaylistPicker = false
    @State private var toast: ToastType?
    @State private var toastTask: Task<Void, Never>?

    // True if there is a next track in either queue
    private var hasNext: Bool {
        !player.upcomingTracks.isEmpty || !player.upcomingYoutubeTracks.isEmpty
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
                VStack(spacing: 3) {
                    Text("Now Playing")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if player.currentTrack?.youtubeVideoID != nil {
                        Label("YouTube", systemImage: "play.rectangle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else if let name = player.currentPlaylistName {
                        Label(name, systemImage: "music.note.list")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal)
            .padding(.top, 10)

            // MARK: Album Art
            RoundedRectangle(cornerRadius: 20)
                .fill(themeManager.current.accent.gradient)
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
                SeekBar(
                    progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                    onSeek: { player.seek(to: $0 * player.duration) }
                )

                HStack {
                    Text(player.currentTime.mmss).font(.caption.monospacedDigit())
                    Spacer()
                    Text(player.duration.mmss).font(.caption.monospacedDigit())
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

            // MARK: Action Row: Shuffle | Add to Playlist | Queue
            HStack {
                Spacer()

                // Shuffle (only relevant for local queues)
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle")
                        .font(.title3)
                        .foregroundStyle(player.isShuffled ? themeManager.current.accent : .secondary)
                        .overlay(alignment: .bottom) {
                            if player.isShuffled {
                                Circle()
                                    .fill(themeManager.current.accent)
                                    .frame(width: 5, height: 5)
                                    .offset(y: 8)
                            }
                        }
                }

                Spacer()

                // Add to Playlist
                addToPlaylistButton

                Spacer()

                // Cast
                AVRoutePickerButton()

                Spacer()

                // Queue
                Button { showingQueue = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .foregroundStyle(hasNext ? .primary : .secondary)
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
        .overlay(alignment: .center) { toastOverlay }
    }

    // MARK: - Add to Playlist Button

    private var eligiblePlaylists: [Playlist] {
        guard let track = player.currentTrack else { return [] }
        let resolved = library.localTrack(matching: track)
        return library.playlists.filter { !$0.trackIDs.contains(resolved.id) }
    }

    @ViewBuilder
    private var addToPlaylistButton: some View {
        Button { showingPlaylistPicker = true } label: {
            Image(systemName: "plus.circle")
                .font(.title3)
                .foregroundStyle(eligiblePlaylists.isEmpty ? .secondary : .primary)
        }
        .disabled(eligiblePlaylists.isEmpty || player.currentTrack == nil)
        .confirmationDialog(
            "Add to Playlist",
            isPresented: $showingPlaylistPicker,
            titleVisibility: .visible
        ) {
            ForEach(eligiblePlaylists) { playlist in
                Button(playlist.name) {
                    guard let track = player.currentTrack else { return }
                    library.addTrack(library.localTrack(matching: track), to: playlist)
                    showToast(.success("Added to \"\(playlist.name)\""))
                }
            }
            Button("Cancel", role: .cancel) {}
        }
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

    @ViewBuilder
    private var toastOverlay: some View {
        if let t = toast {
            ToastView(toast: t)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

}

// MARK: - Queue Sheet

private struct QueueSheet: View {
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) var dismiss

    // Unified upcoming item for display
    private struct QueueItem: Identifiable {
        let id: String
        let title: String
        let artist: String
    }

    private var queueItems: [QueueItem] {
        // YouTube queue takes priority when active
        if player.hasYouTubeQueue {
            return player.upcomingYoutubeTracks.map {
                QueueItem(id: $0.id, title: $0.title, artist: $0.channelTitle)
            }
        }
        return player.upcomingTracks.map {
            QueueItem(id: $0.id.uuidString, title: $0.title, artist: $0.artist ?? "Unknown Artist")
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if queueItems.isEmpty {
                    ContentUnavailableView(
                        "No upcoming tracks",
                        systemImage: "list.bullet",
                        description: Text("Play a playlist or search result to see the queue")
                    )
                } else {
                    List {
                        Section("Up Next") {
                            ForEach(queueItems) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text(item.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .onMove { source, destination in
                                if player.hasYouTubeQueue {
                                    player.moveUpcomingYouTubeTrack(from: source, to: destination)
                                } else {
                                    player.moveUpcomingTrack(from: source, to: destination)
                                }
                            }
                        }
                    }
                    .environment(\.editMode, .constant(.active))
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
// MARK: - Native AirPlay / Bluetooth Route Picker

private final class RoutePickerPresenter: ObservableObject {
    let pickerView: AVRoutePickerView = {
        let v = AVRoutePickerView()
        v.tintColor = .clear
        v.activeTintColor = .clear
        return v
    }()

    func trigger() {
        func findButton(in view: UIView) -> UIButton? {
            for sub in view.subviews {
                if let btn = sub as? UIButton { return btn }
                if let btn = findButton(in: sub) { return btn }
            }
            return nil
        }
        findButton(in: pickerView)?.sendActions(for: .touchUpInside)
    }
}

private struct RoutePickerViewRepresentable: UIViewRepresentable {
    let pickerView: AVRoutePickerView
    func makeUIView(context: Context) -> AVRoutePickerView { pickerView }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct AVRoutePickerButton: View {
    var font: Font = .title3
    @StateObject private var presenter = RoutePickerPresenter()

    var body: some View {
        Button {
            presenter.trigger()
        } label: {
            Image(systemName: "airplayvideo")
                .font(font)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .background(
            RoutePickerViewRepresentable(pickerView: presenter.pickerView)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        )
    }
}

