import Foundation
import Combine

enum PendingPlayerAction { case pause, resume, skip, previous }

/// Singleton that bridges App Intents → running app state.
/// Intents write here; views observe and react.
final class IntentBridge: ObservableObject {
    static let shared = IntentBridge()
    private init() {}

    @Published var pendingYouTubeSearch: String? = nil
    @Published var pendingSavedSongSearch: String? = nil
    @Published var pendingPlaylistName: String? = nil
    @Published var pendingPlayerAction: PendingPlayerAction? = nil
}
