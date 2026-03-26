import Combine
import Foundation
import UniformTypeIdentifiers
import AVFoundation
import SwiftUI
import AVKit

@MainActor
final class AudioLibrary: ObservableObject {
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

            let newTracks = await withTaskGroup(of: (Int, Track).self) { group -> [Track] in
                for (index, url) in audioURLs.enumerated() {
                    group.addTask {
                        let track = await self.buildTrack(from: url)
                        return (index, track)
                    }
                }
                var indexed: [(Int, Track)] = []
                for await pair in group { indexed.append(pair) }
                return indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
            }

            self.tracks = newTracks

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

    private func buildTrack(from url: URL) async -> Track {
        let asset = AVURLAsset(url: url)
        var title    = url.deletingPathExtension().lastPathComponent
        var artist: String?
        var album: String?
        var duration: TimeInterval?

        do {
            let cmDuration = try await asset.load(.duration)
            duration = cmDuration.seconds

            let metadata = try await asset.load(.commonMetadata)
            for item in metadata {
                if item.commonKey?.rawValue == "title",
                   let v = try await item.load(.stringValue) { title = v }
                if item.commonKey?.rawValue == "artist",
                   let v = try await item.load(.stringValue) { artist = v }
                if item.commonKey?.rawValue == "albumName",
                   let v = try await item.load(.stringValue) { album = v }
            }
        } catch {
            print("Failed loading metadata:", error)
        }

        return Track(url: url, title: title, artist: artist, album: album, duration: duration)
    }
}
