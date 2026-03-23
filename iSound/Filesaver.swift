import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Identifiable URL (used as .sheet(item:) binding)

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
    init(_ url: URL) { self.url = url }
}

// MARK: - Document Picker (Move to user-chosen location)

struct FileSaverPicker: UIViewControllerRepresentable {
    let sourceURL: URL
    let onCompletion: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCompletion: onCompletion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // exportingURLs moves the file to wherever the user picks
        let picker = UIDocumentPickerViewController(forExporting: [sourceURL], asCopy: true)
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        // Default to Downloads directory
        picker.directoryURL = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    enum FileSaverError: LocalizedError {
        case cancelled
        var errorDescription: String? { "Save cancelled" }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onCompletion: (Result<URL, Error>) -> Void
        init(onCompletion: @escaping (Result<URL, Error>) -> Void) {
            self.onCompletion = onCompletion
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onCompletion(.success(url))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCompletion(.failure(FileSaverError.cancelled))
        }
    }
}

// MARK: - Download + Save State Machine

/// Shared logic used by both YouTubeSearchView and NowPlayingView.
/// 1. Downloads the file to a temp URL
/// 2. Presents FileSaverPicker so user chooses where to save
/// 3. Copies to ImportedAudio so AudioLibrary finds it in-app
@MainActor
final class DownloadManager: ObservableObject {
    @Published var pendingFileURL: URL?          // set → triggers sheet
    @Published var isDownloading  = false
    @Published var isSaved        = false
    @Published var toast: ToastItem?

    struct ToastItem {
        let message: String
        let isError: Bool
    }

    private var toastTask: Task<Void, Never>?
    private var pendingFileName: String = ""

    func download(videoID: String, title: String, library: AudioLibrary) async {
        guard !isDownloading, !isSaved else { return }
        isDownloading = true
        do {
            let tempURL = try await StreamService.downloadAudioToTemp(for: videoID, title: title)
            pendingFileName = tempURL.lastPathComponent
            isDownloading   = false
            pendingFileURL  = tempURL   // triggers the .sheet in the view
        } catch {
            isDownloading = false
            showToast(error.localizedDescription, isError: true)
        }
    }

    func handleSaveResult(_ result: Result<URL, Error>, library: AudioLibrary) {
        pendingFileURL = nil
        switch result {
        case .success(let savedURL):
            // Also copy into ImportedAudio for in-app playback
            do {
                try StreamService.copyToImportedAudio(
                    from: savedURL,
                    fileName: pendingFileName
                )
                Task { await library.reloadAfterDownload() }
            } catch {
                print("ImportedAudio copy failed: \(error)")
            }
            isSaved = true
            showToast("Saved to \"\(savedURL.deletingLastPathComponent().lastPathComponent)\"")

        case .failure(let error):
            // Only show error if it wasn't a user cancel
            if (error as? FileSaverPicker.FileSaverError) != .cancelled {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    func reset() {
        isDownloading  = false
        isSaved        = false
        pendingFileURL = nil
        toast          = nil
    }

    private func showToast(_ message: String, isError: Bool = false) {
        toastTask?.cancel()
        toast = ToastItem(message: message, isError: isError)
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}
