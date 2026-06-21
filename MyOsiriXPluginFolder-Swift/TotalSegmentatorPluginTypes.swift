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
    let supportsROISubset: Bool
    let supportsFastMode: Bool

    init(
        title: String,
        value: String?,
        description: String,
        supportsROISubset: Bool = false,
        supportsFastMode: Bool = true
    ) {
        self.title = title
        self.value = value
        self.description = description
        self.supportsROISubset = supportsROISubset
        self.supportsFastMode = supportsFastMode
    }
}

struct TaskGroup {
    let name: String
    let tasks: [TaskOption]
}

struct EnvironmentLockManifest: Codable {
    let schemaVersion: Int
    let lockIdentifier: String
    let backend: EnvironmentBackendLock
    let python: EnvironmentPythonLock
    let packages: [EnvironmentPackageLock]
    let dcm2niix: EnvironmentDcm2NiixLock
    let weights: [EnvironmentWeightsLock]
    let offlineInstall: EnvironmentOfflineInstall

    var installRequirements: [String] {
        packages.filter { $0.required }.map { $0.requirement }
    }
}

struct EnvironmentBackendLock: Codable {
    let distributionName: String
    let importName: String
    let version: String
    let sourceTreePolicy: String
    let upstreamURL: String
}

struct EnvironmentPythonLock: Codable {
    let minimumVersion: String
    let maximumExclusiveVersion: String
    let supportedArchitectures: [String]
}

struct EnvironmentPackageLock: Codable {
    let distributionName: String
    let importName: String
    let requirement: String
    let exactVersion: String?
    let minimumVersion: String?
    let maximumExclusiveVersion: String?
    let required: Bool
}

struct EnvironmentDcm2NiixLock: Codable {
    let version: String
    let archiveName: String
    let archiveSHA256: String
    let binarySHA256: String
}

struct EnvironmentWeightsLock: Codable {
    let scope: String
    let provenance: String
}

struct EnvironmentOfflineInstall: Codable {
    let requirementFileName: String
    let instructions: String
}

enum EnvironmentLifecycleState: String {
    case uninitialized
    case checking
    case installingInPlace
    case ready
    case failed
    case repairing
    case updatingInPlace
}

enum EnvironmentReadinessError: LocalizedError {
    case unableToResolveInterpreter
    case processLockUnavailable(owner: String?)
    case missingTotalSegmentator
    case installFailed(String)
    case validationFailed([String])
    case modelWeightsUnavailable
    case dcm2niixUnavailable
    case cancelled
    case interruptedInstallRecovered(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .unableToResolveInterpreter:
            return "Unable to locate a Python interpreter for the TotalSegmentator environment."
        case .processLockUnavailable(let owner):
            if let owner = owner, !owner.isEmpty {
                return "Another Horos/OsiriX process is already preparing the TotalSegmentator environment: \(owner)"
            }
            return "Another Horos/OsiriX process is already preparing the TotalSegmentator environment."
        case .missingTotalSegmentator:
            return "The active Python environment does not provide the pinned TotalSegmentator package."
        case .installFailed(let detail):
            return "Unable to install the pinned TotalSegmentator environment. \(detail)"
        case .validationFailed(let errors):
            return "The active Python environment does not match the pinned lock: \(errors.joined(separator: "; "))"
        case .modelWeightsUnavailable:
            return "The Python package environment is valid, but TotalSegmentator model weights could not be prepared."
        case .dcm2niixUnavailable:
            return "The Python package environment is valid, but pinned dcm2niix could not be prepared."
        case .cancelled:
            return "TotalSegmentator environment setup was cancelled."
        case .interruptedInstallRecovered(let detail):
            return "Detected interrupted environment setup and prepared a retry path. \(detail)"
        case .unknown(let detail):
            return detail
        }
    }
}

struct EnvironmentReadinessResult {
    let state: EnvironmentLifecycleState
    let lockIdentifier: String
    let manifestIdentifier: String?
    let pythonPath: String?
    let dcm2niixPath: String?
    let packageEnvironmentReady: Bool
    let modelWeightsReady: Bool
    let dcm2niixReady: Bool
    let recoveredInterruptedInstall: Bool
    let error: EnvironmentReadinessError?

