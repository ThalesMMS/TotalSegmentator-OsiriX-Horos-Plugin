//
// TotalSegmentatorPluginTypes.swift
// TotalSegmentator
//
// Shared types for the TotalSegmentator Horos plugin.
//

import Cocoa
import CoreData

typealias ExecutableResolution = (executableURL: URL, leadingArguments: [String], environment: [String: String]?)

struct TaskOption {
    let title: String
    let value: String?
    let description: String
}

struct TaskGroup {
    let name: String
    let tasks: [TaskOption]
}

struct ProcessExecutionResult {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
    let error: Error?
}

protocol SegmentationProgressReporting: AnyObject {
    var capturedLog: String { get }
    var isCancellationRequested: Bool { get }

    func append(_ message: String)
    func markProcessFinished()
    func close()
    func close(after delay: TimeInterval)
}

final class TotalSegmentatorActivityReporter: SegmentationProgressReporting {
    private let thread: Thread
    private let manager: ThreadsManager?
    private let lock = NSLock()
    private var didClose = false
    private var logStorage = ""

    var capturedLog: String {
        lock.lock()
        defer { lock.unlock() }
        return logStorage
    }

    var isCancellationRequested: Bool {
        if thread.isCancelled {
            return true
        }
        return (thread.value(forKey: "isCancelled") as? Bool) ?? false
    }

    init(thread: Thread = .current, manager: ThreadsManager? = ThreadsManager.`default`()) {
        self.thread = thread
        self.manager = manager
        Self.configureForActivity(thread)
        update(status: "Starting TotalSegmentator", details: "Preparing segmentation run.", progress: 0.01)
    }

    static func startActivityThread(named name: String, _ body: @escaping () -> Void) {
        let thread = Thread {
            autoreleasepool {
                body()
            }
        }
        thread.name = name
        configureForActivity(thread)

        if let manager = ThreadsManager.`default`() {
            manager.addThreadAndStart(thread)
        } else {
            thread.start()
        }
    }

    func append(_ message: String) {
        let normalized = message.hasSuffix("\n") ? message : message + "\n"
        lock.lock()
        logStorage.append(normalized)
        lock.unlock()

        let status = Self.statusLine(from: message)
        let progress = Self.progressEstimate(for: message)
        update(status: status, details: status, progress: progress)
    }

    func markProcessFinished() {
        update(status: isCancellationRequested ? "Cancelled" : "Finished", details: "TotalSegmentator run completed.", progress: 1.0)
    }

    func close(after delay: TimeInterval) {
        if delay <= 0 {
            close()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.close()
        }
    }

    func close() {
        lock.lock()
        if didClose {
            lock.unlock()
            return
        }
        didClose = true
        lock.unlock()

        if let manager = manager {
            manager.removeThread(thread)
        }
    }

    private func update(status: String, details: String, progress: Double?) {
        setThreadValue(status, forKey: "status")
        setThreadValue(details, forKey: "progressDetails")
        if let progress = progress {
            setThreadValue(max(0.0, min(progress, 1.0)), forKey: "progress")
        }

        DispatchQueue.main.async {
            BrowserController.updateActivity()
        }
    }

    private func setThreadValue(_ value: Any, forKey key: String) {
        thread.setValue(value, forKey: key)
    }

    private static func configureForActivity(_ thread: Thread) {
        thread.name = thread.name ?? "TotalSegmentator"
        thread.setValue(UUID().uuidString, forKey: "uniqueId")
        thread.setValue(true, forKey: "supportsCancel")
        thread.setValue(true, forKey: "supportsBackgrounding")
        thread.setValue(false, forKey: "isCancelled")
        thread.setValue(0.0, forKey: "progress")
        thread.setValue("Queued", forKey: "status")
        thread.setValue("TotalSegmentator", forKey: "progressDetails")
    }

    private static func statusLine(from message: String) -> String {
        let trimmed = message
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Running TotalSegmentator"
        return String(trimmed.prefix(160))
    }

    private static func progressEstimate(for message: String) -> Double? {
        let lowercased = message.lowercased()
        if lowercased.contains("preparing totalsegmentator environment") { return 0.03 }
        if lowercased.contains("ensuring totalsegmentator") { return 0.06 }
        if lowercased.contains("initial setup complete") { return 0.10 }
        if lowercased.contains("running totalsegmentator") { return 0.15 }
        if lowercased.contains("converted nifti") { return 0.82 }
        if lowercased.contains("applying segmentation rois") { return 0.88 }
        if lowercased.contains("created") && lowercased.contains("volumetric brush roi") { return 0.94 }
        if lowercased.contains("applied") && lowercased.contains("rt struct") { return 0.96 }
        if lowercased.contains("segmentation finished successfully") { return 1.0 }
        return nil
    }
}

enum SegmentationOutputType: Equatable {
    case dicom
    case nifti
    case other(String?)

    init(argumentValue: String?) {
        guard let normalized = argumentValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !normalized.isEmpty else {
            self = .dicom
            return
        }

        switch normalized {
        case "dicom":
            self = .dicom
        case "nifti", "nifti_gz", "nii", "nii.gz":
            self = .nifti
        default:
            self = .other(argumentValue)
        }
    }

    var description: String {
        switch self {
        case .dicom:
            return "dicom"
        case .nifti:
            return "nifti"
        case .other(let value):
            return value ?? "unknown"
        }
    }
}

struct ExportedSeries {
    let series: DicomSeries
    let modality: String
    let exportedDirectory: URL
    let exportedFiles: [URL]
    let seriesInstanceUID: String?
    let studyInstanceUID: String?
}

