import Combine
import Foundation
import UniformTypeIdentifiers
import AVFoundation
import SwiftUI
import AVKit

@MainActor
final class AudioLibrary: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var playlists: [Playlist] = []

    private let fileManager = FileManager.default
    private let importFolderName = "ImportedAudio"

    init() {
        Task { await loadExistingTracks() }
    }

    var importDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(importFolderName, isDirectory: true)
    }
    
    func addTrack(_ track: Track, to playlist: Playlist) {
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index].trackIDs.insert(track.id)
            // This triggers the UI to refresh
            objectWillChange.send()
        }
    }
    
    func removeTrack(_ track: Track, from playlist: Playlist) {
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index].trackIDs.remove(track.id)
            objectWillChange.send()
        }
    }
    
    func createPlaylist(name: String) {
        // Because we added the default value in the struct init, this works again:
        let newPlaylist = Playlist(name: name)
        playlists.append(newPlaylist)
    }

    func loadExistingTracks() async {
        do {
            try ensureImportDirectory()

            let urls = try fileManager.contentsOfDirectory(
                at: importDirectory,
                includingPropertiesForKeys: nil
            )

            let audioURLs = urls
                .filter { $0.isFileURL }
                .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }

            let newTracks = await withTaskGroup(of: Track.self) { group -> [Track] in
                for url in audioURLs {
                    group.addTask {
                        await self.buildTrack(from: url)
                    }
                }

                var tracks: [Track] = []

                for await track in group {
                    tracks.append(track)
                }

                return tracks
            }

            await MainActor.run {
                self.tracks = newTracks
            }

        } catch {
            print("AudioLibrary load error: \(error)")
        }
    }

    func importFiles(from urls: [URL]) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask {
                    await self.importFile(from: url)
                }
            }
        }
        await loadExistingTracks()
    }

    func importFile(from url: URL) async {
        do {
            try ensureImportDirectory()
            let destURL = uniqueDestinationURL(forOriginal: url)

            var didStartAccessing = false
            if url.startAccessingSecurityScopedResource() { didStartAccessing = true }
            defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }

            if url.standardizedFileURL != destURL.standardizedFileURL {
                try fileManager.copyItem(at: url, to: destURL)
            }
        } catch {
            print("Failed to import file: \(error)")
        }
    }

    private func ensureImportDirectory() throws {
        if !fileManager.fileExists(atPath: importDirectory.path) {
            try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        }
    }

    private func uniqueDestinationURL(forOriginal url: URL) -> URL {
        let base = importDirectory.appendingPathComponent(url.lastPathComponent)
        if !fileManager.fileExists(atPath: base.path) { return base }
        let name = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        var counter = 1
        while true {
            let candidate = importDirectory.appendingPathComponent("\(name) (\(counter)).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
    
    @MainActor
    func importTrack(from url: URL) {
        // 1. Gain security permission
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        
        do {
            // 2. Setup permanent storage path
            let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let destinationURL = documentsDirectory.appendingPathComponent(url.lastPathComponent)
            
            // 3. Copy file to Documents folder
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: url, to: destinationURL)
            
            // 4. Create Track using your memberwise initializer
            let newTrack = Track(
                id: UUID(),
                url: destinationURL,
                title: url.deletingPathExtension().lastPathComponent,
                artist: "Unknown Artist",
                album: nil,
                duration: nil
            )
            
            self.tracks.append(newTrack)
            
        } catch {
            print("Import failed: \(error.localizedDescription)")
        }
    }
    
    private func buildTrack(from url: URL) async -> Track {
        let asset = AVURLAsset(url: url)

        var title = url.deletingPathExtension().lastPathComponent
        var artist: String?
        var album: String?
        var duration: TimeInterval?

        do {
            let cmDuration = try await asset.load(.duration)
            duration = cmDuration.seconds

            let metadata = try await asset.load(.commonMetadata)

            for item in metadata {
                if item.commonKey?.rawValue == "title",
                   let v = try await item.load(.stringValue) {
                    title = v
                }

                if item.commonKey?.rawValue == "artist",
                   let v = try await item.load(.stringValue) {
                    artist = v
                }

                if item.commonKey?.rawValue == "albumName",
                   let v = try await item.load(.stringValue) {
                    album = v
                }
            }

        } catch {
            print("Failed loading metadata:", error)
        }

        return Track(
            url: url,
            title: title,
            artist: artist,
            album: album,
            duration: duration
        )
    }

}
