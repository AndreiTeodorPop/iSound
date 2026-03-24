import SwiftUI
import UniformTypeIdentifiers

// MARK: - Identifiable URL (used as .sheet(item:) binding)

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
    init(_ url: URL) { self.url = url }
}

// MARK: - Document Picker (moves file to user-chosen location)

struct FileSaverPicker: UIViewControllerRepresentable {
    let sourceURL: URL
    let onCompletion: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCompletion: onCompletion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [sourceURL], asCopy: true)
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
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
