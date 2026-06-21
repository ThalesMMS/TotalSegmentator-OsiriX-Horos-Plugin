//
// SegmentationAuditTests.swift
// TotalSegmentatorTests
//
// Tests for audit and provenance functionality introduced in this PR:
// - TotalSegmentatorHorosPlugin+Audit.swift: containsSensitiveDiagnosticToken,
//   redactedDiagnosticString, redactedCommandLineArguments, validateProvenanceRecord,
//   makeDiagnosticSummary
//

import XCTest
@testable import TotalSegmentatorHorosPlugin

// MARK: - containsSensitiveDiagnosticToken Tests

final class ContainsSensitiveDiagnosticTokenTests: XCTestCase {

    private let plugin = TotalSegmentatorHorosPlugin()

    // MARK: Sensitive tokens: should return true

    func test_license_isSensitive() {
        XCTAssertTrue(plugin.containsSensitiveDiagnosticToken("--license"))
    }

    func test_licenseKey_isSensitive() {
        XCTAssertTrue(plugin.containsSensitiveDiagnosticToken("--license_key"))
    }

    func test_licenseNumber_isSensitive() {
        XCTAssertTrue(plugin.containsSensitiveDiagnosticToken("--license_number"))
    }

    func test_licenseKeyEqualsValue_isSensitive() {
        XCTAssertTrue(plugin.containsSensitiveDiagnosticToken("--license_key=abc123"))
    }

    func test_token_isSensitive() {
        XCTAssertTrue(plugin.containsSensitiveDiagnosticToken("--token"))
    }

    func test_accessToken_isSensitive() {
        XCTAssertTrue(plugin.containsSensitiveDiagnosticToken("--access_token"))
    }

    func test_password_isSensitive() {
        XCTAssertTrue(plugin.containsSensitiveDiagnosticToken("--password"))
    }

    func test_secret_isSensitive() {
        XCTAssertTrue(plugin.containsSensitiveDiagnosticToken("--secret"))
    }

    func test_apiSecret_isSensitive() {
        XCTAssertTrue(plugin.containsSensitiveDiagnosticToken("--api_secret"))
    }

    // MARK: Case insensitivity

    func test_licenseUppercase_isSensitive() {
        XCTAssertTrue(plugin.containsSensitiveDiagnosticToken("--LICENSE"))
    }

    func test_licenseMixedCase_isSensitive() {
        XCTAssertTrue(plugin.containsSensitiveDiagnosticToken("--License_Key"))
    }

    func test_tokenUppercase_isSensitive() {
        XCTAssertTrue(plugin.containsSensitiveDiagnosticToken("TOKEN"))
    }

    func test_passwordUppercase_isSensitive() {
        XCTAssertTrue(plugin.containsSensitiveDiagnosticToken("PASSWORD"))
    }

    // MARK: Non-sensitive tokens: should return false

    func test_task_isNotSensitive() {
        XCTAssertFalse(plugin.containsSensitiveDiagnosticToken("--task"))
    }

    func test_device_isNotSensitive() {
        XCTAssertFalse(plugin.containsSensitiveDiagnosticToken("--device"))
    }

    func test_fast_isNotSensitive() {
        XCTAssertFalse(plugin.containsSensitiveDiagnosticToken("--fast"))
    }

    func test_outputType_isNotSensitive() {
        XCTAssertFalse(plugin.containsSensitiveDiagnosticToken("--output_type"))
    }

    func test_cpu_isNotSensitive() {
        XCTAssertFalse(plugin.containsSensitiveDiagnosticToken("cpu"))
    }

    func test_emptyString_isNotSensitive() {
        XCTAssertFalse(plugin.containsSensitiveDiagnosticToken(""))
    }

    func test_totalTaskValue_isNotSensitive() {
        XCTAssertFalse(plugin.containsSensitiveDiagnosticToken("total"))
    }
}

// MARK: - redactedDiagnosticString Tests

final class RedactedDiagnosticStringTests: XCTestCase {

    private let plugin = TotalSegmentatorHorosPlugin()

    func test_nonSensitiveString_isReturnedUnchanged() {
        XCTAssertEqual(plugin.redactedDiagnosticString("--task=total"), "--task=total")
    }

