import Foundation
import AVFoundation
import Combine
import SwiftUI
import MediaPlayer
import AVKit
import UIKit

@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @MainActor static let shared = AudioPlayer()

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTrack: Track?
    @Published var isExpanded: Bool = false
    @Published var isShuffled: Bool = UserDefaults.standard.bool(forKey: "shuffleEnabled")
    @Published private(set) var currentPlaylistName: String? = nil

    private var player: AVAudioPlayer?
    private var timer: Timer?

    private var interruptionObserver: Any?
    private var routeChangeObserver: Any?
    private var foregroundObserver: Any?
    private var wasPlayingBeforeInterruption: Bool = false

    // Local track queue
    private var originalQueue: [Track] = []
    private var playlistQueue: [Track] = []
    private var currentIndex: Int = 0

    // YouTube queue
    private var youtubeQueue: [YouTubeResult] = []
    private var originalYouTubeQueue: [YouTubeResult] = []
    private var youtubeIndex: Int = 0
    private var youtubeHistory: [YouTubeResult] = []
    private var isLoadingNextYouTube: Bool = false
    private var playedYouTubeIDs: Set<String> = []

    private var streamPlayer: AVPlayer?
    private var streamTimeObserver: Any?
    private var streamEndObserver: Any?
    private var timeControlObserver: NSKeyValueObservation?

    // MARK: - YouTube Queue

    /// Call this from YouTubeSearchView when playing a result,
    /// passing the full results list so next/previous works.
    func setYouTubeQueue(_ results: [YouTubeResult], startingAt index: Int) {
        originalYouTubeQueue = results
        youtubeHistory = []
        playlistQueue = []
        originalQueue = []
        currentPlaylistName = nil

        if isShuffled && results.count > 1 {
            let current = results[index]
            var remaining = results
            remaining.remove(at: index)
            remaining.shuffle()
            youtubeQueue = [current] + remaining
            youtubeIndex = 0
        } else {
            youtubeQueue = results
            youtubeIndex = index
        }
    }

    func clearYouTubeQueue() {
        youtubeQueue = []
        originalYouTubeQueue = []
        youtubeIndex = 0
        youtubeHistory = []
        playedYouTubeIDs = []
    }

    var hasYouTubeQueue: Bool { !youtubeQueue.isEmpty }

    var upcomingYoutubeTracks: [YouTubeResult] {
        guard youtubeIndex + 1 < youtubeQueue.count else { return [] }
        return Array(youtubeQueue[(youtubeIndex + 1)...])
    }

    // MARK: - Shuffle

    func toggleShuffle() {
        isShuffled.toggle()
        UserDefaults.standard.set(isShuffled, forKey: "shuffleEnabled")

        if !youtubeQueue.isEmpty {
            let current = youtubeQueue[youtubeIndex]
            if isShuffled {
                var remaining = youtubeQueue.filter { $0.id != current.id }
                remaining.shuffle()
                youtubeQueue = [current] + remaining
                youtubeIndex = 0
            } else {
                youtubeQueue = originalYouTubeQueue
                youtubeIndex = originalYouTubeQueue.firstIndex { $0.id == current.id } ?? 0
            }
            return
        }

        guard !playlistQueue.isEmpty else { return }
        let current = playlistQueue[currentIndex]
        if isShuffled {
            var remaining = originalQueue.filter { $0.id != current.id }
            remaining.shuffle()
            playlistQueue = [current] + remaining
            currentIndex = 0
        } else {
            playlistQueue = originalQueue
            currentIndex = originalQueue.firstIndex { $0.id == current.id } ?? 0
        }
    }

    // MARK: - Queue (read-only for UI)

    var upcomingTracks: [Track] {
        guard currentIndex + 1 < playlistQueue.count else { return [] }
        return Array(playlistQueue[(currentIndex + 1)...])
    }

    // MARK: - Queue Editing

    func moveUpcomingTrack(from source: IndexSet, to destination: Int) {
        let offset = currentIndex + 1
        let adjustedSource = IndexSet(source.map { $0 + offset })
        let adjustedDest = min(destination + offset, playlistQueue.count)
        playlistQueue.move(fromOffsets: adjustedSource, toOffset: adjustedDest)
        if !isShuffled { originalQueue = playlistQueue }
    }

    func removeUpcomingTrack(at offsets: IndexSet) {
        let offset = currentIndex + 1
        let adjustedOffsets = IndexSet(offsets.map { $0 + offset })
        playlistQueue.remove(atOffsets: adjustedOffsets)
        if !isShuffled { originalQueue = playlistQueue }
    }

    /// Inserts a YouTube result immediately after the current position in the YouTube queue.
    func addYouTubeResultToQueue(_ result: YouTubeResult) {
        guard !youtubeQueue.isEmpty else { return }
        youtubeQueue.insert(result, at: min(youtubeIndex + 1, youtubeQueue.count))
    }

    /// Appends a track immediately after the current position in the local queue.
    /// If nothing is playing yet the track is placed at the front so it plays next.
    /// No-op for YouTube queues — there is no local queue to append to.
    func addToQueue(_ track: Track) {
        guard youtubeQueue.isEmpty else { return }
        let insertionIndex = currentIndex + 1
        if playlistQueue.isEmpty {
            // Nothing queued yet — seed the queue with this track
            originalQueue = [track]
            playlistQueue = [track]
            currentIndex  = 0
        } else {
            playlistQueue.insert(track, at: min(insertionIndex, playlistQueue.count))
            originalQueue.insert(track, at: min(insertionIndex, originalQueue.count))
        }
    }

    func moveUpcomingYouTubeTrack(from source: IndexSet, to destination: Int) {
        let offset = youtubeIndex + 1
        let adjustedSource = IndexSet(source.map { $0 + offset })
        let adjustedDest = min(destination + offset, youtubeQueue.count)
        youtubeQueue.move(fromOffsets: adjustedSource, toOffset: adjustedDest)
    }

    func removeUpcomingYouTubeTrack(at offsets: IndexSet) {
        let offset = youtubeIndex + 1
        let adjustedOffsets = IndexSet(offsets.map { $0 + offset })
        youtubeQueue.remove(atOffsets: adjustedOffsets)
    }

    // MARK: - Background task

    /// Keeps the process alive for up to ~30 s while AVPlayer buffers after a Siri intent.
    /// Without this, iOS suspends the app immediately after `perform()` returns and
    /// the stream never starts.
    private func beginStreamBackgroundTask() {
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "imusic-stream-start") {
            UIApplication.shared.endBackgroundTask(taskID)
        }
        guard taskID != .invalid else { return }
        Task { @MainActor [weak self] in
            defer { UIApplication.shared.endBackgroundTask(taskID) }
            // Poll until the stream is *actually producing audio* (.playing), not just buffering
            // (.waitingToPlayAtSpecifiedRate). Ending the task too early while buffering lets iOS
            // deprioritize the app before AVPlayer finishes starting, causing silence until foreground.
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if let sp = self.streamPlayer, sp.timeControlStatus == .playing { return }
                if self.player?.isPlaying == true { return }
            }
        }
    }

    /// True when AVPlayer is genuinely producing audio (not just flagged isPlaying).
    var isActuallyPlaying: Bool {
        if let sp = streamPlayer {
            return sp.timeControlStatus == .playing || sp.timeControlStatus == .waitingToPlayAtSpecifiedRate
        }
        return player?.isPlaying ?? false
    }

    // MARK: - YouTube streaming

    func playYouTube(url: URL, title: String, artist: String, duration: TimeInterval, videoID: String) {
        stopStreamPlayer()
        stop()

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        streamPlayer = AVPlayer(playerItem: item)

        // Observe real playback state so the lock-screen timer rate stays accurate.
        // When the stream stalls (e.g., while the screen is locked), AVPlayer transitions
        // to .waitingToPlayAtSpecifiedRate or .paused. We update MPNowPlayingInfo so iOS
        // stops extrapolating the lock-screen timer forward during silence.
        timeControlObserver = streamPlayer?.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.streamPlayer === player else { return }
                self.updateNowPlayingInfo()
            }
        }

        let cleanArtist = Self.stripYouTubeTopic(from: artist)
        currentTrack = Track(
            url: url,
            title: title,
            artist: cleanArtist,
            album: nil,
            duration: duration,
            youtubeVideoID: videoID
        )
        self.duration = duration
        currentTime = 0
        isPlaying = true

        // Explicitly activate the audio session before starting the new player.
        // Between stopStreamPlayer() and this play() call there is a momentary gap
        // where no audio is active; without this, iOS can silently deactivate the
        // session and the new AVPlayer will buffer but never produce output.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        streamPlayer?.play()
        beginStreamBackgroundTask()
        schedulePlayRetry()

        attachStreamTimeObserver()

        streamEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playNext()
            }
        }

        updateNowPlayingInfo()
        saveLastPlayedYouTube()

        Task { @MainActor [weak self] in
            do {
                let isPlayable = try await asset.load(.isPlayable)
                if !isPlayable { print("Asset not playable: \(url)") }
            } catch {
                print("Asset load error: \(error)")
            }
            // Only load duration from the asset if the server returned 0 —
            // the MP4 container duration from YouTube DASH/fragmented streams
            // can be double the real length, which would cause silence at the midpoint.
            if (self?.duration ?? 0) < 1,
               let d = try? await asset.load(.duration), d.isNumeric, d.seconds > 1 {
                self?.duration = d.seconds
                self?.updateNowPlayingInfo()
            }
        }
    }

    private func stopStreamPlayer() {
        streamPlayer?.pause()
        if let obs = streamTimeObserver {
            streamPlayer?.removeTimeObserver(obs)
            streamTimeObserver = nil
        }
        if let obs = streamEndObserver {
            NotificationCenter.default.removeObserver(obs)
            streamEndObserver = nil
        }
        timeControlObserver?.invalidate()
        timeControlObserver = nil
        streamPlayer = nil
    }

    private func attachStreamTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        streamTimeObserver = streamPlayer?.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.streamPlayer != nil else { return }
                let seconds = time.seconds
                self.currentTime = seconds
                if let d = self.streamPlayer?.currentItem?.duration,
                   d.isNumeric, d.seconds > 0, self.duration == 0 {
                    self.duration = d.seconds
                }
                // Fallback: AVPlayerItemDidPlayToEndTime doesn't always fire for HTTP streams.
                // If playback has gone 2 s past the reported duration, advance to next track.
                if self.duration > 0, seconds > self.duration {
                    self.stopStreamPlayer()
                    self.isPlaying = false
                    self.playNext()
                }
            }
        }
    }

    // MARK: - Audio Session

    func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            setupRemoteCommands()
            observeAudioSessionNotifications()
        } catch {
            print("Audio session error: \(error)")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playNext()
    }

    // MARK: - Playback

    func play(track: Track) {
        // Playing a local track clears the YouTube queue
        clearYouTubeQueue()
        stop()
        do {
            // Activate the audio session before loading — if it isn't active,
            // player.play() silently returns false and the song appears to stop.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)

            let player = try AVAudioPlayer(contentsOf: track.url)
            self.player = player
            self.currentTrack = track
            // Prefer the metadata duration (set from YouTube API after download) over
            // the file duration — YouTube downloads contain silence padding at the end
            // which inflates player.duration beyond the actual music content.
            self.duration = (track.duration ?? 0) > 0 ? track.duration! : player.duration
            self.currentTime = 0
            player.delegate = self
            player.prepareToPlay()
            let started = player.play()
            isPlaying = started
            if started { startTimer() }
            updateNowPlayingInfo()
            saveLastPlayed()
            if !started { schedulePlayRetry() }
        } catch {
            print("AudioPlayer error: \(error)")
            // AVAudioPlayer can't parse this file (e.g. VBR MP3 without Xing header).
            // Fall back to AVPlayer which uses a more permissive decoder.
            playLocalWithAVPlayer(track: track)
        }
    }

    /// Plays a local file through AVPlayer when AVAudioPlayer fails to parse it.
    private func playLocalWithAVPlayer(track: Track) {
        stopStreamPlayer()
        let asset = AVURLAsset(url: track.url)
        let item  = AVPlayerItem(asset: asset)
        streamPlayer = AVPlayer(playerItem: item)
        streamPlayer?.automaticallyWaitsToMinimizeStalling = false

        currentTrack = track
        duration     = track.duration ?? 0
        currentTime  = 0
        isPlaying    = true

        streamPlayer?.play()
        attachStreamTimeObserver()

        streamEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.playNext() }
        }

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopStreamPlayer()
                if !self.playlistQueue.isEmpty { self.playNext() }
            }
        }

        // Load precise duration from asset asynchronously
        Task { @MainActor [weak self] in
            if let d = try? await asset.load(.duration), d.isNumeric {
                self?.duration = d.seconds
            }
        }

        startTimer()
        updateNowPlayingInfo()
        saveLastPlayed()
    }

    func togglePlayPause() {
        if let sp = streamPlayer {
            if isPlaying {
                sp.pause(); isPlaying = false; stopTimer()
            } else {
                // Re-activate the audio session before resuming (covers post-Siri-TTS interruption)
                try? AVAudioSession.sharedInstance().setActive(true)
                sp.play(); isPlaying = true; startTimer()
            }
            updateNowPlayingInfo()
            return
        }
        // Restored YouTube track with no active stream — re-fetch and start
        if let track = currentTrack, track.isYouTubeTrack, let videoID = track.youtubeVideoID {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let stream = try await StreamService.getStreamURL(for: videoID)
                    guard let url = URL(string: stream.url) else { return }
                    self.playYouTube(
                        url: url,
                        title: track.title,
                        artist: track.artist ?? stream.artist,
                        duration: stream.duration,
                        videoID: videoID
                    )
                } catch {
                    print("Failed to re-fetch YouTube stream: \(error)")
                }
            }
            return
        }
        guard let player else { return }
        if player.isPlaying { player.pause(); isPlaying = false; stopTimer() }
        else                { player.play();  isPlaying = true;  startTimer() }
        updateNowPlayingInfo()
    }

    func stop() {
        stopStreamPlayer()
        stopTimer()
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentTrack = nil
        updateNowPlayingInfo()
    }

    func seek(to time: TimeInterval) {
        if let sp = streamPlayer {
            sp.seek(to: CMTime(seconds: time, preferredTimescale: 600))
            currentTime = time
            updateNowPlayingInfo()
            return
        }
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
        updateNowPlayingInfo()
    }

    func playAll(tracks: [Track], playlistName: String? = nil) {
        guard !tracks.isEmpty else { return }
        clearYouTubeQueue()
        currentPlaylistName = playlistName
        originalQueue = tracks
        playlistQueue = isShuffled ? tracks.shuffled() : tracks
        currentIndex = 0
        play(track: playlistQueue[0])
    }

    /// Plays a single track while setting the full queue for next/previous navigation.
    func play(track: Track, queue: [Track], playlistName: String? = nil) {
        clearYouTubeQueue()
        currentPlaylistName = playlistName
        originalQueue = queue
        playlistQueue = isShuffled ? queue.shuffled() : queue
        currentIndex = playlistQueue.firstIndex(where: { $0.id == track.id }) ?? 0
        play(track: track)
    }

    func playNext() {
        if !youtubeQueue.isEmpty {
            guard !isLoadingNextYouTube else { return }
            isLoadingNextYouTube = true
            beginStreamBackgroundTask() // keep app alive during stream URL fetch

            // Push current track to history before moving forward
            if let track = currentTrack, let videoID = track.youtubeVideoID {
                youtubeHistory.append(YouTubeResult(id: videoID, title: track.title, channelTitle: track.artist ?? "", duration: nil))
            }

            if youtubeIndex + 1 < youtubeQueue.count {
                // Play next item in the search results queue
                youtubeIndex += 1
                let next = youtubeQueue[youtubeIndex]
                Task {
                    let started = await streamYouTubeResult(next)
                    isLoadingNextYouTube = false
                    if !started { playNext() } // stream fetch failed — try the one after it
                }
            } else {
                // Queue exhausted — fetch suggestions
                guard let videoID = currentTrack?.youtubeVideoID else {
                    isLoadingNextYouTube = false
                    stop()
                    return
                }
                Task {
                    await playSuggested(for: videoID)
                    isLoadingNextYouTube = false
                }
            }
            return
        }
        // YouTube track restored from persistence — queue not in memory, fetch suggestions
        if let track = currentTrack, track.isYouTubeTrack, let videoID = track.youtubeVideoID {
            guard !isLoadingNextYouTube else { return }
            isLoadingNextYouTube = true
            beginStreamBackgroundTask()
            Task {
                await playSuggested(for: videoID)
                isLoadingNextYouTube = false
            }
            return
        }
        // Local queue — wrap around to the first track
        guard !playlistQueue.isEmpty else { stop(); return }
        currentIndex = (currentIndex + 1) % playlistQueue.count
        play(track: playlistQueue[currentIndex])
    }

    private func playSuggested(for videoID: String) async {
        playedYouTubeIDs.insert(videoID)

        guard let track = currentTrack else { stop(); return }

        // Build a discovery query that avoids returning more versions of the same song.
        // Using the song title causes YouTube to return the Official Video, Lyrics version,
        // Audio version, etc. — all the same track. Searching by artist name instead finds
        // the artist's other songs and similar artists, giving genuine variety.
        let artist = track.artist ?? ""
        let cleanTitle = LyricsService.shared.cleanTitle(track.title)
        let query: String
        if artist.isEmpty {
            query = "music similar to \(cleanTitle)"
        } else {
            query = "music similar to \(artist)"
        }

        // Channel of the song that just finished — used to avoid suggesting more from the same uploader.
        let currentChannel = youtubeIndex < youtubeQueue.count
            ? youtubeQueue[youtubeIndex].channelTitle.lowercased()
            : artist.lowercased()

        do {
            var results = try await YouTubeService.search(query)

            // 1. Exclude already-played and the current track.
            //    If history has grown so large that everything is filtered, reset it.
            let notPlayed = results.filter { !playedYouTubeIDs.contains($0.id) && $0.id != videoID }
            if notPlayed.isEmpty && !results.isEmpty {
                playedYouTubeIDs.removeAll()
                results = results.filter { $0.id != videoID }
            } else {
                results = notPlayed
            }

            // 2. Prefer results from a different channel than the one currently playing
            //    so the radio doesn't just loop through the same uploader's catalogue.
            if !currentChannel.isEmpty {
                let differentChannel = results.filter {
                    let ch = $0.channelTitle.lowercased()
                    return !ch.contains(currentChannel) && !currentChannel.contains(ch)
                }
                if !differentChannel.isEmpty { results = differentChannel }
                // If every result is from the same channel, fall through with unfiltered set
                // so playback doesn't stop entirely.
            }

            // Shuffle for variety so repeat listens feel fresh
            results.shuffle()
            guard !results.isEmpty else { stop(); return }

            youtubeQueue = results
            for (index, result) in results.enumerated() {
                youtubeIndex = index
                do {
                    let stream = try await StreamService.getStreamURL(for: result.id)
                    guard let url = URL(string: stream.url) else { continue }
                    let artist = stream.artist.trimmingCharacters(in: .whitespaces).isEmpty
                        ? result.artistName
                        : stream.artist
                    playYouTube(url: url, title: result.title, artist: artist,
                                duration: stream.duration, videoID: result.id)
                    return
                } catch {
                    continue
                }
            }
            stop()
        } catch {
            print("Suggestion search failed: \(error)")
            // Network hiccup — don't stop, just leave the queue intact so the user
            // can manually skip or wait. If we have more in the current queue, try next.
            if youtubeIndex + 1 < youtubeQueue.count {
                youtubeIndex += 1
                let next = youtubeQueue[youtubeIndex]
                _ = await streamYouTubeResult(next)
            } else {
                stop()
            }
        }
    }

    func playPrevious() {
        // YouTube queue
        if !youtubeQueue.isEmpty {
            if currentTime > 3 {
                seek(to: 0)
                return
            }
            guard !youtubeHistory.isEmpty else { seek(to: 0); return }
            guard !isLoadingNextYouTube else { return }
            isLoadingNextYouTube = true
            let prev = youtubeHistory.removeLast()
            // Also step back the queue index if possible
            if youtubeIndex > 0 { youtubeIndex -= 1 }
            Task {
                await streamYouTubeResult(prev)
                isLoadingNextYouTube = false
            }
            return
        }
        // Local queue
        if currentTime > 3 {
            seek(to: 0)
        } else if currentIndex > 0 {
            currentIndex -= 1
            play(track: playlistQueue[currentIndex])
        } else {
            seek(to: 0)
        }
    }

    /// Fetches the stream URL for a YouTube result and plays it.
    /// Returns true if playback started successfully.
    @discardableResult
    private func streamYouTubeResult(_ result: YouTubeResult) async -> Bool {
        do {
            let stream = try await StreamService.getStreamURL(for: result.id)
            guard let url = URL(string: stream.url) else { return false }
            let artist = stream.artist.trimmingCharacters(in: .whitespaces).isEmpty
                ? result.artistName
                : stream.artist
            // Strip YouTube-style suffixes ("Artist - Topic") then prepend to title
            // if the title doesn't already start with the artist name.
            let cleanArtist = artist.lowercased().hasSuffix(" - topic")
                ? String(artist.dropLast(" - topic".count)).trimmingCharacters(in: .whitespaces)
                : artist
            let displayTitle = !cleanArtist.isEmpty &&
                !result.title.lowercased().hasPrefix(cleanArtist.lowercased())
                ? "\(cleanArtist) - \(result.title)"
                : result.title
            playYouTube(
                url: url,
                title: displayTitle,
                artist: artist,
                duration: stream.duration,
                videoID: result.id
            )
            return true
        } catch {
            print("Failed to stream YouTube result: \(error)")
            return false
        }
    }

    // MARK: - Metadata sync

    /// Called by AudioLibrary after a track's title/artist is edited.
    /// Updates currentTrack and the queues so NowPlayingView and navigation
    /// reflect the new metadata without requiring a song change.
    func trackMetadataUpdated(oldTrack: Track, newTrack: Track) {
        if currentTrack?.id == oldTrack.id {
            currentTrack = newTrack
            updateNowPlayingInfo()
        }
        playlistQueue = playlistQueue.map { $0.id == oldTrack.id ? newTrack : $0 }
        originalQueue = originalQueue.map { $0.id == oldTrack.id ? newTrack : $0 }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let player = self.player else { return }
                self.currentTime = player.currentTime
                // Stop early if we've reached the stored duration (handles silence-padded downloads)
                if self.duration > 0, player.currentTime >= self.duration {
                    player.stop()
                    self.isPlaying = false
                    self.stopTimer()
                    self.playNext()
                    return
                }
                if !player.isPlaying { self.isPlaying = false; self.stopTimer() }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Notifications

    private func observeAudioSessionNotifications() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] n in
            MainActor.assumeIsolated { self?.handleInterruption(n) }
        }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] n in
            MainActor.assumeIsolated { self?.handleRouteChange(n) }
        }
        // Safety net: if a song-transition stalled in background (player was buffering when
        // the app had no background task left), kick the audio session and re-issue play()
        // as soon as the app comes back to the foreground.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                guard let sp = self.streamPlayer,
                      sp.timeControlStatus != .playing else { return }
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
                try? AVAudioSession.sharedInstance().setActive(true)
                sp.play()
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            pauseForInterruption()
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(rawValue: (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
            // Resume if the system says to, OR if we were playing before (covers Siri intent
            // TTS which doesn't always include the shouldResume flag)
            let shouldResume = opts.contains(.shouldResume) || wasPlayingBeforeInterruption
            wasPlayingBeforeInterruption = false
            if shouldResume, !isPlaying { togglePlayPause() }
        @unknown default: break
        }
    }

    /// Pauses without toggling — safe to call when the system may have already paused AVAudioPlayer.
    private func pauseForInterruption() {
        wasPlayingBeforeInterruption = isPlaying
        streamPlayer?.pause()
        player?.pause()
        isPlaying = false
        stopTimer()
        updateNowPlayingInfo()
    }

    /// Retries playback every second for up to 8 seconds, refreshing the audio session each tick.
    /// Covers: Siri TTS holding the session, lock-screen song transitions where AVPlayer is
    /// buffering (.waitingToPlayAtSpecifiedRate) but not yet producing audio (.playing).
    private func schedulePlayRetry() {
        Task { @MainActor [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.currentTrack != nil else { return }
                // Done only when audio is genuinely being produced, not just buffering.
                if let sp = self.streamPlayer, sp.timeControlStatus == .playing { return }
                if self.player?.isPlaying == true { return }
                // Refresh the session every tick while buffering or stalled.
                // This keeps iOS from deprioritising the app mid-transition.
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch { continue }
                if let sp = self.streamPlayer {
                    sp.play()
                    self.isPlaying = true
                    self.updateNowPlayingInfo()
                } else if let p = self.player, !p.isPlaying {
                    if p.play() { self.isPlaying = true; self.startTimer(); self.updateNowPlayingInfo() }
                }
            }
            // Retries exhausted — skip only if truly stuck, not if still buffering.
            guard let self else { return }
            let isBuffering = self.streamPlayer?.timeControlStatus == .waitingToPlayAtSpecifiedRate
            guard !isBuffering, !self.isActuallyPlaying,
                  !self.playlistQueue.isEmpty || !self.youtubeQueue.isEmpty else { return }
            self.playNext()
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let v = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: v) else { return }
        if reason == .oldDeviceUnavailable, isPlaying { pauseForInterruption() }
    }

    // MARK: - Now Playing / Remote Commands

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        if let track = currentTrack {
            info[MPMediaItemPropertyTitle] = track.title
            if let artist = track.artist, !artist.isEmpty {
                info[MPMediaItemPropertyArtist] = artist
            }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        // Use the real AVPlayer timeControlStatus for the playback rate so the lock-screen
        // timer only counts forward when audio is genuinely being produced. isPlaying stays
        // true during buffering (so the UI play/pause button looks right), but the lock
        // screen must not extrapolate time forward while the stream is stalled.
        let rate: Double
        if let sp = streamPlayer {
            rate = (sp.timeControlStatus == .playing) ? 1.0 : 0.0
        } else {
            rate = (player?.isPlaying == true) ? 1.0 : 0.0
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.isEnabled  = true
        cc.pauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.isEnabled = true
        cc.nextTrackCommand.isEnabled     = true
        cc.previousTrackCommand.isEnabled = true
        cc.changePlaybackPositionCommand.isEnabled = true

        cc.playCommand.addTarget  { [weak self] _ in self.map { if !$0.isPlaying { $0.togglePlayPause() } }; return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self.map { if  $0.isPlaying { $0.togglePlayPause() } }; return .success }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        cc.nextTrackCommand.addTarget     { [weak self] _ in Task { @MainActor in self?.playNext()     }; return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.playPrevious() }; return .success }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self.seek(to: e.positionTime) }
            return .success
        }
    }

    // MARK: - YouTube Last Played Persistence

    private enum YouTubePersistenceKey {
        static let videoID  = "lastYouTubeVideoID"
        static let title    = "lastYouTubeTitle"
        static let artist   = "lastYouTubeArtist"
        static let duration = "lastYouTubeDuration"
        static let queue    = "lastYouTubeQueue"
        static let index    = "lastYouTubeIndex"
    }

    private func saveLastPlayedYouTube() {
        guard let track = currentTrack, track.isYouTubeTrack,
              let videoID = track.youtubeVideoID else { return }
        UserDefaults.standard.set(videoID,          forKey: YouTubePersistenceKey.videoID)
        UserDefaults.standard.set(track.title,      forKey: YouTubePersistenceKey.title)
        UserDefaults.standard.set(track.artist,     forKey: YouTubePersistenceKey.artist)
        UserDefaults.standard.set(duration,         forKey: YouTubePersistenceKey.duration)
        UserDefaults.standard.set(youtubeIndex,     forKey: YouTubePersistenceKey.index)
        if let data = try? JSONEncoder().encode(youtubeQueue) {
            UserDefaults.standard.set(data, forKey: YouTubePersistenceKey.queue)
        }
        // Clear local track state so it doesn't win on next restore
        UserDefaults.standard.removeObject(forKey: PersistenceKey.trackID)
    }

    /// Restores the last played YouTube track as a paused mini-player entry.
    /// The stream URL is re-fetched on demand when the user taps play.
    func restoreLastPlayedYouTube() {
        guard currentTrack == nil,
              let videoID = UserDefaults.standard.string(forKey: YouTubePersistenceKey.videoID),
              let title   = UserDefaults.standard.string(forKey: YouTubePersistenceKey.title)
        else { return }
        let artist   = UserDefaults.standard.string(forKey: YouTubePersistenceKey.artist)
        let duration = UserDefaults.standard.double(forKey: YouTubePersistenceKey.duration)
        // Restore queue and index so next/previous works without re-fetching
        if let data  = UserDefaults.standard.data(forKey: YouTubePersistenceKey.queue),
           let queue = try? JSONDecoder().decode([YouTubeResult].self, from: data) {
            youtubeQueue         = queue
            originalYouTubeQueue = queue
        }
        youtubeIndex = UserDefaults.standard.integer(forKey: YouTubePersistenceKey.index)
        // Use a stable placeholder URL — the real stream is fetched on play
        let placeholderURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
        currentTrack = Track(
            url: placeholderURL, title: title, artist: artist,
            album: nil, duration: duration > 0 ? duration : nil,
            youtubeVideoID: videoID
        )
        self.duration = duration
        isPlaying = false
        updateNowPlayingInfo()
    }

    // MARK: - Last Played Persistence

    private enum PersistenceKey {
        static let trackID    = "lastPlayedTrackID"
        static let queueIDs   = "lastPlayedQueueIDs"
        static let playlist   = "lastPlayedPlaylistName"
    }

    private func saveLastPlayed() {
        guard let track = currentTrack, !track.isYouTubeTrack else { return }
        UserDefaults.standard.set(track.id.uuidString, forKey: PersistenceKey.trackID)
        // Always save the original (unshuffled) queue so toggling shuffle off after
        // restore gives back the correct in-order sequence.
        UserDefaults.standard.set(originalQueue.map(\.id.uuidString), forKey: PersistenceKey.queueIDs)
        UserDefaults.standard.set(currentPlaylistName, forKey: PersistenceKey.playlist)
        // Clear YouTube state so it doesn't win on next restore
        UserDefaults.standard.removeObject(forKey: YouTubePersistenceKey.videoID)
    }

    /// Restores the last played local track (paused) from the library.
    /// No-op if a track is already loaded or nothing was saved.
    func restoreLastPlayed(from library: AudioLibrary) {
        guard currentTrack == nil,
              let idString = UserDefaults.standard.string(forKey: PersistenceKey.trackID),
              let trackID  = UUID(uuidString: idString),
              let track    = library.tracks.first(where: { $0.id == trackID })
        else { return }

        let savedIDs = UserDefaults.standard.stringArray(forKey: PersistenceKey.queueIDs) ?? []
        let queue: [Track] = savedIDs.compactMap { s in
            guard let id = UUID(uuidString: s) else { return nil }
            return library.tracks.first(where: { $0.id == id })
        }

        // Prepare AVAudioPlayer so togglePlayPause works immediately
        do {
            let avPlayer = try AVAudioPlayer(contentsOf: track.url)
            avPlayer.delegate = self
            avPlayer.prepareToPlay()
            self.player = avPlayer
            self.duration = (track.duration ?? 0) > 0 ? track.duration! : avPlayer.duration
        } catch {
            print("restoreLastPlayed: could not prepare player – \(error)")
            return
        }

        currentPlaylistName = UserDefaults.standard.string(forKey: PersistenceKey.playlist)
        originalQueue  = queue.isEmpty ? [track] : queue
        if isShuffled {
            var remaining = originalQueue.filter { $0.id != track.id }
            remaining.shuffle()
            playlistQueue = [track] + remaining
            currentIndex  = 0
        } else {
            playlistQueue = originalQueue
            currentIndex  = originalQueue.firstIndex(where: { $0.id == track.id }) ?? 0
        }
        currentTrack   = track
        currentTime    = 0
        isPlaying      = false
        updateNowPlayingInfo()
    }

    // MARK: - Helpers

    /// Strips the YouTube-generated " - Topic" suffix from artist names.
    private static func stripYouTubeTopic(from artist: String) -> String {
        let suffix = " - Topic"
        guard artist.lowercased().hasSuffix(suffix.lowercased()) else { return artist }
        return String(artist.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
    }

    deinit {
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        if let o = routeChangeObserver  { NotificationCenter.default.removeObserver(o) }
        if let o = foregroundObserver   { NotificationCenter.default.removeObserver(o) }
    }
}