    var isReady: Bool {
        state == .ready && packageEnvironmentReady && modelWeightsReady && dcm2niixReady && error == nil
    }

    var failureMessage: String {
        error?.localizedDescription ?? "The TotalSegmentator environment is not ready."
    }

    /// Creates an environment readiness result indicating the environment is fully prepared.
    static func ready(
        lockIdentifier: String,
        manifestIdentifier: String?,
        pythonPath: String?,
        dcm2niixPath: String?,
        recoveredInterruptedInstall: Bool
    ) -> EnvironmentReadinessResult {
        EnvironmentReadinessResult(
            state: .ready,
            lockIdentifier: lockIdentifier,
            manifestIdentifier: manifestIdentifier,
            pythonPath: pythonPath,
            dcm2niixPath: dcm2niixPath,
            packageEnvironmentReady: true,
            modelWeightsReady: true,
            dcm2niixReady: true,
            recoveredInterruptedInstall: recoveredInterruptedInstall,
            error: nil
        )
    }

    /// Creates an environment readiness result indicating a failure state.
    /// - Returns: An `EnvironmentReadinessResult` with the specified configuration and error.
    static func failure(
        state: EnvironmentLifecycleState = .failed,
        lockIdentifier: String,
        manifestIdentifier: String?,
        pythonPath: String?,
        packageEnvironmentReady: Bool = false,
        modelWeightsReady: Bool = false,
        dcm2niixReady: Bool = false,
        recoveredInterruptedInstall: Bool = false,
        error: EnvironmentReadinessError
    ) -> EnvironmentReadinessResult {
        EnvironmentReadinessResult(
            state: state,
            lockIdentifier: lockIdentifier,
            manifestIdentifier: manifestIdentifier,
            pythonPath: pythonPath,
            dcm2niixPath: nil,
            packageEnvironmentReady: packageEnvironmentReady,
            modelWeightsReady: modelWeightsReady,
            dcm2niixReady: dcm2niixReady,
            recoveredInterruptedInstall: recoveredInterruptedInstall,
            error: error
        )
    }
}

final class EnvironmentLifecycleManager {
    private let condition = NSCondition()
    private var state: EnvironmentLifecycleState = .uninitialized
    private var operationInFlight = false
    private var lastResult: EnvironmentReadinessResult?

    /// Ensures only one environment readiness operation runs at a time across concurrent callers.
    /// - Parameters:
    ///   - operation: A closure that performs the environment readiness check.
    /// - Returns: The result of the environment readiness operation.
    func run(
        progressController: SegmentationProgressReporting?,
        operation: () -> EnvironmentReadinessResult
    ) -> EnvironmentReadinessResult {
        condition.lock()
        if operationInFlight {
            condition.unlock()
            progressController?.append("Checking pinned Python environment: waiting for the active setup operation to finish.")
            condition.lock()
            while operationInFlight {
                condition.wait()
            }
            let result = lastResult ?? EnvironmentReadinessResult.failure(
                lockIdentifier: "",
                manifestIdentifier: nil,
                pythonPath: nil,
                error: .unknown("The shared environment setup operation finished without a readiness result.")
            )
            condition.unlock()
            return result
        }

        operationInFlight = true
        state = .checking
        condition.unlock()

        let result = operation()

        condition.lock()
        state = result.state
        lastResult = result
        operationInFlight = false
        condition.broadcast()
        condition.unlock()

        return result
    }
}

enum TotalSegmentatorCapabilityError: LocalizedError {
    case missingManifest
    case invalidTask(String)
    case unsupportedModality(task: String, modality: String)
    case unsupportedQuality(task: String, quality: String)
    case unsupportedOutputMode(task: String, mode: String)