    func test_sensitiveString_isRedacted() {
        let result = plugin.redactedDiagnosticString("--license_key=abc123")
        XCTAssertEqual(result, "[redacted]")
    }

    func test_sensitiveStringPassword_isRedacted() {
        let result = plugin.redactedDiagnosticString("--password=hunter2")
        XCTAssertEqual(result, "[redacted]")
    }

    func test_sensitiveStringToken_isRedacted() {
        let result = plugin.redactedDiagnosticString("token=xyz")
        XCTAssertEqual(result, "[redacted]")
    }

    func test_homeDirPath_isReplacedWithTilde() {
        let homeDir = NSHomeDirectory()
        let path = "\(homeDir)/Library/Application Support/TotalSegmentator"
        let result = plugin.redactedDiagnosticString(path)
        XCTAssertTrue(result.hasPrefix("~"), "Home directory should be replaced with ~ prefix")
        XCTAssertFalse(result.contains(homeDir), "Home directory path should not appear in output")
    }

    func test_pathNotInHomeDir_isReturnedUnchanged() {
        let path = "/tmp/totalsegmentator/output"
        let result = plugin.redactedDiagnosticString(path)
        XCTAssertEqual(result, path)
    }

    func test_emptyString_isReturnedUnchanged() {
        XCTAssertEqual(plugin.redactedDiagnosticString(""), "")
    }

    func test_nonSensitiveLongString_isReturnedUnchanged() {
        let longArg = "--output_type=nifti_gz"
        XCTAssertEqual(plugin.redactedDiagnosticString(longArg), longArg)
    }
}

// MARK: - redactedCommandLineArguments Tests

final class RedactedCommandLineArgumentsTests: XCTestCase {

    private let plugin = TotalSegmentatorHorosPlugin()

    // MARK: No redaction needed

    func test_emptyArguments_returnsEmpty() {
        XCTAssertEqual(plugin.redactedCommandLineArguments([]), [])
    }

    func test_nonSensitiveArguments_returnedUnchanged() {
        let args = ["--task", "total", "--device", "cpu", "--fast"]
        XCTAssertEqual(plugin.redactedCommandLineArguments(args), args)
    }

    func test_singleNonSensitiveArg_returnedUnchanged() {
        XCTAssertEqual(plugin.redactedCommandLineArguments(["--task"]), ["--task"])
    }

    // MARK: Space-separated key-value pairs

    func test_licenseWithSpaceSeparator_redactsNextValue() {
        let args = ["--license", "abc123", "--task", "total"]
        let result = plugin.redactedCommandLineArguments(args)
        XCTAssertEqual(result, ["--license", "[redacted]", "--task", "total"])
    }

    func test_tokenWithSpaceSeparator_redactsNextValue() {
        let args = ["--token", "sk-secretvalue"]
        let result = plugin.redactedCommandLineArguments(args)
        XCTAssertEqual(result, ["--token", "[redacted]"])
    }

    func test_passwordWithSpaceSeparator_redactsNextValue() {
        let args = ["--device", "cpu", "--password", "hunter2", "--fast"]
        let result = plugin.redactedCommandLineArguments(args)
        XCTAssertEqual(result, ["--device", "cpu", "--password", "[redacted]", "--fast"])
    }

    func test_sensitiveArgAtEnd_redactsImpliedEmptyValue() {
        // When a sensitive key is the last argument, the next arg would be
        // a value but there is none – the key itself is kept, nothing after
        let args = ["--task", "total", "--license"]
        let result = plugin.redactedCommandLineArguments(args)
        // Key is retained; there is no subsequent value to redact
        XCTAssertEqual(result.first(where: { $0 == "--license" }), "--license")
    }

    // MARK: Equals-separated key=value pairs

    func test_licenseEqualsValue_redactsValue() {
        let args = ["--license_key=abc123"]
        let result = plugin.redactedCommandLineArguments(args)
        XCTAssertEqual(result, ["--license_key=[redacted]"])
    }

    func test_licenseEqualsValueInMiddle_redactsOnlyThatValue() {
        let args = ["--task", "total", "--license_key=abc123", "--device", "cpu"]
        let result = plugin.redactedCommandLineArguments(args)
        XCTAssertEqual(result, ["--task", "total", "--license_key=[redacted]", "--device", "cpu"])
    }

