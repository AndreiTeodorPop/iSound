import SwiftUI

// MARK: - Seek bar with tap-to-seek and drag support

struct SeekBar: View {
    let progress: Double          // 0…1, driven by the player
    let onSeek: (Double) -> Void  // called with 0…1 on release

    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    private var display: Double { isDragging ? dragProgress : progress }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(height: isDragging ? 6 : 4)
                Capsule()
                    .fill(Color.primary)
                    .frame(width: max(0, geo.size.width * display), height: isDragging ? 6 : 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        dragProgress = min(max(0, drag.location.x / geo.size.width), 1)
                    }
                    .onEnded { drag in
                        let v = min(max(0, drag.location.x / geo.size.width), 1)
                        onSeek(v)
                        isDragging = false
                    }
            )
        }
        .frame(height: 22)
        .animation(.easeInOut(duration: 0.12), value: isDragging)
    }
}


// MARK: - Shared artwork placeholder used across the app

struct TrackArtworkView: View {
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.secondary.opacity(0.2))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "music.note")
                    .font(size >= 80 ? .largeTitle : .body)
                    .foregroundStyle(.secondary)
            )
    }
}

struct PlayerControlsView: View {
    @EnvironmentObject private var player: AudioPlayer
    var onExpand: () -> Void = {}

    var body: some View {
        VStack(spacing: 8) {
            // 1. Track Info Row
            HStack(spacing: 12) {
                albumArtPlaceholder

                let title = player.currentTrack?.title ?? "Not Playing"
                let artist = player.currentTrack?.artist ?? ""
                let isYouTube = player.currentTrack?.youtubeVideoID != nil
                Text(artist.isEmpty || isYouTube ? title : "\(artist) - \(title)")
                    .font(.subheadline).bold()
                    .lineLimit(1)

                Spacer()

                AVRoutePickerButton(font: .title2)

                playbackButton
            }

            // 2. Progress Row
            progressSlider
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
    }

    // MARK: - Subcomponents
    
    private var albumArtPlaceholder: some View {
        TrackArtworkView(size: 40, cornerRadius: 4)
    }

    private var playbackButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.title2)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        .disabled(player.currentTrack == nil)
    }

    private var progressSlider: some View {
        HStack(spacing: 8) {
            Text(player.currentTime.mmss)
                .font(.caption2.monospacedDigit())
            
            SeekBar(
                progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                onSeek: { player.seek(to: $0 * player.duration) }
            )

            Text(player.duration.mmss)
                .font(.caption2.monospacedDigit())
        }
    }

}