    var errorDescription: String? {
        switch self {
        case .missingManifest:
            return "The TotalSegmentator task capability manifest could not be loaded."
        case .invalidTask(let task):
            return "The selected TotalSegmentator task '\(task)' is not supported by the bundled capability manifest."
        case .unsupportedModality(let task, let modality):
            return "The selected TotalSegmentator task '\(task)' does not support \(modality) input according to the bundled capability manifest."
        case .unsupportedQuality(let task, let quality):
            return "The selected TotalSegmentator task '\(task)' does not support '\(quality)' quality mode according to the bundled capability manifest."
        case .unsupportedOutputMode(let task, let mode):
            return "The selected TotalSegmentator task '\(task)' does not support '\(mode)' output according to the bundled capability manifest."
        }
    }
}

struct TaskCapabilityManifest: Decodable {
    let schemaVersion: Int
    let manifestVersion: String
    let backendSource: String
    let defaultTask: String
    let tasks: [TaskCapability]

    static let fallbackUnavailableManifest = TaskCapabilityManifest(
        schemaVersion: 1,
        manifestVersion: "unavailable",
        backendSource: "unavailable",
        defaultTask: "",
        tasks: []
    )

    var tasksByIdentifier: [String: TaskCapability] {
        Dictionary(uniqueKeysWithValues: tasks.map { ($0.identifier, $0) })
    }

    /// Retrieves the capability for a specified task, using the default task if none is provided.
    /// - Parameters:
    ///   - task: The task identifier. If `nil` or blank, the default task is used.
    /// - Returns: The capability for the task, or `nil` if no matching capability is found.
    func capability(for task: String?) -> TaskCapability? {
        guard let normalized = task?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty else {
            return tasksByIdentifier[defaultTask]
        }

        return tasksByIdentifier[normalized]
    }

    /// Validates that a task and its capabilities match the requested parameters.
    /// - Parameters:
    ///   - task: The task identifier to validate.
    ///   - modality: The modality to verify support for (if provided).
    ///   - useFast: Whether fast-mode execution is requested.
    ///   - additionalArguments: CLI arguments that may contain feature flags like `--fast`, `--fastest`, or `--ml`.
    /// - Returns: The validated `TaskCapability`.
    /// - Throws: `TotalSegmentatorCapabilityError` if the task is invalid or the requested modality, quality modes, or output modes are unsupported.
    func validate(task: String?, modality: String?, useFast: Bool, additionalArguments: [String]) throws -> TaskCapability {
        let normalizedTask = task?.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskIdentifier = normalizedTask?.isEmpty == false ? normalizedTask! : defaultTask

        guard let capability = tasksByIdentifier[taskIdentifier] else {
            throw TotalSegmentatorCapabilityError.invalidTask(taskIdentifier)
        }

        if let modality = modality?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !modality.isEmpty {
            let supported = capability.supportedModalities.map { $0.uppercased() }
            if !supported.contains(modality) {
                throw TotalSegmentatorCapabilityError.unsupportedModality(task: taskIdentifier, modality: modality)
            }
        }

        if useFast, !capability.qualityModes.contains("fast") {
            throw TotalSegmentatorCapabilityError.unsupportedQuality(task: taskIdentifier, quality: "fast")
        }

        if Self.containsFlag("--fast", in: additionalArguments), !capability.qualityModes.contains("fast") {
            throw TotalSegmentatorCapabilityError.unsupportedQuality(task: taskIdentifier, quality: "fast")
        }

        if Self.containsFlag("--fastest", in: additionalArguments), !capability.qualityModes.contains("fastest") {
            throw TotalSegmentatorCapabilityError.unsupportedQuality(task: taskIdentifier, quality: "fastest")
        }

        if Self.containsFlag("--ml", in: additionalArguments), !capability.supportsMultilabel {
            throw TotalSegmentatorCapabilityError.unsupportedOutputMode(task: taskIdentifier, mode: "multilabel")
        }

        return capability
    }

    /// Determines whether a flag is present in arguments, either as an exact token or as a key in a key-value pair.
    /// - Parameters:
    ///   - flag: The flag to search for (e.g., `"--fast"`).
    ///   - arguments: The argument list to search.
    /// - Returns: `true` if an argument exactly matches the flag or starts with the flag followed by `=`, `false` otherwise.
    static func containsFlag(_ flag: String, in arguments: [String]) -> Bool {
        arguments.contains { token in
            token == flag || token.hasPrefix(flag + "=")
        }
    }