    func test_tokenEqualsValue_redactsValue() {
        let args = ["--token=my_secret_token"]
        let result = plugin.redactedCommandLineArguments(args)
        XCTAssertEqual(result, ["--token=[redacted]"])
    }

    func test_passwordEqualsValue_redactsValue() {
        let args = ["--password=hunter2"]
        let result = plugin.redactedCommandLineArguments(args)
        XCTAssertEqual(result, ["--password=[redacted]"])
    }

    // MARK: Multiple sensitive arguments

    func test_multipleSensitiveArgs_allRedacted() {
        let args = ["--license", "lic1", "--token", "tok1"]
        let result = plugin.redactedCommandLineArguments(args)
        XCTAssertEqual(result, ["--license", "[redacted]", "--token", "[redacted]"])
    }

    func test_mixedSensitiveAndNonSensitiveArgs_onlySensitiveRedacted() {
        let args = ["--task", "total", "--license_key=abc", "--device", "mps", "--fast"]
        let result = plugin.redactedCommandLineArguments(args)
        XCTAssertEqual(result, ["--task", "total", "--license_key=[redacted]", "--device", "mps", "--fast"])
    }

    // MARK: Regression: value containing "license" text does NOT get silently dropped

    func test_nonSensitiveArgFollowingRedactedValue_isPreserved() {
        // After redacting --license's value, subsequent non-sensitive args must appear
        let args = ["--license", "val", "--output_type", "nifti"]
        let result = plugin.redactedCommandLineArguments(args)
        XCTAssertEqual(result, ["--license", "[redacted]", "--output_type", "nifti"])
    }

    func test_resultCount_preservedAfterRedaction() {
        // The number of tokens should not change; only their values change
        let args = ["--task", "total", "--license", "abc123"]
        let result = plugin.redactedCommandLineArguments(args)
        XCTAssertEqual(result.count, args.count)
    }
}

// MARK: - validateProvenanceRecord Tests

final class ValidateProvenanceRecordTests: XCTestCase {

    private let plugin = TotalSegmentatorHorosPlugin()

    // MARK: - Builder helpers

    private func makeSourceIdentity(
        sourceIdentityHash: String = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
        orderedSOPHash: String = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    ) -> SegmentationSourceIdentityProvenance {
        SegmentationSourceIdentityProvenance(
            sourceIdentityHash: sourceIdentityHash,
            studyInstanceUIDHash: nil,
            seriesInstanceUIDHash: nil,
            frameOfReferenceUIDHash: nil,
            orderedSOPInstanceUIDsHash: orderedSOPHash,
            sourceInstanceCount: 1
        )
    }

    private func makeRuntime() -> SegmentationRuntimeProvenance {
        SegmentationRuntimeProvenance(
            pluginVersion: "1.0",
            pluginBuild: "1",
            pluginCommit: nil,
            hostApplication: nil,
            hostVersion: nil,
            operatingSystemVersion: "macOS 14.0",
            architecture: "arm64",
            pythonExecutableName: "python3",
            pythonExecutablePathHash: String(repeating: "a", count: 64),
            runtimeCapabilityProbe: nil
        )
    }

    private func makeConfiguration(
        normalizedCLIArguments: [String] = ["--task", "total"]
    ) -> SegmentationConfigurationProvenance {
        SegmentationConfigurationProvenance(
            task: "total",
            capabilityTaskIdentifier: "total",
            requestedLabels: [],
            effectiveLabels: [],
            requestedDevice: nil,
            effectiveDevice: nil,
            requestedQuality: "normal",
            effectiveQuality: "normal",
            normalizedCLIArguments: normalizedCLIArguments,
            capabilityManifestVersion: "2026.06.v1",
            terminologyMappingVersion: nil
        )
    }

    private func makeBackend() -> SegmentationBackendProvenance {
        SegmentationBackendProvenance(
            environmentLockIdentifier: "totalsegmentator-env-2026-06-20-ts-2.11.0",
            environmentManifestIdentifier: nil,
            environmentManifestPathHash: nil,
            bridgeVersion: "1.0",
            bridgeSchemaVersion: 1,
            bridgePackageHash: nil,
            totalSegmentatorVersion: "2.11.0"
        )
    }

