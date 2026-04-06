import Combine
import Foundation
import UniformTypeIdentifiers
import AVFoundation
import SwiftUI
import AVKit

@MainActor
final class AudioLibrary: ObservableObject {
    @MainActor static let shared = AudioLibrary()

    @Published private(set) var tracks: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published private(set) var likedTrackIDs: Set<UUID> = []
    @Published private(set) var likedYouTubeVideoIDs: Set<String> = []

    private let fileManager = FileManager.default

    // MARK: - Persistence

    private var playlistsFileURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("playlists.json")
    }

    private var likedTrackIDsFileURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("liked_tracks.json")
    }

    private var likedYouTubeVideoIDsFileURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("liked_youtube_videos.json")
    }

    init() {
        loadPlaylists()
        loadLikedTrackIDs()
        loadLikedYouTubeVideoIDs()
        Task { await loadExistingTracks() }
    }

    func ensureLoaded() async {
        if tracks.isEmpty {
            await loadExistingTracks()
        }
    }

    // MARK: - Directory

    var downloadsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Downloads", isDirectory: true)
    }

    private func ensureDownloadsDirectory() throws {
        if !fileManager.fileExists(atPath: downloadsDirectory.path) {
            try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Playlist CRUD

    func createPlaylist(name: String, isYouTubePlaylist: Bool = false) {
        playlists.append(Playlist(name: name, isYouTubePlaylist: isYouTubePlaylist))
        savePlaylists()
    }

    /// Saves a YouTube playlist reference to the library without downloading any audio.
    /// If a linked entry for the same YouTube playlist ID already exists it is not duplicated.
    func linkYouTubePlaylist(id playlistID: String, name: String, thumbnailURL: String,
                              itemCount: Int, channelTitle: String) {
        guard !playlists.contains(where: { $0.linkedYouTubePlaylist?.playlistID == playlistID }) else { return }
        let link = Playlist.LinkedYouTubePlaylist(
            playlistID: playlistID, thumbnailURL: thumbnailURL,
            itemCount: itemCount, channelTitle: channelTitle
        )
        playlists.append(Playlist(name: name, isYouTubePlaylist: true, linkedYouTubePlaylist: link))
        savePlaylists()
    }

    /// Adds multiple tracks to a playlist in one shot and saves once.
    func addTracks(_ tracks: [Track], to playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        for track in tracks { playlists[index].trackIDs.insert(track.id) }
        savePlaylists()
        objectWillChange.send()
    }

    func deletePlaylist(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        savePlaylists()
    }

    func addTrack(_ track: Track, to playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].trackIDs.insert(track.id)
        savePlaylists()
        objectWillChange.send()
    }

    func removeTrack(_ track: Track, from playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].trackIDs.remove(track.id)
        savePlaylists()
        objectWillChange.send()
    }

    func renamePlaylist(_ playlist: Playlist, to newName: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].name = newName
        savePlaylists()
    }

    // MARK: - Liked Tracks

    func isLiked(_ track: Track) -> Bool {
        likedTrackIDs.contains(track.id)
    }

    func toggleLike(_ track: Track) {
        if likedTrackIDs.contains(track.id) {
            likedTrackIDs.remove(track.id)
        } else {
            likedTrackIDs.insert(track.id)
        }
        saveLikedTrackIDs()
    }

    private func saveLikedTrackIDs() {
        guard let data = try? JSONEncoder().encode(Array(likedTrackIDs)) else { return }
        try? data.write(to: likedTrackIDsFileURL, options: .atomic)
    }

    private func loadLikedTrackIDs() {
        guard let data = try? Data(contentsOf: likedTrackIDsFileURL),
              let ids = try? JSONDecoder().decode([UUID].self, from: data)
        else { return }
        likedTrackIDs = Set(ids)
    }

    func isYouTubeLiked(videoID: String) -> Bool {
        likedYouTubeVideoIDs.contains(videoID)
    }

    func toggleYouTubeLike(videoID: String) {
        if likedYouTubeVideoIDs.contains(videoID) {
            likedYouTubeVideoIDs.remove(videoID)
        } else {
            likedYouTubeVideoIDs.insert(videoID)
        }
        savelikedYouTubeVideoIDs()
    }

    private func savelikedYouTubeVideoIDs() {
        guard let data = try? JSONEncoder().encode(Array(likedYouTubeVideoIDs)) else { return }
        try? data.write(to: likedYouTubeVideoIDsFileURL, options: .atomic)
    }

    private func loadLikedYouTubeVideoIDs() {
        guard let data = try? Data(contentsOf: likedYouTubeVideoIDsFileURL),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        likedYouTubeVideoIDs = Set(ids)
    }

    // MARK: - Metadata

    /// Updates the title/artist for a local track.
    /// The file is never renamed — the cache key is the filename, so edits
    /// survive app-container path changes (reinstalls, Xcode rebuilds) and
    /// re-importing the original file no longer creates duplicates.
    func updateTrackMetadata(_ track: Track, title: String, artist: String?) {
        let newTitle  = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? track.title
                        : title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? artist?.trimmingCharacters(in: .whitespacesAndNewlines)
                        : nil

        var cache    = loadMetaCache()
        let cacheKey = track.url.lastPathComponent
        // Fall back to a synthetic entry so edits always succeed even on a cold cache.
        let existing = cache[cacheKey] ?? cache[track.url.path] ?? CachedMeta(
            title: track.title, artist: track.artist,
            album: track.album, duration: track.duration, modDate: Date()
        )

        // ── Persist updated metadata (filename key, no file rename) ───────────
        cache[cacheKey] = CachedMeta(
            title: newTitle, artist: newArtist,
            album: existing.album, duration: existing.duration, modDate: existing.modDate
        )
        // Clean up any stale full-path key left from the old format
        cache.removeValue(forKey: track.url.path)
        saveMetaCache(cache)

        // ── Rebuild the in-memory track list ──────────────────────────────────
        let updatedTrack = Track(url: track.url, title: newTitle, artist: newArtist,
                                 album: existing.album, duration: existing.duration)
        tracks = tracks.map { $0.id == track.id ? updatedTrack : $0 }

        // ── Sync the player so NowPlayingView updates immediately ─────────────
        AudioPlayer.shared.trackMetadataUpdated(oldTrack: track, newTrack: updatedTrack)
    }

    func deleteTrack(_ track: Track) async {
        if fileManager.fileExists(atPath: track.url.path) {
            try? fileManager.removeItem(at: track.url)
        }
        for index in playlists.indices {
            playlists[index].trackIDs.remove(track.id)
        }
        savePlaylists()
        await loadExistingTracks()
    }

    // MARK: - Playlist Persistence

    private func savePlaylists() {
        do {
            let data = try JSONEncoder().encode(playlists)
            try data.write(to: playlistsFileURL, options: .atomic)
        } catch {
            print("Failed to save playlists: \(error)")
        }
    }

    private func loadPlaylists() {
        guard fileManager.fileExists(atPath: playlistsFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: playlistsFileURL)
            playlists = try JSONDecoder().decode([Playlist].self, from: data)
        } catch {
            print("Failed to load playlists: \(error)")
        }
    }

    // MARK: - Metadata Cache

    private struct CachedMeta: Codable {
        let title: String
        let artist: String?
        let album: String?
        let duration: TimeInterval?
        let modDate: Date
    }

    private var metaCacheURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("track_meta_cache.json")
    }

    private func loadMetaCache() -> [String: CachedMeta] {
        guard let data = try? Data(contentsOf: metaCacheURL),
              let cache = try? JSONDecoder().decode([String: CachedMeta].self, from: data)
        else { return [:] }
        return cache
    }

    private func saveMetaCache(_ cache: [String: CachedMeta]) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: metaCacheURL, options: .atomic)
    }

    // MARK: - Track Loading

    func loadExistingTracks() async {
        do {
            try ensureDownloadsDirectory()

            let urls = try fileManager.contentsOfDirectory(
                at: downloadsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            )

            let audioURLs = urls
                .filter { $0.isFileURL }
                .sorted { a, b in
                    let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return dateA > dateB
                }

            let cache = loadMetaCache()

            // Each task is nonisolated — runs truly in parallel on the thread pool.
            // The tuple's `filename` member carries only the last path component so
            // the metadata cache is always keyed by filename, never by full path.
            // This ensures cache hits survive sandbox container path changes across
            // app reinstalls or Xcode rebuilds.
            let results: [(index: Int, track: Track, filename: String, meta: CachedMeta)] =
                await withTaskGroup(of: (Int, Track, String, CachedMeta).self) { group in
                    for (index, url) in audioURLs.enumerated() {
                        group.addTask {
                            let fullPath = url.path
                            let filename = url.lastPathComponent
                            let modDate = (try? url.resourceValues(
                                forKeys: [.contentModificationDateKey]
                            ).contentModificationDate) ?? .distantPast

                            // Cache hit — try filename key first, fall back to full path (migration)
                            if let cached = cache[filename] ?? cache[fullPath],
                               abs(cached.modDate.timeIntervalSince(modDate)) < 1 {
                                return await (index,
                                        Track(url: url, title: cached.title, artist: cached.artist,
                                              album: cached.album, duration: cached.duration),
                                        filename, cached)
                            }

                            // Cache miss — read metadata off the thread pool
                            let m = await AudioLibrary.readMeta(from: url)
                            let newMeta = CachedMeta(title: m.title, artist: m.artist,
                                                     album: m.album, duration: m.duration,
                                                     modDate: modDate)
                            return await (index,
                                    Track(url: url, title: m.title, artist: m.artist,
                                          album: m.album, duration: m.duration),
                                    filename, newMeta)
                        }
                    }
                    var out: [(Int, Track, String, CachedMeta)] = []
                    for await r in group { out.append(r) }
                    return out.map { (index: $0.0, track: $0.1, filename: $0.2, meta: $0.3) }
                }

            // Persist updated cache using filename keys, pruning deleted files.
            // Always write under the filename key so the next launch's lookup hits
            // cache[filename] correctly.
            let validFilenames = Set(audioURLs.map { $0.lastPathComponent })
            var updatedCache = cache.filter { validFilenames.contains($0.key) }
            for r in results { updatedCache[r.filename] = r.meta }
            saveMetaCache(updatedCache)

            self.tracks = results.sorted { $0.index < $1.index }.map { $0.track }

            // Prune stale track IDs from all playlists only when we have a non-empty
            // track list. An empty result (e.g. the Downloads directory is temporarily
            // inaccessible on a cold launch) must never be used to wipe playlist
            // membership — that would permanently destroy the user's playlists.
            guard !self.tracks.isEmpty else { return }
            let validIDs = Set(self.tracks.map { $0.id })
            var playlistsChanged = false
            for index in playlists.indices {
                let before = playlists[index].trackIDs.count
                playlists[index].trackIDs.formIntersection(validIDs)
                if playlists[index].trackIDs.count != before { playlistsChanged = true }
            }
            if playlistsChanged { savePlaylists() }

        } catch {
            print("AudioLibrary load error: \(error)")
        }
    }

    // MARK: - Import

    @MainActor
    func importTrack(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            try ensureDownloadsDirectory()
            let destURL = downloadsDirectory.appendingPathComponent(url.lastPathComponent)

            guard !fileManager.fileExists(atPath: destURL.path) else { return }

            if url.standardizedFileURL != destURL.standardizedFileURL {
                try fileManager.copyItem(at: url, to: destURL)
                try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destURL.path)
            }

            Task { await loadExistingTracks() }

        } catch {
            print("Import failed: \(error.localizedDescription)")
        }
    }

    /// Copies a downloaded file into Downloads. Skips silently if already present.
    func copyToDownloads(from sourceURL: URL, fileName: String) throws {
        try ensureDownloadsDirectory()
        let destURL = downloadsDirectory.appendingPathComponent(fileName)
        guard !fileManager.fileExists(atPath: destURL.path) else { return }
        try fileManager.copyItem(at: sourceURL, to: destURL)
        try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destURL.path)
    }

    /// For a YouTube stream track, returns the matching downloaded local file by title.
    func localTrack(matching track: Track) -> Track {
        guard track.isYouTubeTrack else { return track }
        return tracks.first { $0.title == track.title } ?? track
    }

    // MARK: - Helpers

    // nonisolated + static so task-group children run on the thread pool, not the main actor
    nonisolated private static func readMeta(
        from url: URL
    ) async -> (title: String, artist: String?, album: String?, duration: TimeInterval?) {
        let asset = AVURLAsset(url: url)
        var title    = url.deletingPathExtension().lastPathComponent
        var artist: String?
        var album: String?
        var duration: TimeInterval?

        do {
            duration = try await asset.load(.duration).seconds
            for item in try await asset.load(.commonMetadata) {
                switch item.commonKey?.rawValue {
                case "title":     if let v = try? await item.load(.stringValue) { title = v }
                case "artist":    if let v = try? await item.load(.stringValue) { artist = v }
                case "albumName": if let v = try? await item.load(.stringValue) { album = v }
                default: break
                }
            }
        } catch {}

        return (title, artist, album, duration)
    }
}