    /// Loads the task capability manifest from bundled resources.
    /// - Parameters:
    ///   - bundleCandidates: Bundles to search for the manifest, checked in order.
    /// - Returns: The decoded task capability manifest.
    /// - Throws: `TotalSegmentatorCapabilityError.missingManifest` if the manifest is not found in any provided bundle.
    static func loadBundled(bundleCandidates: [Bundle]) throws -> TaskCapabilityManifest {
        for bundle in bundleCandidates {
            guard let url = bundle.url(forResource: "TotalSegmentatorTaskCapabilities", withExtension: "json") else {
                continue
            }

            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(TaskCapabilityManifest.self, from: data)
        }

        throw TotalSegmentatorCapabilityError.missingManifest
    }
}

struct TaskCapability: Decodable {
    let identifier: String
    let displayName: String
    let group: String
    let description: String
    let supportedModalities: [String]
    let supportsRoiSubset: Bool
    let supportsMultilabel: Bool
    let qualityModes: [String]
    let requiresLicense: Bool
    let experimental: Bool
    let deprecated: Bool
}

extension TotalSegmentatorHorosPlugin {
    private static let taskCapabilityManifestLoadResult: Result<TaskCapabilityManifest, Error> = Result {
        try TaskCapabilityManifest.loadBundled(
            bundleCandidates: [
                Bundle(for: TotalSegmentatorHorosPlugin.self),
                Bundle.main
            ]
        )
    }

    static let taskCapabilityManifestLoadError: Error? = {
        switch taskCapabilityManifestLoadResult {
        case .success:
            return nil
        case .failure(let error):
            return error
        }
    }()

    static let taskCapabilityManifest: TaskCapabilityManifest = {
        switch taskCapabilityManifestLoadResult {
        case .success(let manifest):
            return manifest
        case .failure:
            return TaskCapabilityManifest.fallbackUnavailableManifest
        }
    }()

    static var capabilityManifestIsAvailable: Bool {
        taskCapabilityManifestLoadError == nil
    }

    static var capabilityManifestLoadFailureMessage: String {
        let detail = taskCapabilityManifestLoadError?.localizedDescription ?? "Unknown error."
        return "TotalSegmentator cannot start because the bundled task capability manifest could not be loaded. \(detail)"
    }

    /// Organizes task capabilities into groups for UI selection.
    /// The automatic task option is prepended as the first group, deprecated capabilities are excluded, and feature flags are set based on manifest data.
    /// - Returns: An array of task groups, each containing task options with capability information.
    static func taskGroupsFromCapabilityManifest(_ manifest: TaskCapabilityManifest) -> [TaskGroup] {
        var groups: [TaskGroup] = [
            TaskGroup(
                name: NSLocalizedString("Automatic", comment: "Task group header for automatic task selection"),
                tasks: [
                    TaskOption(
                        title: NSLocalizedString("Automatic (default)", comment: "Default task option"),
                        value: nil,
                        description: NSLocalizedString("Leaves --task unset so TotalSegmentator uses its default task for the input images. Recommended for most workflows.", comment: "Task description for automatic task selection")
                    )
                ]
            )
        ]

        var groupedCapabilities: [String: [TaskCapability]] = [:]
        for capability in manifest.tasks where !capability.deprecated {
            groupedCapabilities[capability.group, default: []].append(capability)
        }

        for groupName in manifest.tasks.map(\.group).removingDuplicates() {
            guard let capabilities = groupedCapabilities[groupName], !capabilities.isEmpty else {
                continue
            }

            groups.append(
                TaskGroup(
                    name: NSLocalizedString(groupName, comment: "Task group header from TotalSegmentator capability manifest"),
                    tasks: capabilities.map { capability in
                        TaskOption(
                            title: capability.displayName,
                            value: capability.identifier,
                            description: capability.description,
                            supportsROISubset: capability.supportsRoiSubset,
                            supportsFastMode: capability.qualityModes.contains("fast")
                        )
                    }
                )
            )
        }

        return groups
    }

