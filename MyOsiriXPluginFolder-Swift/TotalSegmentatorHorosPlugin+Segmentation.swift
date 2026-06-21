//
// TotalSegmentatorHorosPlugin+Segmentation.swift
// TotalSegmentator
//

import Cocoa

extension TotalSegmentatorHorosPlugin {
    /// Starts the segmentation workflow by exporting the active viewer's series and presenting the run-configuration sheet.
    /// Initiates the segmentation workflow by validating prerequisites and presenting the run configuration interface.
    ///
    /// Ensures that an active viewer and valid environment are available, exports the active series, reconciles saved preferences with runtime capabilities, and opens the configuration sheet for customizing segmentation parameters before execution. Shows alerts and logs failures if the viewer, environment, or export is unavailable.
    func startSegmentationFlow() {
        // Collect the active series, export it to a temporary folder, and open the configuration UI.
        logToConsole("startSegmentationFlow called")
        guard Self.capabilityManifestIsAvailable else {
            presentCapabilityManifestLoadFailure()
            return
        }

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

        let environmentResult = prepareEnvironmentIfNeeded(progressController: nil)
        guard environmentResult.isReady else {
            logToConsole("startSegmentationFlow aborted: \(environmentResult.failureMessage)")
            presentEnvironmentSetupFailureInstructions(for: environmentResult)
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
        if let savedTask = effectivePreferences.task?.trimmingCharacters(in: .whitespacesAndNewlines),
           !savedTask.isEmpty,
           Self.taskCapabilityManifest.capability(for: savedTask) == nil {
            logToConsole("Ignoring unsupported saved TotalSegmentator task '\(savedTask)' and falling back to Automatic.")
            effectivePreferences.task = nil
            effectivePreferences.useFast = false
            effectivePreferences.selectedClassNames = []
            preferences.store(effectivePreferences)
        }

        let runtimeSelection = Array(selectedClassNames).sorted()
        if !runtimeSelection.isEmpty, runtimeSelection != effectivePreferences.selectedClassNames {
            effectivePreferences.selectedClassNames = runtimeSelection
        }

        let runtimeProbe: RuntimeCapabilityProbe
        if let runtimeExecutable = resolvePythonInterpreter(using: effectivePreferences) {
            runtimeProbe = probeRuntimeCapabilities(using: runtimeExecutable)
            for failure in runtimeProbe.failures {
                logToConsole("Runtime capability probe warning: \(failure)")
            }
        } else {
            runtimeProbe = Self.fallbackRuntimeCapabilityProbe(
                failures: ["Unable to resolve Python interpreter for runtime capability probe before showing run options."]
            )
        }

        let runtimeDeviceOptions = Self.runtimeDeviceOptions(from: runtimeProbe)
        if !Self.deviceValueIsSelectable(effectivePreferences.device, in: runtimeDeviceOptions) {
            logToConsole("Saved TotalSegmentator device '\(effectivePreferences.device ?? "nil")' is not validated by the runtime probe; falling back to Auto.")
            effectivePreferences.device = nil
            preferences.store(effectivePreferences)
        }

        let classSummary = classSelectionSummaryComponents(for: effectivePreferences.selectedClassNames)
        let controller = RunSegmentationWindowController()
        controller.configuration = RunSegmentationWindowController.Configuration(
            preferences: effectivePreferences,
            taskGroups: taskGroups,
            deviceOptions: runtimeDeviceOptions,
            classSummaryText: classSummary.text,
            classSummaryTooltip: classSummary.tooltip,
            outputDirectory: (nil as URL?)
        )

        controller.onLoadClasses = { [weak self] task, executable, completion in
            guard let self = self else {
                completion([])
                return
            }

            self.loadClassOptions(for: task, executable: executable) { [weak self] result in
                switch result {
                case .success(let options):
                    completion(options)
                case .failure(let error):
                    self?.presentAlert(
                        title: "TotalSegmentator",
                        message: error.localizedDescription
                    )
                    completion([])
                }
            }
        }

        controller.onCheckTaskSupportsClassSelection = { [weak self] task in
            self?.supportsClassSelection(for: task) ?? false
        }

        controller.onCheckTaskSupportsFastMode = { [weak self] task in
            self?.supportsFastMode(for: task) ?? false
        }

        controller.onCheckTaskRequiresLicense = { [weak self] task in
            self?.requiresLicense(for: task) ?? false
        }

        controller.onCompletion = { [weak self] result in
            guard let self = self else { return }

            if let result = result {
                self.preferences.store(result.preferences)
                self.selectedClassNames = Set(result.preferences.selectedClassNames)
                self.runConfigurationController = nil

                TotalSegmentatorActivityReporter.startActivityThread(named: "TotalSegmentator") { [weak self] in
                    self?.runSegmentation(
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
    /// Orchestrates the complete segmentation workflow, from environment validation through result integration into Horos.
    /// - Parameters:
    ///   - exportResult: The exported DICOM series and associated job manifest.
    ///   - providedOutputDirectory: An optional directory to which validated artifacts will be published.
    ///   - preferencesState: User-specified segmentation preferences, including task, device, quality mode, and additional arguments.
    func runSegmentation(
        exportResult: ExportResult,
        outputDirectory providedOutputDirectory: URL?,
        preferences preferencesState: SegmentationPreferences.State
    ) {
        // Run the full pipeline: validate the Python environment, assemble arguments, and reimport the results.
        let progressController = TotalSegmentatorActivityReporter()
        var exportContext = exportResult
        defer {
            cleanupTemporaryDirectory(exportResult.directory)
            progressController.close(after: 1.0)
        }

        /// Terminates the segmentation run and displays a failure message to the user.
        func failRun(message: String) {
            progressController.append(message)
            progressController.markProcessFinished()
            DispatchQueue.main.async {
                self.presentProgressLogWindow(with: progressController.capturedLog, finalMessage: message)
                self.presentAlert(title: "TotalSegmentator", message: message)
            }
        }

        guard Self.capabilityManifestIsAvailable else {
            failRun(message: Self.capabilityManifestLoadFailureMessage)
            return
        }

        progressController.append("Starting TotalSegmentator…")
        progressController.append(Self.certificationNotice)
        let environmentResult = prepareEnvironmentIfNeeded(progressController: progressController)
        guard environmentResult.isReady else {
            failRun(message: environmentResult.failureMessage)
            return
        }

        if progressController.isCancellationRequested {
            failRun(message: "TotalSegmentator run was cancelled.")
            return
        }

        guard let executableResolution = resolvePythonInterpreter(using: preferencesState) else {
            failRun(message: "Unable to locate a Python interpreter with TotalSegmentator installed. Please verify the path in the plugin settings.")
            return
        }

        let additionalTokens: [String]
        if let additional = preferencesState.additionalArguments,
           !additional.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            additionalTokens = Self.tokenize(commandLine: additional)
        } else {
            additionalTokens = []
        }

        let outputDetection = Self.detectOutputType(from: additionalTokens)
        let rtStructDetection = Self.extractRTStructExportMode(
            from: outputDetection.remainingTokens,
            defaultMode: preferencesState.rtStructExportMode
        )
        var runPreferences = preferencesState
        runPreferences.rtStructExportMode = rtStructDetection.mode
        let roiSanitizedAdditionalTokens = Self.removeROISubsetTokens(from: rtStructDetection.remainingTokens)
        let qualitySanitizedAdditionalTokens = Self.removeRuntimeQualityTokens(from: roiSanitizedAdditionalTokens)
        let effectiveOutputType: SegmentationOutputType = .nifti
        if outputDetection.type != .nifti {
            logToConsole("Overriding requested output type '\(outputDetection.type.description)' with 'nifti' so volumetric brush ROIs can be generated from voxel masks.")
        }

        guard let primarySeries = exportContext.series.first else {
            failRun(message: "No exported DICOM series was found for segmentation.")
            return
        }

        var jobManifest = exportResult.jobManifest

        let launchCapability: TaskCapability
        do {
            launchCapability = try Self.validateLaunchCapability(
                task: runPreferences.task,
                modality: primarySeries.modality,
                useFast: false,
                additionalArguments: qualitySanitizedAdditionalTokens
            )
        } catch {
            failRun(message: error.localizedDescription)
            return
        }

        let runtimeProbe = probeRuntimeCapabilities(using: executableResolution, progressController: progressController)
        let runtimePolicy: RuntimeExecutionPolicy
        do {
            runtimePolicy = try Self.resolveRuntimeExecutionPolicy(
                requestedDevice: runPreferences.device,
                requestedUseFast: runPreferences.useFast,
                additionalArguments: roiSanitizedAdditionalTokens,
                taskCapability: launchCapability,
                runtimeProbe: runtimeProbe
            )
        } catch {
            failRun(message: error.localizedDescription)
            return
        }

        var totalSegmentatorArguments: [String] = []
        if let task = runPreferences.task, !task.isEmpty {
            totalSegmentatorArguments.append(contentsOf: ["--task", task])
        }

        totalSegmentatorArguments.append(contentsOf: runtimePolicy.cliArguments)

        if launchCapability.requiresLicense, let licenseKey = runPreferences.licenseKey, !licenseKey.isEmpty {
            totalSegmentatorArguments.append(contentsOf: ["--license_number", licenseKey])
        }

        if !runtimePolicy.sanitizedAdditionalArguments.isEmpty {
            totalSegmentatorArguments.append(contentsOf: runtimePolicy.sanitizedAdditionalArguments)
        }

        if launchCapability.supportsMultilabel,
           !TaskCapabilityManifest.containsFlag("--ml", in: totalSegmentatorArguments) {
            totalSegmentatorArguments.append("--ml")
        }

        let configuredClassSelection = runPreferences.selectedClassNames
        if !configuredClassSelection.isEmpty {
            if launchCapability.supportsRoiSubset {
                totalSegmentatorArguments.append("--roi_subset")
                totalSegmentatorArguments.append(contentsOf: configuredClassSelection)
            } else {
                logToConsole("Ignoring configured class selection because the current task does not support ROI subsets.")
            }
        }

        let runWorkspace: SegmentationRunWorkspace
        let outputDirectory: URL
        do {
            let publicationBaseDirectory = try resolvePublicationDirectoryIfProvided(providedOutputDirectory)
            runWorkspace = try makeRunWorkspace(
                for: jobManifest,
                publicationBaseDirectory: publicationBaseDirectory
            )
            try stageRunManifestInputs(for: &exportContext, workspace: runWorkspace)
            outputDirectory = runWorkspace.outputDirectory
        } catch {
            failRun(message: error.localizedDescription)
            return
        }

        logToConsole("Using TotalSegmentator output directory at \(outputDirectory.path)")

        let bridgeScriptURL: URL
        let configurationURL: URL
        let bridgeResultURL: URL

        do {
            bridgeScriptURL = try prepareBridgeScript(at: runWorkspace.workDirectory)
            bridgeResultURL = runWorkspace.workDirectory.appendingPathComponent("TotalSegmentatorBridgeResult.json", isDirectory: false)
            configurationURL = try writeBridgeConfiguration(
                to: runWorkspace.workDirectory,
                dicomDirectory: primarySeries.exportedDirectory,
                outputDirectory: outputDirectory,
                outputType: effectiveOutputType.description,
                totalsegmentatorArguments: totalSegmentatorArguments,
                canonicalOutputName: "segmentation.nii.gz",
                useMultilabel: launchCapability.supportsMultilabel,
                taskIdentifier: launchCapability.identifier
            )
            jobManifest.runSnapshot = Self.snapshotForRun(
                preferences: runPreferences,
                launchCapability: launchCapability,
                selectedClasses: configuredClassSelection,
                additionalArguments: runtimePolicy.sanitizedAdditionalArguments,
                runtimePolicy: runtimePolicy
            )
            jobManifest.environmentSnapshot = SegmentationJobEnvironmentSnapshot(
                environmentLockIdentifier: Self.environmentLockManifest.lockIdentifier,
                environmentManifestIdentifier: currentEnvironmentManifestIdentifier(),
                environmentManifestPath: environmentManifestURL()?.path,
                bridgeVersion: Self.bridgeVersion,
                bridgeSchemaVersion: Self.bridgeSchemaVersion,
                bridgePackageHash: currentBridgePackageHash()
            )
            jobManifest.canonicalOutputPaths = SegmentationJobCanonicalOutputPaths(
                exportDirectory: exportContext.directory.path,
                dicomInputDirectory: primarySeries.exportedDirectory.path,
                exportManifestPath: exportContext.exportManifestURL.path,
                runWorkspaceDirectory: runWorkspace.rootDirectory.path,
                runCompletionManifestPath: runWorkspace.completionManifestURL.path,
                outputDirectory: outputDirectory.path,
                publishedOutputDirectory: runWorkspace.publishedOutputDirectory?.path,
                bridgeScriptPath: bridgeScriptURL.path,
                bridgeConfigurationPath: configurationURL.path
            )
            jobManifest.runState = "readyToLaunch"
            try persistSegmentationJobManifest(jobManifest, to: exportContext.jobManifestURL)
            exportContext.jobManifest = jobManifest
        } catch {
            failRun(message: error.localizedDescription)
            return
        }

        let process = Process()
        process.executableURL = executableResolution.executableURL
        process.arguments = executableResolution.leadingArguments + [
            bridgeScriptURL.path,
            "--config",
            configurationURL.path,
            "--result",
            bridgeResultURL.path
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        if let customEnvironment = executableResolution.environment {
            environment.merge(customEnvironment) { _, new in new }
        }
        if let dcm2niixPath = runPreferences.dcm2niixPath, !dcm2niixPath.isEmpty {
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
        let provenanceConvertedFromNifti: Bool
        switch effectiveOutputType {
        case .nifti:
            provenanceConvertedFromNifti = true
        default:
            provenanceConvertedFromNifti = false
        }
        let effectiveQuality = runtimePolicy.effectiveQuality

        let seriesCount = exportContext.series.count
        let taskDescriptor = runPreferences.task?.isEmpty == false ? runPreferences.task! : launchCapability.identifier
        progressController.append("Running TotalSegmentator (\(taskDescriptor) task) on \(seriesCount) exported series…")
        progressController.append("Capability manifest: \(Self.taskCapabilityManifest.manifestVersion).")
        progressController.append("Canonical task identifier: \(launchCapability.identifier).")
        progressController.append("Runtime capability probe: \(runtimeProbe.probeVersion).")
        progressController.append("Runtime device policy: \(runtimePolicy.selectionReason)")
        progressController.append("Execution device: \(runtimePolicy.effectiveDevice).")
        progressController.append("Quality mode: \(runtimePolicy.effectiveQuality).")
        progressController.append("Output directory: \(outputDirectory.path)")
        for warning in runtimePolicy.warnings {
            progressController.append("Runtime capability warning: \(warning)")
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
                progressController?.append(message)
                self?.logToConsole(message)
            }
        }

        stderrHandle.readabilityHandler = { [weak self, weak progressController] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.append(data)
            if let message = String(data: data, encoding: .utf8), !message.isEmpty {
                progressController?.append(message)
                self?.logToConsole(message)
            }
        }

        let runStartedAt = Date()
        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            let message = "Failed to start segmentation: \(error.localizedDescription)"
            do {
                try self.persistTerminalSegmentationJobManifest(&exportContext, runState: "failed")
            } catch {
                self.logToConsole("Failed to persist failed job manifest: \(error.localizedDescription)")
            }
            let failedStage = SegmentationRunStageOutcome(
                stage: "inference",
                status: "failed",
                startedAt: runStartedAt,
                endedAt: Date(),
                durationSeconds: nil,
                processExitStatus: nil,
                warnings: [message],
                fallbackUsed: false,
                artifactCount: nil
            )
            do {
                try self.persistSegmentationProvenance(
                    for: exportContext,
                    workspace: runWorkspace,
                    preferences: runPreferences,
                    executable: executableResolution,
                    outputType: effectiveOutputType,
                    normalizedCLIArguments: totalSegmentatorArguments,
                    effectiveDevice: runtimePolicy.effectiveDevice,
                    effectiveQuality: effectiveQuality,
                    runtimeProbe: runtimePolicy.runtimeProbe,
                    startedAt: runStartedAt,
                    endedAt: Date(),
                    processExitStatus: nil,
                    cancellationRequested: false,
                    runState: "failed",
                    stageOutcomes: [failedStage],
                    acceptedArtifacts: [],
                    completionManifestURL: nil,
                    convertedFromNifti: provenanceConvertedFromNifti,
                    warnings: [message]
                )
            } catch {
                self.logToConsole("Failed to persist failed-run provenance: \(error.localizedDescription)")
            }
            failRun(message: message)
            return
        }

        var didRequestCancellation = false
        while process.isRunning {
            if progressController.isCancellationRequested {
                didRequestCancellation = true
                progressController.append("Cancellation requested. Terminating TotalSegmentator…")
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        process.waitUntilExit()
        let runEndedAt = Date()
        if didRequestCancellation {
            progressController.append("TotalSegmentator process cancelled.")
        }
        progressController.append("TotalSegmentator finished with status \(process.terminationStatus). Validating outputs…")

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        stdoutBuffer.append(stdoutHandle.readDataToEndOfFile())
        stderrBuffer.append(stderrHandle.readDataToEndOfFile())

        let combinedErrorOutput = String(data: stderrBuffer, encoding: .utf8) ?? ""
        let combinedStandardOutput = String(data: stdoutBuffer, encoding: .utf8) ?? ""
        let combinedOutput = combinedStandardOutput + combinedErrorOutput

        let postProcessingResult: Result<SegmentationImportResult, Error>
        var acceptedArtifactsForProvenance: [SegmentationArtifactRecord] = []
        var completionManifestURLForProvenance: URL?

        if process.terminationStatus == 0 {
            do {
                _ = try self.readBridgeResult(from: bridgeResultURL, expectedStage: "segmentation")
                _ = try self.validateSegmentationOutput(at: outputDirectory, for: exportContext.jobManifest)
                // Import also calls persistAuditMetadata for this same immutable job manifest.
                let importResult = try self.integrateSegmentationOutput(
                    at: outputDirectory,
                    outputType: effectiveOutputType,
                    exportContext: exportContext,
                    preferences: runPreferences,
                    executable: executableResolution,
                    workDirectory: runWorkspace.workDirectory,
                    progressController: progressController
                )
                let completedArtifacts = try self.collectValidatedRunArtifacts(
                    in: outputDirectory,
                    rootDirectory: outputDirectory
                )
                acceptedArtifactsForProvenance = completedArtifacts
                try self.persistTerminalSegmentationJobManifest(&exportContext, runState: "completed")
                _ = try self.persistRunCompletionManifest(
                    for: exportContext.jobManifest,
                    outputDirectory: outputDirectory,
                    completionManifestURL: runWorkspace.completionManifestURL,
                    artifacts: completedArtifacts
                )
                completionManifestURLForProvenance = runWorkspace.completionManifestURL
                if let publishedURL = try self.publishValidatedRunOutput(workspace: runWorkspace) {
                    progressController.append("Published validated artifacts to \(publishedURL.path)")
                }
                postProcessingResult = .success(importResult)
            } catch {
                postProcessingResult = .failure(error)
            }
        } else if didRequestCancellation {
            postProcessingResult = .failure(
                NSError(
                    domain: "org.totalsegmentator.plugin",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "TotalSegmentator run was cancelled."]
                )
            )
        } else {
            postProcessingResult = .failure(
                NSError(
                    domain: "org.totalsegmentator.plugin",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: self.translateErrorOutput(combinedOutput, status: process.terminationStatus)]
                )
            )
        }

        progressController.markProcessFinished()

        let finalRunState: String
        let postProcessingStatus: String
        let provenanceWarnings: [String]
        switch postProcessingResult {
        case .success:
            finalRunState = "completed"
            postProcessingStatus = "completed"
            provenanceWarnings = []
        case .failure(let error):
            finalRunState = didRequestCancellation ? "cancelled" : "failed"
            postProcessingStatus = "failed"
            provenanceWarnings = [error.localizedDescription]
        }

        switch finalRunState {
        case "completed":
            break
        case "cancelled":
            do {
                try self.persistTerminalSegmentationJobManifest(&exportContext, runState: "cancelled")
            } catch {
                logToConsole("Failed to persist terminal job manifest: \(error.localizedDescription)")
            }
        default:
            do {
                try self.persistTerminalSegmentationJobManifest(&exportContext, runState: "failed")
            } catch {
                logToConsole("Failed to persist terminal job manifest: \(error.localizedDescription)")
            }
        }

        let inferenceStatus: String
        if didRequestCancellation {
            inferenceStatus = "cancelled"
        } else {
            inferenceStatus = process.terminationStatus == 0 ? "completed" : "failed"
        }
        let inferenceStage = SegmentationRunStageOutcome(
            stage: "inference",
            status: inferenceStatus,
            startedAt: runStartedAt,
            endedAt: runEndedAt,
            durationSeconds: runEndedAt.timeIntervalSince(runStartedAt),
            processExitStatus: Int(process.terminationStatus),
            warnings: didRequestCancellation ? ["Cancellation requested by user."] : [],
            fallbackUsed: false,
            artifactCount: acceptedArtifactsForProvenance.count
        )
        let postProcessingStage = SegmentationRunStageOutcome(
            stage: "postProcessing",
            status: postProcessingStatus,
            startedAt: runEndedAt,
            endedAt: Date(),
            durationSeconds: nil,
            processExitStatus: nil,
            warnings: provenanceWarnings,
            fallbackUsed: provenanceConvertedFromNifti,
            artifactCount: acceptedArtifactsForProvenance.count
        )
        do {
            try self.persistSegmentationProvenance(
                for: exportContext,
                workspace: runWorkspace,
                preferences: runPreferences,
                executable: executableResolution,
                outputType: effectiveOutputType,
                normalizedCLIArguments: totalSegmentatorArguments,
                effectiveDevice: runtimePolicy.effectiveDevice,
                effectiveQuality: effectiveQuality,
                runtimeProbe: runtimePolicy.runtimeProbe,
                startedAt: runStartedAt,
                endedAt: runEndedAt,
                processExitStatus: Int(process.terminationStatus),
                cancellationRequested: didRequestCancellation,
                runState: finalRunState,
                stageOutcomes: [inferenceStage, postProcessingStage],
                acceptedArtifacts: acceptedArtifactsForProvenance,
                completionManifestURL: completionManifestURLForProvenance,
                convertedFromNifti: provenanceConvertedFromNifti,
                warnings: provenanceWarnings
            )
        } catch {
            logToConsole("Failed to persist segmentation provenance: \(error.localizedDescription)")
        }

        switch postProcessingResult {
        case .success(let importResult):
            progressController.append("Segmentation finished successfully.")
            progressController.append("Imported \(importResult.addedFilePaths.count) file(s) into Horos.")
            if !importResult.rtStructPaths.isEmpty {
                progressController.append("Imported \(importResult.rtStructPaths.count) RT Struct file(s) into the database.")
            }
            let successMessage: String
            if importResult.volumetricROIManifestPath?.isEmpty == false {
                successMessage = "Segmentation finished successfully. Generated volumetric ROIs are now available."
            } else if !importResult.rtStructPaths.isEmpty {
                successMessage = "Segmentation finished successfully. Optional RT Struct artifacts were imported into the database."
            } else {
                successMessage = "Segmentation finished successfully."
            }
            DispatchQueue.main.async {
                self.presentAlert(title: "TotalSegmentator", message: successMessage)
            }
        case .failure(let error):
            let message: String
            if (error as NSError).domain == "org.totalsegmentator.plugin" {
                message = error.localizedDescription
            } else {
                message = error.localizedDescription
            }
            progressController.append(message)
            DispatchQueue.main.async {
                self.presentProgressLogWindow(with: progressController.capturedLog, finalMessage: message)
                self.presentAlert(title: "TotalSegmentator", message: message)
            }
        }
    }

    private func persistTerminalSegmentationJobManifest(_ exportContext: inout ExportResult, runState: String) throws {
        var manifest = exportContext.jobManifest
        manifest.runState = runState
        try persistSegmentationJobManifest(manifest, to: exportContext.jobManifestURL)
        exportContext.jobManifest = manifest
    }

    /// Creates a snapshot of the current segmentation run configuration and runtime execution state.
    /// - Returns: A snapshot containing the task, device settings, quality preferences, runtime policy information, and selected ROI classes.
    static func snapshotForRun(
        preferences: SegmentationPreferences.State,
        launchCapability: TaskCapability,
        selectedClasses: [String],
        additionalArguments: [String],
        runtimePolicy: RuntimeExecutionPolicy
    ) -> SegmentationJobRunSnapshot {
        SegmentationJobRunSnapshot(
            task: preferences.task,
            selectedClasses: launchCapability.supportsRoiSubset ? selectedClasses.sorted() : [],
            useFast: preferences.useFast,
            device: preferences.device,
            additionalArguments: additionalArguments,
            capabilityManifestVersion: taskCapabilityManifest.manifestVersion,
            capabilityTaskIdentifier: launchCapability.identifier,
            requestedDevice: runtimePolicy.requestedDevice,
            effectiveDevice: runtimePolicy.effectiveDevice,
            requestedQuality: runtimePolicy.requestedQuality,
            effectiveQuality: runtimePolicy.effectiveQuality,
            runtimeSelectionReason: runtimePolicy.selectionReason
        )
    }

    /// Locates or creates the plugin's run workspaces directory.
    /// - Returns: The URL to the plugin's runs directory in the application support folder.
    /// - Throws: `SegmentationValidationError.applicationSupportUnavailable` if the application support directory cannot be found.
    private func pluginRunWorkspacesDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SegmentationValidationError.applicationSupportUnavailable
        }

        let pluginDirectory = supportDirectory.appendingPathComponent("TotalSegmentatorHorosPlugin", isDirectory: true)
        let runsDirectory = pluginDirectory.appendingPathComponent("runs", isDirectory: true)
        try fileManager.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
        return runsDirectory
    }

    /// Creates a per-job workspace directory structure with subdirectories for input, work, and output.
    ///
    /// Manifest file paths are computed within the workspace root, and an optional published output directory URL is included if a publication base directory is provided.
    ///
    /// - Parameters:
    ///   - publicationBaseDirectory: An optional directory for publishing validated outputs.
    /// - Returns: A `SegmentationRunWorkspace` configured with directory and manifest paths.
    /// - Throws: `SegmentationValidationError.runWorkspaceAlreadyExists` if the workspace already exists.
    private func makeRunWorkspace(
        for jobManifest: SegmentationJobManifest,
        publicationBaseDirectory: URL?
    ) throws -> SegmentationRunWorkspace {
        let fileManager = FileManager.default
        let runsDirectory = try pluginRunWorkspacesDirectory(fileManager: fileManager)
        let rootDirectory = runsDirectory.appendingPathComponent(jobManifest.jobUUID, isDirectory: true)
        if fileManager.fileExists(atPath: rootDirectory.path) {
            throw SegmentationValidationError.runWorkspaceAlreadyExists(jobManifest.jobUUID)
        }

        let inputDirectory = rootDirectory.appendingPathComponent("input", isDirectory: true)
        let workDirectory = rootDirectory.appendingPathComponent("work", isDirectory: true)
        let outputDirectory = rootDirectory.appendingPathComponent("output", isDirectory: true)
        try fileManager.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let publishedOutputDirectory = publicationBaseDirectory?.appendingPathComponent(jobManifest.jobUUID, isDirectory: true)
        return SegmentationRunWorkspace(
            rootDirectory: rootDirectory,
            inputDirectory: inputDirectory,
            workDirectory: workDirectory,
            outputDirectory: outputDirectory,
            completionManifestURL: rootDirectory.appendingPathComponent("completion.json", isDirectory: false),
            provenanceManifestURL: rootDirectory.appendingPathComponent("provenance.json", isDirectory: false),
            diagnosticSummaryURL: rootDirectory.appendingPathComponent("diagnostic-summary.json", isDirectory: false),
            jobManifestURL: rootDirectory.appendingPathComponent("job.json", isDirectory: false),
            exportManifestURL: rootDirectory.appendingPathComponent("dicom-export-manifest.json", isDirectory: false),
            publicationBaseDirectory: publicationBaseDirectory,
            publishedOutputDirectory: publishedOutputDirectory
        )
    }

    /// Copies manifest files from the export context into the workspace and updates the context paths to reference the workspace copies.
    /// - Parameters:
    ///   - exportContext: The export result whose manifest URLs are updated to point to the workspace copies.
    ///   - workspace: The destination workspace where manifest files are staged.
    /// - Throws: If copying manifest files fails.
    private func stageRunManifestInputs(for exportContext: inout ExportResult, workspace: SegmentationRunWorkspace) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: exportContext.exportManifestURL.path) {
            try fileManager.copyItem(at: exportContext.exportManifestURL, to: workspace.exportManifestURL)
            exportContext.exportManifestURL = workspace.exportManifestURL
        }

        if fileManager.fileExists(atPath: exportContext.jobManifestURL.path) {
            try fileManager.copyItem(at: exportContext.jobManifestURL, to: workspace.jobManifestURL)
        }
        exportContext.jobManifestURL = workspace.jobManifestURL
    }

    /// Validates that the provided directory, if it exists, is a directory rather than a file.
    /// - Returns: The provided directory URL unchanged, or `nil` if the provided directory is `nil`.
    /// - Throws: An NSError if the path exists but is not a directory.
    private func resolvePublicationDirectoryIfProvided(_ providedDirectory: URL?) throws -> URL? {
        guard let providedDirectory else {
            return nil
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: providedDirectory.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            throw NSError(
                domain: "org.totalsegmentator.plugin",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "The selected output path is not a directory."]
            )
        }

        return providedDirectory
    }

