import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Tab Background Decoration

struct TabBackgroundDecoration: View {
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        ZStack {
            Circle()
                .fill(themeManager.current.accent.opacity(0.22))
                .frame(width: 340)
                .blur(radius: 90)
                .offset(x: 140, y: -80)
            Circle()
                .fill(themeManager.current.secondaryAccent.opacity(0.18))
                .frame(width: 270)
                .blur(radius: 75)
                .offset(x: -100, y: 280)
            Circle()
                .fill(themeManager.current.accent.opacity(0.12))
                .frame(width: 220)
                .blur(radius: 65)
                .offset(x: 60, y: 560)
        }
        .ignoresSafeArea()
    }
}

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

private struct PlaylistNavTarget: Identifiable, Hashable {
    let id: UUID
    let action: PlaylistDetailView.InitialAction
}

struct ContentView: View {
    @StateObject private var library: AudioLibrary = .shared
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var searchText: String = ""
    @State private var showingPlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var showingThemePicker = false
    @State private var showingSiri = false
    @State private var selectedTab = 0
    @State private var showingSavedSongs = false
    @State private var selectedPlaylistNav: PlaylistNavTarget?
    @State private var showingPlaylistSearch = false
    @State private var playlistToRename: Playlist?
    @State private var renameText = ""
    @State private var showingRenameAlert = false
    @State private var playlistToDelete: Playlist?
    @State private var showingDeletePlaylistConfirm = false
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
        .onChange(of: library.tracks) { _, tracks in
            guard !tracks.isEmpty else { return }
            player.restoreLastPlayed(from: library)
            // Process intents that fired before the library finished loading
            if let name = IntentBridge.shared.pendingSavedSongSearch {
                IntentBridge.shared.pendingSavedSongSearch = nil
                let q = name.lowercased()
                if let track = tracks.first(where: { $0.title.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) == true) }) {
                    player.play(track: track, queue: tracks)
                }
            }
            if let name = IntentBridge.shared.pendingPlaylistName {
                IntentBridge.shared.pendingPlaylistName = nil
                let q = name.lowercased()
                if let playlist = library.playlists.first(where: { $0.name.lowercased().contains(q) }) {
                    let playlistTracks = tracks.filter { playlist.trackIDs.contains($0.id) }.shuffled()
                    player.playAll(tracks: playlistTracks, playlistName: playlist.name)
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
        .onReceive(IntentBridge.shared.$pendingYouTubePlay.compactMap { $0 }) { pendingQuery in
            selectedTab = 1
            IntentBridge.shared.pendingYouTubePlay = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                IntentBridge.shared.pendingYouTubePlayReady = pendingQuery
            }
        }
        .onReceive(IntentBridge.shared.$pendingSavedSongSearch.compactMap { $0 }) { name in
            guard !library.tracks.isEmpty else { return } // onChange(of: library.tracks) will handle it
            IntentBridge.shared.pendingSavedSongSearch = nil
            let q = name.lowercased()
            if let track = library.tracks.first(where: { $0.title.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) == true) }) {
                player.play(track: track, queue: library.tracks)
            }
        }
        .onReceive(IntentBridge.shared.$pendingPlaylistName.compactMap { $0 }) { name in
            guard !library.playlists.isEmpty, !library.tracks.isEmpty else { return } // onChange(of: library.tracks) will handle it
            IntentBridge.shared.pendingPlaylistName = nil
            let q = name.lowercased()
            if let playlist = library.playlists.first(where: { $0.name.lowercased().contains(q) }) {
                let tracks = library.tracks.filter { playlist.trackIDs.contains($0.id) }.shuffled()
                player.playAll(tracks: tracks, playlistName: playlist.name)
            }
        }
        .onReceive(IntentBridge.shared.$pendingPlayerAction.compactMap { $0 }) { action in
            handlePlayerAction(action)
        }
        .onAppear {
            // Catch intents that fired before the view subscribed (cold launch via Siri)
            if let action = IntentBridge.shared.pendingPlayerAction {
                handlePlayerAction(action)
            }
            if let name = IntentBridge.shared.pendingPlaylistName, !library.playlists.isEmpty, !library.tracks.isEmpty {
                IntentBridge.shared.pendingPlaylistName = nil
                let q = name.lowercased()
                if let playlist = library.playlists.first(where: { $0.name.lowercased().contains(q) }) {
                    let tracks = library.tracks.filter { playlist.trackIDs.contains($0.id) }.shuffled()
                    player.playAll(tracks: tracks, playlistName: playlist.name)
                }
            }
            if let name = IntentBridge.shared.pendingSavedSongSearch, !library.tracks.isEmpty {
                IntentBridge.shared.pendingSavedSongSearch = nil
                let q = name.lowercased()
                if let track = library.tracks.first(where: { $0.title.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) == true) }) {
                    player.play(track: track, queue: library.tracks)
                }
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
        .overlay {
            if showingDuplicatePlaylistAlert {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 16) {
                        VStack(spacing: 8) {
                            Text("Playlist already exists")
                                .font(.headline)
                                .multilineTextAlignment(.center)
                            Text("Please choose a different name.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Divider()
                        Button("OK") { showingDuplicatePlaylistAlert = false }
                            .font(.headline)
                            .foregroundStyle(themeManager.current.accent)
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(40)
                }
            }
        }
    }

    // MARK: - Tabs

    private var homeTab: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    homeSection(title: "Recent tracks", items: Array(library.tracks.prefix(10))) { track in
                        TrackCard(track: track)
                            .onTapGesture { player.play(track: track, queue: library.tracks) }
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
            .background { TabBackgroundDecoration() }
            .navigationTitle("Home")
            // Destination keyed on UUID
            .navigationDestination(for: UUID.self) { id in
                if let playlist = library.playlists.first(where: { $0.id == id }),
                   let link = playlist.linkedYouTubePlaylist {
                    let ytPlaylist = YouTubePlaylist(
                        id: link.playlistID, title: playlist.name, description: "",
                        thumbnailURL: link.thumbnailURL, itemCount: link.itemCount,
                        channelTitle: link.channelTitle
                    )
                    PlaylistItemsView(playlist: ytPlaylist, library: library)
                        .environmentObject(player)
                } else {
                    PlaylistDetailView(playlistID: id, library: library)
                }
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

                List {
                    savedSongsSection
                    playlistsSection
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: player.currentTrack != nil ? 80 : 0)
                }
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
            .background { TabBackgroundDecoration() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showingSavedSongs) {
                SavedSongsView(library: library)
            }
            .navigationDestination(isPresented: $showingPlaylistSearch) {
                PlaylistSearchView(library: library)
            }
            .navigationDestination(item: $selectedPlaylistNav) { nav in
                if let playlist = library.playlists.first(where: { $0.id == nav.id }),
                   let link = playlist.linkedYouTubePlaylist {
                    let ytPlaylist = YouTubePlaylist(
                        id: link.playlistID, title: playlist.name, description: "",
                        thumbnailURL: link.thumbnailURL, itemCount: link.itemCount,
                        channelTitle: link.channelTitle
                    )
                    PlaylistItemsView(playlist: ytPlaylist, library: library)
                        .environmentObject(player)
                } else {
                    PlaylistDetailView(playlistID: nav.id, library: library, initialAction: nav.action)
                }
            }
            .alert("Do you want to delete \"\(playlistToDelete?.name ?? "")\" playlist?", isPresented: $showingDeletePlaylistConfirm) {
                Button("Delete", role: .destructive) {
                    if let p = playlistToDelete { library.deletePlaylist(p) }
                    playlistToDelete = nil
                }
                Button("Cancel", role: .cancel) { playlistToDelete = nil }
            } message: {
                Text("This will remove the playlist but won't delete your songs.")
            }
            .alert("Edit Playlist", isPresented: $showingRenameAlert) {
                TextField("Playlist name", text: $renameText)
                Button("Cancel", role: .cancel) { playlistToRename = nil; renameText = "" }
                Button("Save") {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, let p = playlistToRename { library.renamePlaylist(p, to: name) }
                    playlistToRename = nil; renameText = ""
                }
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
                PlaylistLibraryRow(playlist: playlist, trackCount: playlist.linkedYouTubePlaylist?.itemCount ?? library.tracks.filter { playlist.trackIDs.contains($0.id) }.count) {
                    selectedPlaylistNav = PlaylistNavTarget(id: playlist.id, action: .none)
                } onAddSongs: {
                    selectedPlaylistNav = PlaylistNavTarget(id: playlist.id, action: .addSongs)
                } onSortSongs: {
                    selectedPlaylistNav = PlaylistNavTarget(id: playlist.id, action: .sortSongs)
                } onEdit: {
                    playlistToRename = playlist
                    renameText = playlist.name
                    showingRenameAlert = true
                } onDelete: {
                    playlistToDelete = playlist
                    showingDeletePlaylistConfirm = true
                }
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
                .overlay(alignment: .topTrailing) {
                    if playlist.isYouTubePlaylist {
                        Image(systemName: "play.rectangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(6)
                    }
                }
            Text(playlist.name).font(.subheadline).bold().lineLimit(1).foregroundStyle(.primary)
        }
        .frame(width: 140)
    }

    private func handlePlayerAction(_ action: PendingPlayerAction) {
        IntentBridge.shared.pendingPlayerAction = nil
        switch action {
        case .pause:    if player.isPlaying  { player.togglePlayPause() }
        case .resume:   if !player.isPlaying { player.togglePlayPause() }
        case .skip:     Task { @MainActor in player.playNext() }
        case .previous: Task { @MainActor in player.playPrevious() }
        }
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

// MARK: - Playlist Library Row

private struct PlaylistLibraryRow: View {
    let playlist: Playlist
    let trackCount: Int
    let onTap: () -> Void
    let onAddSongs: () -> Void
    let onSortSongs: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager
    @State private var showingOptions = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(themeManager.current.accent.gradient)
                        .frame(width: 50, height: 50)
                        .overlay(Image(systemName: "music.note.list").foregroundColor(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(playlist.name).font(.headline).lineLimit(1)
                            if playlist.isYouTubePlaylist {
                                Label("YouTube", systemImage: "play.rectangle.fill")
                                    .labelStyle(.iconOnly)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        Text("\(trackCount) songs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Button { showingOptions = true } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingOptions) {
                PlaylistOptionsSheet(
                    playlist: playlist,
                    trackCount: trackCount,
                    onAddSongs: { showingOptions = false; onAddSongs() },
                    onSortSongs: { showingOptions = false; onSortSongs() },
                    onEdit: { showingOptions = false; onEdit() },
                    onDelete: { showingOptions = false; onDelete() }
                )
            }
        }
    }
}

// MARK: - Playlist Options Sheet

private struct PlaylistOptionsSheet: View {
    let playlist: Playlist
    let trackCount: Int
    let onAddSongs: () -> Void
    let onSortSongs: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.current.accent.gradient)
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: "music.note.list").font(.title3).foregroundColor(.white))
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name)
                        .font(.headline)
                    Text("\(trackCount) songs")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            optionRow(icon: "plus.circle", title: "Add Songs",      action: onAddSongs)
            Divider().padding(.leading, 60)
            optionRow(icon: "arrow.up.arrow.down", title: "Sort Songs", action: onSortSongs)
            Divider().padding(.leading, 60)
            optionRow(icon: "pencil",      title: "Edit Playlist",  action: onEdit)
            Divider().padding(.leading, 60)
            optionRow(icon: "trash",       title: "Delete Playlist", isDestructive: true, action: onDelete)

            Spacer()
        }
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
    }

    private func optionRow(icon: String, title: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 24)
                    .foregroundStyle(isDestructive ? Color.red : Color.primary)
                Text(title)
                    .font(.body)
                    .foregroundStyle(isDestructive ? Color.red : Color.primary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
