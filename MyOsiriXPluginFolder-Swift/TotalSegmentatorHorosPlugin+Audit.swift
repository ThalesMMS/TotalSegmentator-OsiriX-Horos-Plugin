//
// TotalSegmentatorHorosPlugin+Audit.swift
// TotalSegmentator
//

import Cocoa
import CryptoKit

extension TotalSegmentatorHorosPlugin {
    func persistAuditMetadata(
        for importResult: SegmentationImportResult,
        exportContext: ExportResult,
        outputDirectory: URL,
        preferences: SegmentationPreferences.State,
        outputType: SegmentationOutputType,
        executable: ExecutableResolution,
        convertedFromNifti: Bool
    ) {
        auditQueue.async {
            let version = self.fetchTotalSegmentatorVersion(using: executable)
            let environmentManifestIdentifier = self.currentEnvironmentManifestIdentifier()
            let environmentManifestPath = self.environmentManifestURL()?.path
            let bridgePackageHash = self.currentBridgePackageHash()
            let jobManifestHash = self.sha256ForAudit(of: exportContext.jobManifestURL)
            let redactedAdditionalArguments: String? = preferences.additionalArguments.flatMap { additionalArguments in
                let redactedTokens = self.redactedCommandLineArguments(Self.tokenize(commandLine: additionalArguments))
                return redactedTokens.isEmpty ? nil : redactedTokens.joined(separator: " ")
            }
            let seriesInfo = exportContext.series.map {
                SegmentationAuditEntry.SeriesInfo(
                    seriesInstanceUID: $0.seriesInstanceUID,
                    studyInstanceUID: $0.studyInstanceUID,
                    modality: $0.modality,
                    exportedFileCount: $0.exportedFiles.count
                )
            }

            let entry = SegmentationAuditEntry(
                timestamp: Date(),
                outputDirectory: outputDirectory.path,
                outputType: outputType.description,
                importedFileCount: importResult.addedFilePaths.count,
                rtStructCount: importResult.rtStructPaths.count,
                task: preferences.task,
                device: preferences.device,
                useFast: preferences.useFast,
                additionalArguments: redactedAdditionalArguments,
                certificationStatusIdentifier: Self.certificationStatusIdentifier,
                certificationStatusDisplayName: Self.certificationStatusDisplayName,
                medicalImagingCertified: Self.medicalImagingCertified,
                validationEvidenceVersion: Self.validationEvidenceVersion,
                bridgeVersion: Self.bridgeVersion,
                bridgeSchemaVersion: Self.bridgeSchemaVersion,
                bridgePackageHash: bridgePackageHash,
                modelVersion: version,
                environmentManifestIdentifier: environmentManifestIdentifier,
                environmentManifestPath: environmentManifestPath,
                environmentLockIdentifier: Self.environmentLockManifest.lockIdentifier,
                jobUUID: exportContext.jobManifest.jobUUID,
                jobManifestPath: exportContext.jobManifestURL.path,
                jobManifestHash: jobManifestHash,
                series: seriesInfo,
                convertedFromNifti: convertedFromNifti
            )

            do {
                try self.appendAuditEntryAtomically(entry)
            } catch {
                NSLog("[TotalSegmentator] Failed to persist audit metadata: %@", error.localizedDescription)
            }
        }
    }

