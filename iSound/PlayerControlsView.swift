import SwiftUI

struct PlayerControlsView: View {
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        VStack(spacing: 8) {
            // 1. Track Info Row
            HStack(spacing: 12) {
                albumArtPlaceholder
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentTrack?.title ?? "Not Playing")
                        .font(.subheadline).bold()
                        .lineLimit(1)
                    Text(player.currentTrack?.artist ?? "Unknown Artist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                playbackButton
            }

            // 2. Progress Row
            progressSlider
        }
        .padding(12)
        .contentShape(Rectangle()) // Makes the whole bar tappable
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
    }

    // MARK: - Subcomponents
    
    private var albumArtPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.secondary.opacity(0.3))
            .frame(width: 40, height: 40)
            .overlay(
                Image(systemName: "music.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            )
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
            Text(timeString(player.currentTime))
                .font(.caption2.monospacedDigit())
            
            Slider(value: Binding(
                get: {
                    guard player.duration > 0 else { return 0 }
                    return player.currentTime / player.duration
                },
                set: { player.seek(to: $0 * player.duration) }
            ))
            .controlSize(.mini)
            .tint(.primary) // Modern replacement for accentColor

            Text(timeString(player.duration))
                .font(.caption2.monospacedDigit())
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "0:00" }
        let total = Int(t.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
