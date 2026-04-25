//
// TotalSegmentatorHorosPlugin+Environment.swift
// TotalSegmentator
//

import Cocoa
import CryptoKit

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

extension TotalSegmentatorHorosPlugin {
    func performInitialSetupIfNeeded(displayProgress: Bool = false) {
        autoreleasepool {
            var preferencesState = preferences.effectivePreferences()
            var updatedPreferences = preferencesState

            let progressController: SegmentationProgressWindowController? = displayProgress ? presentSetupProgressWindowIfNeeded(initialMessage: "Preparing TotalSegmentator environment…") : nil

            guard var executableResolution = resolvePythonInterpreter(using: preferencesState) else {
                if displayProgress {
                    finishSetupProgress(with: nil)
                }
                presentEnvironmentSetupFailureInstructions()
                return
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
                    if displayProgress {
                        finishSetupProgress(with: nil)
                    }
                    presentEnvironmentSetupFailureInstructions()
                    return
                }
            }

            guard pythonModuleAvailable("totalsegmentator", using: executableResolution) else {
                if displayProgress {
                    finishSetupProgress(with: nil)
                }
                presentEnvironmentSetupFailureInstructions()
                return
            }

            let setupSucceeded = ensureTotalSegmentatorSetup(using: executableResolution, progressController: progressController)
            if !setupSucceeded {
                if displayProgress {
                    finishSetupProgress(with: "TotalSegmentator setup encountered issues. Please review the log output.")
                }
                return
            }

            guard let dcm2niixPath = ensureDcm2Niix(using: executableResolution, progressController: progressController) else {
                if displayProgress {
                    finishSetupProgress(with: "Unable to prepare dcm2niix. Please review the displayed instructions.")
                }
                return
            }

            if updatedPreferences.dcm2niixPath != dcm2niixPath {
                updatedPreferences.dcm2niixPath = dcm2niixPath
                preferences.store(updatedPreferences)
            }

            if displayProgress {
                finishSetupProgress(with: "Initial setup complete.")
            }
        }
    }

    private func presentSetupProgressWindowIfNeeded(initialMessage: String? = nil) -> SegmentationProgressWindowController {
        if Thread.isMainThread {
            return presentSetupProgressWindowOnMain(initialMessage: initialMessage)
        }

        var controller: SegmentationProgressWindowController!
        DispatchQueue.main.sync {
            controller = self.presentSetupProgressWindowOnMain(initialMessage: initialMessage)
        }
        return controller
    }

    private func finishSetupProgress(with message: String?) {
        guard let controller = setupProgressWindowController else { return }

        DispatchQueue.main.async {
            if let message = message, !message.isEmpty {
                controller.append(message)
            }
            controller.markProcessFinished()
            controller.close(after: 0.1)
            self.logToConsole("Progress window closed")
        }

        setupProgressWindowController = nil
    }

    private func presentSetupProgressWindowOnMain(initialMessage: String?) -> SegmentationProgressWindowController {
        precondition(Thread.isMainThread, "UI work must happen on main thread")

        if let controller = setupProgressWindowController {
            if let message = initialMessage {
                controller.append(message)
            }
            return controller
        }

        let controller = SegmentationProgressWindowController()
        setupProgressWindowController = controller

        controller.showWindow(nil)
        controller.start()
        if let message = initialMessage {
            controller.append(message)
        } else {
            controller.append("Preparing TotalSegmentator environment…")
        }

        return controller
    }

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
        progressController: SegmentationProgressWindowController?
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
                DispatchQueue.main.async {
                    progressController?.append(message)
                    self?.logToConsole(message)
                }
            }
        }

        stderrHandle.readabilityHandler = { [weak self, weak progressController] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            capturedStderr.append(data)

            if let message = String(data: data, encoding: .utf8), !message.isEmpty {
                DispatchQueue.main.async {
                    progressController?.append(message)
                    self?.logToConsole(message)
                }
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

        process.waitUntilExit()
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

    private func bootstrapManagedPythonEnvironment(
        baseResolution: ExecutableResolution,
        progressController: SegmentationProgressWindowController?
    ) -> (resolution: ExecutableResolution, pythonPath: String)? {
        guard let environmentDirectory = managedEnvironmentDirectory() else {
            logToConsole("Failed to resolve a location for the managed Python environment.")
            return nil
        }

        let binDirectory = environmentDirectory.appendingPathComponent("bin", isDirectory: true)
        let python3URL = binDirectory.appendingPathComponent("python3", isDirectory: false)
        let pythonURL = binDirectory.appendingPathComponent("python", isDirectory: false)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: python3URL.path) && !fileManager.fileExists(atPath: pythonURL.path) {
            progressController?.append("Creating managed Python environment…")
            let result = runPythonProcess(
                using: baseResolution,
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

            _ = runPythonProcess(
                using: managedResolution,
                arguments: ["-m", "pip", "install", "--upgrade", "pip"],
                progressController: progressController
            )

            let installResult = runPythonProcess(
                using: managedResolution,
                arguments: ["-m", "pip", "install", "--upgrade", "TotalSegmentator"],
                progressController: progressController
            )

            if installResult.terminationStatus != 0 || installResult.error != nil {
                logToConsole("Failed to install TotalSegmentator into managed environment: status=\(installResult.terminationStatus)")
                return nil
            }
        }

        guard pythonModuleAvailable("totalsegmentator", using: managedResolution) else {
            logToConsole("Managed environment was created but TotalSegmentator is still unavailable.")
            return nil
        }

        return (managedResolution, pythonBinary.path)
    }

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

    private func ensureTotalSegmentatorSetup(using resolution: ExecutableResolution, progressController: SegmentationProgressWindowController?) -> Bool {
        progressController?.append("Ensuring TotalSegmentator configuration and weights are available…")

        let script = """
import json
import subprocess
import sys
from totalsegmentator.python_api import setup_totalseg, setup_nnunet

setup_totalseg()
setup_nnunet()

requirements = {
    "pydicom": "pydicom",
    "dicom2nifti": "dicom2nifti"
}

for module_name, package_name in requirements.items():
    try:
        __import__(module_name)
    except ImportError:
        subprocess.check_call([sys.executable, "-m", "pip", "install", package_name])

print("__RESULT__" + json.dumps({"status": "ok"}))
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
            progressController?.append("TotalSegmentator setup finished successfully.")
        } else {
            progressController?.append("TotalSegmentator setup finished.")
        }

        return true
    }

    private func ensureDcm2Niix(using resolution: ExecutableResolution, progressController: SegmentationProgressWindowController?) -> String? {
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

    private func attemptLocalDcm2NiixBootstrap(
        progressController: SegmentationProgressWindowController?,
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

    private func pipInstallInstruction(for module: String, using resolution: ExecutableResolution) -> String {
        let components = [resolution.executableURL.path] + resolution.leadingArguments + ["-m", "pip", "install", module]
        return components.map { component -> String in
            if component.contains(" ") {
                return "\"\(component)\""
            }
            return component
        }.joined(separator: " ")
    }

    private func presentEnvironmentSetupFailureInstructions() {
        let message = """
Unable to prepare a Python environment with TotalSegmentator installed.

Please install TotalSegmentator manually, for example:
  python3 -m venv ~/totalseg-env
  ~/totalseg-env/bin/python3 -m pip install --upgrade pip TotalSegmentator

Then update the plugin settings to point to the Python interpreter in that environment.
"""

        DispatchQueue.main.async {
            self.presentAlert(title: "TotalSegmentator", message: message)
        }
    }

    func ensureRtUtilsAvailable(using resolution: ExecutableResolution) -> Bool {
        if pythonModuleAvailable("rt_utils", using: resolution) {
            return true
        }

        logToConsole("The configured Python environment is missing the optional 'rt_utils' package.")
        let command = pipInstallInstruction(for: "rt_utils", using: resolution)
        let message = """
The optional 'rt_utils' package is required to export DICOM RT-Struct files.

Install it by running:
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

            if isPythonExecutable(url) {
                return (url, [], nil)
            }

            if let shebang = shebangResolution(for: url) {
                return shebang
            }

            if url.pathExtension.lowercased() == "py" {
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
