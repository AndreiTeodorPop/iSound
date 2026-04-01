import SwiftUI
import Combine

// MARK: - Toast Model

enum ToastType {
    case success(String)
    case error(String)

    var message: String {
        switch self {
        case .success(let m), .error(let m): return m
        }
    }
    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error:   return "xmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .success: return .green
        case .error:   return .red
        }
    }
}

struct ToastView: View {
    let toast: ToastType
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.icon).foregroundStyle(toast.color)
            Text(toast.message).font(.subheadline.weight(.medium)).lineLimit(2)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(toast.color.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}

// MARK: - Per-Row Download State

private struct YouTubeResultRow: View {
    let result: YouTubeResult
    let isStreaming: Bool
    let isCurrentTrack: Bool
    let isDownloading: Bool
    let isDownloaded: Bool
    let onPlay: () -> Void
    let onDownloadStarted: () -> Void
    let onDownloaded: (URL) -> Void
    let onDownloadCancelled: () -> Void
    let onDownloadError: (Error) -> Void

    @ObservedObject var library: AudioLibrary
    @EnvironmentObject private var player: AudioPlayer
    @State private var showingDuplicateAlert = false
    @State private var showingOptions = false
    @State private var downloadTask: Task<Void, Never>? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if isStreaming {
                    ProgressView().frame(width: 24, height: 24)
                } else if isCurrentTrack {
                    Image(systemName: "waveform").foregroundStyle(.red).frame(width: 24, height: 24)
                } else {
                    Image(systemName: "play.circle").foregroundStyle(.secondary).frame(width: 24, height: 24)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title).font(.headline).lineLimit(2)
                Text(result.channelTitle).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                if result.durationSeconds > 0 {
                    Text(result.durationSeconds.mmss)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    showingOptions = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .sheet(isPresented: $showingOptions) {
            YouTubeTrackOptionsSheet(
                result: result,
                isDownloaded: isDownloaded,
                isDownloading: isDownloading,
                onDownloadStarted: onDownloadStarted,
                onDownloaded: onDownloaded,
                onDownloadCancelled: onDownloadCancelled,
                onDownloadError: onDownloadError,
                library: library
            )
            .environmentObject(player)
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        Button {
            if isDownloaded {
                showingDuplicateAlert = true
            } else if isDownloading {
                downloadTask?.cancel()
                downloadTask = nil
            } else {
                downloadTask = Task { await startDownload() }
            }
        } label: {
            ZStack {
                if isDownloading {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        .transition(.scale.combined(with: .opacity))
                } else if isDownloaded {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .font(.title3)
            .frame(width: 28, height: 28)
            .animation(.spring(response: 0.3), value: isDownloading)
            .animation(.spring(response: 0.3), value: isDownloaded)
        }
        .buttonStyle(.plain)
        .alert("Already Downloaded", isPresented: $showingDuplicateAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\"\(result.title)\" is already in your library.")
        }
    }

    private func startDownload() async {
        onDownloadStarted()
        do {
            let tempURL = try await StreamService.downloadAudioToTemp(
                for: result.id,
                title: result.title
            )
            let fileName = tempURL.lastPathComponent
            try library.copyToDownloads(from: tempURL, fileName: fileName)
            await library.loadExistingTracks()
            let savedURL = library.downloadsDirectory.appendingPathComponent(fileName)
            onDownloaded(savedURL)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                onDownloadCancelled()
            } else {
                onDownloadError(error)
            }
        }
    }

}

// MARK: - Main View

@MainActor
struct YouTubeSearchView: View {
    @EnvironmentObject private var player: AudioPlayer

    @State private var query             = ""
    @State private var results: [YouTubeResult] = []
    @State private var isSearching       = false
    @State private var isLoadingID: String?      = nil
    @State private var downloadingIDs: Set<String> = []
    @State private var downloadedIDs:  Set<String> = []
    @State private var toast: ToastType?             = nil
    @State private var toastTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?
    @State private var autoPlayNextSearch = false

    @ObservedObject var library: AudioLibrary

