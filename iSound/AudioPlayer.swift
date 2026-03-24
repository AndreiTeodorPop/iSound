import Foundation
import AVFoundation
import Combine
import SwiftUI
import MediaPlayer
import AVKit

@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTrack: Track?
    @Published var isExpanded: Bool = false
    @Published var isShuffled: Bool = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    private var interruptionObserver: Any?
    private var routeChangeObserver: Any?
    private var observationTask: Task<Void, Never>?

    // Local track queue
    private var originalQueue: [Track] = []
    private var playlistQueue: [Track] = []
    private var currentIndex: Int = 0

    // YouTube queue
    private var youtubeQueue: [YouTubeResult] = []
    private var youtubeIndex: Int = 0
    private var isLoadingNextYouTube: Bool = false

    private var streamPlayer: AVPlayer?
    private var streamTimeObserver: Any?

    // MARK: - YouTube Queue

    /// Call this from YouTubeSearchView when playing a result,
    /// passing the full results list so next/previous works.
    func setYouTubeQueue(_ results: [YouTubeResult], startingAt index: Int) {
        youtubeQueue = results
        youtubeIndex = index
        // Clear local queue so next/previous routes to YouTube queue
        playlistQueue = []
        originalQueue = []
    }

    func clearYouTubeQueue() {
        youtubeQueue = []
        youtubeIndex = 0
    }

    var hasYouTubeQueue: Bool { !youtubeQueue.isEmpty }

    var upcomingYoutubeTracks: [YouTubeResult] {
        guard youtubeIndex + 1 < youtubeQueue.count else { return [] }
        return Array(youtubeQueue[(youtubeIndex + 1)...])
    }

    // MARK: - Shuffle

    func toggleShuffle() {
        isShuffled.toggle()
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

    // MARK: - YouTube streaming

    func playYouTube(url: URL, title: String, artist: String, duration: TimeInterval, videoID: String) {
        stopStreamPlayer()
        stop()

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        streamPlayer = AVPlayer(playerItem: item)
        streamPlayer?.automaticallyWaitsToMinimizeStalling = false

        currentTrack = Track(
            url: url,
            title: title,
            artist: artist,
            album: "YouTube",
            duration: duration,
            youtubeVideoID: videoID
        )
        self.duration = duration
        currentTime = 0
        isPlaying = true

        streamPlayer?.play()

        attachStreamTimeObserver()
        updateNowPlayingInfo()

        Task { @MainActor in
            do {
                let isPlayable = try await asset.load(.isPlayable)
                if !isPlayable { print("Asset not playable: \(url)") }
            } catch {
                print("Asset load error: \(error)")
            }
        }

        let nc = NotificationCenter.default
        let endName = AVPlayerItem.didPlayToEndTimeNotification
        let endObject = item as AnyObject
        Task {
            for await notification in nc.notifications(named: endName) {
                if let obj = notification.object as AnyObject?, obj === endObject {
                    await MainActor.run { [weak self] in self?.playNext() }
                    break
                }
            }
        }
    }

    private func stopStreamPlayer() {
        streamPlayer?.pause()
        if let obs = streamTimeObserver {
            streamPlayer?.removeTimeObserver(obs)
            streamTimeObserver = nil
        }
        streamPlayer = nil
    }

    private func attachStreamTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        streamTimeObserver = streamPlayer?.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = time.seconds
                if let d = self.streamPlayer?.currentItem?.duration,
                   d.isNumeric, d.seconds > 0, self.duration == 0 {
                    self.duration = d.seconds
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
            let player = try AVAudioPlayer(contentsOf: track.url)
            self.player = player
            self.currentTrack = track
            self.duration = player.duration
            self.currentTime = 0
            player.delegate = self
            player.prepareToPlay()
            player.play()
            isPlaying = true
            startTimer()
            updateNowPlayingInfo()
        } catch {
            print("AudioPlayer error: \(error)")
        }
    }

    func togglePlayPause() {
        if let sp = streamPlayer {
            if isPlaying { sp.pause(); isPlaying = false; stopTimer() }
            else         { sp.play();  isPlaying = true;  startTimer() }
            updateNowPlayingInfo()
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

    func playAll(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        clearYouTubeQueue()
        originalQueue = tracks
        playlistQueue = isShuffled ? tracks.shuffled() : tracks
        currentIndex = 0
        play(track: playlistQueue[0])
    }

    func playNext() {
        // YouTube queue takes priority
        if !youtubeQueue.isEmpty {
            guard youtubeIndex + 1 < youtubeQueue.count else { stop(); return }
            guard !isLoadingNextYouTube else { return }
            isLoadingNextYouTube = true
            youtubeIndex += 1
            let next = youtubeQueue[youtubeIndex]
            Task {
                await streamYouTubeResult(next)
                isLoadingNextYouTube = false
            }
            return
        }
        // Local queue
        guard currentIndex + 1 < playlistQueue.count else { stop(); return }
        currentIndex += 1
        play(track: playlistQueue[currentIndex])
    }

    func playPrevious() {
        // YouTube queue
        if !youtubeQueue.isEmpty {
            if currentTime > 3 {
                seek(to: 0)
                return
            }
            guard youtubeIndex > 0 else { seek(to: 0); return }
            guard !isLoadingNextYouTube else { return }
            isLoadingNextYouTube = true
            youtubeIndex -= 1
            let prev = youtubeQueue[youtubeIndex]
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
    private func streamYouTubeResult(_ result: YouTubeResult) async {
        do {
            let stream = try await StreamService.getStreamURL(for: result.id)
            guard let url = URL(string: stream.url) else { return }
            playYouTube(
                url: url,
                title: stream.title,
                artist: stream.artist,
                duration: stream.duration,
                videoID: result.id
            )
        } catch {
            print("Failed to stream YouTube result: \(error)")
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let player = self.player else { return }
                self.currentTime = player.currentTime
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
        observationTask = Task { @MainActor in
            let interruptions = NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification)
            let routeChanges  = NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification)
            async let i: Void = { for await n in interruptions { await self.handleInterruption(n) } }()
            async let r: Void = { for await n in routeChanges  { await self.handleRouteChange(n)  } }()
            _ = await [i, r]
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            if isPlaying { togglePlayPause() }
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(rawValue: (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
            if opts.contains(.shouldResume), !isPlaying { togglePlayPause() }
        @unknown default: break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let v = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: v) else { return }
        if reason == .oldDeviceUnavailable, isPlaying { togglePlayPause() }
    }

    // MARK: - Now Playing / Remote Commands

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        if let track = currentTrack {
            info[MPMediaItemPropertyTitle] = track.title
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.isEnabled  = true
        cc.pauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.isEnabled = true
        cc.nextTrackCommand.isEnabled     = true
        cc.previousTrackCommand.isEnabled = true

        cc.playCommand.addTarget  { [weak self] _ in self.map { if !$0.isPlaying { $0.togglePlayPause() } }; return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self.map { if  $0.isPlaying { $0.togglePlayPause() } }; return .success }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        cc.nextTrackCommand.addTarget     { [weak self] _ in Task { @MainActor in self?.playNext()     }; return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.playPrevious() }; return .success }
    }

    deinit {
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        if let o = routeChangeObserver  { NotificationCenter.default.removeObserver(o) }
        observationTask?.cancel()
    }
}
