import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var library = AudioLibrary()
    @EnvironmentObject private var player: AudioPlayer

    @State private var searchText: String = ""
    @State private var showingImporter = false
    @State private var showingPlaylistAlert = false
    @State private var newPlaylistName = ""

    private var filteredTracks: [Track] {
        let base = library.tracks
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            ($0.artist?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                homeTab
                    .tabItem { Label("Home", systemImage: "house") }

                YouTubeSearchView(library: library)
                    .tabItem { Label("YouTube", systemImage: "play.rectangle") }

                libraryTab
                    .tabItem { Label("Library", systemImage: "music.note.list") }
            }

            if player.currentTrack != nil {
                PlayerControlsView()
                    .padding(.horizontal)
                    .padding(.bottom, 55)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture {
                        player.isExpanded = true
                    }
                    .fullScreenCover(isPresented: $player.isExpanded) {
                        NowPlayingView(library: library)
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: player.currentTrack)
        .alert("New Playlist", isPresented: $showingPlaylistAlert) {
            TextField("Playlist Name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
            Button("Create") {
                if !newPlaylistName.isEmpty {
                    library.createPlaylist(name: newPlaylistName)
                    newPlaylistName = ""
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    library.importTrack(from: url)
                }
            case .failure(let error):
                print("Import failed: \(error.localizedDescription)")
            }
        }
        .onAppear {
            player.configureAudioSession()
        }
    }

    // MARK: - Tabs

    private var homeTab: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    homeSection(title: "Recently Added", items: Array(library.tracks.suffix(5))) { track in
                        TrackCard(track: track)
                            .onTapGesture { player.play(track: track) }
                    }

                    homeSection(title: "Your Playlists", items: library.playlists) { playlist in
                        // Pass ID only — PlaylistDetailView looks up live data itself
                        NavigationLink(value: playlist.id) {
                            playlistCard(playlist)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Home")
            // Destination keyed on UUID
            .navigationDestination(for: UUID.self) { id in
                PlaylistDetailView(playlistID: id, library: library)
            }
        }
    }

    private var libraryTab: some View {
        NavigationStack {
            List {
                savedSongsSection
                playlistsSection
            }
            .navigationTitle("Library")
            .navigationDestination(for: UUID.self) { id in
                PlaylistDetailView(playlistID: id, library: library)
            }
            .toolbar {
                Button { showingImporter = true } label: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var savedSongsSection: some View {
        Section {
            NavigationLink {
                SavedSongsView(library: library)
            } label: {
                HStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.pink.gradient)
                        .frame(width: 50, height: 50)
                        .overlay(Image(systemName: "music.note").foregroundColor(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved Songs").font(.headline)
                        Text("\(library.tracks.count) songs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var playlistsSection: some View {
        Section("Playlists") {
            Button(action: { showingPlaylistAlert = true }) {
                Label("Create Playlist", systemImage: "plus.circle.fill")
                    .foregroundStyle(.green)
            }

            ForEach(library.playlists) { playlist in
                // Navigate by ID so PlaylistDetailView always reads live data
                NavigationLink(value: playlist.id) {
                    HStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.gradient)
                            .frame(width: 50, height: 50)
                            .overlay(Image(systemName: "music.note.list").foregroundColor(.white))
                        Text(playlist.name).font(.headline)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func homeSection<Data: RandomAccessCollection, Content: View>(
        title: String,
        items: Data,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) -> some View where Data.Element: Identifiable {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(items) { item in
                        content(item)
                    }
                }
            }
        }
    }

    private func playlistCard(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.gradient)
                .frame(width: 140, height: 140)
                .overlay(Image(systemName: "music.note.list").font(.largeTitle).foregroundColor(.white))
            Text(playlist.name).font(.subheadline).bold().lineLimit(1).foregroundStyle(.primary)
        }
        .frame(width: 140)
    }

    private func trackRow(_ track: Track) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(track.title).font(.headline)
                Text(track.artist ?? "Unknown Artist").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if player.currentTrack?.id == track.id {
                Image(systemName: "waveform").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { player.play(track: track) }
        // Context menu removed — add to playlist via SavedSongsView + button
    }
}