    /// Validates that the requested segmentation task and configuration are supported.
    /// - Parameters:
    ///   - task: The requested task identifier, or `nil` to use the default task.
    ///   - modality: The input modality, or `nil` to skip modality validation.
    ///   - useFast: Whether fast quality mode is requested.
    ///   - additionalArguments: Command-line arguments that may specify quality modes or output options.
    ///   - manifest: The capability manifest to validate against. Defaults to the bundled manifest.
    /// - Returns: The capability for the validated task.
    /// - Throws: `TotalSegmentatorCapabilityError` if the task, modality, or configuration is not supported.
    static func validateLaunchCapability(
        task: String?,
        modality: String?,
        useFast: Bool,
        additionalArguments: [String],
        manifest: TaskCapabilityManifest = TotalSegmentatorHorosPlugin.taskCapabilityManifest
    ) throws -> TaskCapability {
        return try manifest.validate(
            task: task,
            modality: modality,
            useFast: useFast,
            additionalArguments: additionalArguments
        )
    }
}

private extension Array where Element: Hashable {
    /// Removes duplicate elements from the array.
    /// - Returns: An array containing only the first occurrence of each element.
    func removingDuplicates() -> [Element] {
        var seen: Set<Element> = []
        var result: [Element] = []
        for element in self where !seen.contains(element) {
            seen.insert(element)
            result.append(element)
        }
        return result
    }
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

enum RTStructExportMode: String, Codable, CaseIterable, Equatable {
    case disabled
    case optional
    case required

    init(preferenceValue: String?) {
        guard let normalized = preferenceValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let mode = RTStructExportMode(rawValue: normalized) else {
            self = .disabled
            return
        }

        self = mode
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
    var exportManifestURL: URL
    var jobManifestURL: URL
    var jobManifest: SegmentationJobManifest
}

struct SegmentationRunWorkspace {
    let rootDirectory: URL
    let inputDirectory: URL
    let workDirectory: URL
    let outputDirectory: URL
    let completionManifestURL: URL
    let provenanceManifestURL: URL
    let diagnosticSummaryURL: URL
    let jobManifestURL: URL
    let exportManifestURL: URL
    let publicationBaseDirectory: URL?
    let publishedOutputDirectory: URL?
}

struct SegmentationArtifactRecord: Codable {
    let relativePath: String
    let kind: String
    let sha256: String
    let byteCount: Int64
}

struct SegmentationRunCompletionManifest: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let completedAt: Date
    let jobUUID: String
    let sourceIdentityHash: String
    let validationVersion: String
    let outputDirectory: String
    let artifactCount: Int
    let artifacts: [SegmentationArtifactRecord]
}

struct SegmentationRunStageOutcome: Codable {
    let stage: String
    let status: String
    let startedAt: Date?
    let endedAt: Date?
    let durationSeconds: Double?
    let processExitStatus: Int?
    let warnings: [String]
    let fallbackUsed: Bool
    let artifactCount: Int?
}

struct SegmentationSourceIdentityProvenance: Codable {
    let sourceIdentityHash: String
    let studyInstanceUIDHash: String?
    let seriesInstanceUIDHash: String?
    let frameOfReferenceUIDHash: String?
    let orderedSOPInstanceUIDsHash: String
    let sourceInstanceCount: Int
}

struct SegmentationRuntimeProvenance: Codable {
    let pluginVersion: String
    let pluginBuild: String
    let pluginCommit: String?
    let hostApplication: String?
    let hostVersion: String?
    let operatingSystemVersion: String
    let architecture: String
    let pythonExecutableName: String
    let pythonExecutablePathHash: String
    let runtimeCapabilityProbe: RuntimeCapabilityProbe?
}

struct SegmentationConfigurationProvenance: Codable {
    let task: String?
    let capabilityTaskIdentifier: String?
    let requestedLabels: [String]
    let effectiveLabels: [String]
    let requestedDevice: String?
    let effectiveDevice: String?
    let requestedQuality: String
    let effectiveQuality: String
    let normalizedCLIArguments: [String]
    let capabilityManifestVersion: String
    let terminologyMappingVersion: String?
}

struct SegmentationBackendProvenance: Codable {
    let environmentLockIdentifier: String
    let environmentManifestIdentifier: String?
    let environmentManifestPathHash: String?
    let bridgeVersion: String
    let bridgeSchemaVersion: Int
    let bridgePackageHash: String?
    let totalSegmentatorVersion: String?
}

struct SegmentationProvenanceRecord: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let jobUUID: String
    let runState: String
    let startedAt: Date?
    let endedAt: Date?
    let processExitStatus: Int?
    let jobManifestSchemaVersion: Int
    let jobManifestHash: String?
    let sourceIdentity: SegmentationSourceIdentityProvenance
    let runtime: SegmentationRuntimeProvenance
    let runtimeProbe: RuntimeCapabilityProbe?
    let configuration: SegmentationConfigurationProvenance
    let backend: SegmentationBackendProvenance
    let stageOutcomes: [SegmentationRunStageOutcome]
    let acceptedArtifacts: [SegmentationArtifactRecord]
    let artifactIntegrityMismatches: [String]
    let completionManifestPath: String?
    let completionManifestHash: String?
    let outputType: String
    let convertedFromNifti: Bool
    let cancellationRequested: Bool
    let warnings: [String]
}

