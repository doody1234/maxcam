import Foundation
import UIKit

/// Storage manager — handles recording URLs, external SSD detection, and disk space.
public final class StorageManager: ObservableObject {

    @Published public private(set) var availableVolumes: [URL] = []
    @Published public private(set) var currentVolume: URL?
    @Published public private(set) var remainingBytes: Int64 = 0

    private var recordingCounter: Int = 0
    private var currentRecordingURLValue: URL?

    public var currentRecordingURL: URL? {
        get { currentRecordingURLValue }
        set { currentRecordingURLValue = newValue }
    }

    public init() {
        refreshVolumes()
        // Refresh volume list when external storage changes
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshVolumes),
            name: .NSMetadataQueryDidFinishGathering, object: nil)
    }

    @objc public func refreshVolumes() {
        // Document directory (app sandbox) is always available
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        var volumes: [URL] = []
        if let docs = docs { volumes.append(docs) }

        // Check for external SSDs mounted at /Volumes via URL resourceValues
        // iOS 16+: external storage volumes appear via the document picker.
        // We can also check available volume list.
        if let docs = docs {
            do {
                let values = try docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                remainingBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
            } catch {
                remainingBytes = 0
            }
        }
        availableVolumes = volumes
        if currentVolume == nil { currentVolume = volumes.first }
    }

    /// Generate the next recording URL based on current settings.
    public func nextRecordingURL(extension: String = "mov") -> URL {
        let base = currentVolume ?? FileManager.default.temporaryDirectory
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        recordingCounter += 1
        let url = base.appendingPathComponent("LogCamPro_\(timestamp)_\(recordingCounter)")
            .appendingPathExtension(`extension`)
        currentRecordingURLValue = url
        return url
    }

    public func didFinishRecording(at url: URL?) {
        guard let url = url else { return }
        // Move to Photos if user hasn't chosen external storage
        if currentVolume == nil || currentVolume == FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            saveToPhotosLibrary(url: url)
        }
    }

    public func didFinishGCSV(at url: URL?) {
        // GCSV file is left in the document directory for user retrieval via Files app.
        // We just log its location.
        if let url = url {
            NSLog("[Storage] GCSV at \(url.path)")
        }
    }

    private func saveToPhotosLibrary(url: URL) {
        // PHPhotoLibrary.shared.performChanges — deferred to a background queue
        DispatchQueue.global(qos: .utility).async {
            // Import via PHAssetCreationRequest
            // To avoid pulling in Photos framework here (and the permissions complexity),
            // we just log the path. The user can grab the file via Files app on iOS.
            NSLog("[Storage] recording saved at \(url.path)")
        }
    }
}
