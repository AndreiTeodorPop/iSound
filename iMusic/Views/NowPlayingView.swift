import SwiftUI
import AVKit
import Combine

struct NowPlayingView: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) var dismiss

    @ObservedObject var library: AudioLibrary

    @State private var showingQueue  = false
    @State private var showingLyrics = false
    @State private var showingOptions        = false
    @State private var toast: ToastType?
    @State private var toastTask: Task<Void, Never>?
    @State private var isDownloadingYouTube  = false

    private var currentYouTubeVideoID: String? {
        player.currentTrack?.youtubeVideoID
    }


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
                Button { showingOptions = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .disabled(player.currentTrack == nil)
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
            HStack(spacing: 12) {
                Spacer(minLength: 44)

                VStack(spacing: 3) {
                    let title = player.currentTrack?.title ?? "Unknown"
                    let artist = player.currentTrack?.artist ?? ""
                    let isYouTube = player.currentTrack?.youtubeVideoID != nil
                    Text(artist.isEmpty || isYouTube ? title : "\(artist) - \(title)")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity)

                if currentYouTubeVideoID != nil {
                    Button {
                        if !isDownloadingYouTube {
                            isDownloadingYouTube = true
                            Task { await downloadCurrentYouTubeTrack() }
                        }
                    } label: {
                        Group {
                            if isDownloadingYouTube {
                                ProgressView().frame(width: 28, height: 28)
                            } else {
                                Image(systemName: "arrow.down.circle")
                                    .foregroundStyle(.secondary)
                                    .font(.title2)
                            }
                        }
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer(minLength: 44)
                }
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

                // Lyrics
                Button { showingLyrics = true } label: {
                    Image(systemName: "quote.bubble")
                        .font(.title3)
                        .foregroundStyle(.primary)
                }
                .fullScreenCover(isPresented: $showingLyrics) {
                    LyricsFullScreenView(track: player.currentTrack)
                        .environmentObject(player)
                        .environmentObject(themeManager)
                }

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
        .sheet(isPresented: $showingOptions) { optionsSheet }
    }

    @ViewBuilder
    private var optionsSheet: some View {
        if let track = player.currentTrack {
            if let videoID = track.youtubeVideoID {
                let ytResult = YouTubeResult(
                    id: videoID,
                    title: track.title,
                    channelTitle: track.artist ?? "",
                    duration: nil
                )
                YouTubeTrackOptionsSheet(
                    result: ytResult,
                    isDownloaded: library.tracks.contains { $0.title == track.title },
                    isDownloading: false,
                    onDownloadStarted: {},
                    onDownloaded: { _ in },
                    onDownloadCancelled: {},
                    onDownloadError: { _ in },
                    library: library
                )
                .environmentObject(player)
            } else {
                let currentPlaylist = library.playlists.first {
                    $0.name == player.currentPlaylistName
                }
                TrackOptionsSheet(
                    track: track,
                    playlistContext: currentPlaylist,
                    onAddToQueue: { player.addToQueue(track) },
                    onDelete: {
                        Task {
                            await library.deleteTrack(track)
                            dismiss()
                        }
                    },
                    onRemoveFromPlaylist: currentPlaylist.map { playlist in
                        { library.removeTrack(track, from: playlist) }
                    },
                    library: library
                )
                .environmentObject(player)
            }
        }
    }


    // MARK: - YouTube Download

    private func downloadCurrentYouTubeTrack() async {
        guard let videoID = currentYouTubeVideoID,
              let title = player.currentTrack?.title else {
            isDownloadingYouTube = false
            return
        }
        do {
            let tempURL = try await StreamService.downloadAudioToTemp(for: videoID, title: title, artist: player.currentTrack?.artist)
            isDownloadingYouTube = false
            presentShareSheet(url: tempURL)
        } catch {
            isDownloadingYouTube = false
            showToast(.error("Download failed"))
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

// MARK: - Lyrics Full Screen View

private struct LyricsFullScreenView: View {
    let track: Track?

    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var syncedLines: [LyricLine]? = nil
    @State private var plainResult: LyricsResult? = nil
    @State private var isLoading = false
    @State private var showTranslated = true
    @State private var userIsScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>? = nil

    private var fetchKey: String {
        guard let t = track else { return "" }
        return "\(t.artist ?? "")|\(t.title)"
    }

    private var accentColor: Color { themeManager.current.accent }

    private var activeLineIndex: Int? {
        guard let lines = syncedLines, !lines.isEmpty else { return nil }
        let t = player.currentTime
        var result: Int? = nil
        for (i, line) in lines.enumerated() {
            if line.timestamp <= t { result = i } else { break }
        }
        return result
    }

    var body: some View {
        ZStack {
            accentColor.ignoresSafeArea()

            VStack(spacing: 0) {

                // MARK: Header
                HStack(alignment: .center) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    VStack(spacing: 3) {
                        Text(track?.title ?? "Lyrics")
                            .font(.headline.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(track?.artist ?? "")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer()
                    Color.clear.frame(width: 30, height: 30)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)

                // MARK: Lyrics Content
                Group {
                    if isLoading {
                        Spacer()
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.4)
                        Spacer()
                    } else if let lines = syncedLines, !lines.isEmpty,
                              !(showTranslated && plainResult?.translated != nil) {
                        // Show synced only when NOT switched to translated view
                        VStack(spacing: 0) {
                            SyncedLyricsScrollView(
                                lines: lines,
                                activeIndex: activeLineIndex,
                                userIsScrolling: $userIsScrolling,
                                onTap: { line in
                                    player.seek(to: line.timestamp)
                                }
                            )
                            let syncSource = plainResult?.source ?? "LrcLib"
                            Text("Source: \(syncSource)")
                                .font(.footnote.bold())
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.top, 4)
                        }
                    } else if let r = plainResult {
                        let displayText = showTranslated ? r.englishText : r.original
                        let lines = displayText
                            .components(separatedBy: "\n")
                            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

                        VStack(spacing: 0) {
                            ScrollView(showsIndicators: false) {
                                VStack(alignment: .leading, spacing: 18) {
                                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.title2.bold())
                                            .foregroundStyle(.white)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.bottom, 20)
                            }
                            .mask(
                                VStack(spacing: 0) {
                                    Rectangle()
                                    LinearGradient(
                                        colors: [.black, .clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    .frame(height: 80)
                                }
                            )

                            if let src = r.source {
                                Text("Source: \(src)")
                                    .font(.footnote.bold())
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 6)
                            }
                        }
                    } else {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "quote.bubble")
                                .font(.system(size: 50))
                                .foregroundStyle(.white.opacity(0.5))
                            Text("No lyrics found")
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                    }
                }

                // MARK: Bottom Controls
                VStack(spacing: 14) {
                    HStack {
                        if let r = plainResult {
                            ShareLink(
                                item: showTranslated ? r.englishText : r.original,
                                subject: Text(track?.title ?? ""),
                                message: Text("\(track?.artist ?? "") – \(track?.title ?? "")\n\n")
                            ) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                            }
                        } else {
                            Color.clear.frame(width: 30, height: 30)
                        }

                        Spacer()

                        if let r = plainResult, !r.isEnglish, r.translated != nil {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showTranslated.toggle()
                                }
                            } label: {
                                Label(
                                    showTranslated ? "Original" : "English",
                                    systemImage: "globe"
                                )
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.white.opacity(0.2))
                                .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 26)

                    VStack(spacing: 6) {
                        GeometryReader { geo in
                            let progress = player.duration > 0
                                ? min(player.currentTime / player.duration, 1)
                                : 0
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(.white.opacity(0.3))
                                    .frame(height: 4)
                                Capsule()
                                    .fill(.white)
                                    .frame(width: max(0, geo.size.width * progress), height: 4)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                let ratio = location.x / geo.size.width
                                player.seek(to: ratio * player.duration)
                            }
                        }
                        .frame(height: 18)

                        HStack {
                            Text(player.currentTime.mmss)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.7))
                            Spacer()
                            let remaining = max(0, player.duration - player.currentTime)
                            Text("-\(remaining.mmss)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 26)

                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 72))
                            .foregroundStyle(.white)
                    }
                    .padding(.bottom, 8)
                }
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
        }
        .task(id: fetchKey) {
            guard let track, !fetchKey.isEmpty else {
                syncedLines = nil
                plainResult = nil
                return
            }
            isLoading = true
            syncedLines = nil
            plainResult = nil
            showTranslated = true

            async let synced = LyricsService.shared.fetchSynced(
                title: track.title,
                artist: track.artist ?? ""
            )
            async let plain = LyricsService.shared.fetch(
                title: track.title,
                artist: track.artist ?? ""
            )

            let (syncedResult, plainFetched) = await (synced, plain)
            syncedLines = syncedResult
            plainResult = plainFetched
            isLoading = false
        }
    }
}

