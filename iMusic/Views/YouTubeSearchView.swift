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
    @State private var showingDuplicateAlert = false
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
                downloadButton
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
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
                showToast(.success("Saved to \"\(savedURL.deletingLastPathComponent().lastPathComponent)\""))
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