    private func makeValidRecord(
        schemaVersion: Int = SegmentationProvenanceRecord.currentSchemaVersion,
        jobUUID: String = "test-job-uuid-1234",
        sourceIdentityHash: String = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
        acceptedArtifacts: [SegmentationArtifactRecord] = [],
        normalizedCLIArguments: [String] = ["--task", "total"]
    ) -> SegmentationProvenanceRecord {
        SegmentationProvenanceRecord(
            schemaVersion: schemaVersion,
            generatedAt: Date(),
            jobUUID: jobUUID,
            runState: "completed",
            jobManifestSchemaVersion: 1,
            jobManifestHash: nil,
            sourceIdentity: makeSourceIdentity(sourceIdentityHash: sourceIdentityHash),
            runtime: makeRuntime(),
            runtimeProbe: nil,
            configuration: makeConfiguration(normalizedCLIArguments: normalizedCLIArguments),
            backend: makeBackend(),
            stageOutcomes: [],
            acceptedArtifacts: acceptedArtifacts,
            artifactIntegrityMismatches: [],
            completionManifestPath: nil,
            completionManifestHash: nil,
            outputType: "dicom",
            convertedFromNifti: false,
            cancellationRequested: false,
            warnings: []
        )
    }

    private func makeArtifact(
        sha256: String = String(repeating: "a", count: 64),
        byteCount: Int64 = 1024
    ) -> SegmentationArtifactRecord {
        SegmentationArtifactRecord(
            relativePath: "output/result.dcm",
            kind: "dicom",
            sha256: sha256,
            byteCount: byteCount
        )
    }

    // MARK: - Valid records pass validation

    func test_validRecord_doesNotThrow() {
        let record = makeValidRecord()
        XCTAssertNoThrow(try plugin.validateProvenanceRecord(record))
    }

    func test_validRecordWithArtifacts_doesNotThrow() {
        let artifact = makeArtifact()
        let record = makeValidRecord(acceptedArtifacts: [artifact])
        XCTAssertNoThrow(try plugin.validateProvenanceRecord(record))
    }

    func test_validRecordWithMultipleArtifacts_doesNotThrow() {
        let artifacts = [
            makeArtifact(sha256: String(repeating: "a", count: 64), byteCount: 512),
            makeArtifact(sha256: String(repeating: "b", count: 64), byteCount: 1024),
            makeArtifact(sha256: String(repeating: "c", count: 64), byteCount: 2048)
        ]
        let record = makeValidRecord(acceptedArtifacts: artifacts)
        XCTAssertNoThrow(try plugin.validateProvenanceRecord(record))
    }

    // MARK: - Schema version validation (code 1201)

