//
// TotalSegmentatorHorosPlugin+Segmentation.swift
// TotalSegmentator
//

import Cocoa

extension TotalSegmentatorHorosPlugin {
    /// Starts the segmentation workflow by exporting the active viewer's series and presenting the run-configuration sheet.
    /// - Discussion: Presents alerts and aborts when no active 2D viewer, viewer window, or export result is available. When the user confirms the run configuration, the chosen preferences and selected classes are stored and segmentation is initiated in the background; if the configuration is cancelled, the temporary export directory is cleaned up.
    func startSegmentationFlow() {
        // Collect the active series, export it to a temporary folder, and open the configuration UI.
        logToConsole("startSegmentationFlow called")
        let primaryViewer = (self.value(forKey: "viewerController") as? ViewerController) ?? ViewerController.frontMostDisplayed2DViewer()
        logToConsole("viewerController via KVC: \((self.value(forKey: "viewerController") as? ViewerController) != nil)")
        guard let viewer = primaryViewer else {
            presentAlert(title: "TotalSegmentator", message: "No active viewer is available.")
            logToConsole("startSegmentationFlow aborted: no 2D viewer available.")
            return
        }

        guard let presentingWindow = viewer.window else {
            presentAlert(title: "TotalSegmentator", message: "Unable to locate the active viewer window.")
            logToConsole("startSegmentationFlow aborted: viewer window not found.")
            return
        }

        let exportResult: ExportResult
        do {
            exportResult = try exportActiveSeries(from: viewer)
        } catch {
            presentAlert(title: "TotalSegmentator", message: error.localizedDescription)
            logToConsole("startSegmentationFlow aborted during export: \(error.localizedDescription)")
            return
        }

        var effectivePreferences = preferences.effectivePreferences()
        let runtimeSelection = Array(selectedClassNames).sorted()
        if !runtimeSelection.isEmpty, runtimeSelection != effectivePreferences.selectedClassNames {
            effectivePreferences.selectedClassNames = runtimeSelection
        }

        let classSummary = classSelectionSummaryComponents(for: effectivePreferences.selectedClassNames)
        let controller = RunSegmentationWindowController()
        controller.configuration = RunSegmentationWindowController.Configuration(
            preferences: effectivePreferences,
            taskOptions: taskOptions,
            deviceOptions: deviceOptions,
            classSummaryText: classSummary.text,
            classSummaryTooltip: classSummary.tooltip,
            outputDirectory: (nil as URL?)
        )

        controller.onCompletion = { [weak self] result in
            guard let self = self else { return }

            if let result = result {
                self.preferences.store(result.preferences)
                self.selectedClassNames = Set(result.preferences.selectedClassNames)
                self.runConfigurationController = nil

                DispatchQueue.global(qos: .userInitiated).async {
                    self.runSegmentation(
                        exportResult: exportResult,
                        outputDirectory: result.outputDirectory,
                        preferences: result.preferences
                    )
                }
            } else {
                self.cleanupTemporaryDirectory(exportResult.directory)
                self.runConfigurationController = nil
            }
        }

        runConfigurationController = controller

        DispatchQueue.main.async {
            guard let sheetWindow = controller.window else {
                self.presentAlert(title: "TotalSegmentator", message: "Unable to load the run configuration interface.")
                self.cleanupTemporaryDirectory(exportResult.directory)
                self.runConfigurationController = nil
                return
            }

            presentingWindow.beginSheet(sheetWindow, completionHandler: nil)
        }
    }

