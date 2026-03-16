import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var library = AudioLibrary()
    @EnvironmentObject private var player: AudioPlayer
    
    // UI State
    @State private var searchText: String = ""
    @State private var showingImporter = false
    @State private var showingPlaylistAlert = false
    @State private var newPlaylistName = ""

    // Search Logic
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
            // MARK: - Layer 1: Navigation
            TabView {
                homeTab
                    .tabItem { Label("Home", systemImage: "house") }
                
                searchTab
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                
                libraryTab
                    .tabItem { Label("Library", systemImage: "music.note.list") }
            }
            
            // MARK: - Layer 2: Mini-Player Overlay
            if player.currentTrack != nil {
                PlayerControlsView()
                    .padding(.horizontal)
                    .padding(.bottom, 55) // Clears the TabBar area
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture {
                        player.isExpanded = true
                    }
                    .fullScreenCover(isPresented: $player.isExpanded) {
                        NowPlayingView()
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
                // Ensure we handle the security-scoped URLs correctly here
                for url in urls {
                    // Calling it explicitly
                    self.library.importTrack(from: url)
                }
            case .failure(let error):
                print("Import failed: \(error.localizedDescription)")
            }
        }
        .onAppear {
            player.configureAudioSession()
        }
    }

    // MARK: - Tab Views

    private var homeTab: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    homeSection(title: "Recently Added", items: Array(library.tracks.suffix(5))) { track in
                        TrackCard(track: track)
                            .onTapGesture { player.play(track: track) }
                    }
                    
                    homeSection(title: "Your Playlists", items: library.playlists) { playlist in
                        NavigationLink(value: playlist) {
                            playlistCard(playlist)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Home")
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist, library: library)
            }
        }
    }

    private var searchTab: some View {
        NavigationStack {
            List(filteredTracks) { track in
                trackRow(track)
            }
            .navigationTitle("Search")
            .searchable(text: $searchText)
            .toolbar {
                Button { showingImporter = true } label: { Image(systemName: "square.and.arrow.down") }
            }
            .overlay {
                if library.tracks.isEmpty {
                    ContentUnavailableView("No Music", systemImage: "music.note", description: Text("Tap the import icon to add songs"))
                }
            }
        }
    }

    private var libraryTab: some View {
        NavigationStack {
            List {
                Button(action: { showingPlaylistAlert = true }) {
                    Label("Create Playlist", systemImage: "plus.circle.fill")
                        .foregroundStyle(.green)
                }
                
                ForEach(library.playlists) { playlist in
                    NavigationLink(value: playlist) {
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
            .navigationTitle("Library")
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist, library: library)
            }
        }
    }

    // MARK: - View Helpers

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
        .contextMenu {
            Menu("Add to Playlist") {
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) { library.addTrack(track, to: playlist) }
                }
            }
        }
    }
}
