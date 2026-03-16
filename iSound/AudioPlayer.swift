import Foundation
import AVFoundation
import Combine
import SwiftUI
import MediaPlayer

@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTrack: Track?
    @Published var isExpanded: Bool = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    private var interruptionObserver: Any?
    private var routeChangeObserver: Any?
    private var observationTask: Task<Void, Never>?
    private var playlistQueue: [Track] = []
    private var currentIndex: Int = 0

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
            // Since the class is @MainActor, this method is
            // automatically treated as being on the main thread.
            self.playNext()
        }

    func play(track: Track) {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: track.url)
            self.player = player
            self.currentTrack = track
            self.duration = player.duration
            self.currentTime = 0
            player.delegate = self // Add this line
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
        guard let player = player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
        updateNowPlayingInfo()
    }

    func stop() {
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
        guard let player = player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
        updateNowPlayingInfo()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }

            Task { @MainActor in
                guard let player = self.player else { return }

                self.currentTime = player.currentTime

                if !player.isPlaying {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func observeAudioSessionNotifications() {
        // We create a single task to manage our async streams
        observationTask = Task { @MainActor in
            // Use withTaskGroup if you want to run them in parallel,
            // but simple separate tasks or loops work too.
            
            // 1. Observe Interruptions
            let interruptions = NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification)
            
            // 2. Observe Route Changes
            let routeChanges = NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification)

            // We can use a TaskGroup or just spawn two sub-tasks
            async let handleInterruptions: Void = {
                for await notification in interruptions {
                    await self.handleInterruption(notification)
                }
            }()

            async let handleRouteChanges: Void = {
                for await notification in routeChanges {
                    await self.handleRouteChange(notification)
                }
            }()
            
            _ = await [handleInterruptions, handleRouteChanges]
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
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            if options.contains(.shouldResume) {
                if !isPlaying { togglePlayPause() }
            }
        @unknown default: break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        if reason == .oldDeviceUnavailable {
            // e.g., headphones unplugged
            if isPlaying { togglePlayPause() }
        }
    }

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
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if !self.isPlaying { self.togglePlayPause() }
            return .success
        }
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isPlaying { self.togglePlayPause() }
            return .success
        }
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        // Add Next Track Command
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                    self.playNext()
                }
                return .success
            }

            // Add Previous Track Command
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
                guard let self = self else { return .commandFailed }
                Task { @MainActor in
                    self.playPrevious()
                }
                return .success
            }
        
    }
    
    func playAll(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        self.playlistQueue = tracks
        self.currentIndex = 0
        self.play(track: tracks[0])
    }
    
    func playNext() {
        guard currentIndex + 1 < playlistQueue.count else {
            // Option: loop back to 0 or stop
            stop()
            return
        }
        currentIndex += 1
        play(track: playlistQueue[currentIndex])
    }

    func playPrevious() {
        // If we are more than 3 seconds into a song, restart it instead of skipping back
        if currentTime > 3 {
            seek(to: 0)
        } else if currentIndex > 0 {
            currentIndex -= 1
            play(track: playlistQueue[currentIndex])
        } else {
            seek(to: 0)
        }
    }

    deinit {
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        if let o = routeChangeObserver { NotificationCenter.default.removeObserver(o) }
        observationTask?.cancel()
    }
}
