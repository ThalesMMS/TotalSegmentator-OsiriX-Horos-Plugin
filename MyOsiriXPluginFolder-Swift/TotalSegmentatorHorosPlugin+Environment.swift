//
// TotalSegmentatorHorosPlugin+Environment.swift
// TotalSegmentator
//

import Cocoa
import CryptoKit
import Darwin

private enum Dcm2NiixBootstrap {
    // When updating the pinned dcm2niix version, download this exact archive,
    // recompute both SHA-256 digests, and update all constants together.
    static let pinnedVersion = "v1.0.20250506"
    static let archiveName = "dcm2niix_mac.zip"
    static var pinnedDcm2NiixDownloadURL: String {
        "https://github.com/rordenlab/dcm2niix/releases/download/\(pinnedVersion)/\(archiveName)"
    }
    static let expectedDcm2NiixSHA256 = "6b66e0e83a3c62f8ad56df26e129234fb7424508dccf03525a1879e0291e52f1"
    static let expectedBinarySHA256 = "d5ed1c549df2246e53875dfbd54d7ce7519c8a64f0c8f93c55edc7cb8e9d02e2"
}

private final class EnvironmentProcessLock {
    private var fileDescriptor: Int32 = -1
    let url: URL

    init(url: URL, ownerDescription: String) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = open(url.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw NSError(
                domain: "org.totalsegmentator.plugin.environment-lock",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Unable to open environment lock file at \(url.path)."]
            )
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw NSError(
                domain: "org.totalsegmentator.plugin.environment-lock",
                code: Int(errno),
                userInfo: [
                    NSLocalizedDescriptionKey: "Environment setup lock is already held.",
                    "owner": Self.currentOwner(at: url) ?? ""
                ]
            )
        }

        fileDescriptor = descriptor
        writeOwner(ownerDescription)
    }

    deinit {
        if fileDescriptor >= 0 {
            _ = flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }

    /// Reads the owner description from a lock file.
    /// - Parameters:
    ///   - url: The lock file URL.
    /// - Returns: The owner description if the lock file can be read and contains non-empty text, `nil` otherwise.
    static func currentOwner(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let rawOwner = String(data: data, encoding: .utf8) else {
            return nil
        }
        let owner = rawOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty else {
            return nil
        }
        return owner
    }

    /// Writes the process owner information to the lock file.
    ///
    /// Truncates the file, seeks to the beginning, and writes the owner description followed by a newline.
    private func writeOwner(_ ownerDescription: String) {
        _ = ftruncate(fileDescriptor, 0)
        _ = lseek(fileDescriptor, 0, SEEK_SET)
        guard let data = (ownerDescription + "\n").data(using: .utf8) else {
            return
        }
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = write(fileDescriptor, baseAddress, buffer.count)
        }
    }
}

extension TotalSegmentatorHorosPlugin {
    static let environmentLockManifest: EnvironmentLockManifest = {
        do {
            for bundle in [Bundle(for: TotalSegmentatorHorosPlugin.self), Bundle.main] {
                guard let url = bundle.url(forResource: "TotalSegmentatorEnvironmentLock", withExtension: "json") else {
                    continue
                }
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(EnvironmentLockManifest.self, from: data)
            }
            throw TotalSegmentatorCapabilityError.missingManifest
        } catch {
            fatalError("Unable to load TotalSegmentatorEnvironmentLock.json: \(error.localizedDescription)")
        }
    }()

    /// Prepares the plugin environment for operation.
    ///
    /// Validates that the Python interpreter, totalsegmentator module, and dcm2niix binary are configured and available.
    /// - Parameters:
    ///   - progressController: Optional progress reporter for setup steps and cancellation requests.
    /// - Returns: An `EnvironmentReadinessResult` indicating whether the environment is ready, or describing any failure or cancellation.
    func prepareEnvironmentIfNeeded(progressController: SegmentationProgressReporting? = nil) -> EnvironmentReadinessResult {
        environmentLifecycleManager.run(progressController: progressController) {
            self.performSerializedEnvironmentSetup(progressController: progressController)
        }
    }

    /// Ensures the environment is set up and presents failure instructions if not ready.
    /// - Parameters:
    ///   - progressController: An optional object for reporting setup progress and checking for cancellation requests.
    /// - Returns: `true` if the environment is ready, `false` otherwise.
    @discardableResult
    func performInitialSetupIfNeeded(progressController: SegmentationProgressReporting? = nil) -> Bool {
        let result = prepareEnvironmentIfNeeded(progressController: progressController)
        if !result.isReady {
            presentEnvironmentSetupFailureInstructions(for: result)
        }
        return result.isReady
    }

