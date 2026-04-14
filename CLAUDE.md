# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

- **Open project**: `iMusic.xcodeproj` in Xcode 15+
- **Build**: Cmd+B (or `xcodebuild -project iMusic.xcodeproj -scheme iMusic -sdk iphonesimulator`)
- **Run**: Cmd+R on simulator or physical device
- **No external Swift Package Manager dependencies** — pure Xcode project using native frameworks only

**Required setup**: `iMusic/Info.plist` (gitignored) must contain `YoutubeAPIKey` with a valid YouTube Data API v3 key.

## Architecture

**MVVM + Service-Oriented**, iOS 16+, SwiftUI, async/await throughout.

### Service Layer (`Services/`) — all `@MainActor` singletons

- **AudioPlayer.swift** — Core playback engine. Dual-player: `AVAudioPlayer` for local files, `AVPlayer` for YouTube streams. Manages two separate queues (local + YouTube), shuffle, history, progress tracking, lock screen/Control Center via `MPRemoteCommandCenter`, and audio session for background playback.
- **AudioLibrary.swift** — Persistence. Discovers audio files from Documents directory, manages playlists (CRUD), liked tracks/videos. Persists to JSON files (`playlists.json`, `liked_tracks.json`, `liked_youtube_videos.json`) in Documents.
- **InvidiousService.swift** — YouTube Data API v3: search, channel fetching, playlist fetching, video details.
- **StreamService.swift** — Calls the self-hosted Railway backend (`imusic-production-4e58.up.railway.app`) for `/stream`, `/download`, and `/related` endpoints.
- **LyricsService.swift** — Fetches, parses, and caches lyrics with synced lyric support and multi-language translation.

Services are injected at root (`iMusicApp.swift`) as `@StateObject` and passed down as `@EnvironmentObject`.

### Models (`Models/`)

- **Track** — Represents both local files and YouTube videos. Uses deterministic UUID from filename for stable identity across reinstalls. Stores YouTube video ID for stream lookups.
- **Playlist** — Stores ordered Track UUIDs with optional linked YouTube playlist metadata. Custom `Codable` for backward compatibility.

### Views (`Views/`)

Tab-based navigation (ContentView):
1. **YouTubeSearchView** — Search, auto-play first result, channel browsing
2. **SavedSongsView** — Local library with alphabet index
3. Settings tab

Full-screen overlay: **NowPlayingView** (artwork, seek bar, lyrics display).
**PlaylistDetailView** — drag-to-reorder queue, add/remove tracks.
**YouTubeChannelView** — browse channel playlists.
**TrackOptionsSheet** — add to playlist, like track.

### Theme System (`Theme/`)

`ThemeManager` (ObservableObject) + `AppTheme` enum with 6 color themes. Persisted in UserDefaults. Available app-wide via `@EnvironmentObject`.

### Siri / AppIntents (`Intents/iMusicIntents.swift`)

Uses AppIntents framework (no separate extension). Intents: `PlayYouTubeIntent`, `PlaySavedSongIntent`, `PlayPlaylistIntent`, `PauseMusic`, `ResumeMusic`, `SkipTrack`. Routes through `IntentBridge.shared` → `AudioPlayer.shared`.

### Backend Server (`Server/`)

Python Flask + yt-dlp, containerized with Docker, deployed on Railway.
- `/stream?id=` — returns playable audio URL + metadata
- `/download?id=` — streams audio for local save
- `/related?id=` — recommended videos

Uses multiple yt-dlp client profiles and `cookies.txt` to bypass bot detection. Prefers non-fragmented M4A streams to avoid AVFoundation duration metadata bugs. Caches extracted info for 1 hour.

To run locally: `pip install -r Server/requirements.txt && python Server/server.py`

## Key Patterns

- **Dual-queue playback**: Local and YouTube queues are managed independently inside `AudioPlayer`. When switching between local and YouTube playback, the other player is paused/reset.
- **Stable Track IDs**: UUID is derived deterministically from filename — this is intentional so playlist membership survives reinstalls.
- **`@MainActor` on services**: All service mutations happen on the main actor, so no `DispatchQueue.main` calls are needed in views.
- **Info.plist is gitignored**: Never commit `Info.plist`; it contains the YouTube API key.