// MARK: - Synced Lyrics Scroll View

private struct SyncedLyricsScrollView: View {
    let lines: [LyricLine]
    let activeIndex: Int?
    @Binding var userIsScrolling: Bool
    let onTap: (LyricLine) -> Void

    @State private var scrollResumeTask: Task<Void, Never>? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(lines) { line in
                        let isActive = activeIndex == line.id
                        let isPast = activeIndex.map { line.id <= $0 } ?? false

                        Group {
                            if line.text.isEmpty {
                                Color.clear.frame(height: 4)
                            } else {
                                Text(line.text)
                                    .font(.title2.bold())
                                    .foregroundStyle(
                                        isActive
                                            ? .white
                                            : isPast
                                                ? .white.opacity(0.55)
                                                : .white.opacity(0.3)
                                    )
                                    .scaleEffect(isActive ? 1.04 : 1.0, anchor: .leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isActive)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        onTap(line)
                                    }
                            }
                        }
                        .id(line.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
                .padding(.top, 8)
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in
                        userIsScrolling = true
                        scrollResumeTask?.cancel()
                        scrollResumeTask = Task {
                            try? await Task.sleep(for: .seconds(4))
                            guard !Task.isCancelled else { return }
                            userIsScrolling = false
                        }
                    }
            )
            .onChange(of: activeIndex) { _, newIndex in
                guard !userIsScrolling, let index = newIndex else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .mask(
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 80)
            }
        )
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