    /// Executes the segmentation pipeline for the given exported series and integrates or imports the results into the application.
    /// Cleans up the temporary export directory on completion and updates the user via progress UI and alerts on the main queue.
    /// - Parameters:
    ///   - exportResult: The export context containing the temporary directory and exported series metadata to be segmented.
    ///   - outputDirectory: Optional user-provided output directory to write TotalSegmentator outputs; if `nil`, an output directory is resolved automatically.
    ///   - preferences: A snapshot of segmentation preferences used to configure TotalSegmentator (task, device, additional arguments, class selection, etc.).
    func runSegmentation(
        exportResult: ExportResult,
        outputDirectory providedOutputDirectory: URL?,
        preferences preferencesState: SegmentationPreferences.State
    ) {
        // Run the full pipeline: validate the Python environment, assemble arguments, and reimport the results.
        defer { cleanupTemporaryDirectory(exportResult.directory) }

        performInitialSetupIfNeeded(displayProgress: true)

        guard let executableResolution = resolvePythonInterpreter(using: preferencesState) else {
            DispatchQueue.main.async {
                self.presentAlert(
                    title: "TotalSegmentator",
                    message: "Unable to locate a Python interpreter with TotalSegmentator installed. Please verify the path in the plugin settings."
                )
            }
            return
        }

        let additionalTokens: [String]
        if let additional = preferencesState.additionalArguments,
           !additional.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            additionalTokens = tokenize(commandLine: additional)
        } else {
            additionalTokens = []
        }

        let outputDetection = detectOutputType(from: additionalTokens)
        let sanitizedAdditionalTokens = removeROISubsetTokens(from: outputDetection.remainingTokens)
        let effectiveOutputType: SegmentationOutputType = .dicom
        if outputDetection.type != .dicom {
            logToConsole("Overriding requested output type '\(outputDetection.type.description)' with 'dicom' to ensure RT Struct overlays are generated.")
        }

        if effectiveOutputType == .dicom {
            guard ensureRtUtilsAvailable(using: executableResolution) else {
                return
            }
        }

        var totalSegmentatorArguments: [String] = []
        if let task = preferencesState.task, !task.isEmpty {
            totalSegmentatorArguments.append(contentsOf: ["--task", task])
        }

        if preferencesState.useFast {
            totalSegmentatorArguments.append("--fast")
        }

        if let device = preferencesState.device, !device.isEmpty {
            totalSegmentatorArguments.append(contentsOf: ["--device", device])
        }

        if let licenseKey = preferencesState.licenseKey, !licenseKey.isEmpty {
            totalSegmentatorArguments.append(contentsOf: ["--license_number", licenseKey])
        }

        if !sanitizedAdditionalTokens.isEmpty {
            totalSegmentatorArguments.append(contentsOf: sanitizedAdditionalTokens)
        }

        let configuredClassSelection = preferencesState.selectedClassNames
        if !configuredClassSelection.isEmpty {
            if supportsClassSelection(for: preferencesState.task) {
                totalSegmentatorArguments.append("--roi_subset")
                totalSegmentatorArguments.append(contentsOf: configuredClassSelection)
            } else {
                logToConsole("Ignoring configured class selection because the current task does not support ROI subsets.")
            }
        }

        guard let primarySeries = exportResult.series.first else {
            DispatchQueue.main.async {
                self.presentAlert(
                    title: "TotalSegmentator",
                    message: "No exported DICOM series was found for segmentation."
                )
            }
            return
        }

        let outputDirectory: URL
        do {
            outputDirectory = try resolveOutputDirectory(using: providedOutputDirectory, exportContext: exportResult)
        } catch {
            DispatchQueue.main.async {
                self.presentAlert(title: "TotalSegmentator", message: error.localizedDescription)
            }
            return
        }

        logToConsole("Using TotalSegmentator output directory at \(outputDirectory.path)")

        let bridgeScriptURL: URL
        let configurationURL: URL

        do {
            bridgeScriptURL = try prepareBridgeScript(at: exportResult.directory)
            configurationURL = try writeBridgeConfiguration(
                to: exportResult.directory,
                dicomDirectory: primarySeries.exportedDirectory,
                outputDirectory: outputDirectory,
                outputType: effectiveOutputType.description,
                totalsegmentatorArguments: totalSegmentatorArguments
            )
        } catch {
            DispatchQueue.main.async {
                self.presentAlert(title: "TotalSegmentator", message: error.localizedDescription)
            }
            return
        }

