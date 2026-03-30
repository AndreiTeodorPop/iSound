import AppIntents

// MARK: - Play YouTube (search + auto-play first result)

struct PlayYouTubeIntent: AppIntent {
    static var title: LocalizedStringResource = "Play a Song on YouTube"
    static var description = IntentDescription("Search YouTube and immediately play the top result in iMusic")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Song or Artist", description: "What to play on YouTube")
    var songName: String

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            IntentBridge.shared.pendingYouTubePlay = songName
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
    }
}
