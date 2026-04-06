import SwiftUI

// MARK: - Channel Playlists View

@MainActor
struct ChannelPlaylistsView: View {
    let channel: YouTubeChannel
    @ObservedObject var library: AudioLibrary
    @EnvironmentObject private var player: AudioPlayer

    @State private var playlists: [YouTubePlaylist] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var toast: ToastType?
    @State private var toastTask: Task<Void, Never>?
    @State private var playlistOptions: YouTubePlaylist? = nil
    @State private var navigatingTo: YouTubePlaylist? = nil
    @State private var searchText = ""

    private var filteredPlaylists: [YouTubePlaylist] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return playlists }
        return playlists.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List(filteredPlaylists) { playlist in
            HStack(spacing: 0) {
                Button {
                    navigatingTo = playlist
                } label: {
                    playlistRowContent(playlist)
                }
                .buttonStyle(.plain)

                Button { playlistOptions = playlist } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 4))
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: player.currentTrack != nil ? 80 : 0)
        }
        .scrollContentBackground(.hidden)
        .background { TabBackgroundDecoration() }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search playlists")
        .navigationTitle(channel.title)
        .navigationBarTitleDisplayMode(.large)
        .scrollIndicators(.visible)
        .overlay { overlayView }
        .overlay(alignment: .bottom) { toastOverlay }
        .task { await loadPlaylists() }
        .sheet(item: $playlistOptions) { playlist in
            playlistOptionsSheet(playlist)
        }
        .navigationDestination(item: $navigatingTo) { playlist in
            PlaylistItemsView(playlist: playlist, library: library)
                .environmentObject(player)
        }
    }

    // MARK: - Playlist Row Content

    @ViewBuilder
    private func playlistRowContent(_ playlist: YouTubePlaylist) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: playlist.thumbnailURL)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color(white: 0.2)
                        .overlay(
                            Image(systemName: "music.note.list")
                                .foregroundStyle(Color(white: 0.5))
                        )
                }
            }
            .frame(width: 56, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(playlist.itemCount) videos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }

    // MARK: - Options Sheet

    @ViewBuilder
    private func playlistOptionsSheet(_ playlist: YouTubePlaylist) -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 20)

            HStack(spacing: 12) {
                AsyncImage(url: URL(string: playlist.thumbnailURL)) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                    default: Color(white: 0.2).overlay(Image(systemName: "music.note.list").foregroundStyle(Color(white: 0.5)))
                    }
                }
                .frame(width: 56, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.title).font(.headline).lineLimit(1)
                    Text("\(playlist.itemCount) videos").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            Divider()

            Button {
                library.linkYouTubePlaylist(
                    id: playlist.id, name: playlist.title,
                    thumbnailURL: playlist.thumbnailURL,
                    itemCount: playlist.itemCount,
                    channelTitle: playlist.channelTitle
                )
                playlistOptions = nil
                showToast(.success("Added to library"))
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "music.note.list")
                        .font(.body)
                        .frame(width: 24)
                    Text("Add to library")
                        .font(.body)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(20)
    }

    // MARK: - Load

    private func loadPlaylists() async {
        isLoading = true
        loadError = nil
        do {
            playlists = try await YouTubeService.getChannelPlaylists(channelID: channel.id)
        } catch {
            loadError = error.localizedDescription
            showToast(.error(error.localizedDescription))
        }
        isLoading = false
    }

    // MARK: - Toast

    private func showToast(_ type: ToastType) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.3)) { toast = type }
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut) { toast = nil }
        }
    }

    @ViewBuilder
    private var overlayView: some View {
        if isLoading {
            ProgressView("Loading playlists…")
        } else if playlists.isEmpty && loadError == nil {
            ContentUnavailableView("No playlists", systemImage: "music.note.list",
                                   description: Text("This channel has no public playlists."))
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let t = toast {
            ToastView(toast: t)
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Playlist Items View

@MainActor
struct PlaylistItemsView: View {
    let playlist: YouTubePlaylist
    @ObservedObject var library: AudioLibrary
    @EnvironmentObject private var player: AudioPlayer

    @State private var items: [YouTubeResult] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isLoadingID: String?
    @State private var downloadingIDs: Set<String> = []
    @State private var downloadedIDs:  Set<String> = []
    @State private var toast: ToastType?
    @State private var toastTask: Task<Void, Never>?
    @State private var searchText = ""
    @AppStorage("ytPlaylistSortOrder") private var sortOrder: SortOrder = .defaultOrder
    @State private var showingSortSheet = false
    @State private var showingDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss

    private var linkedPlaylist: Playlist? {
        library.playlists.first { $0.linkedYouTubePlaylist?.playlistID == playlist.id }
    }

    enum SortOrder: String, CaseIterable {
        case titleAZ, titleZA, defaultOrder

        static var allCases: [SortOrder] { [.titleAZ, .defaultOrder] }

        var label: String {
            switch self {
            case .titleAZ:      return "Alphabetically (A–Z)"
            case .titleZA:      return "Alphabetically (Z–A)"
            case .defaultOrder: return "Default"
            }
        }

        var isAlphabetical: Bool { self == .titleAZ || self == .titleZA }
    }

    private var sortedItems: [YouTubeResult] {
        switch sortOrder {
        case .titleAZ:      return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleZA:      return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .defaultOrder: return items
        }
    }

    private var filteredItems: [YouTubeResult] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sortedItems }
        return sortedItems.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.channelTitle.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            // Playlist name + song count header
            if !items.isEmpty {
                Section {
                    Text(playlist.title)
                        .font(.largeTitle).bold()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                    HStack(spacing: 6) {
                        Image(systemName: "person.circle.fill")
                            .foregroundStyle(.secondary)
                        Text("\(items.count) songs")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if linkedPlaylist != nil {
                            Button { showingDeleteConfirmation = true } label: {
                                Image(systemName: "heart.fill")
                                    .font(.title2)
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }

            // "Play All" / "Shuffle" header section
            if !items.isEmpty {
                Section {
                    HStack(spacing: 12) {
                        Button {
                            Task { await playAll() }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Play All")
                                    .font(.headline)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color.red)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await shuffleAll() }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "shuffle")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Shuffle")
                                    .font(.headline)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color.red.opacity(0.75))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }

            // Video rows
            Section {
                ForEach(filteredItems) { result in
                    resultRow(result)
                        .id(result.id)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }
                if !searchText.isEmpty && filteredItems.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .overlay(alignment: .trailing) {
            if !filteredItems.isEmpty && sortOrder.isAlphabetical {
                let available: Set<String> = Set(filteredItems.map { result in
                    let ch = result.title.first
                    return (ch?.isLetter == true) ? String(ch!).uppercased() : "#"
                })
                AlphabetIndexView(proxy: proxy, availableLetters: available) { letter in
                    guard letter != "#" else {
                        return filteredItems.first { !($0.title.first?.isLetter ?? true) }?.id
                    }
                    return filteredItems.first { $0.title.uppercased().hasPrefix(letter) }?.id
                }
                .padding(.vertical, 8)
                .padding(.trailing, 4)
            }
        }
        } // end ScrollViewReader
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: player.currentTrack != nil ? 80 : 0)
        }
        .scrollContentBackground(.hidden)
        .background { TabBackgroundDecoration() }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search songs")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .scrollIndicators(sortOrder.isAlphabetical ? .hidden : .visible)
        .overlay { overlayView }
        .overlay(alignment: .bottom) { toastOverlay }
        .overlay {
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
        }
        .animation(.spring(), value: showingSortSheet)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSortSheet = true } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .fontWeight(.semibold)
                }
            }
        }
        .alert("Do you want to delete this playlist?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let p = linkedPlaylist { library.deletePlaylist(p) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the playlist from your library.")
        }
        .task { await loadItems() }
        .onChange(of: library.tracks) { (_: [Track], tracks: [Track]) in
            let savedTitles = Set(tracks.map { $0.title })
            let updatedIDs = downloadedIDs.filter { (id: String) -> Bool in
                items.first(where: { $0.id == id }).map { savedTitles.contains($0.title) } ?? false
            }
            downloadedIDs = updatedIDs
        }
    }

    // MARK: - Row Builder

    @ViewBuilder
    private func resultRow(_ result: YouTubeResult) -> some View {
        YouTubeResultRow(
            result: result,
            isStreaming:       isLoadingID == result.id,
            isCurrentTrack:    player.currentTrack?.youtubeVideoID == result.id,
            isDownloading:     downloadingIDs.contains(result.id),
            isDownloaded:      downloadedIDs.contains(result.id),
            onPlay: {
                Task { await playResult(result) }
            },
            onDownloadStarted: {
                withAnimation { _ = downloadingIDs.insert(result.id) }
            },
            onDownloaded: { _ in
                withAnimation {
                    downloadingIDs.remove(result.id)
                    _ = downloadedIDs.insert(result.id)
                }
                showToast(.success("Saved to library"))
            },
            onDownloadCancelled: {
                withAnimation { _ = downloadingIDs.remove(result.id) }
            },
            onDownloadError: { error in
                withAnimation { _ = downloadingIDs.remove(result.id) }
                showToast(.error(error.localizedDescription))
            },
            library: library
        )
    }

    // MARK: - Play Actions

    private func playResult(_ result: YouTubeResult) async {
        guard isLoadingID == nil else { return }
        isLoadingID = result.id

        if let index = items.firstIndex(where: { $0.id == result.id }) {
            player.setYouTubeQueue(items, startingAt: index)
        }

        do {
            let stream = try await StreamService.getStreamURL(for: result.id)
            guard let url = URL(string: stream.url) else {
                showToast(.error("Invalid stream URL"))
                isLoadingID = nil
                return
            }
            let artist = stream.artist.trimmingCharacters(in: .whitespaces).isEmpty
                ? result.artistName
                : stream.artist
            player.playYouTube(
                url: url,
                title: stream.title,
                artist: artist,
                duration: stream.duration,
                videoID: result.id
            )
        } catch {
            showToast(.error(error.localizedDescription))
        }
        isLoadingID = nil
    }

    private func playAll() async {
        let queue = filteredItems.isEmpty ? items : filteredItems
        guard !queue.isEmpty, isLoadingID == nil else { return }
        let first = queue[0]
        isLoadingID = first.id
        player.setYouTubeQueue(queue, startingAt: 0)

        do {
            let stream = try await StreamService.getStreamURL(for: first.id)
            guard let url = URL(string: stream.url) else {
                showToast(.error("Invalid stream URL"))
                isLoadingID = nil
                return
            }
            let artist = stream.artist.trimmingCharacters(in: .whitespaces).isEmpty
                ? first.artistName
                : stream.artist
            player.playYouTube(
                url: url,
                title: stream.title,
                artist: artist,
                duration: stream.duration,
                videoID: first.id
            )
        } catch {
            showToast(.error(error.localizedDescription))
        }
        isLoadingID = nil
    }

    private func shuffleAll() async {
        guard !items.isEmpty, isLoadingID == nil else { return }
        let shuffled = items.shuffled()
        let first = shuffled[0]
        isLoadingID = first.id
        player.setYouTubeQueue(shuffled, startingAt: 0)

        do {
            let stream = try await StreamService.getStreamURL(for: first.id)
            guard let url = URL(string: stream.url) else {
                showToast(.error("Invalid stream URL"))
                isLoadingID = nil
                return
            }
            let artist = stream.artist.trimmingCharacters(in: .whitespaces).isEmpty
                ? first.artistName
                : stream.artist
            player.playYouTube(
                url: url,
                title: stream.title,
                artist: artist,
                duration: stream.duration,
                videoID: first.id
            )
        } catch {
            showToast(.error(error.localizedDescription))
        }
        isLoadingID = nil
    }

    // MARK: - Load

    private func loadItems() async {
        isLoading = true
        loadError = nil
        do {
            let fetched = try await YouTubeService.getPlaylistItems(playlistID: playlist.id)
            items = fetched
            let savedTitles = Set(library.tracks.map { $0.title })
            downloadedIDs = Set(fetched.filter { savedTitles.contains($0.title) }.map { $0.id })
        } catch {
            loadError = error.localizedDescription
            showToast(.error(error.localizedDescription))
        }
        isLoading = false
    }

    // MARK: - Toast

    private func showToast(_ type: ToastType) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.3)) { toast = type }
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut) { toast = nil }
        }
    }

    @ViewBuilder
    private var overlayView: some View {
        if isLoading {
            ProgressView("Loading videos…")
        } else if items.isEmpty && loadError == nil {
            ContentUnavailableView("No videos", systemImage: "play.slash",
                                   description: Text("This playlist has no public videos."))
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let t = toast {
            ToastView(toast: t)
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - YouTubePlaylist Hashable conformance (needed for NavigationLink value:)

extension YouTubePlaylist: Hashable {
    static func == (lhs: YouTubePlaylist, rhs: YouTubePlaylist) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
