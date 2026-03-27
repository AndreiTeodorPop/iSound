import AppIntents

// MARK: - Search YouTube

struct SearchYouTubeIntent: AppIntent {
    static var title: LocalizedStringResource = "Search YouTube for a Song"
    static var description = IntentDescription("Search for a song or artist on YouTube in iMusic")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Song or Artist", description: "What to search for on YouTube")
    var songName: String

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            IntentBridge.shared.pendingYouTubeSearch = songName
        }
        return .result()
    }
}

// MARK: - Play Saved Song

struct PlaySavedSongIntent: AppIntent {
    static var title: LocalizedStringResource = "Play a Saved Song"
    static var description = IntentDescription("Play a song from your iMusic library")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Song Name", description: "Name of the saved song to play")
    var songName: String

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            IntentBridge.shared.pendingSavedSongSearch = songName
        }
        return .result()
    }
}

// MARK: - Play Playlist

struct PlayPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Play a Playlist"
    static var description = IntentDescription("Play one of your iMusic playlists")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Playlist Name", description: "Name of the playlist to play")
    var playlistName: String

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            IntentBridge.shared.pendingPlaylistName = playlistName
        }
        return .result()
    }
}

// MARK: - Pause

struct PauseMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Music"
    static var description = IntentDescription("Pause the currently playing song in iMusic")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            IntentBridge.shared.pendingPlayerAction = .pause
        }
        return .result()
    }
}

// MARK: - Resume

struct ResumeMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Music"
    static var description = IntentDescription("Resume playing music in iMusic")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            IntentBridge.shared.pendingPlayerAction = .resume
        }
        return .result()
    }
}

// MARK: - Skip

struct SkipTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Track"
    static var description = IntentDescription("Skip to the next song in iMusic")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            IntentBridge.shared.pendingPlayerAction = .skip
        }
        return .result()
    }
}

// MARK: - Siri Shortcuts

struct iMusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchYouTubeIntent(),
            phrases: [
                "Search YouTube in \(.applicationName)",
                "Search for a song in \(.applicationName)",
                "Find music in \(.applicationName)"
            ],
            shortTitle: "Search YouTube",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: PlaySavedSongIntent(),
            phrases: [
                "Play a song in \(.applicationName)",
                "Play music in \(.applicationName)"
            ],
            shortTitle: "Play Saved Song",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play a playlist in \(.applicationName)",
                "Play my playlist in \(.applicationName)"
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
                "Resume music in \(.applicationName)",
                "Play music in \(.applicationName)"
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: SkipTrackIntent(),
            phrases: [
                "Skip in \(.applicationName)",
                "Next song in \(.applicationName)",
                "Skip track in \(.applicationName)"
            ],
            shortTitle: "Skip Track",
            systemImageName: "forward.fill"
        )
    }
}