    func test_wrongSchemaVersion_throws1201() {
        let record = makeValidRecord(schemaVersion: 999)
        XCTAssertThrowsError(try plugin.validateProvenanceRecord(record)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "org.totalsegmentator.plugin.provenance")
            XCTAssertEqual(nsError.code, 1201)
        }
    }

    func test_schemaVersionZero_throws1201() {
        let record = makeValidRecord(schemaVersion: 0)
        XCTAssertThrowsError(try plugin.validateProvenanceRecord(record)) { error in
            XCTAssertEqual((error as NSError).code, 1201)
        }
    }

    // MARK: - Source identity validation (code 1202)

    func test_emptyJobUUID_throws1202() {
        let record = makeValidRecord(jobUUID: "")
        XCTAssertThrowsError(try plugin.validateProvenanceRecord(record)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "org.totalsegmentator.plugin.provenance")
            XCTAssertEqual(nsError.code, 1202)
        }
    }

    func test_emptySourceIdentityHash_throws1202() {
        let record = makeValidRecord(sourceIdentityHash: "")
        XCTAssertThrowsError(try plugin.validateProvenanceRecord(record)) { error in
            XCTAssertEqual((error as NSError).code, 1202)
        }
    }

    // MARK: - Artifact integrity validation (code 1203)

    func test_artifactWithShortSha256_throws1203() {
        let artifact = makeArtifact(sha256: "tooshort")
        let record = makeValidRecord(acceptedArtifacts: [artifact])
        XCTAssertThrowsError(try plugin.validateProvenanceRecord(record)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "org.totalsegmentator.plugin.provenance")
            XCTAssertEqual(nsError.code, 1203)
        }
    }

    func test_artifactWithLongSha256_throws1203() {
        // sha256 must be exactly 64 hex characters
        let artifact = makeArtifact(sha256: String(repeating: "a", count: 65))
        let record = makeValidRecord(acceptedArtifacts: [artifact])
        XCTAssertThrowsError(try plugin.validateProvenanceRecord(record)) { error in
            XCTAssertEqual((error as NSError).code, 1203)
        }
    }

    func test_artifactWithZeroByteCount_throws1203() {
        let artifact = makeArtifact(byteCount: 0)
        let record = makeValidRecord(acceptedArtifacts: [artifact])
        XCTAssertThrowsError(try plugin.validateProvenanceRecord(record)) { error in
            XCTAssertEqual((error as NSError).code, 1203)
        }
    }

    func test_artifactWithNegativeByteCount_throws1203() {
        let artifact = makeArtifact(byteCount: -1)
        let record = makeValidRecord(acceptedArtifacts: [artifact])
        XCTAssertThrowsError(try plugin.validateProvenanceRecord(record)) { error in
            XCTAssertEqual((error as NSError).code, 1203)
        }
    }

    func test_oneValidAndOneInvalidArtifact_throws1203() {
        let validArtifact = makeArtifact(sha256: String(repeating: "a", count: 64), byteCount: 1024)
        let invalidArtifact = makeArtifact(sha256: "tooshort", byteCount: 512)
        let record = makeValidRecord(acceptedArtifacts: [validArtifact, invalidArtifact])
        XCTAssertThrowsError(try plugin.validateProvenanceRecord(record)) { error in
            XCTAssertEqual((error as NSError).code, 1203)
        }
    }

    // MARK: - Unredacted secret detection (code 1204)

    func test_licenseNumberInArgs_throws1204() {
        let record = makeValidRecord(normalizedCLIArguments: ["--license_number=abc123"])
        XCTAssertThrowsError(try plugin.validateProvenanceRecord(record)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "org.totalsegmentator.plugin.provenance")
            XCTAssertEqual(nsError.code, 1204)
        }
    }

    func test_skPrefixTokenInArgs_throws1204() {
        // TotalSegmentator API keys often start with "sk-"
        let record = makeValidRecord(normalizedCLIArguments: ["--license", "sk-secretvalue"])
        XCTAssertThrowsError(try plugin.validateProvenanceRecord(record)) { error in
            XCTAssertEqual((error as NSError).code, 1204)
        }
    }

    func test_licenseNumberUppercaseInArgs_throws1204() {
        // Check is case-insensitive for license_number=
        let record = makeValidRecord(normalizedCLIArguments: ["LICENSE_NUMBER=abc"])
        XCTAssertThrowsError(try plugin.validateProvenanceRecord(record)) { error in
            XCTAssertEqual((error as NSError).code, 1204)
        }
    }

    func test_redactedLicenseInArgs_doesNotThrow() {
        // Properly redacted license argument should pass validation
        let record = makeValidRecord(normalizedCLIArguments: ["--license_key=[redacted]"])
        XCTAssertNoThrow(try plugin.validateProvenanceRecord(record))
    }

    func test_emptyArgs_doesNotThrow() {
        let record = makeValidRecord(normalizedCLIArguments: [])
        XCTAssertNoThrow(try plugin.validateProvenanceRecord(record))
    }
}

// MARK: - makeDiagnosticSummary Tests

final class MakeDiagnosticSummaryTests: XCTestCase {

    private let plugin = TotalSegmentatorHorosPlugin()

    private func makeSourceIdentity() -> SegmentationSourceIdentityProvenance {
        SegmentationSourceIdentityProvenance(
            sourceIdentityHash: String(repeating: "a", count: 64),
            studyInstanceUIDHash: nil,
            seriesInstanceUIDHash: nil,
            frameOfReferenceUIDHash: nil,
            orderedSOPInstanceUIDsHash: String(repeating: "b", count: 64),
            sourceInstanceCount: 5
        )
    }

