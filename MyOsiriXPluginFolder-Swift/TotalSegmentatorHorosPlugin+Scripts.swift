//
// TotalSegmentatorHorosPlugin+Scripts.swift
// TotalSegmentator
//

import Cocoa
import CryptoKit

extension TotalSegmentatorHorosPlugin {
    static let bridgeVersion = "0.1.0"
    static let bridgeSchemaVersion = 1
    static let expectedBridgePackageHash = "ffd4f76c452463fe8fd0f42283943dc6c83b2108cb2530a5b5f13cb177b724f4"

    /// Resolves the bundled CLI bridge script into the specified directory.
    /// - Parameters:
    ///   - directory: The directory where the script should be resolved.
    /// - Returns: A URL to the resolved CLI script.
    /// - Throws: If the bridge package cannot be located, copied, validated, or if the script is missing.
    func prepareBridgeScript(at directory: URL) throws -> URL {
        try resolveBundledBridgeScript(named: "cli.py", at: directory)
    }

    /// Resolves the bundled NIfTI conversion script into the provided directory.
    /// - Parameters:
    ///   - directory: The directory where the script will be resolved.
    /// - Returns: The URL of the resolved NIfTI conversion script.
    func prepareNiftiConversionScript(at directory: URL) throws -> URL {
        try resolveBundledBridgeScript(named: "nifti_conversion.py", at: directory)
    }

    /// Resolves and returns the bundled volumetric projection script in the provided directory.
    /// - Parameters:
    ///   - directory: The directory where the script will be resolved.
    /// - Returns: The URL to the volumetric projection script.
    /// - Throws: If the script cannot be located, copied, or validated.
    func prepareVolumetricProjectionScript(at directory: URL) throws -> URL {
        try resolveBundledBridgeScript(named: "volumetric_projection.py", at: directory)
    }

    /// Resolves the bundled Python runtime capability probe script into the specified directory.
    /// - Parameters:
    ///   - directory: The directory where the script will be resolved.
    /// - Returns: The URL of the resolved script file.
    func prepareRuntimeCapabilityProbeScript(at directory: URL) throws -> URL {
        try resolveBundledBridgeScript(named: "runtime_capabilities.py", at: directory)
    }

    /// Resolves the path to a bundled Python bridge script.
    /// - Parameters:
    ///   - scriptName: The name of the script file.
    ///   - directory: The directory where the bridge package will be copied.
    /// - Returns: The URL path to the resolved script.
    /// - Throws: An error if the script does not exist in the bridge package.
    func resolveBundledBridgeScript(named scriptName: String, at directory: URL) throws -> URL {
        let bridgeRoot = try copyBundledBridgePackage(to: directory)
        let scriptURL = bridgeRoot
            .appendingPathComponent("ts_horos_bridge", isDirectory: true)
            .appendingPathComponent(scriptName, isDirectory: false)

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw NSError(
                domain: "org.totalsegmentator.plugin.bridge",
                code: 1101,
                userInfo: [NSLocalizedDescriptionKey: "Bundled bridge script is missing: \(scriptName)."]
            )
        }

