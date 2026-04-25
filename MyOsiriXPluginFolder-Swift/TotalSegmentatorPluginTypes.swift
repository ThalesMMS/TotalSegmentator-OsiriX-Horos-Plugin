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