    /// Orchestrates the complete environment setup for TotalSegmentator.
    ///
    /// Ensures the Python environment is configured and all required components are available,
    /// including the interpreter, managed virtual environment if needed, pinned environment
    /// validation, model weights, and dcm2niix.
    ///
    /// - Returns: An `EnvironmentReadinessResult` indicating ready status or the specific failure encountered.
    private func performSerializedEnvironmentSetup(progressController: SegmentationProgressReporting?) -> EnvironmentReadinessResult {
        autoreleasepool {
            let lockIdentifier = Self.environmentLockManifest.lockIdentifier
            let initialManifestIdentifier = currentEnvironmentManifestIdentifier()
            var recoveredInterruptedInstall = false
            var preferencesState = preferences.effectivePreferences()
            var updatedPreferences = preferencesState

            progressController?.append("Checking pinned Python environment \(lockIdentifier)…")
            guard let processLock = acquireEnvironmentProcessLock() else {
                let owner = environmentProcessLockURL().flatMap { EnvironmentProcessLock.currentOwner(at: $0) }
                return EnvironmentReadinessResult.failure(
                    lockIdentifier: lockIdentifier,
                    manifestIdentifier: initialManifestIdentifier,
                    pythonPath: preferencesState.executablePath,
                    error: .processLockUnavailable(owner: owner)
                )
            }
            defer { withExtendedLifetime(processLock) {} }

            recoveredInterruptedInstall = recoverAbandonedEnvironmentInstallMarker(progressController: progressController)

            let capabilityManifest = Self.taskCapabilityManifest
            progressController?.append("Loaded capability manifest \(capabilityManifest.manifestVersion) with \(capabilityManifest.tasks.count) tasks.")
            logToConsole("Loaded TotalSegmentator capability manifest \(capabilityManifest.manifestVersion) with \(capabilityManifest.tasks.count) tasks.")

            guard var executableResolution = resolvePythonInterpreter(using: preferencesState) else {
                return EnvironmentReadinessResult.failure(
                    lockIdentifier: lockIdentifier,
                    manifestIdentifier: currentEnvironmentManifestIdentifier(),
                    pythonPath: preferencesState.executablePath,
                    recoveredInterruptedInstall: recoveredInterruptedInstall,
                    error: .unableToResolveInterpreter
                )
            }

            if !pythonModuleAvailable("totalsegmentator", using: executableResolution) {
                logToConsole("TotalSegmentator module not found. Attempting to create a managed virtual environment.")

                if let managed = bootstrapManagedPythonEnvironment(baseResolution: executableResolution, progressController: progressController) {
                    executableResolution = managed.resolution
                    updatedPreferences.executablePath = managed.pythonPath
                    preferences.store(updatedPreferences)
                    preferencesState = updatedPreferences

                    DispatchQueue.main.async { [weak self] in
                        self?.executablePathField?.stringValue = managed.pythonPath
                    }
                } else {
                    return EnvironmentReadinessResult.failure(
                        state: .installingInPlace,
                        lockIdentifier: lockIdentifier,
                        manifestIdentifier: currentEnvironmentManifestIdentifier(),
                        pythonPath: preferencesState.executablePath,
                        recoveredInterruptedInstall: recoveredInterruptedInstall,
                        error: .installFailed("Managed virtualenv creation or pinned package installation failed.")
                    )
                }
            }

            guard pythonModuleAvailable("totalsegmentator", using: executableResolution) else {
                return EnvironmentReadinessResult.failure(
                    lockIdentifier: lockIdentifier,
                    manifestIdentifier: currentEnvironmentManifestIdentifier(),
                    pythonPath: executableResolution.executableURL.path,
                    recoveredInterruptedInstall: recoveredInterruptedInstall,
                    error: .missingTotalSegmentator
                )
            }

            progressController?.append("Validating pinned Python environment…")
            if let validationError = validatePinnedPythonEnvironment(using: executableResolution, progressController: progressController) {
                if isManagedEnvironmentPython(executableResolution.executableURL),
                   let rebuilt = rebuildManagedPythonEnvironment(
                    currentResolution: executableResolution,
                    progressController: progressController
                   ) {
                    executableResolution = rebuilt.resolution
                    updatedPreferences.executablePath = rebuilt.pythonPath
                    preferences.store(updatedPreferences)
                    preferencesState = updatedPreferences

                    DispatchQueue.main.async { [weak self] in
                        self?.executablePathField?.stringValue = rebuilt.pythonPath
                    }

                    if let repairedValidationError = validatePinnedPythonEnvironment(using: executableResolution, progressController: progressController) {
                        return EnvironmentReadinessResult.failure(
                            lockIdentifier: lockIdentifier,
                            manifestIdentifier: currentEnvironmentManifestIdentifier(),
                            pythonPath: executableResolution.executableURL.path,
                            recoveredInterruptedInstall: recoveredInterruptedInstall,
                            error: repairedValidationError
                        )
                    }
                    progressController?.append("Managed Python environment repair completed.")
                } else {
                    return EnvironmentReadinessResult.failure(
                        lockIdentifier: lockIdentifier,
                        manifestIdentifier: currentEnvironmentManifestIdentifier(),
                        pythonPath: executableResolution.executableURL.path,
                        recoveredInterruptedInstall: recoveredInterruptedInstall,
                        error: validationError
                    )
                }
            }

            if progressController?.isCancellationRequested == true {
                return EnvironmentReadinessResult.failure(
                    lockIdentifier: lockIdentifier,
                    manifestIdentifier: currentEnvironmentManifestIdentifier(),
                    pythonPath: executableResolution.executableURL.path,
                    packageEnvironmentReady: true,
                    recoveredInterruptedInstall: recoveredInterruptedInstall,
                    error: .cancelled
                )
            }

            progressController?.append("Preparing TotalSegmentator model weights…")
            let setupSucceeded = ensureTotalSegmentatorSetup(using: executableResolution, progressController: progressController)
            if !setupSucceeded {
                progressController?.append("TotalSegmentator setup encountered issues. Please review the log output.")
                return EnvironmentReadinessResult.failure(
                    lockIdentifier: lockIdentifier,
                    manifestIdentifier: currentEnvironmentManifestIdentifier(),
                    pythonPath: executableResolution.executableURL.path,
                    packageEnvironmentReady: true,
                    recoveredInterruptedInstall: recoveredInterruptedInstall,
                    error: progressController?.isCancellationRequested == true ? .cancelled : .modelWeightsUnavailable
                )
            }

            progressController?.append("Preparing pinned dcm2niix…")
            guard let dcm2niixPath = ensureDcm2Niix(using: executableResolution, progressController: progressController) else {
                progressController?.append("Unable to prepare dcm2niix. Please review the displayed instructions.")
                return EnvironmentReadinessResult.failure(
                    lockIdentifier: lockIdentifier,
                    manifestIdentifier: currentEnvironmentManifestIdentifier(),
                    pythonPath: executableResolution.executableURL.path,
                    packageEnvironmentReady: true,
                    modelWeightsReady: true,
                    recoveredInterruptedInstall: recoveredInterruptedInstall,
                    error: progressController?.isCancellationRequested == true ? .cancelled : .dcm2niixUnavailable
                )
            }

            if updatedPreferences.dcm2niixPath != dcm2niixPath {
                updatedPreferences.dcm2niixPath = dcm2niixPath
                preferences.store(updatedPreferences)
            }

            progressController?.append("Environment ready.")
            return EnvironmentReadinessResult.ready(
                lockIdentifier: lockIdentifier,
                manifestIdentifier: currentEnvironmentManifestIdentifier(),
                pythonPath: executableResolution.executableURL.path,
                dcm2niixPath: dcm2niixPath,
                recoveredInterruptedInstall: recoveredInterruptedInstall
            )
        }
    }

    /// Attempts to acquire an exclusive process-wide lock for environment setup.
    /// - Returns: An `EnvironmentProcessLock` if the lock was successfully acquired, `nil` otherwise.
    private func acquireEnvironmentProcessLock() -> EnvironmentProcessLock? {
        guard let lockURL = environmentProcessLockURL() else {
            return nil
        }

        let owner = "pid=\(ProcessInfo.processInfo.processIdentifier) lock=\(Self.environmentLockManifest.lockIdentifier) started=\(ISO8601DateFormatter().string(from: Date()))"
        return try? EnvironmentProcessLock(url: lockURL, ownerDescription: owner)
    }

    /// Returns the URL to the environment setup lock file.
    /// - Returns: The lock file URL, or `nil` if the plugin support directory is unavailable.
    private func environmentProcessLockURL() -> URL? {
        pluginSupportDirectory()?.appendingPathComponent("environment-setup.lock", isDirectory: false)
    }

    /// Resolves the location of the environment installation marker file.
    /// - Returns: The URL of the marker file, or `nil` if the plugin support directory is unavailable.
    private func environmentInstallMarkerURL() -> URL? {
        pluginSupportDirectory()?.appendingPathComponent("environment-install-marker.json", isDirectory: false)
    }