    @discardableResult
    func persistSegmentationProvenance(
        for exportContext: ExportResult,
        workspace: SegmentationRunWorkspace,
        preferences: SegmentationPreferences.State,
        executable: ExecutableResolution,
        outputType: SegmentationOutputType,
        normalizedCLIArguments: [String],
        effectiveDevice: String?,
        effectiveQuality: String,
        runtimeProbe: RuntimeCapabilityProbe?,
        startedAt: Date?,
        endedAt: Date?,
        processExitStatus: Int?,
        cancellationRequested: Bool,
        runState: String,
        stageOutcomes: [SegmentationRunStageOutcome],
        acceptedArtifacts: [SegmentationArtifactRecord],
        completionManifestURL: URL?,
        convertedFromNifti: Bool,
        warnings: [String]
    ) throws -> SegmentationProvenanceRecord {
        let jobManifest = exportContext.jobManifest
        let environmentManifestPathHash = environmentManifestURL().map { sha256ForAudit(of: $0.path) }
        let completionManifestHash = completionManifestURL.flatMap { sha256ForAudit(of: $0) }
        let completionManifestPath = completionManifestURL.map { relativeProvenancePath(from: workspace.rootDirectory, to: $0) }
        let artifactIntegrityMismatches = verifyArtifactIntegrity(
            acceptedArtifacts,
            rootDirectory: workspace.outputDirectory
        )
        let redactedWarnings = warnings.map { redactedDiagnosticString($0) }

        let record = SegmentationProvenanceRecord(
            schemaVersion: SegmentationProvenanceRecord.currentSchemaVersion,
            generatedAt: Date(),
            jobUUID: jobManifest.jobUUID,
            runState: runState,
            startedAt: startedAt,
            endedAt: endedAt,
            processExitStatus: processExitStatus,
            jobManifestSchemaVersion: jobManifest.schemaVersion,
            jobManifestHash: sha256ForAudit(of: exportContext.jobManifestURL),
            sourceIdentity: redactedSourceIdentity(from: jobManifest),
            runtime: SegmentationRuntimeProvenance(
                pluginVersion: jobManifest.pluginVersion,
                pluginBuild: jobManifest.pluginBuild,
                pluginCommit: Bundle(for: TotalSegmentatorHorosPlugin.self).object(forInfoDictionaryKey: "SourceRevision") as? String,
                hostApplication: jobManifest.hostHints.hostApplication,
                hostVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: currentProcessArchitecture(),
                pythonExecutableName: executable.executableURL.lastPathComponent,
                pythonExecutablePathHash: sha256ForAudit(of: executable.executableURL.path),
                runtimeCapabilityProbe: runtimeProbe
            ),
            runtimeProbe: runtimeProbe,
            configuration: SegmentationConfigurationProvenance(
                task: preferences.task,
                capabilityTaskIdentifier: jobManifest.runSnapshot?.capabilityTaskIdentifier,
                requestedLabels: preferences.selectedClassNames.sorted(),
                effectiveLabels: jobManifest.runSnapshot?.selectedClasses ?? [],
                requestedDevice: jobManifest.runSnapshot?.requestedDevice ?? preferences.device,
                effectiveDevice: effectiveDevice,
                requestedQuality: jobManifest.runSnapshot?.requestedQuality ?? qualityDescription(useFast: preferences.useFast),
                effectiveQuality: effectiveQuality,
                normalizedCLIArguments: redactedCommandLineArguments(normalizedCLIArguments),
                capabilityManifestVersion: Self.taskCapabilityManifest.manifestVersion,
                terminologyMappingVersion: currentTerminologyMappingVersion()
            ),
            backend: SegmentationBackendProvenance(
                environmentLockIdentifier: Self.environmentLockManifest.lockIdentifier,
                environmentManifestIdentifier: currentEnvironmentManifestIdentifier(),
                environmentManifestPathHash: environmentManifestPathHash,
                bridgeVersion: Self.bridgeVersion,
                bridgeSchemaVersion: Self.bridgeSchemaVersion,
                bridgePackageHash: currentBridgePackageHash(),
                totalSegmentatorVersion: fetchTotalSegmentatorVersion(using: executable)
            ),
            stageOutcomes: stageOutcomes,
            acceptedArtifacts: acceptedArtifacts,
            artifactIntegrityMismatches: artifactIntegrityMismatches,
            completionManifestPath: completionManifestPath,
            completionManifestHash: completionManifestHash,
            outputType: outputType.description,
            convertedFromNifti: convertedFromNifti,
            cancellationRequested: cancellationRequested,
            warnings: redactedWarnings
        )

        try validateProvenanceRecord(record)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: workspace.provenanceManifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(record).write(to: workspace.provenanceManifestURL, options: .atomic)
        try persistDiagnosticSummary(
            makeDiagnosticSummary(from: record),
            to: workspace.diagnosticSummaryURL
        )
        return record
    }