        return scriptURL
    }

    /// Copies the bundled Python bridge package to the specified directory and validates its integrity.
    /// - Parameters:
    ///   - directory: The directory where the bridge package should be copied.
    /// - Returns: The URL of the copied and validated Python bridge package.
    /// - Throws: If the bundled package cannot be located, copied, or validation fails.
    func copyBundledBridgePackage(to directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let sourceURL = try bundledBridgePackageURL()
        let destinationURL = directory.appendingPathComponent("python_bridge", isDirectory: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        try verifyBundledBridgeHealth(at: destinationURL)
        return destinationURL
    }

    /// Locates the bundled Python bridge package.
    /// - Returns: The URL of the bundled Python bridge package.
    /// - Throws: An error if the bundled bridge package cannot be located.
    func bundledBridgePackageURL() throws -> URL {
        let bundle = Bundle(for: TotalSegmentatorHorosPlugin.self)
        if let resourceURL = bundle.url(forResource: "python_bridge", withExtension: nil) {
            return resourceURL
        }

        let sourceTreeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("python_bridge", isDirectory: true)
        if FileManager.default.fileExists(atPath: sourceTreeURL.path) {
            return sourceTreeURL
        }

        throw NSError(
            domain: "org.totalsegmentator.plugin.bridge",
            code: 1100,
            userInfo: [NSLocalizedDescriptionKey: "Unable to locate bundled TotalSegmentator Python bridge."]
        )
    }

    /// Computes the SHA-256 hash of the bundled bridge package.
    /// - Returns: The computed hash as a lowercase hex string, or `nil` if the package cannot be located or the hash computation fails.
    func currentBridgePackageHash() -> String? {
        guard let url = try? bundledBridgePackageURL() else {
            return nil
        }
        return try? bridgePackageHash(for: url)
    }

    /// Computes a SHA-256 hash of the Python bridge package.
    /// - Parameters:
    ///   - packageURL: The directory containing the Python bridge package.
    /// - Returns: The SHA-256 hash as a lowercase hexadecimal string.
    /// - Throws: An `NSError` with code 1102 if unable to enumerate the package directory.
    func bridgePackageHash(for packageURL: URL) throws -> String {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NSError(
                domain: "org.totalsegmentator.plugin.bridge",
                code: 1102,
                userInfo: [NSLocalizedDescriptionKey: "Unable to enumerate bundled Python bridge."]
            )
        }

        let packageRootPath = packageURL.standardizedFileURL.resolvingSymlinksInPath().path
        let packageRootPrefix = packageRootPath.hasSuffix("/") ? packageRootPath : packageRootPath + "/"
        var fileEntries: [(relativePath: String, fileURL: URL)] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if fileURL.pathComponents.contains("__pycache__") { continue }
            if fileURL.pathExtension == "pyc" { continue }

            let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
            guard filePath.hasPrefix(packageRootPrefix) else {
                throw NSError(
                    domain: "org.totalsegmentator.plugin.bridge",
                    code: 1110,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to derive a stable relative bridge path for \(fileURL.lastPathComponent)."]
                )
            }
            let relativePath = String(filePath.dropFirst(packageRootPrefix.count))
            fileEntries.append((relativePath: relativePath, fileURL: fileURL))
        }

        var hasher = SHA256()
        for entry in fileEntries.sorted(by: { $0.relativePath < $1.relativePath }) {
            if let relativeData = entry.relativePath.data(using: .utf8) {
                hasher.update(data: relativeData)
            }
            hasher.update(data: try Data(contentsOf: entry.fileURL))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Validates that the bundled Python bridge package's hash, required scripts, and version markers match the plugin's expectations.
    /// - Parameter packageURL: The URL of the bundled bridge package directory.
    /// - Throws: `NSError` if the package hash does not match, required scripts are missing, or version markers are incorrect.
    func verifyBundledBridgeHealth(at packageURL: URL) throws {
        let actualHash = try bridgePackageHash(for: packageURL)
        guard actualHash == Self.expectedBridgePackageHash else {
            throw NSError(
                domain: "org.totalsegmentator.plugin.bridge",
                code: 1107,
                userInfo: [NSLocalizedDescriptionKey: "Bundled Python bridge package hash does not match the plugin."]
            )
        }

        let packageDirectory = packageURL.appendingPathComponent("ts_horos_bridge", isDirectory: true)
        for scriptName in ["cli.py", "nifti_conversion.py", "volumetric_projection.py", "runtime_capabilities.py", "schemas.py"] {
            let scriptURL = packageDirectory.appendingPathComponent(scriptName, isDirectory: false)
            guard FileManager.default.fileExists(atPath: scriptURL.path) else {
                throw NSError(
                    domain: "org.totalsegmentator.plugin.bridge",
                    code: 1108,
                    userInfo: [NSLocalizedDescriptionKey: "Bundled Python bridge package is missing \(scriptName)."]
                )
            }
        }

        let schemasURL = packageDirectory.appendingPathComponent("schemas.py", isDirectory: false)
        let schemasSource = try String(contentsOf: schemasURL, encoding: .utf8)
        guard schemasSource.contains("BRIDGE_VERSION = \"\(Self.bridgeVersion)\""),
              schemasSource.contains("BRIDGE_SCHEMA_VERSION = \(Self.bridgeSchemaVersion)") else {
            throw NSError(
                domain: "org.totalsegmentator.plugin.bridge",
                code: 1109,
                userInfo: [NSLocalizedDescriptionKey: "Bundled Python bridge schema does not match the plugin."]
            )
        }
    }

    /// Probes the system's runtime capabilities.
    /// - Parameters:
    ///   - progressController: Reports progress during probe execution.
    /// - Returns: A RuntimeCapabilityProbe containing the detected system capabilities. If detection fails, returns a fallback probe with failure information.
    func probeRuntimeCapabilities(
        using executable: ExecutableResolution,
        progressController: SegmentationProgressReporting? = nil
    ) -> RuntimeCapabilityProbe {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TotalSegmentatorRuntimeProbe-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: workDirectory)
        }

        do {
            let scriptURL = try prepareRuntimeCapabilityProbeScript(at: workDirectory)
            let result = runPythonProcess(
                using: executable,
                arguments: [scriptURL.path],
                progressController: progressController
            )

            if let error = result.error {
                return Self.fallbackRuntimeCapabilityProbe(
                    failures: ["Runtime capability probe failed to start: \(error.localizedDescription)"]
                )
            }

            guard result.terminationStatus == 0 else {
                let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
                return Self.fallbackRuntimeCapabilityProbe(
                    failures: ["Runtime capability probe exited with status \(result.terminationStatus): \(stderr)"]
                )
            }

            let decoder = JSONDecoder()
            let probe = try decoder.decode(RuntimeCapabilityProbe.self, from: result.stdout)
            if probe.schemaVersion != RuntimeCapabilityProbe.currentSchemaVersion {
                return Self.fallbackRuntimeCapabilityProbe(
                    failures: ["Runtime capability probe schema \(probe.schemaVersion) does not match \(RuntimeCapabilityProbe.currentSchemaVersion)."]
                )
            }

            return probe
        } catch {
            return Self.fallbackRuntimeCapabilityProbe(
                failures: ["Runtime capability probe failed: \(error.localizedDescription)"]
            )
        }
    }

    /// Validates and returns the bridge result payload from a JSON file.
    ///
    /// - Parameters:
    ///   - resultURL: The URL of the bridge result JSON file.
    ///   - expectedStage: The optional expected stage field value for validation.
    /// - Returns: The parsed and validated bridge result payload.
    /// - Throws: If the JSON is invalid, the schema version does not match, the stage does not match the expected value, or the bridge reported an error status.
    func readBridgeResult(from resultURL: URL, expectedStage: String? = nil) throws -> [String: Any] {
        let data = try Data(contentsOf: resultURL)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "org.totalsegmentator.plugin.bridge",
                code: 1103,
                userInfo: [NSLocalizedDescriptionKey: "Bridge result is not a JSON object."]
            )
        }

        guard (payload["schema_version"] as? Int) == Self.bridgeSchemaVersion else {
            throw NSError(
                domain: "org.totalsegmentator.plugin.bridge",
                code: 1104,
                userInfo: [NSLocalizedDescriptionKey: "Bridge result schema version does not match the plugin."]
            )
        }

        if let expectedStage = expectedStage {
            guard let stage = payload["stage"] as? String else {
                throw NSError(
                    domain: "org.totalsegmentator.plugin.bridge",
                    code: 1105,
                    userInfo: [NSLocalizedDescriptionKey: "Bridge result is missing expected stage '\(expectedStage)'."]
                )
            }
            if stage != expectedStage {
                throw NSError(
                    domain: "org.totalsegmentator.plugin.bridge",
                    code: 1105,
                    userInfo: [NSLocalizedDescriptionKey: "Bridge result stage '\(stage)' did not match expected stage '\(expectedStage)'."]
                )
            }
        }

        if let status = payload["status"] as? String,
           status == "error" {
            let message = payload["message"] as? String ?? "Bridge reported an error."
            throw NSError(
                domain: "org.totalsegmentator.plugin.bridge",
                code: 1106,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        return payload
    }

    /// Writes volumetric projection configuration to a JSON file.
    /// - Parameters:
    ///   - directory: The directory where the configuration file will be created.
    ///   - manifestPath: The manifest path to include in the configuration.
    ///   - outputDirectory: The output directory path to include in the configuration.
    ///   - planes: The plane data to include in the configuration.
    /// - Returns: The URL of the created configuration file.
    func writeVolumetricProjectionConfiguration(
        to directory: URL,
        manifestPath: String,
        outputDirectory: URL,
        planes: [[String: Any]]
    ) throws -> URL {
        let configurationURL = directory.appendingPathComponent("TotalSegmentatorVolumetricProjection.json", isDirectory: false)

        let payload: [String: Any] = [
            "schema_version": Self.bridgeSchemaVersion,
            "manifest_path": manifestPath,
            "output_dir": outputDirectory.path,
            "planes": planes
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: configurationURL, options: .atomic)

        return configurationURL
    }

    /// Creates a TotalSegmentator bridge configuration file with the specified parameters.
    /// - Parameters:
    ///   - directory: The directory where the configuration file will be written.
    ///   - outputType: The desired output format.
    /// - Returns: The URL of the created configuration file.
    func writeBridgeConfiguration(
        to directory: URL,
        dicomDirectory: URL,
        outputDirectory: URL,
        outputType: String,
        totalsegmentatorArguments: [String],
        canonicalOutputName: String,
        useMultilabel: Bool,
        taskIdentifier: String
    ) throws -> URL {
        let configurationURL = directory.appendingPathComponent("TotalSegmentatorBridgeConfiguration.json", isDirectory: false)

        let payload: [String: Any] = [
            "schema_version": Self.bridgeSchemaVersion,
            "dicom_dir": dicomDirectory.path,
            "output_dir": outputDirectory.path,
            "output_type": outputType,
            "totalseg_args": totalsegmentatorArguments,
            "canonical_output_name": canonicalOutputName,
            "use_multilabel": useMultilabel,
            "task_identifier": taskIdentifier
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: configurationURL, options: .atomic)

        return configurationURL
    }

    /// Writes NIfTI conversion configuration to a JSON file.
    /// - Parameters:
    ///   - directory: The directory where the configuration file is written.
    ///   - niftiDirectory: The path to the NIfTI files.
    ///   - referenceDirectory: The path to the reference DICOM directory.
    ///   - outputDirectory: The path to the output directory.
    ///   - preferences: Segmentation preferences containing selected classes and RT struct export settings.
    ///   - jobManifest: Job metadata including the job UUID, source identity hash, and DICOM instance UIDs.
    ///   - allowBinaryMaskCompatibility: Whether to allow binary mask format compatibility in the output.
    /// - Returns: The URL of the written configuration file.
    func writeNiftiConversionConfiguration(
        to directory: URL,
        niftiDirectory: URL,
        referenceDirectory: URL,
        outputDirectory: URL,
        preferences: SegmentationPreferences.State,
        jobManifest: SegmentationJobManifest,
        allowBinaryMaskCompatibility: Bool
    ) throws -> URL {
        let configurationURL = directory.appendingPathComponent("TotalSegmentatorNiftiConversion.json", isDirectory: false)

        var payload: [String: Any] = [
            "schema_version": Self.bridgeSchemaVersion,
            "nifti_dir": niftiDirectory.path,
            "reference_dicom_dir": referenceDirectory.path,
            "output_dir": outputDirectory.path,
            "selected_classes": preferences.selectedClassNames,
            "rtstruct_name": "segmentations_rtstruct.dcm",
            "rtstruct_mode": preferences.rtStructExportMode.rawValue,
            "job": [
                "job_uuid": jobManifest.jobUUID,
                "source_identity_hash": jobManifest.sourceIdentityHash,
                "roi_provenance_comment": roiProvenanceComment(for: jobManifest),
                "source_identity": [
                    "study_instance_uid": jobManifest.studyInstanceUID ?? "",
                    "series_instance_uid": jobManifest.seriesInstanceUID ?? "",
                    "frame_of_reference_uid": jobManifest.frameOfReferenceUID ?? "",
                    "ordered_sop_instance_uids": jobManifest.orderedSOPInstanceUIDs
                ]
            ],
            "allow_binary_mask_compatibility": allowBinaryMaskCompatibility
        ]

        if let task = preferences.task {
            payload["task"] = task
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: configurationURL, options: .atomic)

        return configurationURL
    }
}