    private func makeValidRecord() -> SegmentationProvenanceRecord {
        SegmentationProvenanceRecord(
            schemaVersion: SegmentationProvenanceRecord.currentSchemaVersion,
            generatedAt: Date(),
            jobUUID: "test-job-uuid",
            runState: "completed",
            jobManifestSchemaVersion: 1,
            jobManifestHash: nil,
            sourceIdentity: makeSourceIdentity(),
            runtime: SegmentationRuntimeProvenance(
                pluginVersion: "1.0",
                pluginBuild: "1",
                pluginCommit: nil,
                hostApplication: nil,
                hostVersion: nil,
                operatingSystemVersion: "macOS 14.0",
                architecture: "arm64",
                pythonExecutableName: "python3",
                pythonExecutablePathHash: String(repeating: "c", count: 64),
                runtimeCapabilityProbe: nil
            ),
            runtimeProbe: nil,
            configuration: SegmentationConfigurationProvenance(
                task: "total",
                capabilityTaskIdentifier: nil,
                requestedLabels: [],
                effectiveLabels: [],
                requestedDevice: nil,
                effectiveDevice: nil,
                requestedQuality: "normal",
                effectiveQuality: "normal",
                normalizedCLIArguments: [],
                capabilityManifestVersion: "2026.06.v1",
                terminologyMappingVersion: nil
            ),
            backend: SegmentationBackendProvenance(
                environmentLockIdentifier: "test-lock-id",
                environmentManifestIdentifier: nil,
                environmentManifestPathHash: nil,
                bridgeVersion: "1.0",
                bridgeSchemaVersion: 1,
                bridgePackageHash: nil,
                totalSegmentatorVersion: nil
            ),
            stageOutcomes: [],
            acceptedArtifacts: [],
            artifactIntegrityMismatches: [],
            completionManifestPath: nil,
            completionManifestHash: nil,
            outputType: "dicom",
            convertedFromNifti: false,
            cancellationRequested: false,
            warnings: ["test-warning"]
        )
    }

    func test_makeDiagnosticSummary_usesCurrentSchemaVersion() {
        let record = makeValidRecord()
        let summary = plugin.makeDiagnosticSummary(from: record)
        XCTAssertEqual(summary.schemaVersion, SegmentationDiagnosticSummary.currentSchemaVersion)
    }

    func test_makeDiagnosticSummary_preservesJobUUID() {
        let record = makeValidRecord()
        let summary = plugin.makeDiagnosticSummary(from: record)
        XCTAssertEqual(summary.jobUUID, record.jobUUID)
    }

    func test_makeDiagnosticSummary_preservesRunState() {
        let record = makeValidRecord()
        let summary = plugin.makeDiagnosticSummary(from: record)
        XCTAssertEqual(summary.runState, record.runState)
    }

    func test_makeDiagnosticSummary_sourceDICOMIncluded_isFalse() {
        // Diagnostic summaries must never include source DICOM data
        let record = makeValidRecord()
        let summary = plugin.makeDiagnosticSummary(from: record)
        XCTAssertFalse(summary.sourceDICOMIncluded)
    }

    func test_makeDiagnosticSummary_directPatientIdentifiersIncluded_isFalse() {
        // Diagnostic summaries must never include direct patient identifiers
        let record = makeValidRecord()
        let summary = plugin.makeDiagnosticSummary(from: record)
        XCTAssertFalse(summary.directPatientIdentifiersIncluded)
    }

    func test_makeDiagnosticSummary_preservesWarnings() {
        let record = makeValidRecord()
        let summary = plugin.makeDiagnosticSummary(from: record)
        XCTAssertEqual(summary.warnings, record.warnings)
    }

    func test_makeDiagnosticSummary_preservesSourceIdentity() {
        let record = makeValidRecord()
        let summary = plugin.makeDiagnosticSummary(from: record)
        XCTAssertEqual(summary.redactedSourceIdentity.sourceIdentityHash, record.sourceIdentity.sourceIdentityHash)
    }

    func test_makeDiagnosticSummary_preservesConfiguration() {
        let record = makeValidRecord()
        let summary = plugin.makeDiagnosticSummary(from: record)
        XCTAssertEqual(summary.configuration.task, record.configuration.task)
    }