        let process = Process()
        process.executableURL = executableResolution.executableURL
        process.arguments = executableResolution.leadingArguments + [bridgeScriptURL.path, "--config", configurationURL.path]

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        if let customEnvironment = executableResolution.environment {
            environment.merge(customEnvironment) { _, new in new }
        }
        if let dcm2niixPath = preferencesState.dcm2niixPath, !dcm2niixPath.isEmpty {
            let binaryURL = URL(fileURLWithPath: dcm2niixPath)
            let directoryPath = binaryURL.deletingLastPathComponent().path
            var pathVariable = environment["PATH"] ?? ""
            let existingComponents = pathVariable.split(separator: ":").map(String.init)
            if !existingComponents.contains(directoryPath) {
                pathVariable = directoryPath + (pathVariable.isEmpty ? "" : ":" + pathVariable)
            }
            environment["PATH"] = pathVariable
            environment["TOTALSEGMENTATOR_DCM2NIIX"] = dcm2niixPath
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdoutBuffer = Data()
        var stderrBuffer = Data()

        let progressController = makeProgressWindow(for: process)
        let seriesCount = exportResult.series.count
        let taskDescriptor = preferencesState.task?.isEmpty == false ? preferencesState.task! : "total"
        progressController.append("Running TotalSegmentator (\(taskDescriptor) task) on \(seriesCount) exported series…")
        progressController.append("Output directory: \(outputDirectory.path)")
        if let device = preferencesState.device, !device.isEmpty {
            progressController.append("Execution device: \(device).")
        }
        if !configuredClassSelection.isEmpty {
            let summary = configuredClassSelection.sorted().joined(separator: ", ")
            progressController.append("ROI subset: \(summary).")
        }
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { [weak self, weak progressController] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutBuffer.append(data)
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
            stderrBuffer.append(data)
            if let message = String(data: data, encoding: .utf8), !message.isEmpty {
                DispatchQueue.main.async {
                    progressController?.append(message)
                    self?.logToConsole(message)
                }
            }
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            DispatchQueue.main.async {
                progressController.markProcessFinished()
                progressController.close()
                self.presentAlert(
                    title: "TotalSegmentator",
                    message: "Failed to start segmentation: \(error.localizedDescription)"
                )
                self.progressWindowController = nil
            }
            return
        }

        process.waitUntilExit()
        progressController.append("TotalSegmentator finished with status \(process.terminationStatus). Validating outputs…")

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        stdoutBuffer.append(stdoutHandle.readDataToEndOfFile())
        stderrBuffer.append(stderrHandle.readDataToEndOfFile())

        let combinedErrorOutput = String(data: stderrBuffer, encoding: .utf8) ?? ""
        let combinedStandardOutput = String(data: stdoutBuffer, encoding: .utf8) ?? ""
        let combinedOutput = combinedStandardOutput + combinedErrorOutput

        let postProcessingResult: Result<SegmentationImportResult, Error>

        if process.terminationStatus == 0 {
            do {
                try self.validateSegmentationOutput(at: outputDirectory)
                let importResult = try self.integrateSegmentationOutput(
                    at: outputDirectory,
                    outputType: effectiveOutputType,
                    exportContext: exportResult,
                    preferences: preferencesState,
                    executable: executableResolution,
                    progressController: progressController
                )
                postProcessingResult = .success(importResult)
            } catch {
                postProcessingResult = .failure(error)
            }
        } else {
            postProcessingResult = .failure(
                NSError(
                    domain: "org.totalsegmentator.plugin",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: self.translateErrorOutput(combinedOutput, status: process.terminationStatus)]
                )
            )
        }

