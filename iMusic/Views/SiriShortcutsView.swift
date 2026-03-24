import SwiftUI
import AppIntents

struct SiriShortcutsView: View {
    private let shortcuts: [(icon: String, color: Color, title: String, phrase: String)] = [
        (
            icon: "magnifyingglass",
            color: .red,
            title: "Search YouTube",
            phrase: "\"Search for [song] in iMusic\""
        ),
        (
            icon: "music.note",
            color: .blue,
            title: "Play a Saved Song",
            phrase: "\"Play [song] in iMusic\""
        ),
        (
            icon: "music.note.list",
            color: .green,
            title: "Play a Playlist",
            phrase: "\"Play my [playlist] playlist in iMusic\""
        ),
    ]

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 44))
                        .foregroundStyle(.purple)
                    Text("Siri Shortcuts")
                        .font(.title2.bold())
                    Text("Use these phrases with Hey Siri to control iMusic hands-free.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            Section("Available Commands") {
                ForEach(shortcuts, id: \.title) { item in
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(item.color.gradient)
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: item.icon)
                                    .foregroundStyle(.white)
                                    .font(.system(size: 20))
                            )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.headline)
                            Text(item.phrase)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("How to use") {
                Label("Say \"Hey Siri\" or hold the side button", systemImage: "1.circle.fill")
                Label("Speak the command with your song or playlist name", systemImage: "2.circle.fill")
                Label("iMusic opens and starts playing automatically", systemImage: "3.circle.fill")
            }
            .foregroundStyle(.secondary)
            .font(.subheadline)

            Section {
                Button {
                    if let url = URL(string: "App-prefs:SIRI") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Manage in Settings → Siri & Search", systemImage: "gear")
                }
            }
        }
        .navigationTitle("Siri")
        .navigationBarTitleDisplayMode(.inline)
    }
}