    func validateProvenanceRecord(_ record: SegmentationProvenanceRecord) throws {
        guard record.schemaVersion == SegmentationProvenanceRecord.currentSchemaVersion else {
            throw NSError(
                domain: "org.totalsegmentator.plugin.provenance",
                code: 1201,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported provenance schema version."]
            )
        }
        guard !record.jobUUID.isEmpty, !record.sourceIdentity.sourceIdentityHash.isEmpty else {
            throw NSError(
                domain: "org.totalsegmentator.plugin.provenance",
                code: 1202,
                userInfo: [NSLocalizedDescriptionKey: "Provenance record is missing immutable source identity."]
            )
        }
        for artifact in record.acceptedArtifacts where artifact.sha256.count != 64 || artifact.byteCount <= 0 {
            throw NSError(
                domain: "org.totalsegmentator.plugin.provenance",
                code: 1203,
                userInfo: [NSLocalizedDescriptionKey: "Provenance record contains invalid artifact integrity metadata."]
            )
        }
        let combinedArguments = record.configuration.normalizedCLIArguments.joined(separator: " ")
        if combinedArguments.lowercased().contains("license_number=") || combinedArguments.contains("sk-") {
            throw NSError(
                domain: "org.totalsegmentator.plugin.provenance",
                code: 1204,
                userInfo: [NSLocalizedDescriptionKey: "Provenance record contains an unredacted secret."]
            )
        }
    }

    func makeDiagnosticSummary(from record: SegmentationProvenanceRecord) -> SegmentationDiagnosticSummary {
        SegmentationDiagnosticSummary(
            schemaVersion: SegmentationDiagnosticSummary.currentSchemaVersion,
            generatedAt: Date(),
            jobUUID: record.jobUUID,
            runState: record.runState,
            sourceDICOMIncluded: false,
            directPatientIdentifiersIncluded: false,
            redactedSourceIdentity: record.sourceIdentity,
            runtimeProbe: record.runtimeProbe,
            configuration: record.configuration,
            backend: record.backend,
            stageOutcomes: record.stageOutcomes,
            acceptedArtifacts: record.acceptedArtifacts,
            artifactIntegrityMismatches: record.artifactIntegrityMismatches,
            warnings: record.warnings
        )
    }

    func persistDiagnosticSummary(_ summary: SegmentationDiagnosticSummary, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(summary).write(to: fileURL, options: .atomic)
    }

    private func appendAuditEntryAtomically(_ entry: SegmentationAuditEntry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        var lineData = data
        lineData.append(0x0A)

        let fileURL = try auditLogFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var existingData = Data()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            existingData = try Data(contentsOf: fileURL)
            if !validateAuditLogLine(existingData) {
                try quarantineCorruptAuditLog(at: fileURL)
                existingData = Data()
            }
        }