    func test_makeDiagnosticSummary_hasGeneratedAtTimestamp() {
        let beforeCall = Date()
        let record = makeValidRecord()
        let summary = plugin.makeDiagnosticSummary(from: record)
        let afterCall = Date()
        XCTAssertGreaterThanOrEqual(summary.generatedAt, beforeCall)
        XCTAssertLessThanOrEqual(summary.generatedAt, afterCall)
    }
}

// MARK: - EnvironmentReadinessResult Tests

final class EnvironmentReadinessResultTests: XCTestCase {

    func test_readyFactory_isReady() {
        let result = EnvironmentReadinessResult.ready(
            lockIdentifier: "test-lock",
            manifestIdentifier: "test-manifest",
            pythonPath: "/usr/bin/python3",
            dcm2niixPath: "/usr/local/bin/dcm2niix",
            recoveredInterruptedInstall: false
        )
        XCTAssertTrue(result.isReady)
    }

    func test_readyFactory_hasReadyState() {
        let result = EnvironmentReadinessResult.ready(
            lockIdentifier: "test-lock",
            manifestIdentifier: nil,
            pythonPath: nil,
            dcm2niixPath: nil,
            recoveredInterruptedInstall: false
        )
        XCTAssertEqual(result.state, .ready)
    }

    func test_readyFactory_hasNilError() {
        let result = EnvironmentReadinessResult.ready(
            lockIdentifier: "test-lock",
            manifestIdentifier: nil,
            pythonPath: nil,
            dcm2niixPath: nil,
            recoveredInterruptedInstall: false
        )
        XCTAssertNil(result.error)
    }

    func test_readyFactory_preservesLockIdentifier() {
        let result = EnvironmentReadinessResult.ready(
            lockIdentifier: "totalsegmentator-env-2026-06-20",
            manifestIdentifier: nil,
            pythonPath: nil,
            dcm2niixPath: nil,
            recoveredInterruptedInstall: false
        )
        XCTAssertEqual(result.lockIdentifier, "totalsegmentator-env-2026-06-20")
    }

    func test_readyFactory_preservesManifestIdentifier() {
        let result = EnvironmentReadinessResult.ready(
            lockIdentifier: "test-lock",
            manifestIdentifier: "test-manifest-id",
            pythonPath: nil,
            dcm2niixPath: nil,
            recoveredInterruptedInstall: false
        )
        XCTAssertEqual(result.manifestIdentifier, "test-manifest-id")
    }

    func test_readyFactory_recoveredInterruptedInstall_isPreserved() {
        let recovered = EnvironmentReadinessResult.ready(
            lockIdentifier: "test-lock",
            manifestIdentifier: nil,
            pythonPath: nil,
            dcm2niixPath: nil,
            recoveredInterruptedInstall: true
        )
        XCTAssertTrue(recovered.recoveredInterruptedInstall)

        let notRecovered = EnvironmentReadinessResult.ready(
            lockIdentifier: "test-lock",
            manifestIdentifier: nil,
            pythonPath: nil,
            dcm2niixPath: nil,
            recoveredInterruptedInstall: false
        )
        XCTAssertFalse(notRecovered.recoveredInterruptedInstall)
    }

    func test_failureFactory_isNotReady() {
        let result = EnvironmentReadinessResult.failure(
            lockIdentifier: "test-lock",
            manifestIdentifier: nil,
            pythonPath: nil,
            error: .unableToResolveInterpreter
        )
        XCTAssertFalse(result.isReady)
    }

    func test_failureFactory_hasFailedState() {
        let result = EnvironmentReadinessResult.failure(
            lockIdentifier: "test-lock",
            manifestIdentifier: nil,
            pythonPath: nil,
            error: .missingTotalSegmentator
        )
        XCTAssertEqual(result.state, .failed)
    }

    func test_failureFactory_preservesError() {
        let result = EnvironmentReadinessResult.failure(
            lockIdentifier: "test-lock",
            manifestIdentifier: nil,
            pythonPath: nil,
            error: .cancelled
        )
        if case .cancelled = result.error {
            // Expected
        } else {
            XCTFail("Expected .cancelled error")
        }
    }

    func test_failureMessage_isNonEmpty() {
        let result = EnvironmentReadinessResult.failure(
            lockIdentifier: "test-lock",
            manifestIdentifier: nil,
            pythonPath: nil,
            error: .missingTotalSegmentator
        )
        XCTAssertFalse(result.failureMessage.isEmpty)
    }