    var body: some View {
        NavigationStack {
            List(results) { result in
                resultRow(result)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }
            .scrollContentBackground(.hidden)
            .background { TabBackgroundDecoration() }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search songs, artists…")
            .onChange(of: query) { _, newValue in
                searchTask?.cancel()
                guard !newValue.trimmingCharacters(in: .whitespaces).isEmpty else {
                    results = []
                    return
                }
                searchTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await performSearch()
                    if autoPlayNextSearch {
                        autoPlayNextSearch = false
                        if let first = results.first,
                           let index = results.firstIndex(where: { $0.id == first.id }) {
                            player.setYouTubeQueue(results, startingAt: index)
                        }
                        if let first = results.first {
                            await playResult(first)
                        }
                    }
                }
            }
            .scrollIndicators(.visible)
            .overlay { overlayView }
            .overlay(alignment: .bottom) { toastOverlay }
            .onChange(of: library.tracks) { _, tracks in
                let savedTitles = Set(tracks.map { $0.title })
                downloadedIDs = downloadedIDs.filter { id in
                    results.first(where: { $0.id == id }).map { savedTitles.contains($0.title) } ?? false
                }
            }
            .onReceive(IntentBridge.shared.$pendingYouTubeSearch.compactMap { $0 }) { searchQuery in
                IntentBridge.shared.pendingYouTubeSearch = nil
                query = searchQuery
                // onChange(of: query) handles the search — no second task needed
            }
            .onReceive(IntentBridge.shared.$pendingYouTubePlayReady.compactMap { $0 }) { searchQuery in
                IntentBridge.shared.pendingYouTubePlayReady = nil
                autoPlayNextSearch = true
                query = searchQuery
            }
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
            onDownloaded: { (savedURL: URL) in
                withAnimation {
                    downloadingIDs.remove(result.id)
                    _ = downloadedIDs.insert(result.id)
                }
                showToast(.success("Saved to library"))
            },
            onDownloadCancelled: {
                withAnimation { _ = downloadingIDs.remove(result.id) }
            },
            onDownloadError: { (error: Error) in
                withAnimation { _ = downloadingIDs.remove(result.id) }
                showToast(.error(error.localizedDescription))
            },
            library: library
        )
    }

    // MARK: - Stream Action

    private func playResult(_ result: YouTubeResult) async {
        guard isLoadingID == nil else { return }
        isLoadingID = result.id

        // Find the tapped result's index and register the full list as the queue
        if let index = results.firstIndex(where: { $0.id == result.id }) {
            player.setYouTubeQueue(results, startingAt: index)
        }

        do {
            let stream = try await StreamService.getStreamURL(for: result.id)
            guard let url = URL(string: stream.url) else {
                showToast(.error("Invalid stream URL"))
                isLoadingID = nil
                return
            }
            player.playYouTube(
                url: url,
                title: stream.title,
                artist: stream.artist,
                duration: stream.duration,
                videoID: result.id
            )
        } catch {
            showToast(.error(error.localizedDescription))
        }
        isLoadingID = nil
    }

    // MARK: - Search

    private func performSearch() async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        results = []
        let savedTitles = Set(library.tracks.map { $0.title })
        do {
            let fetched = try await YouTubeService.search(query)
            results = fetched
            downloadedIDs = Set(fetched.filter { savedTitles.contains($0.title) }.map { $0.id })
        } catch {
            isSearching = false
            if error is CancellationError { return }
            if (error as? URLError)?.code == .cancelled { return }
            showToast(.error(error.localizedDescription))
            return
        }
        isSearching = false
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
        if isSearching {
            ProgressView("Searching…")
        } else if results.isEmpty && !query.isEmpty {
            ContentUnavailableView("No results", systemImage: "magnifyingglass")
        } else if results.isEmpty {
            ContentUnavailableView(
                "Search on YouTube",
                systemImage: "play.rectangle",
                description: Text("Type a song or artist to get started")
            )
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

// MARK: - YouTube Track Options Sheet

struct YouTubeTrackOptionsSheet: View {
    let result: YouTubeResult
    let isDownloaded: Bool
    let isDownloading: Bool

    let onDownloadStarted: () -> Void
    let onDownloaded: (URL) -> Void
    let onDownloadCancelled: () -> Void
    let onDownloadError: (Error) -> Void

    @ObservedObject var library: AudioLibrary
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var showingAddToPlaylist = false
    @State private var isSavingToLibrary = false
    @State private var isSavingToFiles = false
    @State private var saveToLibraryTask: Task<Void, Never>? = nil
    @State private var saveToFilesTask: Task<Void, Never>? = nil

    private var thumbnailURL: URL? {
        URL(string: "https://img.youtube.com/vi/\(result.id)/mqdefault.jpg")
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 36)

                // Thumbnail
                AsyncImage(url: thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Color(white: 0.2)
                            .overlay(
                                Image(systemName: "play.rectangle")
                                    .font(.system(size: 48))
                                    .foregroundStyle(Color(white: 0.5))
                            )
                    }
                }
                .frame(width: 200, height: 113)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 20)

                // Title + channel
                VStack(spacing: 6) {
                    Text(result.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Text(result.channelTitle)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(white: 0.6))
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.bottom, 32)