struct ExportResult {
    let directory: URL
    let series: [ExportedSeries]
}

struct SegmentationImportResult {
    let addedFilePaths: [String]
    let rtStructPaths: [String]
    let importedObjectIDs: [NSManagedObjectID]
    let outputType: SegmentationOutputType
    let volumetricROIManifestPath: String?
}

enum NiftiConversionError: LocalizedError {
    case missingReferenceSeries
    case scriptFailed(status: Int32, stderr: String)
    case responseParsingFailed
    case noOutputsProduced

    var errorDescription: String? {
        switch self {
        case .missingReferenceSeries:
            return "Unable to locate a reference DICOM series for NIfTI conversion."
        case .scriptFailed(let status, let stderr):
            if stderr.isEmpty {
                return "The NIfTI to DICOM conversion script failed with status \(status)."
            }
            return "The NIfTI to DICOM conversion script failed with status \(status): \(stderr)"
        case .responseParsingFailed:
            return "Failed to parse the response from the NIfTI to DICOM conversion script."
        case .noOutputsProduced:
            return "The NIfTI to DICOM conversion did not produce any importable files."
        }
    }
}

enum SegmentationPostProcessingError: LocalizedError {
    case browserUnavailable
    case databaseUnavailable
    case noImportableResults
    case unsupportedOutputType(String?)

    var errorDescription: String? {
        switch self {
        case .browserUnavailable:
            return "The Horos browser window is not available."
        case .databaseUnavailable:
            return "The Horos database is not available."
        case .noImportableResults:
            return "No segmentation outputs could be imported into Horos."
        case .unsupportedOutputType(let value):
            if let value = value, !value.isEmpty {
                return "The segmentation output type '\(value)' is not supported by the plugin."
            }
            return "The segmentation output type is not supported by the plugin."
        }
    }
}

enum ClassSelectionError: LocalizedError {
    case retrievalFailed(String)
    case decodingFailed
    case noClassesAvailable

    var errorDescription: String? {
        switch self {
        case .retrievalFailed(let message):
            return "Failed to load available classes: \(message)"
        case .decodingFailed:
            return "Received an unexpected response while loading available classes."
        case .noClassesAvailable:
            return "No selectable classes were returned for the current task."
        }
    }
}

enum Dcm2NiixBootstrapError: LocalizedError {
    case cachedBinaryInvalid(expected: String)
    case cachedBinaryRemovalFailed(expected: String)
    case checksumUnavailable
    case checksumMismatch(expected: String, actual: String)
    case extractedBinaryMissing
    case extractedBinaryChecksumMismatch

    var errorDescription: String? {
        switch self {
        case .cachedBinaryInvalid(let expected):
            return "Cached dcm2niix is invalid and cannot be used. Please retry bootstrap or install dcm2niix manually. Expected SHA-256 \(expected)."
        case .cachedBinaryRemovalFailed(let expected):
            return "Cached dcm2niix is invalid and could not be quarantined or removed, so bootstrapping was aborted. Please remove it manually or install dcm2niix yourself. Expected SHA-256 \(expected)."
        case .checksumUnavailable:
            return "The downloaded dcm2niix file could not be verified. The file may be corrupted or tampered with. Please retry or manually install dcm2niix."
        case .checksumMismatch(let expected, let actual):
            return "The downloaded dcm2niix file did not match the expected checksum. The file may be corrupted or tampered with. Please retry or manually install dcm2niix. Expected SHA-256 \(expected), actual SHA-256 \(actual)."
        case .extractedBinaryMissing:
            return "The verified dcm2niix archive did not contain the expected dcm2niix binary. Please install dcm2niix manually."
        case .extractedBinaryChecksumMismatch:
            return "The extracted dcm2niix binary did not match the expected checksum. The file may be corrupted or tampered with. Please retry or manually install dcm2niix."
        }
    }
}

enum ClassSelectionSummaryFormatter {
    static func components(for names: [String]) -> (text: String, tooltip: String?) {
        let sorted = names.sorted()
        if sorted.isEmpty {
            return (
                NSLocalizedString("All classes", comment: "Summary shown when all classes are selected"),
                nil
            )
        }

        if sorted.count <= 3 {
            let summary = sorted.joined(separator: ", ")
            return (summary, summary)
        }

        let summaryText = String(
            format: NSLocalizedString("%d classes selected", comment: "Summary with number of selected classes"),
            sorted.count
        )
        return (summaryText, sorted.joined(separator: ", "))
    }
}

struct SegmentationAuditEntry: Codable {
    struct SeriesInfo: Codable {
        let seriesInstanceUID: String?
        let studyInstanceUID: String?
        let modality: String
        let exportedFileCount: Int
    }

    let timestamp: Date
    let outputDirectory: String
    let outputType: String
    let importedFileCount: Int
    let rtStructCount: Int
    let task: String?
    let device: String?
    let useFast: Bool
    let additionalArguments: String?
    let modelVersion: String?
    let series: [SeriesInfo]
    let convertedFromNifti: Bool
}

enum SegmentationValidationError: LocalizedError {
    case executableNotFound
    case outputDirectoryMissing
    case outputDirectoryEmpty

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Unable to locate the TotalSegmentator executable. Please review the settings."
        case .outputDirectoryMissing:
            return "No output directory was created by TotalSegmentator."
        case .outputDirectoryEmpty:
            return "The TotalSegmentator output directory is empty. Please check the logs for errors."
        }
    }
}
