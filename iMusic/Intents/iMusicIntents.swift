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

// MARK: - Siri Shortcuts

struct iMusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchYouTubeIntent(),
            phrases: [
                "Search for a song in \(.applicationName)",
                "Search YouTube in \(.applicationName)",
                "Find music in \(.applicationName)"
            ],
            shortTitle: "Search YouTube",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: PlaySavedSongIntent(),
            phrases: [
                "Play a song in \(.applicationName)",
                "Play music from my library in \(.applicationName)"
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
    }
}