                // Options
                VStack(spacing: 0) {
                    optionRow(
                        icon: isDownloaded ? "checkmark.circle.fill" : "music.note.list",
                        title: isDownloaded ? "Saved to library" : "Add to saved songs",
                        iconColor: isDownloaded ? .green : .white,
                        isLoading: isSavingToLibrary
                    ) {
                        guard !isDownloaded, !isSavingToLibrary else { return }
                        isSavingToLibrary = true
                        saveToLibraryTask = Task { await saveToLibrary() }
                    }

                    optionRow(icon: "play.circle", title: "Add to player queue") {
                        player.addYouTubeResultToQueue(result)
                        dismiss()
                    }

                    optionRow(icon: "text.badge.plus", title: "Add to playlist") {
                        showingAddToPlaylist = true
                    }

                    optionRow(
                        icon: "arrow.down.to.line",
                        title: isSavingToFiles ? "Preparing…" : "Download",
                        isLoading: isSavingToFiles
                    ) {
                        guard !isSavingToFiles else { return }
                        isSavingToFiles = true
                        saveToFilesTask = Task { await saveToFiles() }
                    }
                }

                Spacer(minLength: 24)

                Button { dismiss() } label: {
                    Text("CANCEL")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color(white: 0.15))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(20)
        .sheet(isPresented: $showingAddToPlaylist) {
            YouTubeAddToPlaylistSheet(result: result, library: library,
                                      onDownloadStarted: onDownloadStarted,
                                      onDownloaded: onDownloaded,
                                      onDownloadCancelled: onDownloadCancelled,
                                      onDownloadError: onDownloadError)
        }
    }

    private func optionRow(icon: String, title: String, iconColor: Color = .white, isLoading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 20) {
                if isLoading {
                    ProgressView()
                        .frame(width: 28)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(iconColor)
                        .frame(width: 28)
                }
                Text(title)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Saves the song into the app library (Songs tab)
    private func saveToLibrary() async {
        onDownloadStarted()
        do {
            let tempURL = try await StreamService.downloadAudioToTemp(for: result.id, title: result.title)
            let fileName = tempURL.lastPathComponent
            try library.copyToDownloads(from: tempURL, fileName: fileName)
            await library.loadExistingTracks()
            let savedURL = library.downloadsDirectory.appendingPathComponent(fileName)
            onDownloaded(savedURL)
            isSavingToLibrary = false
            dismiss()
        } catch {
            isSavingToLibrary = false
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                onDownloadCancelled()
            } else {
                onDownloadError(error)
            }
        }
    }

    // Downloads to a temp file and presents the iOS Save to Files / share sheet
    private func saveToFiles() async {
        do {
            let tempURL = try await StreamService.downloadAudioToTemp(for: result.id, title: result.title)
            isSavingToFiles = false
            presentShareSheet(url: tempURL)
        } catch {
            isSavingToFiles = false
            if !(error is CancellationError || (error as? URLError)?.code == .cancelled) {
                onDownloadError(error)
            }
        }
    }

    private func presentShareSheet(url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        top.present(activityVC, animated: true)
    }
}

// MARK: - YouTube Add to Playlist Sheet

private struct YouTubeAddToPlaylistSheet: View {
    let result: YouTubeResult
    @ObservedObject var library: AudioLibrary

    let onDownloadStarted: () -> Void
    let onDownloaded: (URL) -> Void
    let onDownloadCancelled: () -> Void
    let onDownloadError: (Error) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var downloadingFor: UUID? = nil

    var body: some View {
        NavigationStack {
            List(library.playlists, id: \.id) { playlist in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name).font(.headline).lineLimit(1)
                        Text("\(playlist.trackIDs.count) songs").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if downloadingFor == playlist.id {
                        ProgressView().frame(width: 24, height: 24)
                    } else {
                        Button {
                            downloadAndAdd(to: playlist)
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if library.playlists.isEmpty {
                    ContentUnavailableView("No playlists", systemImage: "music.note.list",
                                          description: Text("Create a playlist in the Library tab first."))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(20)
    }

    private func downloadAndAdd(to playlist: Playlist) {
        let playlistID = playlist.id
        downloadingFor = playlistID
        onDownloadStarted()
        Task {
            do {
                let tempURL = try await StreamService.downloadAudioToTemp(for: result.id, title: result.title)
                let fileName = tempURL.lastPathComponent
                try library.copyToDownloads(from: tempURL, fileName: fileName)
                await library.loadExistingTracks()
                let savedURL = library.downloadsDirectory.appendingPathComponent(fileName)
                // Match by filename — more reliable than full URL comparison
                if let track = library.tracks.first(where: { $0.url.lastPathComponent == fileName }),
                   let target = library.playlists.first(where: { $0.id == playlistID }) {
                    library.addTrack(track, to: target)
                }
                // Mark as saved in the search results (Add to saved songs state)
                onDownloaded(savedURL)
                downloadingFor = nil
                dismiss()
            } catch {
                downloadingFor = nil
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    onDownloadCancelled()
                } else {
                    onDownloadError(error)
                }
            }
        }
    }
}
