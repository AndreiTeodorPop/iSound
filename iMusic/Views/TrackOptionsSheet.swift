import SwiftUI
import AVFoundation
import UIKit

// MARK: - Track Options Sheet

struct TrackOptionsSheet: View {
    let track: Track
    let playlistContext: Playlist?

    let onAddToQueue: () -> Void
    let onDelete: () -> Void
    let onRemoveFromPlaylist: (() -> Void)?

    @EnvironmentObject private var player: AudioPlayer
    @ObservedObject var library: AudioLibrary

    @Environment(\.dismiss) private var dismiss

    @State private var showingEditSheet = false
    @State private var showingAddToPlaylist = false
    @State private var artwork: UIImage? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 36)

                artworkView
                    .padding(.bottom, 20)

                trackInfoView
                    .padding(.bottom, 32)

                optionsList

                Spacer(minLength: 24)

                cancelButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 36)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(20)
        .task { await loadArtwork() }
        .sheet(isPresented: $showingEditSheet) {
            EditTrackSheet(track: track, library: library)
        }
        .sheet(isPresented: $showingAddToPlaylist) {
            AddToPlaylistSheet(
                track: track,
                excludingPlaylist: playlistContext,
                library: library
            )
        }
    }

    // MARK: - Artwork

    private var artworkView: some View {
        Group {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
            } else {
                Color(white: 0.2)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 56))
                            .foregroundStyle(Color(white: 0.5))
                    )
            }
        }
        .frame(width: 200, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func loadArtwork() async {
        guard track.url.isFileURL else { return }
        let asset = AVURLAsset(url: track.url)
        guard let items = try? await asset.load(.commonMetadata) else { return }
        for item in items {
            guard item.commonKey?.rawValue == "artwork",
                  let data = try? await item.load(.dataValue),
                  let image = UIImage(data: data)
            else { continue }
            artwork = image
            return
        }
    }

    // MARK: - Track Info

    private var trackInfoView: some View {
        VStack(spacing: 6) {
            Text(track.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Text(track.artist ?? "Unknown Artist")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color(white: 0.6))
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Options List

    private var optionsList: some View {
        VStack(spacing: 0) {

            optionRow(icon: "play.circle", title: "Add to player queue") {
                onAddToQueue()
                dismiss()
            }

            optionRow(icon: "pencil", title: "Edit track") {
                showingEditSheet = true
            }

            optionRow(icon: "text.badge.plus", title: "Add to playlist") {
                showingAddToPlaylist = true
            }

            if let onRemove = onRemoveFromPlaylist {
                optionRow(icon: "minus.circle", title: "Remove from playlist") {
                    onRemove()
                    dismiss()
                }
            }

            optionRow(icon: "trash", title: "Delete", iconColor: .red) {
                onDelete()
                dismiss()
            }
        }
    }

    private func optionRow(
        icon: String,
        title: String,
        iconColor: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(iconColor)
                    .frame(width: 28)

                Text(title)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white)

                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cancel

    private var cancelButton: some View {
        Button {
            dismiss()
        } label: {
            Text("CANCEL")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color(white: 0.15))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Edit Track Sheet

private struct EditTrackSheet: View {
    let track: Track
    @ObservedObject var library: AudioLibrary

    @Environment(\.dismiss) private var dismiss

    @State private var titleText: String = ""
    @State private var artistText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Track info") {
                    LabeledContent("Title") {
                        TextField("Title", text: $titleText)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Artist") {
                        TextField("Artist", text: $artistText)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Edit Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        library.updateTrackMetadata(
                            track,
                            title: titleText,
                            artist: artistText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : artistText
                        )
                        dismiss()
                    }) {
                        Text("Save").fontWeight(.semibold)
                    }
                    .disabled(titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            titleText  = track.title
            artistText = track.artist ?? ""
        }
        .presentationDetents([.medium])
        .presentationCornerRadius(20)
    }
}

// MARK: - Add to Playlist Sheet

private struct AddToPlaylistSheet: View {
    let track: Track
    let excludingPlaylist: Playlist?
    @ObservedObject var library: AudioLibrary

    @Environment(\.dismiss) private var dismiss

    @State private var addedIDs: Set<UUID> = []

    private var availablePlaylists: [Playlist] {
        library.playlists.filter { $0.id != excludingPlaylist?.id }
    }

    var body: some View {
        NavigationStack {
            List(availablePlaylists, id: \.id) { playlist in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text("\(playlist.trackIDs.count) songs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if addedIDs.contains(playlist.id) || playlist.trackIDs.contains(track.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            library.addTrack(track, to: playlist)
                            addedIDs.insert(playlist.id)
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if availablePlaylists.isEmpty {
                    ContentUnavailableView(
                        "No playlists",
                        systemImage: "music.note.list",
                        description: Text("Create a playlist in the Library tab first.")
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(20)
    }
}
