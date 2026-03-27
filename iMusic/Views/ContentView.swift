import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Track Card (home screen horizontal scroll)

struct TrackCard: View {
    let track: Track
    var body: some View {
        VStack(alignment: .leading) {
            TrackArtworkView(size: 140, cornerRadius: 8)
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

struct ContentView: View {
    @StateObject private var library = AudioLibrary()
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var searchText: String = ""
    @State private var showingPlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var showingThemePicker = false
    @State private var showingSiri = false
    @State private var selectedTab = 0
    @State private var showingSavedSongs = false
    @State private var selectedPlaylistID: UUID?
    @State private var showingPlaylistSearch = false
    @State private var playlistSortOrder: PlaylistSortOrder = .custom
    @State private var showingSortSheet = false
    @State private var showingDuplicatePlaylistAlert = false

    enum PlaylistSortOrder: CaseIterable {
        case custom, alphabetically, byTracksCount, fromNewest

        var label: String {
            switch self {
            case .custom:          return "Default"
            case .alphabetically:  return "Alphabetically"
            case .byTracksCount:   return "By tracks' count"
            case .fromNewest:      return "From newest"
            }
        }
    }

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
            TabView(selection: $selectedTab) {
                homeTab
                    .tabItem { Label("Home", systemImage: "house") }
                    .tag(0)

                YouTubeSearchView(library: library)
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(1)

                libraryTab
                    .tabItem { Label("Library", systemImage: "music.note.list") }
                    .tag(2)
            }

            if player.currentTrack != nil {
                PlayerControlsView(onExpand: { player.isExpanded = true })
                    .padding(.horizontal)
                    .padding(.bottom, 55)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .fullScreenCover(isPresented: $player.isExpanded) {
                        NowPlayingView(library: library)
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: player.currentTrack)
        .onReceive(IntentBridge.shared.$pendingYouTubeSearch.compactMap { $0 }) { pendingQuery in
            selectedTab = 1
            IntentBridge.shared.pendingYouTubeSearch = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                IntentBridge.shared.pendingYouTubeSearch = pendingQuery
            }
        }
        .onReceive(IntentBridge.shared.$pendingSavedSongSearch.compactMap { $0 }) { name in
            IntentBridge.shared.pendingSavedSongSearch = nil
            let q = name.lowercased()
            if let track = library.tracks.first(where: { $0.title.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) == true) }) {
                player.play(track: track, queue: library.tracks)
            }
        }
        .onReceive(IntentBridge.shared.$pendingPlaylistName.compactMap { $0 }) { name in
            IntentBridge.shared.pendingPlaylistName = nil
            let q = name.lowercased()
            if let playlist = library.playlists.first(where: { $0.name.lowercased().contains(q) }) {
                let tracks = library.tracks.filter { playlist.trackIDs.contains($0.id) }
                player.playAll(tracks: tracks, playlistName: playlist.name)
            }
        }
        .onReceive(IntentBridge.shared.$pendingPlayerAction.compactMap { $0 }) { action in
            IntentBridge.shared.pendingPlayerAction = nil
            switch action {
            case .pause:    if player.isPlaying  { player.togglePlayPause() }
            case .resume:   if !player.isPlaying { player.togglePlayPause() }
            case .skip:     Task { @MainActor in player.playNext() }
            case .previous: Task { @MainActor in player.playPrevious() }
            }
        }
        .alert("Create playlist", isPresented: $showingPlaylistAlert) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                if library.playlists.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                    newPlaylistName = ""
                    showingDuplicatePlaylistAlert = true
                } else {
                    library.createPlaylist(name: name)
                    newPlaylistName = ""
                }
            }
        }
        .alert("Playlist already exists", isPresented: $showingDuplicatePlaylistAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A playlist with that name already exists. Please choose a different name.")
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button { showingSiri = true } label: {
                            Image(systemName: "waveform.and.mic")
                        }
                        Button { showingThemePicker = true } label: {
                            Image(systemName: "paintpalette")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingThemePicker) {
                ThemePickerView()
            }
            .sheet(isPresented: $showingSiri) {
                NavigationStack {
                    SiriShortcutsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingSiri = false }
                        }
                    }
                }
            }
        }
    }

    private var libraryTab: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Library")
                            .font(.largeTitle).bold()
                        Spacer()
                        Button { showingPlaylistSearch = true } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(Color(.systemGroupedBackground))

                List {
                    savedSongsSection
                    playlistsSection
                }
                .listStyle(.insetGrouped)
            }
            .overlay {
                if showingSortSheet {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.spring()) { showingSortSheet = false } }
                    SortSheetView(title: "Sort Playlists", selection: $playlistSortOrder, isPresented: $showingSortSheet) { $0.label }
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .padding(.horizontal, 24)
                }
            }
            .animation(.spring(), value: showingSortSheet)
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showingSavedSongs) {
                SavedSongsView(library: library)
            }
            .navigationDestination(isPresented: $showingPlaylistSearch) {
                PlaylistSearchView(library: library)
            }
            .navigationDestination(item: $selectedPlaylistID) { id in
                PlaylistDetailView(playlistID: id, library: library)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var savedSongsSection: some View {
        Section {
            Button { showingSavedSongs = true } label: {
                HStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(themeManager.current.secondaryAccent.gradient)
                        .frame(width: 50, height: 50)
                        .overlay(Image(systemName: "music.note").foregroundColor(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved songs").font(.headline)
                        Text("\(library.tracks.count) songs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
    }

    private var sortedPlaylists: [Playlist] {
        switch playlistSortOrder {
        case .custom:         return library.playlists
        case .alphabetically: return library.playlists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .byTracksCount:  return library.playlists.sorted { $0.trackIDs.count > $1.trackIDs.count }
        case .fromNewest:     return library.playlists.sorted { $0.createdAt > $1.createdAt }
        }
    }

    @ViewBuilder
    private var playlistsSection: some View {
        Section {
            ForEach(sortedPlaylists) { playlist in
                Button { selectedPlaylistID = playlist.id } label: {
                    HStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(themeManager.current.accent.gradient)
                            .frame(width: 50, height: 50)
                            .overlay(Image(systemName: "music.note.list").foregroundColor(.white))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name).font(.headline)
                            Text("\(playlist.trackIDs.count) songs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
            .onDelete { indexSet in
                for index in indexSet {
                    library.deletePlaylist(sortedPlaylists[index])
                }
            }
            Button { showingPlaylistAlert = true } label: {
                HStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 50, height: 50)
                        .overlay(Image(systemName: "plus").foregroundColor(.secondary))
                    Text("Create playlist")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            HStack {
                Text("Playlists")
                Spacer()
                Button { showingPlaylistAlert = true } label: {
                    Image(systemName: "plus")
                        .fontWeight(.semibold)
                }
                Button { showingSortSheet = true } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .fontWeight(.semibold)
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
                .fill(themeManager.current.accent.gradient)
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
                Image(systemName: "waveform").foregroundStyle(themeManager.current.accent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { player.play(track: track) }
        // Context menu removed — add to playlist via SavedSongsView + button
    }
}
