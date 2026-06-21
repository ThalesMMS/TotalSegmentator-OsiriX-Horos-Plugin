//
// TotalSegmentatorJobManifestTypes.swift
// TotalSegmentator
//
// DICOM export and segmentation job manifest contracts.
//

import CryptoKit
import Foundation

struct DicomExportedInstance: Codable {
    let sourcePathHash: String
    let destinationName: String
    let sopInstanceUID: String
    let studyInstanceUID: String?
    let seriesInstanceUID: String?
    let frameOfReferenceUID: String?
    let modality: String
    let sourceOrderIndex: Int
    let dicomFrameID: Int?
    let frameCount: Int
    let byteCount: Int64
    let sha256: String
    let rows: Int?
    let columns: Int?
    let sliceLocation: Double?
    let imagePositionPatient: [Double]?
    let imageOrientationPatient: [Double]?
}

struct DicomExportManifest: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let createdAt: Date
    let jobUUID: String
    let sourceIdentityHash: String
    let studyInstanceUID: String?
    let seriesInstanceUID: String?
    let frameOfReferenceUID: String?
    let modality: String
    let sourceInstanceCount: Int
    let exportedFileCount: Int
    let exportComplete: Bool
    let instances: [DicomExportedInstance]
}

struct SegmentationJobSourceFile: Codable {
    let relativePath: String
    let sha256: String
    let byteCount: Int64
    let sopInstanceUID: String?
}

struct SegmentationJobGeometry: Codable {
    let rows: Int?
    let columns: Int?
    let numberOfFrames: Int?
    let pixelSpacing: [Double]?
    let sliceSpacing: Double?
    let slicePositions: [Double]
    let imageOrientationPatient: [Double]?
    let imagePositionPatient: [Double]?
    let normalizedAffine: [Double]?
    let coordinateSystemConvention: String
}

struct SegmentationJobFrameIdentity: Codable {
    let sopInstanceUID: String
    let frameIndex: Int
    let dicomFrameID: Int?
    let sourceFileRelativePath: String?
    let frameOfReferenceUID: String?
}

struct SegmentationJobDerivedGeometry: Codable {
    let kind: String
    let sourceToDerivedTransform: [Double]?
    let notes: String?
}

struct SegmentationJobHostHints: Codable {
    let hostApplication: String?
    let hostSeriesObjectURI: String?
    let hostViewerDescription: String?
}

struct SegmentationJobRunSnapshot: Codable {
    let task: String?
    let selectedClasses: [String]
    let useFast: Bool
    let device: String?
    let additionalArguments: [String]
    let capabilityManifestVersion: String
    let capabilityTaskIdentifier: String
    let requestedDevice: String?
    let effectiveDevice: String
    let requestedQuality: String
    let effectiveQuality: String
    let runtimeSelectionReason: String
}

struct SegmentationJobEnvironmentSnapshot: Codable {
    let environmentLockIdentifier: String
    let environmentManifestIdentifier: String?
    let environmentManifestPath: String?
    let bridgeVersion: String
    let bridgeSchemaVersion: Int
    let bridgePackageHash: String?
}

struct SegmentationJobCanonicalOutputPaths: Codable {
    let exportDirectory: String
    let dicomInputDirectory: String?
    let exportManifestPath: String?
    let runWorkspaceDirectory: String?
    let runCompletionManifestPath: String?
    let outputDirectory: String?
    let publishedOutputDirectory: String?
    let bridgeScriptPath: String?
    let bridgeConfigurationPath: String?
}

struct SegmentationJobManifest: Codable {
    static let currentSchemaVersion = 1
    static let dicomLPSCoordinateSystem = "DICOM_LPS"

    let schemaVersion: Int
    let jobUUID: String
    let createdAt: Date
    let pluginVersion: String
    let pluginBuild: String
    let studyInstanceUID: String?
    let seriesInstanceUID: String?
    let frameOfReferenceUID: String?
    let modality: String
    let orderedSOPInstanceUIDs: [String]
    let sourceIdentityHash: String
    let sourceFileCount: Int
    let sourceFiles: [SegmentationJobSourceFile]
    let geometry: SegmentationJobGeometry
    let frameIdentities: [SegmentationJobFrameIdentity]
    let derivedGeometry: SegmentationJobDerivedGeometry
    let hostHints: SegmentationJobHostHints
    var runSnapshot: SegmentationJobRunSnapshot?
    var environmentSnapshot: SegmentationJobEnvironmentSnapshot?
    var canonicalOutputPaths: SegmentationJobCanonicalOutputPaths
    var runState: String

    private struct SourceIdentityPayload: Codable {
        let studyInstanceUID: String?
        let seriesInstanceUID: String?
        let frameOfReferenceUID: String?
        let orderedSOPInstanceUIDs: [String]
    }

    /// Encodes source identity information as JSON with deterministically sorted keys.
    /// - Parameters:
    ///   - studyInstanceUID: Optional study instance UID.
    ///   - seriesInstanceUID: Optional series instance UID.
    ///   - frameOfReferenceUID: Optional frame of reference UID.
    ///   - orderedSOPInstanceUIDs: Ordered SOP instance UIDs.
    /// - Returns: JSON-encoded data containing the source identity information, or empty data if encoding fails.
    static func sourceIdentityPayload(
        studyInstanceUID: String?,
        seriesInstanceUID: String?,
        frameOfReferenceUID: String?,
        orderedSOPInstanceUIDs: [String]
    ) -> Data {
        let payload = SourceIdentityPayload(
            studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: seriesInstanceUID,
            frameOfReferenceUID: frameOfReferenceUID,
            orderedSOPInstanceUIDs: orderedSOPInstanceUIDs
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)) ?? Data()
    }

    /// Computes a deterministic SHA256 hash of the source identity information.
    /// - Parameters:
    ///   - studyInstanceUID: The optional study instance UID.
    ///   - seriesInstanceUID: The optional series instance UID.
    ///   - frameOfReferenceUID: The optional frame of reference UID.
    ///   - orderedSOPInstanceUIDs: The ordered SOP instance UIDs identifying the source instances.
    /// - Returns: A lowercase hexadecimal string representation of the SHA256 hash.
    static func computeSourceIdentityHash(
        studyInstanceUID: String?,
        seriesInstanceUID: String?,
        frameOfReferenceUID: String?,
        orderedSOPInstanceUIDs: [String]
    ) -> String {
        let payload = sourceIdentityPayload(
            studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: seriesInstanceUID,
            frameOfReferenceUID: frameOfReferenceUID,
            orderedSOPInstanceUIDs: orderedSOPInstanceUIDs
        )
        let digest = SHA256.hash(data: payload)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
