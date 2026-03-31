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

    private let fileManager = FileManager.default

    // MARK: - Persistence

    private var playlistsFileURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("playlists.json")
    }

    init() {
        loadPlaylists()
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

    func createPlaylist(name: String) {
        playlists.append(Playlist(name: name))
        savePlaylists()
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

            // Each task is nonisolated — runs truly in parallel on the thread pool
            let results: [(index: Int, track: Track, path: String, meta: CachedMeta)] =
                await withTaskGroup(of: (Int, Track, String, CachedMeta).self) { group in
                    for (index, url) in audioURLs.enumerated() {
                        group.addTask {
                            let path = url.path
                            let modDate = (try? url.resourceValues(
                                forKeys: [.contentModificationDateKey]
                            ).contentModificationDate) ?? .distantPast

                            // Cache hit — skip AVFoundation entirely
                            if let cached = cache[path],
                               abs(cached.modDate.timeIntervalSince(modDate)) < 1 {
                                return await (index,
                                        Track(url: url, title: cached.title, artist: cached.artist,
                                              album: cached.album, duration: cached.duration),
                                        path, cached)
                            }

                            // Cache miss — read metadata off the thread pool
                            let m = await AudioLibrary.readMeta(from: url)
                            let newMeta = CachedMeta(title: m.title, artist: m.artist,
                                                     album: m.album, duration: m.duration,
                                                     modDate: modDate)
                            return await (index,
                                    Track(url: url, title: m.title, artist: m.artist,
                                          album: m.album, duration: m.duration),
                                    path, newMeta)
                        }
                    }
                    var out: [(Int, Track, String, CachedMeta)] = []
                    for await r in group { out.append(r) }
                    return out.map { (index: $0.0, track: $0.1, path: $0.2, meta: $0.3) }
                }

            // Persist updated cache, pruning deleted files
            let validPaths = Set(audioURLs.map { $0.path })
            var updatedCache = cache.filter { validPaths.contains($0.key) }
            for r in results { updatedCache[r.path] = r.meta }
            saveMetaCache(updatedCache)

            self.tracks = results.sorted { $0.index < $1.index }.map { $0.track }

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