struct SegmentationDiagnosticSummary: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let jobUUID: String
    let runState: String
    let sourceDICOMIncluded: Bool
    let directPatientIdentifiersIncluded: Bool
    let redactedSourceIdentity: SegmentationSourceIdentityProvenance
    let runtimeProbe: RuntimeCapabilityProbe?
    let configuration: SegmentationConfigurationProvenance
    let backend: SegmentationBackendProvenance
    let stageOutcomes: [SegmentationRunStageOutcome]
    let acceptedArtifacts: [SegmentationArtifactRecord]
    let artifactIntegrityMismatches: [String]
    let warnings: [String]
}

struct SegmentationImportResult {
    let addedFilePaths: [String]
    let rtStructPaths: [String]
    let importedObjectIDs: [NSManagedObjectID]
    let outputType: SegmentationOutputType
    let volumetricROIManifestPath: String?
    let rtStructExportMode: RTStructExportMode
    let rtStructStatus: String?
    let rtStructError: String?
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
    let certificationStatusIdentifier: String
    let certificationStatusDisplayName: String
    let medicalImagingCertified: Bool
    let validationEvidenceVersion: String
    let bridgeVersion: String
    let bridgeSchemaVersion: Int
    let bridgePackageHash: String?
    let modelVersion: String?
    let environmentManifestIdentifier: String?
    let environmentManifestPath: String?
    let environmentLockIdentifier: String?
    let jobUUID: String?
    let jobManifestPath: String?
    let jobManifestHash: String?
    let series: [SeriesInfo]
    let convertedFromNifti: Bool
}

enum SegmentationValidationError: LocalizedError {
    case executableNotFound
    case outputDirectoryMissing
    case outputDirectoryEmpty
    case expectedArtifactMissing(String)
    case outputArtifactEmpty(String)
    case runWorkspaceAlreadyExists(String)
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Unable to locate the TotalSegmentator executable. Please review the settings."
        case .outputDirectoryMissing:
            return "No output directory was created by TotalSegmentator."
        case .outputDirectoryEmpty:
            return "The TotalSegmentator output directory is empty. Please check the logs for errors."
        case .expectedArtifactMissing(let name):
            return "The TotalSegmentator output is missing the expected artifact: \(name)."
        case .outputArtifactEmpty(let name):
            return "The TotalSegmentator output artifact '\(name)' is empty."
        case .runWorkspaceAlreadyExists(let jobUUID):
            return "A TotalSegmentator run workspace already exists for job \(jobUUID)."
        case .applicationSupportUnavailable:
            return "Unable to resolve the Application Support directory for TotalSegmentator run storage."
        }
    }
}