        existingData.append(lineData)
        try existingData.write(to: fileURL, options: .atomic)
    }

    private func validateAuditLogLine(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        guard let text = String(data: data, encoding: .utf8) else { return false }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in text.split(whereSeparator: \.isNewline) {
            guard !String(line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            guard let lineData = String(line).data(using: .utf8),
                  (try? decoder.decode(SegmentationAuditEntry.self, from: lineData)) != nil else {
                return false
            }
        }
        return true
    }

    private func quarantineCorruptAuditLog(at fileURL: URL) throws {
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let corruptURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".corrupt-\(stamp)", isDirectory: false)
        try FileManager.default.moveItem(at: fileURL, to: corruptURL)
    }

    private func auditLogFileURL() throws -> URL {
        let fileManager = FileManager.default

        guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "org.totalsegmentator.plugin",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Unable to resolve the Application Support directory for audit logging."]
            )
        }

        let pluginDirectory = supportDirectory.appendingPathComponent("TotalSegmentatorHorosPlugin", isDirectory: true)
        return pluginDirectory.appendingPathComponent("audit-log.jsonl", isDirectory: false)
    }

    private func redactedSourceIdentity(from jobManifest: SegmentationJobManifest) -> SegmentationSourceIdentityProvenance {
        SegmentationSourceIdentityProvenance(
            sourceIdentityHash: jobManifest.sourceIdentityHash,
            studyInstanceUIDHash: jobManifest.studyInstanceUID.map { sha256ForAudit(of: $0) },
            seriesInstanceUIDHash: jobManifest.seriesInstanceUID.map { sha256ForAudit(of: $0) },
            frameOfReferenceUIDHash: jobManifest.frameOfReferenceUID.map { sha256ForAudit(of: $0) },
            orderedSOPInstanceUIDsHash: orderedSOPInstanceUIDsHash(jobManifest.orderedSOPInstanceUIDs),
            sourceInstanceCount: jobManifest.orderedSOPInstanceUIDs.count
        )
    }

    func redactedCommandLineArguments(_ arguments: [String]) -> [String] {
        var redacted: [String] = []
        var shouldRedactNextValue = false

        for argument in arguments {
            if shouldRedactNextValue {
                redacted.append("[redacted]")
                shouldRedactNextValue = false
                continue
            }

            if containsSensitiveDiagnosticToken(argument) {
                if let separatorIndex = argument.firstIndex(of: "=") {
                    let prefix = argument[..<separatorIndex]
                    redacted.append("\(prefix)=[redacted]")
                } else {
                    redacted.append(argument)
                    shouldRedactNextValue = true
                }
            } else {
                redacted.append(redactedDiagnosticString(argument))
            }
        }

        return redacted
    }

    func redactedDiagnosticString(_ value: String) -> String {
        if containsSensitiveDiagnosticToken(value) {
            return "[redacted]"
        }
        return value.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    func containsSensitiveDiagnosticToken(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return ["license", "token", "password", "secret"].contains { lowercased.contains($0) }
    }

    private func verifyArtifactIntegrity(_ artifacts: [SegmentationArtifactRecord], rootDirectory: URL) -> [String] {
        var mismatches: [String] = []
        for artifact in artifacts {
            let fileURL = rootDirectory.appendingPathComponent(artifact.relativePath, isDirectory: false)
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let byteCount = values.fileSize,
                  Int64(byteCount) == artifact.byteCount,
                  let hash = sha256ForAudit(of: fileURL),
                  hash == artifact.sha256 else {
                mismatches.append(artifact.relativePath)
                continue
            }
        }
        return mismatches
    }

    private func relativeProvenancePath(from rootDirectory: URL, to fileURL: URL) -> String {
        let rootPath = rootDirectory.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return fileURL.lastPathComponent
    }

    private func sha256Hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func orderedSOPInstanceUIDsHash(_ values: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(values)) ?? Data()
        return sha256Hex(data: data)
    }

    private func qualityDescription(useFast: Bool) -> String {
        useFast ? "fast" : "normal"
    }

    private func currentProcessArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func fetchTotalSegmentatorVersion(using executable: ExecutableResolution) -> String? {
        let process = Process()
        process.executableURL = executable.executableURL
        process.arguments = executable.leadingArguments + ["-m", "totalsegmentator.bin.TotalSegmentator", "--version"]
        process.environment = executable.environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else {
            return nil
        }

        return version
    }

    private func currentTerminologyMappingVersion() -> String? {
        let candidateBundles = [
            Bundle(for: TotalSegmentatorHorosPlugin.self),
            Bundle.main
        ]
        for bundle in candidateBundles {
            let directURL = bundle.resourceURL?
                .appendingPathComponent("python_bridge", isDirectory: true)
                .appendingPathComponent("ts_horos_bridge", isDirectory: true)
                .appendingPathComponent("TotalSegmentatorTerminology.json", isDirectory: false)
            let fallbackURL = bundle.url(forResource: "TotalSegmentatorTerminology", withExtension: "json")

            for url in [directURL, fallbackURL].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let version = object["mapping_version"] as? String,
                      !version.isEmpty else {
                    continue
                }
                return version
            }
        }
        return nil
    }

    private func sha256ForAudit(of string: String) -> String {
        sha256Hex(data: Data(string.utf8))
    }

    private func sha256ForAudit(of fileURL: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { fileHandle.closeFile() }

        var hasher = SHA256()
        while true {
            let data = fileHandle.readData(ofLength: 1024 * 1024)
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