    /// Publishes validated run output to a publication directory.
    /// - Parameters:
    ///   - runWorkspace: The workspace containing output and publication directory information.
    /// - Returns: The URL of the published output directory, or `nil` if publication directories are not configured.
    /// - Throws: If the target publication directory already exists or if file operations fail.
    private func publishValidatedRunOutput(workspace runWorkspace: SegmentationRunWorkspace) throws -> URL? {
        guard let publicationBaseDirectory = runWorkspace.publicationBaseDirectory,
              let publishedOutputDirectory = runWorkspace.publishedOutputDirectory else {
            return nil
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: publicationBaseDirectory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: publishedOutputDirectory.path) {
            throw NSError(
                domain: "org.totalsegmentator.plugin",
                code: 1003,
                userInfo: [NSLocalizedDescriptionKey: "The validated output publication directory already exists."]
            )
        }

        let stagingURL = publicationBaseDirectory.appendingPathComponent(
            ".\(publishedOutputDirectory.lastPathComponent).staging",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: stagingURL.path) {
            try fileManager.removeItem(at: stagingURL)
        }

        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            try copyRunOutputContents(from: runWorkspace.outputDirectory, to: stagingURL)
            if fileManager.fileExists(atPath: runWorkspace.completionManifestURL.path) {
                try fileManager.copyItem(
                    at: runWorkspace.completionManifestURL,
                    to: stagingURL.appendingPathComponent("completion.json", isDirectory: false)
                )
            }
            try fileManager.moveItem(at: stagingURL, to: publishedOutputDirectory)
        } catch {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
            throw error
        }

