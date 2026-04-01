import SwiftUI
import UniformTypeIdentifiers

// MARK: - Row

private struct SavedTrackRow: View {
    let track: Track
    let isCurrent: Bool
    @ObservedObject var library: AudioLibrary
    let onTap: () -> Void
    let onDelete: () -> Void
    let onAddToQueue: () -> Void

    @EnvironmentObject private var player: AudioPlayer

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
            .sheet(isPresented: $showingOptions) {
                TrackOptionsSheet(
                    track: track,
                    playlistContext: nil,
                    onAddToQueue: onAddToQueue,
                    onDelete: onDelete,
                    onRemoveFromPlaylist: nil,
                    library: library
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
    }
}

// MARK: - Sort Sheet

private struct TrackSortSheetView: View {
    @Binding var sortOrder: SavedSongsView.TrackSortOrder
    @Binding var isPresented: Bool
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        VStack(spacing: 10) {
            Text("Sort songs")
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.top, 16)
                .padding(.bottom, 4)

            ForEach(SavedSongsView.TrackSortOrder.allCases, id: \.self) { option in
                Button {
                    withAnimation(.spring()) {
                        if option == .titleAZ {
                            sortOrder = (sortOrder == .titleAZ) ? .titleZA : .titleAZ
                        } else {
                            sortOrder = option
                        }
                        isPresented = false
                    }
                } label: {
                    let label: String = {
                        if option == .titleAZ {
                            if sortOrder == .titleAZ { return "Alphabetically (A–Z)" }
                            if sortOrder == .titleZA { return "Alphabetically (Z–A)" }
                        }
                        return option.label
                    }()
                    Text(label)
                        .font(.body).fontWeight(.semibold)
                        .foregroundStyle(themeManager.current.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(Capsule())
                }
            }

            Button {
                withAnimation(.spring()) { isPresented = false }
            } label: {
                Text("Cancel")
                    .font(.body).fontWeight(.semibold)
                    .foregroundStyle(themeManager.current.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(Capsule())
            }
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 12)
        .background(Color(.systemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Main View

struct SavedSongsView: View {
    @ObservedObject var library: AudioLibrary
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var toast: ToastType?
    @State private var toastTask: Task<Void, Never>?
    @State private var searchText = ""
    @State private var showingImporter = false
    @State private var showingSortSheet = false
    @AppStorage("savedSongsSortOrder") private var sortOrder: TrackSortOrder = .recentlyAdded

    enum TrackSortOrder: String, CaseIterable {
        case titleAZ, titleZA, recentlyAdded, defaultOrder

        static var allCases: [TrackSortOrder] { [.titleAZ, .recentlyAdded, .defaultOrder] }

        var label: String {
            switch self {
            case .titleAZ:       return "Alphabetically (A–Z)"
            case .titleZA:       return "Alphabetically (Z–A)"
            case .recentlyAdded: return "Recently added"
            case .defaultOrder:  return "Default"
            }
        }

        var isAlphabetical: Bool { self == .titleAZ || self == .titleZA }
    }

    private var sortedTracks: [Track] {
        switch sortOrder {
        case .titleAZ:       return library.tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleZA:       return library.tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending}
        case .recentlyAdded: return library.tracks
        case .defaultOrder:  return library.tracks
        }
    }

    private var filteredTracks: [Track] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return sortedTracks }
        let q = searchText.lowercased()
        return sortedTracks.filter {
            $0.title.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) == true)
        }
    }

    var body: some View {
        ZStack {
            ScrollViewReader { proxy in
            ScrollView {
                // Header
                VStack(spacing: 16) {
                    Text("Saved songs")
                        .font(.largeTitle).bold()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)

                    // Shuffle
                    Button {
                        player.playAll(tracks: filteredTracks.shuffled())
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

                    // Import
                    Button { showingImporter = true } label: {
                        Label("IMPORT SONGS", systemImage: "icloud.and.arrow.down")
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
                LazyVStack(spacing: 0) {
                    ForEach(filteredTracks, id: \.id) { track in
                        let isCurrent = player.currentTrack?.id == track.id
                        SavedTrackRow(
                            track: track,
                            isCurrent: isCurrent,
                            library: library,
                            onTap: { player.play(track: track, queue: filteredTracks) },
                            onDelete: {
                                if player.currentTrack?.id == track.id { player.stop() }
                                Task { await library.deleteTrack(track) }
                            },
                            onAddToQueue: {
                                player.addToQueue(track)
                                showToast(.success("Added to queue"))
                            }
                        )
                        .id(track.id)
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .scrollIndicators(sortOrder.isAlphabetical ? .hidden : .automatic)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: player.currentTrack != nil ? 100 : 0)
            }
            .overlay(alignment: .trailing) {
                if !filteredTracks.isEmpty && (sortOrder == .titleAZ || sortOrder == .titleZA) {
                    let available: Set<String> = Set(filteredTracks.map { track in
                        let ch = track.title.first
                        return (ch?.isLetter == true) ? String(ch!).uppercased() : "#"
                    })
                    AlphabetIndexView(proxy: proxy, availableLetters: available) { letter in
                        guard letter != "#" else {
                            return filteredTracks.first { !($0.title.first?.isLetter ?? true) }?.id
                        }
                        return filteredTracks.first { $0.title.uppercased().hasPrefix(letter) }?.id
                    }
                    .padding(.vertical, 8)
                    .padding(.trailing, 4)
                }
            }
            } // end ScrollViewReader

            // Empty state — inside ZStack so sort sheet renders above it
            if library.tracks.isEmpty {
                ContentUnavailableView(
                    "No saved songs",
                    systemImage: "music.note",
                    description: Text("Tap Import Songs to add music from your device")
                )
            } else if filteredTracks.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }

            // Sort overlay — topmost layer
            if showingSortSheet {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring()) { showingSortSheet = false } }
                TrackSortSheetView(sortOrder: $sortOrder, isPresented: $showingSortSheet)
                    .padding(.horizontal, 24)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
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
        .overlay(alignment: .bottom) {
            if let t = toast {
                ToastView(toast: t)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: toast != nil)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls { library.importTrack(from: url) }
            }
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
}
