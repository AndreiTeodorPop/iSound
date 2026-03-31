import AppIntents
import AVFoundation

private struct IntentError: LocalizedError {
    let errorDescription: String?
}

// MARK: - Play YouTube (search + auto-play first result)

struct PlayYouTubeIntent: AppIntent {
    static var title: LocalizedStringResource = "Play a Song on YouTube"
    static var description = IntentDescription("Search YouTube and immediately play the top result in iMusic")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Song or Artist", description: "What to play on YouTube", requestValueDialog: "Which track would you like to play from YouTube?")
    var songName: String

    func perform() async throws -> some IntentResult {
        let results = try await YouTubeService.search(songName)
        guard let first = results.first else {
            throw IntentError(errorDescription: "I couldn't find \"\(songName)\" on YouTube")
        }
        let stream = try await StreamService.getStreamURL(for: first.id)
        guard let url = URL(string: stream.url) else {
            throw IntentError(errorDescription: "Couldn't get a stream for \"\(songName)\"")
        }
        await MainActor.run {
            AudioPlayer.shared.configureAudioSession()
            AudioPlayer.shared.setYouTubeQueue(results, startingAt: 0)
            AudioPlayer.shared.playYouTube(
                url: url, title: stream.title, artist: stream.artist,
                duration: stream.duration, videoID: first.id
            )
        }
        return .result()
    }
}

// MARK: - Play Saved Song

struct PlaySavedSongIntent: AppIntent {
    static var title: LocalizedStringResource = "Play a Saved Song"
    static var description = IntentDescription("Play a song from your iMusic library")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Song Name", description: "Name of the saved song to play", requestValueDialog: "Which song would you like to play?")
    var songName: String

    func perform() async throws -> some IntentResult {
        let library = await AudioLibrary.shared
        await library.ensureLoaded()
        let tracks = await MainActor.run { library.tracks }
        let q = songName.lowercased()
        guard let track = tracks.first(where: {
            $0.title.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) == true)
        }) else {
            throw IntentError(errorDescription: "I couldn't find \"\(songName)\" in your library")
        }
        await MainActor.run {
            AudioPlayer.shared.configureAudioSession()
            AudioPlayer.shared.play(track: track, queue: tracks)
        }
        return .result()
    }
}

// MARK: - Play Playlist

struct PlayPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Play a Playlist"
    static var description = IntentDescription("Shuffle and play a playlist from your iMusic library")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Playlist Name", description: "Name of the playlist to play", requestValueDialog: "Which playlist would you like to play?")
    var playlistName: String

    func perform() async throws -> some IntentResult {
        let library = await AudioLibrary.shared
        await library.ensureLoaded()
        let (tracks, playlists) = await MainActor.run { (library.tracks, library.playlists) }
        let q = playlistName.lowercased()
        guard let playlist = playlists.first(where: { $0.name.lowercased().contains(q) }) else {
            throw IntentError(errorDescription: "I couldn't find a playlist named \"\(playlistName)\"")
        }
        let playlistTracks = tracks.filter { playlist.trackIDs.contains($0.id) }.shuffled()
        guard !playlistTracks.isEmpty else {
            throw IntentError(errorDescription: "The playlist \"\(playlist.name)\" is empty")
        }
        await MainActor.run {
            AudioPlayer.shared.configureAudioSession()
            AudioPlayer.shared.playAll(tracks: playlistTracks, playlistName: playlist.name)
        }
        return .result()
    }
}

// MARK: - Pause

struct PauseMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Music"
    static var description = IntentDescription("Pause the currently playing song in iMusic")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            if AudioPlayer.shared.isPlaying {
                AudioPlayer.shared.togglePlayPause()
            }
        }
        return .result(dialog: "Paused")
    }
}

// MARK: - Resume

struct ResumeMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Music"
    static var description = IntentDescription("Resume playing music in iMusic")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            let player = AudioPlayer.shared
            if !player.isPlaying && player.currentTrack != nil {
                player.togglePlayPause()
            }
        }
        return .result()
    }
}

// MARK: - Skip

struct SkipTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Track"
    static var description = IntentDescription("Skip to the next song in iMusic")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            AudioPlayer.shared.playNext()
        }
        return .result(dialog: "Skipped")
    }
}

// MARK: - Previous Track

struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description = IntentDescription("Go back to the previous song in iMusic")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            AudioPlayer.shared.playPrevious()
        }
        return .result(dialog: "Previous track")
    }
}

// MARK: - Siri Shortcuts

struct iMusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayYouTubeIntent(),
            phrases: [
                "Play a song on YouTube in \(.applicationName)",
                "Play music on YouTube in \(.applicationName)"
            ],
            shortTitle: "Play on YouTube",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PlaySavedSongIntent(),
            phrases: [
                "Play saved song in \(.applicationName)",
                "Play a saved song in \(.applicationName)"
            ],
            shortTitle: "Play Saved Song",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play playlist in \(.applicationName)",
                "Play a playlist in \(.applicationName)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: PauseMusicIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Pause music in \(.applicationName)"
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeMusicIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume music in \(.applicationName)"
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: SkipTrackIntent(),
            phrases: [
                "Skip in \(.applicationName)",
                "Next song in \(.applicationName)"
            ],
            shortTitle: "Skip Track",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: PreviousTrackIntent(),
            phrases: [
                "Previous in \(.applicationName)",
                "Previous song in \(.applicationName)"
            ],
            shortTitle: "Previous Track",
            systemImageName: "backward.fill"
        )
    }
}