        return publishedOutputDirectory
    }

    /// Copies all visible items from a source directory to a destination directory, preserving filenames.
    /// - Throws: An error if copying fails.
    private func copyRunOutputContents(from sourceDirectory: URL, to destinationDirectory: URL) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for sourceURL in contents {
            let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    /// Displays a progress log window with the provided log content and final message.
    private func presentProgressLogWindow(with log: String, finalMessage: String) {
        let controller = SegmentationProgressWindowController()
        errorLogWindowController = controller
        controller.showWindow(nil)

        let trimmedLog = log.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLog.isEmpty {
            controller.append(finalMessage)
        } else {
            controller.append(trimmedLog)
            if !trimmedLog.contains(finalMessage) {
                controller.append(finalMessage)
            }
        }

        controller.markProcessFinished()
    }

    static func resolveOutputDirectoryIfProvided(_ provided: URL, fileManager: FileManager = .default) throws -> URL {
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

    static func tokenize(commandLine: String) -> [String] {
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

    /// Identifies the output type specified in command-line arguments.
    /// - Parameter tokens: The command-line arguments to scan.
    /// - Returns: The detected output type (`.dicom` if unspecified or if no value follows the flag) and the remaining tokens with `--output_type` flags removed.
    static func detectOutputType(from tokens: [String]) -> (type: SegmentationOutputType, remainingTokens: [String]) {
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

    /// Extracts the RT-Struct export mode from command-line tokens and removes all RT-Struct-related flags.
    /// - Parameters:
    ///   - defaultMode: The mode to use if no RT-Struct flags are found in the tokens.
    /// - Returns: A tuple containing the parsed export mode and the remaining tokens with RT-Struct flags removed.
    static func extractRTStructExportMode(
        from tokens: [String],
        defaultMode: RTStructExportMode
    ) -> (mode: RTStructExportMode, remainingTokens: [String]) {
        var mode = defaultMode
        var remainingTokens: [String] = []

        var index = 0
        while index < tokens.count {
            let token = tokens[index]

            if token == "--rtstruct" || token == "--rt-struct" {
                mode = .optional
                index += 1
                continue
            }

            if token == "--no-rtstruct" || token == "--no-rt-struct" {
                mode = .disabled
                index += 1
                continue
            }

            if token == "--rtstruct-mode" || token == "--rt-struct-mode" {
                let nextIndex = index + 1
                if nextIndex < tokens.count, !tokens[nextIndex].hasPrefix("--") {
                    if let parsedMode = RTStructExportMode(rawValue: tokens[nextIndex].lowercased()) {
                        mode = parsedMode
                    }
                    index += 2
                    continue
                }

                index += 1
                continue
            }

            if token.hasPrefix("--rtstruct-mode=") {
                let value = String(token.dropFirst("--rtstruct-mode=".count)).lowercased()
                if let parsedMode = RTStructExportMode(rawValue: value) {
                    mode = parsedMode
                }
                index += 1
                continue
            }

            if token.hasPrefix("--rt-struct-mode=") {
                let value = String(token.dropFirst("--rt-struct-mode=".count)).lowercased()
                if let parsedMode = RTStructExportMode(rawValue: value) {
                    mode = parsedMode
                }
                index += 1
                continue
            }

            remainingTokens.append(token)
            index += 1
        }

        return (mode, remainingTokens)
    }

    /// Removes ROI subset selection flags and their values from the given tokens.
    /// - Returns: The filtered tokens.
    static func removeROISubsetTokens(from tokens: [String]) -> [String] {
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