    func test_failureFactory_customState_isPreserved() {
        let result = EnvironmentReadinessResult.failure(
            state: .installingInPlace,
            lockIdentifier: "test-lock",
            manifestIdentifier: nil,
            pythonPath: nil,
            error: .installFailed("pip failed")
        )
        XCTAssertEqual(result.state, .installingInPlace)
    }

    func test_isReady_requiresAllComponentsReady() {
        // isReady checks state == .ready AND packageEnvironmentReady AND modelWeightsReady AND dcm2niixReady AND error == nil
        let result = EnvironmentReadinessResult(
            state: .ready,
            lockIdentifier: "test-lock",
            manifestIdentifier: nil,
            pythonPath: nil,
            dcm2niixPath: nil,
            packageEnvironmentReady: true,
            modelWeightsReady: true,
            dcm2niixReady: false,     // dcm2niixReady is false
            recoveredInterruptedInstall: false,
            error: nil
        )
        XCTAssertFalse(result.isReady, "isReady should be false when dcm2niixReady is false")
    }
}

// MARK: - EnvironmentLockManifest Tests

final class EnvironmentLockManifestTests: XCTestCase {

    func test_environmentLockManifest_isLoaded() {
        // The bundled TotalSegmentatorEnvironmentLock.json must be loadable
        let lock = TotalSegmentatorHorosPlugin.environmentLockManifest
        XCTAssertFalse(lock.lockIdentifier.isEmpty)
    }

    func test_environmentLockManifest_hasExpectedSchemaVersion() {
        let lock = TotalSegmentatorHorosPlugin.environmentLockManifest
        XCTAssertEqual(lock.schemaVersion, 1)
    }

    func test_environmentLockManifest_lockIdentifierIsNonEmpty() {
        let lock = TotalSegmentatorHorosPlugin.environmentLockManifest
        XCTAssertFalse(lock.lockIdentifier.isEmpty)
    }

    func test_environmentLockManifest_hasRequiredPackages() {
        let lock = TotalSegmentatorHorosPlugin.environmentLockManifest
        XCTAssertFalse(lock.packages.isEmpty, "Lock manifest must declare at least one package")
    }

    func test_environmentLockManifest_requiredPackagesHaveRequirements() {
        let lock = TotalSegmentatorHorosPlugin.environmentLockManifest
        for package in lock.packages where package.required {
            XCTAssertFalse(package.requirement.isEmpty, "Required package \(package.distributionName) must have a requirement string")
        }
    }

    func test_environmentLockManifest_includesTotalSegmentatorPackage() {
        let lock = TotalSegmentatorHorosPlugin.environmentLockManifest
        let hasTotalSegmentator = lock.packages.contains {
            $0.importName == "totalsegmentator" || $0.distributionName == "TotalSegmentator"
        }
        XCTAssertTrue(hasTotalSegmentator, "Lock manifest must include TotalSegmentator package")
    }

    func test_environmentLockManifest_installRequirements_areNonEmpty() {
        let lock = TotalSegmentatorHorosPlugin.environmentLockManifest
        XCTAssertFalse(lock.installRequirements.isEmpty, "installRequirements must include at least the required packages")
    }

    func test_environmentLockManifest_installRequirements_onlyIncludeRequired() {
        let lock = TotalSegmentatorHorosPlugin.environmentLockManifest
        let requiredNames = Set(lock.packages.filter { $0.required }.map { $0.requirement })
        let installReqs = Set(lock.installRequirements)
        // All install requirements must correspond to required packages
        XCTAssertEqual(installReqs, requiredNames)
    }

    func test_environmentLockManifest_dcm2niixIsPresent() {
        let lock = TotalSegmentatorHorosPlugin.environmentLockManifest
        XCTAssertFalse(lock.dcm2niix.version.isEmpty, "dcm2niix version must be specified in the lock manifest")
    }

    func test_environmentLockManifest_dcm2niixHasBinarySHA256() {
        let lock = TotalSegmentatorHorosPlugin.environmentLockManifest
        // Binary SHA256 must be exactly 64 hex characters for a SHA-256 hash
        XCTAssertEqual(lock.dcm2niix.binarySHA256.count, 64)
    }
}
