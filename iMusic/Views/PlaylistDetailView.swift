import SwiftUI

struct PlaylistDetailView: View {
    let playlistID: UUID
    @ObservedObject var library: AudioLibrary
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var showingAddSongs = false
    @State private var showingDeleteConfirmation = false
    @State private var showingSortSheet = false
    @State private var sortOrder: TrackSortOrder = .recentlyAdded
    @State private var searchText = ""

    @Environment(\.dismiss) private var dismiss

    enum TrackSortOrder: CaseIterable {
        case recentlyAdded, titleAZ, titleZA, artist

        static var allCases: [TrackSortOrder] { [.recentlyAdded, .titleAZ, .artist] }

        var label: String {
            switch self {
            case .recentlyAdded: return "Recently Added"
            case .titleAZ:       return "Alphabetically (A–Z)"
            case .titleZA:       return "Alphabetically (Z–A)"
            case .artist:        return "Artist"
            }
        }
    }

    // MARK: - Live lookup

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

    private var sortedTracksInPlaylist: [Track] {
        switch sortOrder {
        case .recentlyAdded: return tracksInPlaylist
        case .titleAZ:       return tracksInPlaylist.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleZA:       return tracksInPlaylist.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .artist:        return tracksInPlaylist.sorted { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending }
        }
    }

    private var filteredTracksInPlaylist: [Track] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return sortedTracksInPlaylist }
        let q = searchText.lowercased()
        return sortedTracksInPlaylist.filter {
            $0.title.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) == true)
        }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let playlist {
                ZStack {
                ScrollViewReader { proxy in
                ScrollView {

                    // Info + buttons
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Text(playlist.name)
                                .font(.largeTitle).bold()
                            Spacer()
                            Button {
                                showingDeleteConfirmation = true
                            } label: {
                                Image(systemName: "heart.fill")
                                    .font(.title2)
                                    .foregroundStyle(themeManager.current.accent)
                            }
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "person.circle.fill")
                                .foregroundStyle(.secondary)
                            Text("\(tracksInPlaylist.count) songs")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        // Shuffle
                        Button {
                            player.playAll(tracks: tracksInPlaylist.shuffled(), playlistName: playlist.name)
                        } label: {
                            Text("SHUFFLE")
                                .font(.headline).bold()
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(
                                    LinearGradient(
                                        colors: [themeManager.current.accent, themeManager.current.secondaryAccent],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(Capsule())
                        }

                        // Add Songs
                        Button { showingAddSongs = true } label: {
                            Text("ADD SONGS")
                                .font(.subheadline).bold()
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .overlay(Capsule().stroke(Color.primary.opacity(0.4), lineWidth: 1.5))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                    Divider().padding(.horizontal)

                    // Track list
                    if tracksInPlaylist.isEmpty {
                        ContentUnavailableView {
                            Label("No songs yet", systemImage: "music.note.list")
                        } description: {
                            Text("Tap Add Songs to get started.")
                        }
                        .padding(.top, 40)
                    } else if filteredTracksInPlaylist.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .padding(.top, 40)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredTracksInPlaylist) { track in
                                trackRow(for: track, playlist: playlist)
                                    .id(track.id)
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                }
                .overlay(alignment: .trailing) {
                    if !filteredTracksInPlaylist.isEmpty {
                        let available: Set<String> = Set(filteredTracksInPlaylist.map { track in
                            let ch = track.title.first
                            return (ch?.isLetter == true) ? String(ch!).uppercased() : "#"
                        })
                        AlphabetIndexView(proxy: proxy, availableLetters: available) { letter in
                            guard letter != "#" else {
                                return filteredTracksInPlaylist.first { !($0.title.first?.isLetter ?? true) }?.id
                            }
                            return filteredTracksInPlaylist.first { $0.title.uppercased().hasPrefix(letter) }?.id
                        }
                        .padding(.vertical, 8)
                        .padding(.trailing, 4)
                    }
                }
                } // end ScrollViewReader

                // Sort overlay — topmost layer
                if showingSortSheet {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.spring()) { showingSortSheet = false } }
                    SortSheetView(title: "Sort Songs", selection: $sortOrder, isPresented: $showingSortSheet) { option in
                        if option == .titleAZ {
                            return sortOrder == .titleAZ ? "Alphabetically (A–Z)" : (sortOrder == .titleZA ? "Alphabetically (Z–A)" : "Alphabetically")
                        }
                        return option.label
                    } onSelect: { option in
                        if option == .titleAZ {
                            sortOrder = (sortOrder == .titleAZ) ? .titleZA : .titleAZ
                        } else {
                            sortOrder = option
                        }
                    }
                        .padding(.horizontal, 24)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                } // end ZStack
                .animation(.spring(), value: showingSortSheet)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingSortSheet = true } label: {
                            Image(systemName: "line.3.horizontal.decrease")
                                .fontWeight(.semibold)
                        }
                    }
                }
                .confirmationDialog(
                    "Delete \"\(playlist.name)\"?",
                    isPresented: $showingDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete Playlist", role: .destructive) {
                        library.deletePlaylist(playlist)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will remove the playlist but won't delete your songs.")
                }
                .sheet(isPresented: $showingAddSongs) {
                    AddSongsSheet(
                        tracks: tracksNotInPlaylist,
                        onAdd: { track in library.addTrack(track, to: playlist) }
                    )
                }
            } else {
                ContentUnavailableView("Playlist not found", systemImage: "music.note.list")
            }
        }
    }

    // MARK: - Track Row

    private func trackRow(for track: Track, playlist: Playlist) -> some View {
        PlaylistTrackRow(
            track: track,
            isCurrent: player.currentTrack?.id == track.id,
            onTap: { player.play(track: track, queue: tracksInPlaylist, playlistName: playlist.name) },
            onRemove: { library.removeTrack(track, from: playlist) }
        )
    }
}

// MARK: - Track Row

private struct PlaylistTrackRow: View {
    let track: Track
    let isCurrent: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    @State private var showingOptions = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body).fontWeight(.semibold)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                HStack(spacing: 5) {
                    if isCurrent {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                    }
                    Text(track.artist ?? "Unknown artist")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button { showingOptions = true } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .confirmationDialog("", isPresented: $showingOptions, titleVisibility: .hidden) {
                Button("Remove from Playlist", role: .destructive) { onRemove() }
                Button("Cancel", role: .cancel) {}
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
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

    init() { playlistID = UUID() }

    var body: some View {
        NavigationStack {
            PlaylistDetailView(playlistID: playlistID, library: library)
                .environmentObject(AudioPlayer())
        }
    }
}

#Preview { PlaylistDetailPreview() }