    /// Records the current environment installation state to disk for interrupted installation recovery.
    /// - Parameters:
    ///   - state: The current lifecycle state to record.
    ///   - resolution: The resolved Python interpreter; used to record the executable path if available.
    /// - Returns: `true` if the marker was written successfully, `false` otherwise.
    private func recordEnvironmentMutationMarker(
        state: EnvironmentLifecycleState,
        resolution: ExecutableResolution?,
        progressController: SegmentationProgressReporting?
    ) -> Bool {
        guard let markerURL = environmentInstallMarkerURL() else {
            return false
        }

        let currentManifestIdentifier = currentEnvironmentManifestIdentifier()
        let marker: [String: Any] = [
            "schemaVersion": 1,
            "state": state.rawValue,
            "targetLockIdentifier": Self.environmentLockManifest.lockIdentifier,
            "currentManifestIdentifier": currentManifestIdentifier ?? NSNull(),
            "healthStatus": currentManifestIdentifier == Self.environmentLockManifest.lockIdentifier ? "matching-manifest" : "missing-or-mismatched-manifest",
            "pythonPath": resolution?.executableURL.path ?? NSNull(),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "startedAt": ISO8601DateFormatter().string(from: Date())
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: markerURL, options: .atomic)
            progressController?.append("Recorded environment install marker for \(Self.environmentLockManifest.lockIdentifier).")
            return true
        } catch {
            logToConsole("Failed to record environment install marker: \(error.localizedDescription)")
            return false
        }
    }

    /// Removes the environment installation marker file if it exists.
    private func removeEnvironmentMutationMarker() {
        guard let markerURL = environmentInstallMarkerURL(),
              FileManager.default.fileExists(atPath: markerURL.path) else {
            return
        }
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// Detects and removes a stale environment installation marker from a previous interrupted setup.
    /// - Parameter progressController: Optional progress controller for reporting recovery status.
    /// - Returns: `true` if an abandoned marker was found and removed, `false` otherwise.
    @discardableResult
    private func recoverAbandonedEnvironmentInstallMarker(progressController: SegmentationProgressReporting?) -> Bool {
        guard let markerURL = environmentInstallMarkerURL(),
              FileManager.default.fileExists(atPath: markerURL.path) else {
            return false
        }

        let markerDescription = (try? String(contentsOf: markerURL, encoding: .utf8)) ?? markerURL.path
        progressController?.append("Detected interrupted environment setup. Clearing stale install marker and retrying health check.")
        logToConsole("Detected interrupted environment setup marker: \(markerDescription)")
        removeEnvironmentMutationMarker()
        return true
    }

    /// Determines whether a Python module is available in the given Python environment.
    /// - Parameters:
    ///   - moduleName: The name of the Python module to check.
    ///   - resolution: The Python interpreter resolution to use.
    /// - Returns: `true` if the module is available, `false` otherwise.
    func pythonModuleAvailable(_ moduleName: String, using resolution: ExecutableResolution) -> Bool {
        let script = """
import importlib.util
import sys

module = sys.argv[1]
spec = importlib.util.find_spec(module)
sys.exit(0 if spec is not None else 1)
"""

        let result = runPythonProcess(
            using: resolution,
            arguments: ["-c", script, moduleName],
            progressController: nil
        )

        if let error = result.error {
            logToConsole("Python execution failed while probing module '\(moduleName)': \(error.localizedDescription)")
            return false
        }

        return result.terminationStatus == 0
    }

    func runPythonProcess(
        using resolution: ExecutableResolution,
        arguments: [String],
        environment customEnvironment: [String: String]? = nil,
        progressController: SegmentationProgressReporting?
    ) -> ProcessExecutionResult {
        let process = Process()
        process.executableURL = resolution.executableURL
        process.arguments = resolution.leadingArguments + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"

        if let baseEnvironment = resolution.environment {
            environment.merge(baseEnvironment) { _, new in new }
        }

        if let custom = customEnvironment {
            environment.merge(custom) { _, new in new }
        }

        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var capturedStdout = Data()
        var capturedStderr = Data()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { [weak self, weak progressController] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            capturedStdout.append(data)

            if let message = String(data: data, encoding: .utf8), !message.isEmpty {
                progressController?.append(message)
                self?.logToConsole(message)
            }
        }

        stderrHandle.readabilityHandler = { [weak self, weak progressController] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            capturedStderr.append(data)

            if let message = String(data: data, encoding: .utf8), !message.isEmpty {
                progressController?.append(message)
                self?.logToConsole(message)
            }
        }

        var launchError: Error?

        do {
            try process.run()
        } catch {
            launchError = error
        }

        if let error = launchError {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            return ProcessExecutionResult(terminationStatus: -1, stdout: capturedStdout, stderr: capturedStderr, error: error)
        }

        var didRequestCancellation = false
        while process.isRunning {
            if progressController?.isCancellationRequested == true {
                didRequestCancellation = true
                progressController?.append("Cancellation requested. Terminating current process…")
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        process.waitUntilExit()
        if didRequestCancellation {
            progressController?.append("Process cancelled.")
        }
        progressController?.append("TotalSegmentator finished with status \(process.terminationStatus). Validating outputs…")

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        capturedStdout.append(stdoutHandle.readDataToEndOfFile())
        capturedStderr.append(stderrHandle.readDataToEndOfFile())

        return ProcessExecutionResult(
            terminationStatus: process.terminationStatus,
            stdout: capturedStdout,
            stderr: capturedStderr,
            error: nil
        )
    }

    /// Ensures a managed Python virtual environment exists with the TotalSegmentator module installed.
    /// - Parameters:
    ///   - baseResolution: The Python interpreter resolution to use for creating the virtual environment.
    /// - Returns: A tuple containing the ExecutableResolution for the managed environment and the path to the Python binary, or `nil` if the bootstrap fails.
    private func bootstrapManagedPythonEnvironment(
        baseResolution: ExecutableResolution,
        progressController: SegmentationProgressReporting?
    ) -> (resolution: ExecutableResolution, pythonPath: String)? {
        guard let environmentDirectory = managedEnvironmentDirectory() else {
            logToConsole("Failed to resolve a location for the managed Python environment.")
            return nil
        }

        let binDirectory = environmentDirectory.appendingPathComponent("bin", isDirectory: true)
        let python3URL = binDirectory.appendingPathComponent("python3", isDirectory: false)
        let pythonURL = binDirectory.appendingPathComponent("python", isDirectory: false)
        let fileManager = FileManager.default
        var mutationMarkerRecorded = false

        guard let environmentBaseResolution = managedEnvironmentBaseResolution(
            preferred: baseResolution,
            progressController: progressController
        ) else {
            progressController?.append("No Python interpreter compatible with \(Self.environmentLockManifest.lockIdentifier) was found for managed environment creation.")
            return nil
        }

        func recordMutationMarkerIfNeeded(resolution: ExecutableResolution?) {
            if !mutationMarkerRecorded {
                mutationMarkerRecorded = recordEnvironmentMutationMarker(
                    state: .installingInPlace,
                    resolution: resolution,
                    progressController: progressController
                )
            }
        }

        defer {
            if mutationMarkerRecorded {
                removeEnvironmentMutationMarker()
            }
        }

        if !fileManager.fileExists(atPath: python3URL.path) && !fileManager.fileExists(atPath: pythonURL.path) {
            progressController?.append("Creating managed Python environment…")
            recordMutationMarkerIfNeeded(resolution: environmentBaseResolution)
            let result = runPythonProcess(
                using: environmentBaseResolution,
                arguments: ["-m", "venv", environmentDirectory.path],
                progressController: progressController
            )

            if result.terminationStatus != 0 || result.error != nil {
                progressController?.append("Failed to create the virtual environment. Please review the console output.")
                logToConsole("Failed to create virtual environment: status=\(result.terminationStatus)")
                return nil
            }
        }

        let pythonBinary: URL
        if fileManager.isExecutableFile(atPath: python3URL.path) {
            pythonBinary = python3URL
        } else if fileManager.isExecutableFile(atPath: pythonURL.path) {
            pythonBinary = pythonURL
        } else {
            logToConsole("Managed Python environment exists but no executable interpreter was found.")
            return nil
        }

        var environment = baseResolution.environment ?? [:]
        var existingPath = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let binPath = binDirectory.path
        let pathComponents = existingPath.split(separator: ":").map(String.init)
        if !pathComponents.contains(binPath) {
            existingPath = binPath + (existingPath.isEmpty ? "" : ":" + existingPath)
        }
        environment["PATH"] = existingPath
        environment["VIRTUAL_ENV"] = environmentDirectory.path

        let managedResolution: ExecutableResolution = (pythonBinary, [], environment)

        if !pythonModuleAvailable("totalsegmentator", using: managedResolution) {
            progressController?.append("Installing TotalSegmentator into managed environment…")
            recordMutationMarkerIfNeeded(resolution: managedResolution)

            if !installPinnedPythonPackages(using: managedResolution, progressController: progressController) {
                return nil
            }
        }

        guard pythonModuleAvailable("totalsegmentator", using: managedResolution) else {
            logToConsole("Managed environment was created but TotalSegmentator is still unavailable.")
            return nil
        }

        return (managedResolution, pythonBinary.path)
    }

    private func rebuildManagedPythonEnvironment(
        currentResolution: ExecutableResolution,
        progressController: SegmentationProgressReporting?
    ) -> (resolution: ExecutableResolution, pythonPath: String)? {
        guard let environmentDirectory = managedEnvironmentDirectory(),
              isManagedEnvironmentPython(currentResolution.executableURL) else {
            return nil
        }
        guard let baseResolution = managedEnvironmentBaseResolution(
            preferred: currentResolution,
            progressController: progressController
        ) else {
            progressController?.append("Unable to find a Python interpreter compatible with the pinned environment lock.")
            return nil
        }

        let markerRecorded = recordEnvironmentMutationMarker(
            state: .repairing,
            resolution: currentResolution,
            progressController: progressController
        )
        defer {
            if markerRecorded {
                removeEnvironmentMutationMarker()
            }
        }

        do {
            if FileManager.default.fileExists(atPath: environmentDirectory.path) {
                progressController?.append("Rebuilding managed Python environment to match \(Self.environmentLockManifest.lockIdentifier)…")
                try FileManager.default.removeItem(at: environmentDirectory)
            }
        } catch {
            progressController?.append("Unable to remove the managed Python environment for repair: \(error.localizedDescription)")
            return nil
        }

        return bootstrapManagedPythonEnvironment(
            baseResolution: baseResolution,
            progressController: progressController
        )
    }

    private func managedEnvironmentBaseResolution(
        preferred: ExecutableResolution?,
        progressController: SegmentationProgressReporting?
    ) -> ExecutableResolution? {
        if let preferred = preferred,
           !isManagedEnvironmentPython(preferred.executableURL),
           pythonResolutionMatchesEnvironmentLock(preferred) {
            return preferred
        }

        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let candidatePaths = [
            "/opt/homebrew/bin/python3.12",
            "/usr/local/bin/python3.12",
            "\(homeDirectory)/.local/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/usr/local/bin/python3.11",
            "\(homeDirectory)/.local/bin/python3.11",
            "/opt/homebrew/bin/python3.10",
            "/usr/local/bin/python3.10",
            "\(homeDirectory)/.local/bin/python3.10",
            "/opt/homebrew/bin/python3.9",
            "/usr/local/bin/python3.9",
            "\(homeDirectory)/.local/bin/python3.9",
            "/usr/bin/python3"
        ]

        for path in candidatePaths {
            guard let resolution = interpreterResolution(for: path) else { continue }
            if pythonResolutionMatchesEnvironmentLock(resolution) {
                progressController?.append("Using \(path) for managed Python environment creation.")
                return resolution
            }
        }

        let candidateNames = ["python3.12", "python3.11", "python3.10", "python3.9"]
        for name in candidateNames {
            let resolution: ExecutableResolution = (URL(fileURLWithPath: "/usr/bin/env"), [name], nil)
            if pythonResolutionMatchesEnvironmentLock(resolution) {
                progressController?.append("Using \(name) for managed Python environment creation.")
                return resolution
            }
        }

        return nil
    }

    private func pythonResolutionMatchesEnvironmentLock(_ resolution: ExecutableResolution) -> Bool {
        guard let identity = pythonRuntimeIdentity(using: resolution),
              let pythonVersion = identity["pythonVersion"] as? String,
              let architecture = identity["architecture"] as? String else {
            return false
        }

        let lock = Self.environmentLockManifest.python
        guard compareVersions(pythonVersion, lock.minimumVersion) != .orderedAscending else {
            return false
        }
        guard compareVersions(pythonVersion, lock.maximumExclusiveVersion) == .orderedAscending else {
            return false
        }
        return lock.supportedArchitectures.contains(architecture)
    }

    private func pythonRuntimeIdentity(using resolution: ExecutableResolution) -> [String: Any]? {
        let script = """
import json
import platform

print("__RESULT__" + json.dumps({
    "pythonVersion": platform.python_version(),
    "architecture": platform.machine()
}))
"""
        let result = runPythonProcess(
            using: resolution,
            arguments: ["-c", script],
            progressController: nil
        )

        guard result.error == nil, result.terminationStatus == 0 else {
            return nil
        }
        return extractResultDictionary(from: result.stdout)
    }

    private func isManagedEnvironmentPython(_ url: URL) -> Bool {
        guard let environmentDirectory = managedEnvironmentDirectory() else {
            return false
        }
        let environmentPath = environmentDirectory.standardizedFileURL.path
        let pythonPath = url.standardizedFileURL.path
        return pythonPath == environmentPath || pythonPath.hasPrefix(environmentPath + "/")
    }

    /// Ensures the managed Python environment directory exists.
    /// - Returns: The URL to the environment directory, or `nil` if the directory cannot be created.
    private func managedEnvironmentDirectory() -> URL? {
        let fileManager = FileManager.default
        guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let pluginDirectory = supportDirectory.appendingPathComponent("TotalSegmentatorHorosPlugin", isDirectory: true)
        let environmentDirectory = pluginDirectory.appendingPathComponent("PythonEnvironment", isDirectory: true)

        do {
            try fileManager.createDirectory(at: environmentDirectory, withIntermediateDirectories: true)
        } catch {
            logToConsole("Failed to create managed environment directory: \(error.localizedDescription)")
            return nil
        }

        return environmentDirectory
    }

    /// Computes the location of the environment manifest file.
    /// - Returns: The URL of the environment manifest file, or `nil` if the plugin support directory is unavailable.
    func environmentManifestURL() -> URL? {
        return pluginSupportDirectory()?.appendingPathComponent("environment-manifest.json", isDirectory: false)
    }

    /// Retrieves the lock identifier from the current environment manifest.
    /// - Returns: The lock identifier string from the environment manifest, or `nil` if the manifest file is unavailable or does not contain a lock identifier.
    func currentEnvironmentManifestIdentifier() -> String? {
        guard let url = environmentManifestURL(),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        return dictionary["lockIdentifier"] as? String
    }

    /// Installs pinned Python packages specified in the environment lock manifest.
    /// - Parameters:
    ///   - resolution: The Python executable and environment to use for installation.
    ///   - progressController: Controller for reporting progress messages.
    /// - Returns: `true` if the packages were successfully installed, `false` otherwise.
    private func installPinnedPythonPackages(
        using resolution: ExecutableResolution,
        progressController: SegmentationProgressReporting?
    ) -> Bool {
        let lock = Self.environmentLockManifest
        progressController?.append("Installing pinned TotalSegmentator environment \(lock.lockIdentifier)…")

        let installResult = runPythonProcess(
            using: resolution,
            arguments: ["-m", "pip", "install", "--upgrade"] + lock.installRequirements,
            progressController: progressController
        )

        if installResult.terminationStatus != 0 || installResult.error != nil {
            logToConsole("Failed to install pinned TotalSegmentator environment: status=\(installResult.terminationStatus)")
            return false
        }

        return true
    }

    /// Validates the Python environment against pinned requirements and persists the manifest.
    ///
    /// Captures the environment manifest, compares it against the pinned lock's version and platform constraints, and writes the manifest to disk if validation succeeds.
    /// - Parameters:
    ///   - resolution: The Python interpreter to validate.
    ///   - progressController: Reports validation progress.
    /// - Returns: `nil` if valid and the manifest is persisted; an `EnvironmentReadinessError` otherwise.
    private func validatePinnedPythonEnvironment(
        using resolution: ExecutableResolution,
        progressController: SegmentationProgressReporting?
    ) -> EnvironmentReadinessError? {
        guard let manifest = captureEnvironmentManifest(using: resolution, progressController: progressController) else {
            progressController?.append("Unable to capture the Python environment manifest.")
            return .validationFailed(["unable to capture environment-manifest.json"])
        }

        let errors = environmentValidationErrors(for: manifest, lock: Self.environmentLockManifest)
        guard errors.isEmpty else {
            progressController?.append("Python environment does not match \(Self.environmentLockManifest.lockIdentifier):")
            for error in errors {
                progressController?.append("- \(error)")
            }
            return .validationFailed(errors)
        }

        do {
            try writeEnvironmentManifest(manifest)
            progressController?.append("Python environment matches \(Self.environmentLockManifest.lockIdentifier).")
            logToConsole("Python environment matches \(Self.environmentLockManifest.lockIdentifier).")
            return nil
        } catch {
            progressController?.append("Failed to persist environment-manifest.json: \(error.localizedDescription)")
            return .validationFailed(["failed to persist environment-manifest.json: \(error.localizedDescription)"])
        }
    }

    /// Captures the current Python environment's installed packages, versions, and module metadata.
    /// - Parameters:
    ///   - resolution: The Python interpreter to use.
    /// - Returns: A dictionary containing the environment manifest with Python version, installed packages and their details, all installed distributions, weights directory, and platform information, or `nil` if capture fails.
    private func captureEnvironmentManifest(
        using resolution: ExecutableResolution,
        progressController: SegmentationProgressReporting?
    ) -> [String: Any]? {
        guard let lockData = try? JSONEncoder().encode(Self.environmentLockManifest),
              let lockJSON = String(data: lockData, encoding: .utf8) else {
            return nil
        }

        let script = """
import datetime
import hashlib
import importlib
import importlib.metadata
import json
import platform
import sys

lock = json.loads(sys.argv[1])

def file_sha256(path):
    if not path:
        return None
    try:
        with open(path, "rb") as handle:
            digest = hashlib.sha256()
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except Exception:
        return None

packages = {}
for package in lock["packages"]:
    distribution = package["distributionName"]
    module_name = package["importName"]
    record = {
        "requirement": package["requirement"],
        "version": None,
        "modulePath": None,
        "sha256": None,
        "status": "missing"
    }
    try:
        record["version"] = importlib.metadata.version(distribution)
    except importlib.metadata.PackageNotFoundError:
        pass
    try:
        module = importlib.import_module(module_name)
        record["modulePath"] = getattr(module, "__file__", None)
        record["sha256"] = file_sha256(record["modulePath"])
        if record["version"] is not None:
            record["status"] = "ok"
    except Exception as exc:
        record["importError"] = str(exc)
    packages[distribution] = record

installed_distributions = []
for distribution in importlib.metadata.distributions():
    name = distribution.metadata.get("Name")
    version = distribution.version
    if name and version:
        installed_distributions.append({"name": name, "version": version})
installed_distributions.sort(key=lambda item: item["name"].lower())

weights_dir = None
try:
    from totalsegmentator.config import get_weights_dir
    weights_dir = str(get_weights_dir())
except Exception:
    pass

manifest = {
    "schemaVersion": 1,
    "lockIdentifier": lock["lockIdentifier"],
    "setupTimestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "pythonExecutable": sys.executable,
    "pythonVersion": platform.python_version(),
    "platform": platform.platform(),
    "machine": platform.machine(),
    "architecture": platform.machine(),
    "backend": lock["backend"],
    "packages": packages,
    "installedDistributions": installed_distributions,
    "dcm2niix": lock["dcm2niix"],
    "weightsDirectory": weights_dir,
    "sourceTreePolicy": lock["backend"]["sourceTreePolicy"]
}

print("__RESULT__" + json.dumps(manifest, sort_keys=True))
"""

        let result = runPythonProcess(
            using: resolution,
            arguments: ["-c", script, lockJSON],
            progressController: progressController
        )

        guard result.error == nil, result.terminationStatus == 0 else {
            logToConsole("Environment manifest capture failed: status=\(result.terminationStatus)")
            return nil
        }

        return extractResultDictionary(from: result.stdout)
    }

    /// Writes the environment manifest to disk as formatted JSON.
    /// - Throws: If URL resolution fails or if serialization or file writing encounters an error.
    private func writeEnvironmentManifest(_ manifest: [String: Any]) throws {
        guard let url = environmentManifestURL() else {
            throw NSError(
                domain: "org.totalsegmentator.plugin",
                code: 2001,
                userInfo: [NSLocalizedDescriptionKey: "Unable to resolve environment-manifest.json path."]
            )
        }

        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// Validates an environment manifest against pinned lock requirements.
    /// - Parameters:
    ///   - manifest: The captured environment manifest to validate.
    ///   - lock: The pinned lock manifest defining acceptable versions and constraints.
    /// - Returns: Array of validation error messages, empty if the manifest is valid.
    private func environmentValidationErrors(for manifest: [String: Any], lock: EnvironmentLockManifest) -> [String] {
        var errors: [String] = []

        if manifest["lockIdentifier"] as? String != lock.lockIdentifier {
            errors.append("lock identifier mismatch")
        }

        let pythonVersion = manifest["pythonVersion"] as? String ?? ""
        if compareVersions(pythonVersion, lock.python.minimumVersion) == .orderedAscending {
            errors.append("python version \(pythonVersion) is below \(lock.python.minimumVersion)")
        }
        if compareVersions(pythonVersion, lock.python.maximumExclusiveVersion) != .orderedAscending {
            errors.append("python version \(pythonVersion) is not below \(lock.python.maximumExclusiveVersion)")
        }

        let architecture = manifest["architecture"] as? String ?? ""
        if !lock.python.supportedArchitectures.contains(architecture) {
            errors.append("unsupported architecture \(architecture)")
        }

        let resolvedPackages = manifest["packages"] as? [String: Any] ?? [:]
        for package in lock.packages where package.required {
            guard let resolvedPackage = resolvedPackages[package.distributionName] as? [String: Any],
                  let version = resolvedPackage["version"] as? String,
                  (resolvedPackage["status"] as? String) == "ok" else {
                errors.append("missing package \(package.distributionName)")
                continue
            }

            if let exact = package.exactVersion, compareVersions(version, exact) != .orderedSame {
                errors.append("\(package.distributionName) resolved \(version), expected \(exact)")
            }
            if let minimum = package.minimumVersion, compareVersions(version, minimum) == .orderedAscending {
                errors.append("\(package.distributionName) resolved \(version), below \(minimum)")
            }
            if let maximum = package.maximumExclusiveVersion, compareVersions(version, maximum) != .orderedAscending {
                errors.append("\(package.distributionName) resolved \(version), not below \(maximum)")
            }
        }

        return errors
    }

    /// Compares two version strings numerically.
    /// - Returns: `.orderedAscending` if the first version is earlier, `.orderedDescending` if it is later, `.orderedSame` if they are equal.
    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = numericVersionComponents(lhs)
        let right = numericVersionComponents(rhs)
        let count = max(left.count, right.count)

        for index in 0..<count {
            let lvalue = index < left.count ? left[index] : 0
            let rvalue = index < right.count ? right[index] : 0
            if lvalue < rvalue { return .orderedAscending }
            if lvalue > rvalue { return .orderedDescending }
        }

        return .orderedSame
    }

    /// Splits a version string into its numeric parts.
    /// - Returns: An array of integers representing the numeric components of the version string.
    private func numericVersionComponents(_ version: String) -> [Int] {
        version
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { component in
                component.isEmpty ? nil : Int(component)
            }
    }

    /// Ensures TotalSegmentator is configured with model weights.
    /// - Parameters:
    ///   - resolution: The Python interpreter to use.
    ///   - progressController: Optional controller for reporting setup progress.
    /// - Returns: `true` if setup completed successfully, `false` otherwise.
    private func ensureTotalSegmentatorSetup(using resolution: ExecutableResolution, progressController: SegmentationProgressReporting?) -> Bool {
        progressController?.append("Ensuring TotalSegmentator configuration and weights are available…")

        let script = """
import json
import sys
from totalsegmentator.python_api import setup_totalseg, setup_nnunet

setup_totalseg()
setup_nnunet()

mandatory_requirements = {
    "pydicom": "pydicom",
    "dicom2nifti": "dicom2nifti"
}
optional_requirements = {
    "rt_utils": "rt-utils"
}

missing_mandatory = []
for module_name, package_name in mandatory_requirements.items():
    try:
        __import__(module_name)
    except ImportError:
        missing_mandatory.append(package_name)

missing_optional = []
for module_name, package_name in optional_requirements.items():
    try:
        __import__(module_name)
    except ImportError:
        missing_optional.append(package_name)

if missing_mandatory:
    print("__RESULT__" + json.dumps({"status": "missing", "packages": missing_mandatory, "optional_missing": missing_optional}))
    sys.exit(2)

print("__RESULT__" + json.dumps({"status": "ok", "optional_missing": missing_optional}))
"""

        let result = runPythonProcess(
            using: resolution,
            arguments: ["-c", script],
            progressController: progressController
        )

        if let error = result.error {
            logToConsole("Failed to execute TotalSegmentator setup: \(error.localizedDescription)")
            return false
        }

        guard result.terminationStatus == 0 else {
            logToConsole("TotalSegmentator setup script exited with status \(result.terminationStatus)")
            return false
        }

        if let dictionary = extractResultDictionary(from: result.stdout), dictionary["status"] as? String == "ok" {
            if let optionalMissing = dictionary["optional_missing"] as? [String], !optionalMissing.isEmpty {
                let message = "Optional TotalSegmentator package(s) missing: \(optionalMissing.joined(separator: ", ")). RT Struct export may be unavailable."
                logToConsole(message)
                progressController?.append(message)
            }
            progressController?.append("TotalSegmentator setup finished successfully.")
        } else {
            progressController?.append("TotalSegmentator setup finished.")
        }

        return true
    }

    private func ensureDcm2Niix(using resolution: ExecutableResolution, progressController: SegmentationProgressReporting?) -> String? {
        progressController?.append("Checking for dcm2niix availability…")

        let script = """
import json
import platform
import shutil
import sys

from pathlib import Path

from totalsegmentator.config import get_weights_dir


def locate():
    path = shutil.which("dcm2niix")
    if path:
        return path

    weights = Path(get_weights_dir())
    if platform.system().lower().startswith("win"):
        candidate = weights / "dcm2niix.exe"
    else:
        candidate = weights / "dcm2niix"

    if candidate.exists():
        return str(candidate)

    return None


result = locate()
if result is None:
    print("__RESULT__" + json.dumps({"path": None}))
    sys.exit(1)

print("__RESULT__" + json.dumps({"path": result}))
"""

        let result = runPythonProcess(
            using: resolution,
            arguments: ["-c", script],
            progressController: progressController
        )

        if let error = result.error {
            logToConsole("Failed to verify dcm2niix availability: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.presentAlert(
                    title: "TotalSegmentator",
                    message: "Unable to verify or download dcm2niix. Please install it manually and update your PATH."
                )
            }
            return nil
        }

        if result.terminationStatus == 0,
           let dictionary = extractResultDictionary(from: result.stdout),
           let path = dictionary["path"] as? String,
           !path.isEmpty {
            progressController?.append("dcm2niix available at: \(path)")
            return path
        }

        var dcm2niixBootstrapFailure: Dcm2NiixBootstrapError?
        if let fallbackPath = attemptLocalDcm2NiixBootstrap(
            progressController: progressController,
            bootstrapFailure: &dcm2niixBootstrapFailure
        ) {
            return fallbackPath
        }

        DispatchQueue.main.async {
            self.presentAlert(
                title: "TotalSegmentator",
                message: dcm2niixBootstrapFailure.map { failure in
                    "dcm2niix could not be prepared automatically. \(failure.localizedDescription)"
                } ?? "dcm2niix could not be downloaded automatically. Verification failure is one possible cause; please retry later or install dcm2niix manually and ensure it is on the PATH."
            )
        }
        return nil
    }

    private func extractResultDictionary(from data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(whereSeparator: { $0.isNewline }) {
            if line.hasPrefix("__RESULT__") {
                let payloadString = String(line.dropFirst("__RESULT__".count))
                if let payloadData = payloadString.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: payloadData, options: []),
                   let dictionary = object as? [String: Any] {
                    return dictionary
                }
            }
        }
        return nil
    }

    private func pluginSupportDirectory() -> URL? {
        guard let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = supportDir.appendingPathComponent("TotalSegmentatorHorosPlugin", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                logToConsole("Failed to create plugin support directory: \(error.localizedDescription)")
                return nil
            }
        }
        return directory
    }

    private func sha256(ofFileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Ensures a verified copy of the pinned dcm2niix binary is available locally.
    /// - Parameters:
    ///   - bootstrapFailure: On failure, populated with the specific bootstrap error.
    /// - Returns: The file path to the verified dcm2niix binary, or `nil` if it cannot be obtained.
    private func attemptLocalDcm2NiixBootstrap(
        progressController: SegmentationProgressReporting?,
        bootstrapFailure: inout Dcm2NiixBootstrapError?
    ) -> String? {
        guard let supportDirectory = pluginSupportDirectory() else {
            return nil
        }

        let binaryURL = supportDirectory.appendingPathComponent("dcm2niix", isDirectory: false)
        let quarantinedBinaryURL = supportDirectory.appendingPathComponent("dcm2niix.quarantined", isDirectory: false)

        if FileManager.default.isExecutableFile(atPath: binaryURL.path) {
            if sha256(ofFileAt: binaryURL) == Dcm2NiixBootstrap.expectedBinarySHA256 {
                progressController?.append("Using existing pinned dcm2niix \(Dcm2NiixBootstrap.pinnedVersion) at \(binaryURL.path)")
                return binaryURL.path
            }
            bootstrapFailure = .cachedBinaryInvalid(expected: Dcm2NiixBootstrap.expectedBinarySHA256)
            try? FileManager.default.removeItem(at: quarantinedBinaryURL)
            do {
                try FileManager.default.moveItem(at: binaryURL, to: quarantinedBinaryURL)
                progressController?.append("Cached dcm2niix is invalid and has been quarantined. A verified replacement will be downloaded. Expected SHA-256: \(Dcm2NiixBootstrap.expectedBinarySHA256).")
            } catch {
                do {
                    try FileManager.default.removeItem(at: binaryURL)
                    progressController?.append("Cached dcm2niix is invalid and has been removed. A verified replacement will be downloaded. Expected SHA-256: \(Dcm2NiixBootstrap.expectedBinarySHA256).")
                } catch {
                    bootstrapFailure = .cachedBinaryRemovalFailed(expected: Dcm2NiixBootstrap.expectedBinarySHA256)
                    progressController?.append("Cached dcm2niix is invalid and cannot be quarantined or removed. It cannot be used; bootstrapping aborted.")
                    return nil
                }
            }
        }

        progressController?.append("Attempting local bootstrap of pinned dcm2niix \(Dcm2NiixBootstrap.pinnedVersion)…")

        let archiveURL = supportDirectory.appendingPathComponent(Dcm2NiixBootstrap.archiveName, isDirectory: false)
        try? FileManager.default.removeItem(at: archiveURL)

        guard let downloadURL = URL(string: Dcm2NiixBootstrap.pinnedDcm2NiixDownloadURL) else {
            progressController?.append("Unable to resolve dcm2niix download URL.")
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        var downloadError: Error?

        let task = URLSession.shared.downloadTask(with: downloadURL) { location, _, error in
            defer { semaphore.signal() }
            if let error = error {
                downloadError = error
                return
            }

            guard let location = location else {
                downloadError = NSError(domain: "TotalSegmentatorHorosPlugin", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download location missing"])
                return
            }

            do {
                try FileManager.default.moveItem(at: location, to: archiveURL)
            } catch {
                downloadError = error
            }
        }

        task.resume()

        if semaphore.wait(timeout: .now() + 120) == .timedOut {
            task.cancel()
            progressController?.append("Timeout while downloading dcm2niix archive.")
            return nil
        }

        if let error = downloadError {
            progressController?.append("Failed to download dcm2niix: \(error.localizedDescription)")
            return nil
        }

        guard let actualArchiveSHA256 = sha256(ofFileAt: archiveURL) else {
            bootstrapFailure = .checksumUnavailable
            try? FileManager.default.removeItem(at: archiveURL)
            progressController?.append(Dcm2NiixBootstrapError.checksumUnavailable.localizedDescription)
            return nil
        }

        guard actualArchiveSHA256.caseInsensitiveCompare(Dcm2NiixBootstrap.expectedDcm2NiixSHA256) == .orderedSame else {
            try? FileManager.default.removeItem(at: archiveURL)
            let error = Dcm2NiixBootstrapError.checksumMismatch(
                expected: Dcm2NiixBootstrap.expectedDcm2NiixSHA256,
                actual: actualArchiveSHA256
            )
            bootstrapFailure = error
            progressController?.append(error.localizedDescription)
            return nil
        }

        progressController?.append("Verified dcm2niix archive checksum for \(Dcm2NiixBootstrap.pinnedVersion).")
        try? FileManager.default.removeItem(at: binaryURL)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", archiveURL.path, "-d", supportDirectory.path]

        do {
            try unzip.run()
            unzip.waitUntilExit()
        } catch {
            progressController?.append("Unable to extract dcm2niix: \(error.localizedDescription)")
            return nil
        }

        guard unzip.terminationStatus == 0 else {
            progressController?.append("Extraction of dcm2niix failed with status \(unzip.terminationStatus).")
            return nil
        }

        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: binaryURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            bootstrapFailure = .extractedBinaryMissing
            progressController?.append(Dcm2NiixBootstrapError.extractedBinaryMissing.localizedDescription)
            progressController?.append("Expected path: \(binaryURL.path)")
            try? FileManager.default.removeItem(at: archiveURL)
            return nil
        }

        guard sha256(ofFileAt: binaryURL)?.caseInsensitiveCompare(Dcm2NiixBootstrap.expectedBinarySHA256) == .orderedSame else {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: binaryURL)
            bootstrapFailure = .extractedBinaryChecksumMismatch
            progressController?.append(Dcm2NiixBootstrapError.extractedBinaryChecksumMismatch.localizedDescription)
            return nil
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: binaryURL.path)
            if let permissions = attributes[.posixPermissions] as? NSNumber {
                let current = permissions.uint16Value
                if current & 0o111 == 0 {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
                }
            } else {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
            }
        } catch {
            progressController?.append("Failed to update dcm2niix permissions: \(error.localizedDescription)")
            return nil
        }

        try? FileManager.default.removeItem(at: archiveURL)

        progressController?.append("Verified dcm2niix downloaded to \(binaryURL.path)")
        return binaryURL.path
    }

    /// Generates a shell-safe command line for installing the pinned Python packages.
    /// - Parameter resolution: The resolved Python interpreter and environment configuration.
    /// - Returns: A space-separated command string with components quoted to protect spaces.
    private func lockedEnvironmentInstallInstruction(using resolution: ExecutableResolution) -> String {
        let components = [resolution.executableURL.path] + resolution.leadingArguments + ["-m", "pip", "install", "--upgrade"] + Self.environmentLockManifest.installRequirements
        return components.map { component -> String in
            if component.contains(" ") {
                return "\"\(component)\""
            }
            return component
        }.joined(separator: " ")
    }

    /// Builds a pip install command string for the optional rt-utils package.
    /// - Returns: A formatted shell command string suitable for display or execution.
    private func optionalRtUtilsInstallInstruction(using resolution: ExecutableResolution) -> String {
        let requirement = Self.environmentLockManifest.packages
            .first { $0.importName == "rt_utils" }?
            .requirement ?? "rt-utils"
        let components = [resolution.executableURL.path] + resolution.leadingArguments + ["-m", "pip", "install", "--upgrade", requirement]
        return components.map { component -> String in
            if component.contains(" ") {
                return "\"\(component)\""
            }
            return component
        }.joined(separator: " ")
    }

    /// Displays an alert explaining the environment setup failure and providing recovery instructions.
    func presentEnvironmentSetupFailureInstructions(for result: EnvironmentReadinessResult? = nil) {
        let requirements = Self.environmentLockManifest.installRequirements.joined(separator: " ")
        let failure = result?.failureMessage ?? "The active environment is not ready."
        let message = """
Unable to prepare a Python environment with TotalSegmentator installed.

The active environment must match \(Self.environmentLockManifest.lockIdentifier) from TotalSegmentatorEnvironmentLock.json.

Failure:
  \(failure)

Safe managed-environment repair removes only the virtualenv and stale install marker, not preferences or run artifacts:
  ~/Library/Application Support/TotalSegmentatorHorosPlugin/PythonEnvironment
  ~/Library/Application Support/TotalSegmentatorHorosPlugin/environment-install-marker.json

If environment-setup.lock is reported as held, close the other Horos/OsiriX process and retry.

Then run the plugin again, or install the locked requirements manually with Python \(Self.environmentLockManifest.python.minimumVersion)..<\(Self.environmentLockManifest.python.maximumExclusiveVersion):
  python3.12 -m venv ~/totalseg-env
  ~/totalseg-env/bin/python3 -m pip install --upgrade \(requirements)

For offline installs, mirror those locked artifacts, pre-populate model weights, install the pinned dcm2niix binary, then update the plugin settings to point to the Python interpreter in that environment.
"""

        DispatchQueue.main.async {
            self.presentAlert(title: "TotalSegmentator", message: message)
        }
    }

    /// Verifies that the optional `rt_utils` module is available in the Python environment.
    /// - Returns: `true` if the `rt_utils` module is available, `false` otherwise.
    func ensureRtUtilsAvailable(using resolution: ExecutableResolution) -> Bool {
        if pythonModuleAvailable("rt_utils", using: resolution) {
            return true
        }

        logToConsole("The configured Python environment is missing the optional 'rt_utils' package.")
        let command = optionalRtUtilsInstallInstruction(using: resolution)
        let message = """
The optional 'rt_utils' package is required only when DICOM RT-Struct export is enabled.
Direct volumetric ROI import does not require it.

Repair the active environment with the locked requirements by running:
  \(command)

After installing the package, re-run the segmentation.
"""

        DispatchQueue.main.async {
            self.presentAlert(title: "TotalSegmentator", message: message)
        }

        return false
    }

    func resolvePythonInterpreter(using preferencesState: SegmentationPreferences.State) -> ExecutableResolution? {
        if let explicitPath = preferencesState.executablePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitPath.isEmpty,
           let resolution = interpreterResolution(for: explicitPath) {
            return resolution
        }

        if let defaultExecutable = try? self.preferences.defaultExecutableURL(),
           let resolution = interpreterResolution(for: defaultExecutable.path) {
            return resolution
        }

        return (
            URL(fileURLWithPath: "/usr/bin/env"),
            ["python3"],
            nil
        )
    }

    private func interpreterResolution(for path: String) -> ExecutableResolution? {
        if path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path)
            let fileManager = FileManager.default

            if isPythonExecutable(url), fileManager.isExecutableFile(atPath: url.path) {
                return (url, [], nil)
            }

            if let shebang = shebangResolution(for: url) {
                return shebang
            }

            if url.pathExtension.lowercased() == "py", fileManager.isReadableFile(atPath: url.path) {
                return (
                    URL(fileURLWithPath: "/usr/bin/env"),
                    ["python3", url.path],
                    nil
                )
            }

            return nil
        } else {
            if path.lowercased().contains("python") {
                return (
                    URL(fileURLWithPath: "/usr/bin/env"),
                    [path],
                    nil
                )
            }

            if let located = locateExecutableInPATH(named: path) {
                if isPythonExecutable(located) {
                    return (located, [], nil)
                }

                if let shebang = shebangResolution(for: located) {
                    return shebang
                }
            }

            return nil
        }
    }

    private func locateExecutableInPATH(named command: String) -> URL? {
        let fileManager = FileManager.default
        let pathVariable = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for entry in pathVariable.split(separator: ":") {
            let directory = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !directory.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func isPythonExecutable(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name == "python" || name == "python3" || name.hasPrefix("python3") || name.hasPrefix("python")
    }

    private func shebangResolution(for url: URL) -> ExecutableResolution? {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 256)
        guard let contents = String(data: data, encoding: .utf8) else { return nil }
        guard let firstLine = contents.components(separatedBy: .newlines).first, firstLine.hasPrefix("#!") else {
            return nil
        }

        let shebangBody = firstLine.dropFirst(2)
        let components = shebangBody.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }

        let executablePath = components[0]
        let arguments = Array(components.dropFirst())

        let executableURL = URL(fileURLWithPath: executablePath)
        return (executableURL, arguments, nil)
    }
}