        DispatchQueue.main.async {
            progressController.markProcessFinished()

            switch postProcessingResult {
            case .success(let importResult):
                progressController.append("Segmentation finished successfully.")
                progressController.append("Imported \(importResult.addedFilePaths.count) file(s) into Horos.")
                if !importResult.rtStructPaths.isEmpty {
                    progressController.append("Detected \(importResult.rtStructPaths.count) RT Struct file(s).")
                }
                progressController.close(after: 0.5)
                let successMessage: String
                if importResult.rtStructPaths.isEmpty {
                    successMessage = "Segmentation finished successfully."
                } else {
                    successMessage = "Segmentation finished successfully. Generated ROIs are now available."
                }
                self.presentAlert(title: "TotalSegmentator", message: successMessage)
            case .failure(let error):
                let message = error.localizedDescription
                progressController.append(message)
                progressController.close(after: 0.5)
                self.presentAlert(title: "TotalSegmentator", message: message)
            }

            self.progressWindowController = nil
        }
    }

    private func resolveOutputDirectory(using providedDirectory: URL?, exportContext: ExportResult) throws -> URL {
        let fileManager = FileManager.default

        if let provided = providedDirectory {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: provided.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue {
                    throw NSError(
                        domain: "org.totalsegmentator.plugin",
                        code: 1002,
                        userInfo: [NSLocalizedDescriptionKey: "The selected output path is not a directory."]
                    )
                }
            } else {
                try fileManager.createDirectory(at: provided, withIntermediateDirectories: true)
            }
            return provided
        }

        let baseName = "segmentation_output"
        let defaultDirectory = exportContext.directory.appendingPathComponent(baseName, isDirectory: true)

        if !fileManager.fileExists(atPath: defaultDirectory.path) {
            try fileManager.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
            return defaultDirectory
        }

        let uniqueDirectory = exportContext.directory.appendingPathComponent("\(baseName)_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: uniqueDirectory, withIntermediateDirectories: true)
        return uniqueDirectory
    }

    private func makeProgressWindow(for process: Process) -> SegmentationProgressWindowController {
        let controller: SegmentationProgressWindowController = {
            if Thread.isMainThread {
                return SegmentationProgressWindowController()
            } else {
                return DispatchQueue.main.sync { SegmentationProgressWindowController() }
            }
        }()

        DispatchQueue.main.async {
            controller.showWindow(nil)
            controller.start()
        }

        controller.setCancelHandler { [weak process] in
            process?.terminate()
        }

        progressWindowController = controller
        return controller
    }

    private func tokenize(commandLine: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var isInQuotes = false
        var escapeNext = false
        var quoteCharacter: Character = "\""

        for character in commandLine {
            if escapeNext {
                current.append(character)
                escapeNext = false
                continue
            }

            if character == "\\" {
                escapeNext = true
                continue
            }

            if character == "\"" || character == "'" {
                if isInQuotes {
                    if character == quoteCharacter {
                        isInQuotes = false
                    } else {
                        current.append(character)
                    }
                } else {
                    isInQuotes = true
                    quoteCharacter = character
                }
                continue
            }

            if character.isWhitespace && !isInQuotes {
                if !current.isEmpty {
                    arguments.append(current)
                    current = ""
                }
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            arguments.append(current)
        }

        return arguments
    }

    private func detectOutputType(from tokens: [String]) -> (type: SegmentationOutputType, remainingTokens: [String]) {
        var detectedType: SegmentationOutputType = .dicom
        var remainingTokens: [String] = []

        var index = 0
        while index < tokens.count {
            let token = tokens[index]

            if token == "--output_type" {
                let nextIndex = index + 1
                if nextIndex < tokens.count {
                    let valueCandidate = tokens[nextIndex]
                    if valueCandidate.hasPrefix("--") {
                        detectedType = .dicom
                        index += 1
                        continue
                    }

                    detectedType = SegmentationOutputType(argumentValue: valueCandidate)
                    index += 2
                    continue
                }

                detectedType = .dicom
                index += 1
                continue
            }

            if token.hasPrefix("--output_type=") {
                let value = String(token.dropFirst("--output_type=".count))
                detectedType = SegmentationOutputType(argumentValue: value)
                index += 1
                continue
            }

            remainingTokens.append(token)
            index += 1
        }

        return (detectedType, remainingTokens)
    }

    private func removeROISubsetTokens(from tokens: [String]) -> [String] {
        var filtered: [String] = []
        var index = 0

        while index < tokens.count {
            let token = tokens[index]

            if token == "--roi_subset" {
                index += 1
                while index < tokens.count, !tokens[index].hasPrefix("--") {
                    index += 1
                }
                continue
            }

            if token.hasPrefix("--roi_subset=") {
                index += 1
                continue
            }

            filtered.append(token)
            index += 1
        }

        return filtered
    }
}