//
// TotalSegmentatorHorosPlugin+Import.swift
// TotalSegmentator
//

import Cocoa
import CoreData
import CryptoKit

private let totalSegmentatorROIDisplayOpacity: Float = 0.30

fileprivate struct ViewerSeriesIdentity {
    let studyInstanceUID: String?
    let seriesInstanceUID: String?
    let frameOfReferenceUID: String?
    let orderedSOPInstanceUIDs: [String]
    let rows: Int?
    let columns: Int?
    let frameCount: Int
}

fileprivate enum ViewerSeriesIdentityMatch {
    case exactSourceInstanceSet
    case sameSeriesReorderedDisplay
    case mismatch(String)

    var isCompatible: Bool {
        switch self {
        case .exactSourceInstanceSet, .sameSeriesReorderedDisplay:
            return true
        case .mismatch:
            return false
        }
    }

    var message: String {
        switch self {
        case .exactSourceInstanceSet:
            return "exact source instance set"
        case .sameSeriesReorderedDisplay:
            return "same source series with reordered display"
        case .mismatch(let reason):
            return reason
        }
    }
}

extension TotalSegmentatorHorosPlugin {
    /// Imports TotalSegmentator segmentation output and applies ROI visualization.
    ///
    /// Processes output in DICOM or NIfTI format. For NIfTI, converts to DICOM artifacts before importing. Updates visualization with volumetric ROI overlays and persists audit metadata.
    ///
    /// - Parameters:
    ///   - url: The output file or directory to import.
    ///   - outputType: The format of the output.
    ///   - workDirectory: Optional directory for NIfTI conversion work files. Defaults to the input directory if not provided.
    /// - Returns: A `SegmentationImportResult` containing imported object identifiers, file paths, and ROI metadata.
    /// - Throws: `SegmentationPostProcessingError.unsupportedOutputType` if output type is unsupported, or errors from conversion or import operations.
    func integrateSegmentationOutput(
        at url: URL,
        outputType: SegmentationOutputType,
        exportContext: ExportResult,
        preferences: SegmentationPreferences.State,
        executable: ExecutableResolution,
        workDirectory: URL? = nil,
        progressController: SegmentationProgressReporting?
    ) throws -> SegmentationImportResult {
        let normalizedOutput = outputType.description.uppercased()
        progressController?.append("Importing TotalSegmentator outputs (\(normalizedOutput))…")
        let importResult: SegmentationImportResult
        let auditOutputType: SegmentationOutputType
        let convertedFromNifti: Bool

        switch outputType {
        case .dicom:
            importResult = try importDicomOutputs(from: url, progressController: progressController)
            auditOutputType = .dicom
            convertedFromNifti = false
        case .nifti:
            let conversionOutput = try convertNiftiOutputsToDicom(
                from: url,
                exportContext: exportContext,
                preferences: preferences,
                executable: executable,
                workDirectory: workDirectory,
                progressController: progressController
            )
            importResult = try importDicomOutputs(
                from: conversionOutput.directory,
                volumetricROIManifestPath: conversionOutput.volumetricROIManifestPath,
                rtStructExportMode: conversionOutput.rtStructExportMode,
                rtStructStatus: conversionOutput.rtStructStatus,
                rtStructError: conversionOutput.rtStructError,
                progressController: progressController
            )
            auditOutputType = .dicom
            convertedFromNifti = true
        case .other(let value):
            throw SegmentationPostProcessingError.unsupportedOutputType(value)
        }

        progressController?.append("Preparing ROI overlays for visualization…")
        updateVisualization(
            with: importResult,
            exportContext: exportContext,
            preferences: preferences,
            executable: executable,
            progressController: progressController
        )
        persistAuditMetadata(
            for: importResult,
            exportContext: exportContext,
            outputDirectory: url,
            preferences: preferences,
            outputType: auditOutputType,
            executable: executable,
            convertedFromNifti: convertedFromNifti
        )

        return importResult
    }

    /// Enumerates and imports DICOM and RT Struct files from a directory into the Horos database.
    ///
    /// - Throws: `SegmentationPostProcessingError.noImportableResults` if neither DICOM files nor a volumetric ROI manifest are found.
    /// - Throws: `SegmentationPostProcessingError.databaseUnavailable` if the Horos database cannot be accessed.
    /// - Returns: Import result containing file paths, object identifiers, and RT Struct and volumetric ROI metadata.
    private func importDicomOutputs(
        from directory: URL,
        volumetricROIManifestPath: String? = nil,
        rtStructExportMode: RTStructExportMode = .disabled,
        rtStructStatus: String? = nil,
        rtStructError: String? = nil,
        progressController: SegmentationProgressReporting? = nil
    ) throws -> SegmentationImportResult {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var dicomPaths: [String] = []
        var rtStructPaths: [String] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
                continue
            }

            if isLikelyDicomFile(at: fileURL) {
                dicomPaths.append(fileURL.path)
                if isLikelyRTStruct(at: fileURL) {
                    rtStructPaths.append(fileURL.path)
                }
            }
        }

        let hasVolumetricManifest = volumetricROIManifestPath?.isEmpty == false

        guard !dicomPaths.isEmpty || hasVolumetricManifest else {
            throw SegmentationPostProcessingError.noImportableResults
        }

        var importedObjectIDs: [NSManagedObjectID] = []
        var importedIDSet = Set<NSManagedObjectID>()
        var importError: Error?

        if !dicomPaths.isEmpty {
            progressController?.append("Importing \(dicomPaths.count) DICOM/RT Struct artifact(s) into the Horos database.")
            DispatchQueue.main.sync {
                guard let database = BrowserController.currentBrowser()?.database else {
                    importError = SegmentationPostProcessingError.databaseUnavailable
                    return
                }

                if let result = database.addFiles(
                    atPaths: dicomPaths,
                    postNotifications: true,
                    dicomOnly: true,
                    rereadExistingItems: false,
                    generatedByOsiriX: true,
                    returnArray: true
                ) as? [NSManagedObjectID] {
                    importedObjectIDs = result
                    importedIDSet.formUnion(result)
                }

                if !rtStructPaths.isEmpty,
                   let additionalIDs = database.addFiles(
                       atPaths: rtStructPaths,
                       postNotifications: true,
                       dicomOnly: true,
                       rereadExistingItems: true,
                       generatedByOsiriX: true,
                       returnArray: true
                   ) as? [NSManagedObjectID] {
                    for identifier in additionalIDs where !importedIDSet.contains(identifier) {
                        importedObjectIDs.append(identifier)
                        importedIDSet.insert(identifier)
                    }
                }
            }
        }

        if let error = importError {
            throw error
        }

        return SegmentationImportResult(
            addedFilePaths: dicomPaths,
            rtStructPaths: rtStructPaths,
            importedObjectIDs: importedObjectIDs,
            outputType: .dicom,
            volumetricROIManifestPath: volumetricROIManifestPath,
            rtStructExportMode: rtStructExportMode,
            rtStructStatus: rtStructStatus,
            rtStructError: rtStructError
        )
    }

    private struct NiftiConversionManifest: Decodable {
        let rtStructPaths: [String]
        let rtStructMode: String?
        let rtStructStatus: String?
        let rtStructError: String?
        let dicomSeriesDirectories: [String]
        let volumetricROIManifestPath: String?

        enum CodingKeys: String, CodingKey {
            case rtStructPaths = "rtstruct_paths"
            case rtStructMode = "rtstruct_mode"
            case rtStructStatus = "rtstruct_status"
            case rtStructError = "rtstruct_error"
            case dicomSeriesDirectories = "dicom_series_directories"
            case volumetricROIManifestPath = "volumetric_roi_manifest_path"
        }
    }

    private struct NiftiConversionOutput {
        let directory: URL
        let volumetricROIManifestPath: String?
        let rtStructExportMode: RTStructExportMode
        let rtStructStatus: String?
        let rtStructError: String?
    }

    /// Converts NIfTI segmentation outputs to DICOM format and generates supporting artifacts.
    /// - Parameters:
    ///   - directory: The directory containing NIfTI segmentation outputs.
    ///   - workDirectory: Optional working directory for conversion artifacts; defaults to the input directory.
    /// - Returns: A `NiftiConversionOutput` containing the conversion directory, paths to generated artifacts, and RT Struct export status and error information.
    /// - Throws: `NiftiConversionError.missingReferenceSeries` if the export context has no source series, `NiftiConversionError.scriptFailed` if the Python conversion process fails, `NiftiConversionError.noOutputsProduced` if no DICOM or volumetric ROI artifacts were generated, or conversion configuration errors.
    private func convertNiftiOutputsToDicom(
        from directory: URL,
        exportContext: ExportResult,
        preferences: SegmentationPreferences.State,
        executable: ExecutableResolution,
        workDirectory: URL?,
        progressController: SegmentationProgressReporting?
    ) throws -> NiftiConversionOutput {
        guard let referenceSeries = exportContext.series.first else {
            throw NiftiConversionError.missingReferenceSeries
        }

        let fileManager = FileManager.default
        let conversionDirectory = directory.appendingPathComponent("dicom_conversion", isDirectory: true)

        if !fileManager.fileExists(atPath: conversionDirectory.path) {
            try fileManager.createDirectory(at: conversionDirectory, withIntermediateDirectories: true)
        }

        let taskIdentifier = exportContext.jobManifest.runSnapshot?.capabilityTaskIdentifier ?? preferences.task
        let conversionCapability = Self.taskCapabilityManifest.capability(for: taskIdentifier)
        let allowBinaryMaskCompatibility = conversionCapability?.supportsMultilabel == false
        let conversionWorkDirectory = (workDirectory ?? directory)
            .appendingPathComponent("nifti_conversion", isDirectory: true)
        try fileManager.createDirectory(at: conversionWorkDirectory, withIntermediateDirectories: true)

        let scriptURL = try prepareNiftiConversionScript(at: conversionWorkDirectory)
        let configurationURL = try writeNiftiConversionConfiguration(
            to: conversionWorkDirectory,
            niftiDirectory: directory,
            referenceDirectory: referenceSeries.exportedDirectory,
            outputDirectory: conversionDirectory,
            preferences: preferences,
            jobManifest: exportContext.jobManifest,
            allowBinaryMaskCompatibility: allowBinaryMaskCompatibility
        )
        let resultURL = conversionWorkDirectory.appendingPathComponent(
            "TotalSegmentatorNiftiConversionResult.json",
            isDirectory: false
        )

        let result = runPythonProcess(
            using: executable,
            arguments: [scriptURL.path, "--config", configurationURL.path, "--result", resultURL.path],
            progressController: progressController
        )

        if let error = result.error {
            throw error
        }

        if result.terminationStatus != 0 {
            if fileManager.fileExists(atPath: resultURL.path) {
                _ = try readBridgeResult(from: resultURL, expectedStage: "nifti_conversion")
            }
            let stderrString = String(data: result.stderr, encoding: .utf8) ?? ""
            throw NiftiConversionError.scriptFailed(
                status: result.terminationStatus,
                stderr: stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let resultPayload = try readBridgeResult(from: resultURL, expectedStage: "nifti_conversion")
        let manifestData = try JSONSerialization.data(withJSONObject: resultPayload)
        let manifest = try JSONDecoder().decode(NiftiConversionManifest.self, from: manifestData)

        let hasVolumetricManifest = manifest.volumetricROIManifestPath?.isEmpty == false
        if manifest.rtStructPaths.isEmpty && manifest.dicomSeriesDirectories.isEmpty && !hasVolumetricManifest {
            throw NiftiConversionError.noOutputsProduced
        }

        if hasVolumetricManifest {
            progressController?.append("Generated volumetric ROI manifest from canonical NIfTI output.")
        }

        let rtStructExportMode = RTStructExportMode(preferenceValue: manifest.rtStructMode)
        switch manifest.rtStructStatus {
        case "disabled":
            progressController?.append("RT Struct generation disabled.")
        case "succeeded":
            progressController?.append("Generated \(manifest.rtStructPaths.count) RT Struct artifact(s) for database interoperability.")
        case "failed":
            let errorMessage = manifest.rtStructError?.isEmpty == false ? ": \(manifest.rtStructError!)" : "."
            progressController?.append("Optional RT Struct generation failed\(errorMessage)")
        default:
            break
        }

        progressController?.append("Prepared segmentation post-processing artifacts.")
        logToConsole("Prepared segmentation post-processing artifacts at \(conversionDirectory.path)")

        return NiftiConversionOutput(
            directory: conversionDirectory,
            volumetricROIManifestPath: manifest.volumetricROIManifestPath,
            rtStructExportMode: rtStructExportMode,
            rtStructStatus: manifest.rtStructStatus,
            rtStructError: manifest.rtStructError
        )
    }

    /// Imports NIfTI files from a directory into the Horos database.
    /// - Parameters:
    ///   - directory: The directory containing the NIfTI files to import.
    /// - Returns: A `SegmentationImportResult` with imported file paths and database object identifiers.
    /// - Throws: `noImportableResults` if no NIfTI files are found; `databaseUnavailable` if the Horos database is unavailable.
    private func importNiftiOutputs(from directory: URL) throws -> SegmentationImportResult {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var niftiPaths: [String] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
                continue
            }

            if isLikelyNiftiFile(at: fileURL) {
                niftiPaths.append(fileURL.path)
            }
        }

        guard !niftiPaths.isEmpty else {
            throw SegmentationPostProcessingError.noImportableResults
        }

        var importedObjectIDs: [NSManagedObjectID] = []
        var importError: Error?

        DispatchQueue.main.sync {
            guard let database = BrowserController.currentBrowser()?.database else {
                importError = SegmentationPostProcessingError.databaseUnavailable
                return
            }

            if let result = database.addFiles(
                atPaths: niftiPaths,
                postNotifications: true,
                dicomOnly: false,
                rereadExistingItems: false,
                generatedByOsiriX: true,
                returnArray: true
            ) as? [NSManagedObjectID] {
                importedObjectIDs = result
            }
        }

        if let error = importError {
            throw error
        }

        return SegmentationImportResult(
            addedFilePaths: niftiPaths,
            rtStructPaths: [],
            importedObjectIDs: importedObjectIDs,
            outputType: .nifti,
            volumetricROIManifestPath: nil,
            rtStructExportMode: .disabled,
            rtStructStatus: nil,
            rtStructError: nil
        )
    }

    /// Applies volumetric ROI overlays from an import result to the active viewer and registers ROI resynchronization coordination.
    /// 
    /// This method handles the complete visualization setup after segmentation import: importing volumetric ROI brushes from the manifest, deduplicating ROIs across the active and other displayed viewers, applying opacity settings to TotalSegmentator-generated ROIs, and registering the ROI resync coordinator to maintain consistency across compatible viewers. If no volumetric manifest is available or ROI display is disabled, this method logs a status message and returns without modifications.
    /// - Parameters:
    ///   - importResult: The segmentation import result containing volumetric ROI manifest path and imported object identifiers.
    ///   - exportContext: The export context providing series and job manifest information for viewer identification.
    ///   - preferences: User preferences including the ROI display visibility flag.
    ///   - executable: The executable resolution for volumetric projection operations.
    ///   - progressController: Optional controller for reporting progress messages.
    private func updateVisualization(
        with importResult: SegmentationImportResult,
        exportContext: ExportResult,
        preferences: SegmentationPreferences.State,
        executable: ExecutableResolution,
        progressController: SegmentationProgressReporting?
    ) {
        let hasVolumetricManifest = importResult.volumetricROIManifestPath?.isEmpty == false

        guard hasVolumetricManifest else {
            if !importResult.rtStructPaths.isEmpty {
                progressController?.append("RT Struct artifact(s) were imported into the database; no volumetric ROI manifest is available for direct viewer display.")
            }
            return
        }

        if preferences.hideROIs {
            DispatchQueue.main.async {
                progressController?.append("Skipping ROI overlay display per preferences.")
            }
            return
        }

        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            progressController?.append("Applying segmentation ROIs to the active viewer…")

            guard let browser = BrowserController.currentBrowser() else {
                progressController?.append("Unable to locate the Horos browser to update the viewer.")
                semaphore.signal()
                return
            }

            guard let activeViewer = self.verifiedSourceViewer(
                for: exportContext,
                browser: browser,
                progressController: progressController
            ) else {
                progressController?.append("Unable to find a verified source-series viewer for ROI overlay.")
                semaphore.signal()
                return
            }
            let expectedROIComment = self.roiProvenanceComment(for: exportContext.jobManifest)

            var importedVolumetricROICount = 0
            var importedVolumetricLabelCount = 0
            var skippedVolumetricSliceCount = 0

            if let manifestPath = importResult.volumetricROIManifestPath,
               !manifestPath.isEmpty {
                let summary = TSVolumetricROIImporter.importVolumetricROIs(fromManifest: manifestPath, into: activeViewer)
                importedVolumetricROICount = (summary["roi_count"] as? NSNumber)?.intValue ?? 0
                importedVolumetricLabelCount = (summary["label_count"] as? NSNumber)?.intValue ?? 0
                skippedVolumetricSliceCount = (summary["skipped_slice_count"] as? NSNumber)?.intValue ?? 0

                if let errorMessage = summary["error"] as? String, !errorMessage.isEmpty {
                    progressController?.append("Volumetric ROI import warning: \(errorMessage)")
                    self.logToConsole("Volumetric ROI import warning: \(errorMessage)")
                }

                if importedVolumetricROICount > 0 {
                    progressController?.append("Created \(importedVolumetricROICount) volumetric brush ROI slice(s) across \(importedVolumetricLabelCount) label(s).")
                    if skippedVolumetricSliceCount > 0 {
                        progressController?.append("Skipped \(skippedVolumetricSliceCount) empty or unmatched volumetric ROI slice(s).")
                    }
                }
            }

            if importedVolumetricROICount == 0 {
                progressController?.append("No segmentation ROIs could be applied to the active viewer.")
                semaphore.signal()
                return
            }

            let finishVisualization: () -> Void = {
                let labelNames = self.totalSegmentatorLabelNames(from: importResult.volumetricROIManifestPath)
                if importedVolumetricROICount > 0 {
                    self.deduplicateTotalSegmentatorROIs(in: activeViewer, labelNames: labelNames, roiComment: expectedROIComment)
                    self.applyTotalSegmentatorROIOpacity(in: activeViewer, labelNames: labelNames, roiComment: expectedROIComment)
                    self.persistROIs(from: activeViewer)
                }

                let removedDuplicateROIs = self.deduplicateDisplayedTotalSegmentatorROIs(labelNames: labelNames, jobManifest: exportContext.jobManifest, roiComment: expectedROIComment)
                if removedDuplicateROIs > 0 {
                    progressController?.append("Removed \(removedDuplicateROIs) duplicate generated ROI(s) from open TotalSegmentator viewers.")
                    self.logToConsole("Removed \(removedDuplicateROIs) duplicate generated ROI(s) from open TotalSegmentator viewers.")
                }

                if let database = browser.database,
                   let importedObjects = database.objects(withIDs: importResult.importedObjectIDs) as? [NSManagedObject] {
                    let importedSeries = importedObjects.compactMap { $0 as? DicomSeries }
                    let targetSeries = importedSeries.first { series in
                        guard let modality = series.modality else { return false }
                        return modality.uppercased() == "RTSTRUCT"
                    } ?? importedSeries.first

                    if let series = targetSeries, let study = series.study {
                        browser.selectStudy(with: study.objectID)
                    }
                }

                activeViewer.refresh()
                activeViewer.window?.makeKeyAndOrderFront(nil)
                activeViewer.needsDisplayUpdate()
                self.roiResyncCoordinator.register(
                    viewer: activeViewer,
                    importResult: importResult,
                    executable: executable,
                    jobManifest: exportContext.jobManifest,
                    owner: self
                )

                if importedVolumetricROICount > 0 {
                    progressController?.append("Stored volumetric brush ROIs in Horos.")
                }

                semaphore.signal()
            }

            finishVisualization()
        }

        semaphore.wait()
    }

    /// Loads the first compatible series from the export context into a Horos viewer.
    /// - Returns: A viewer containing the loaded series, or nil if no series could be loaded.
    private func openViewer(for exportContext: ExportResult, browser: BrowserController) -> ViewerController? {
        for exportedSeries in exportContext.series {
            if let viewer = browser.loadSeries(exportedSeries.series, nil, true, keyImagesOnly: false) {
                return viewer
            }
        }

        return nil
    }

    /// Locates and verifies a source viewer matching the export context's expected series identity.
    /// - Returns: A verified viewer, or nil if no compatible viewer is found or identity verification fails.
    fileprivate func verifiedSourceViewer(
        for exportContext: ExportResult,
        browser: BrowserController,
        progressController: SegmentationProgressReporting?
    ) -> ViewerController? {
        let matchingDisplayedViewers = compatibleDisplayedSourceViewers(for: exportContext.jobManifest)
        if let viewer = matchingDisplayedViewers.first {
            if matchingDisplayedViewers.count > 1 {
                logToConsole("Multiple source-series viewers match job \(exportContext.jobManifest.jobUUID); using the first displayed exact match.")
            }
            return viewer
        }

        guard let openedViewer = openViewer(for: exportContext, browser: browser) else {
            return nil
        }

        let match = viewerSeriesIdentityMatch(for: openedViewer, jobManifest: exportContext.jobManifest)
        guard match.isCompatible else {
            let message = "Opened viewer failed source identity verification: \(match.message)."
            progressController?.append(message)
            logToConsole(message)
            return nil
        }

        return openedViewer
    }

    /// Filters displayed 2D viewers to those compatible with the job's expected source series identity.
    /// - Parameter jobManifest: The segmentation job manifest defining the expected identity.
    /// - Returns: An array of compatible displayed viewers.
    fileprivate func compatibleDisplayedSourceViewers(for jobManifest: SegmentationJobManifest) -> [ViewerController] {
        let displayedViewers = (ViewerController.getDisplayed2DViewers() as? [ViewerController]) ?? []
        return displayedViewers.filter { viewer in
            viewerSeriesIdentityMatch(for: viewer, jobManifest: jobManifest).isCompatible
        }
    }

    /// Validates whether a viewer's series identity matches a job manifest's expected source identity.
    /// - Returns: A `ViewerSeriesIdentityMatch` describing the validation outcome: exact match, reordered match, or mismatch with reason.
    fileprivate func viewerSeriesIdentityMatch(for viewer: ViewerController, jobManifest: SegmentationJobManifest) -> ViewerSeriesIdentityMatch {
        guard let identity = viewerSeriesIdentity(for: viewer) else {
            return .mismatch("viewer identity unavailable")
        }

        let expectedSOPs = jobManifest.orderedSOPInstanceUIDs
        guard !expectedSOPs.isEmpty else {
            return .mismatch("job source identity has no SOP Instance UIDs")
        }

        let actualSOPs = identity.orderedSOPInstanceUIDs
        guard !actualSOPs.isEmpty else {
            return .mismatch("viewer source identity has no SOP Instance UIDs")
        }

        guard Set(actualSOPs) == Set(expectedSOPs), actualSOPs.count == expectedSOPs.count else {
            return .mismatch("source identity mismatch: SOP Instance UID set differs")
        }

        if let expectedStudy = normalizedViewerString(jobManifest.studyInstanceUID),
           identity.studyInstanceUID != expectedStudy {
            return .mismatch("source identity mismatch: Study Instance UID differs")
        }

        if let expectedSeries = normalizedViewerString(jobManifest.seriesInstanceUID),
           identity.seriesInstanceUID != expectedSeries {
            return .mismatch("source identity mismatch: Series Instance UID differs")
        }

        if let expectedFrame = normalizedViewerString(jobManifest.frameOfReferenceUID),
           identity.frameOfReferenceUID != expectedFrame {
            return .mismatch("source identity mismatch: Frame of Reference UID differs")
        }

        if let expectedRows = jobManifest.geometry.rows,
           let actualRows = identity.rows,
           expectedRows != actualRows {
            return .mismatch("source geometry mismatch: row count differs")
        }

        if let expectedColumns = jobManifest.geometry.columns,
           let actualColumns = identity.columns,
           expectedColumns != actualColumns {
            return .mismatch("source geometry mismatch: column count differs")
        }

        if actualSOPs == expectedSOPs {
            return .exactSourceInstanceSet
        }
        return .sameSeriesReorderedDisplay
    }

    /// Extracts identity information from a viewer controller.
    /// - Parameter viewer: The viewer controller.
    /// - Returns: A `ViewerSeriesIdentity` containing SOP Instance UIDs, study and series UIDs, frame of reference, pixel dimensions, and frame count, or `nil` if no SOP Instance UIDs are found.
    fileprivate func viewerSeriesIdentity(for viewer: ViewerController) -> ViewerSeriesIdentity? {
        let fileList = (viewer.fileList() as? [Any]) ?? []
        let pixList = (viewer.pixList() as? [Any]) ?? []
        let orderedSOPs = fileList.compactMap { sopInstanceUID(from: $0) }
        guard !orderedSOPs.isEmpty else {
            return nil
        }

        let firstImage = fileList.first
        let firstPix = pixList.compactMap { $0 as? DCMPix }.first
        let studyInstanceUID = normalizedViewerString(viewer.studyInstanceUID())
            ?? firstImage.flatMap { self.studyInstanceUID(from: $0) }
        let seriesInstanceUID = firstImage.flatMap { self.seriesInstanceUID(from: $0) }
        let frameOfReferenceUID = pixList.compactMap { element -> String? in
            guard let pix = element as? DCMPix else { return nil }
            return normalizedViewerString(pix.frameofReferenceUID)
        }.first
        let rows = firstPix.map { Int($0.pheight) }
        let columns = firstPix.map { Int($0.pwidth) }

        return ViewerSeriesIdentity(
            studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: seriesInstanceUID,
            frameOfReferenceUID: frameOfReferenceUID,
            orderedSOPInstanceUIDs: orderedSOPs,
            rows: rows,
            columns: columns,
            frameCount: pixList.count
        )
    }

    /// Generates a provenance comment string for ROIs associated with a specific segmentation job.
    /// - Parameters:
    ///   - jobManifest: The segmentation job manifest containing the job UUID and source identity hash.
    /// - Returns: A formatted string containing the ROI comment prefix, job UUID, and source identity hash, used to identify and track ROIs across viewers.
    func roiProvenanceComment(for jobManifest: SegmentationJobManifest) -> String {
        "\(TotalSegmentatorROIResyncCoordinator.generatedROICommentPrefix); job=\(jobManifest.jobUUID); source=\(jobManifest.sourceIdentityHash)"
    }

    /// Applies ROI data from an RTSTRUCT file to the viewer.
    /// - Parameters:
    ///   - path: The file path to the RTSTRUCT file.
    ///   - viewer: The viewer in which to create the ROIs.
    /// - Returns: `true` if ROI creation succeeded, `false` otherwise.
    private func applyRTStructOverlay(from path: String, to viewer: ViewerController) -> Bool {
        guard let dcmObject = DCMObject(contentsOfFile: path, decodingPixelData: false) else {
            return false
        }

        if let currentPix = viewer.imageView()?.curDCM {
            currentPix.createROIs(fromRTSTRUCT: dcmObject)
            return true
        }

        if let pixList = viewer.pixList() {
            for case let pix as DCMPix in pixList {
                pix.createROIs(fromRTSTRUCT: dcmObject)
                return true
            }
        }

        let movieCount = Int(viewer.maxMovieIndex())
        if movieCount >= 0 {
            for index in 0...movieCount {
                if let pixList = viewer.pixList(index) {
                    for case let pix as DCMPix in pixList {
                        pix.createROIs(fromRTSTRUCT: dcmObject)
                        return true
                    }
                }
            }
        }

        return false
    }

    fileprivate func reloadROIs(in viewer: ViewerController) {
        let maxIndex = Int(viewer.maxMovieIndex())
        if maxIndex >= 0 {
            for index in 0...maxIndex {
                viewer.loadROI(Int(index))
            }
        } else {
            viewer.loadROI(Int(viewer.curMovieIndex()))
        }
    }

    private func waitForRTStructConversionsToFinish(
        progressController: SegmentationProgressReporting?,
        timeout: TimeInterval = 120
    ) -> Bool {
        guard let manager = ThreadsManager.`default`() else {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let threadObjects = manager.threads() ?? []
            let hasConversion = threadObjects.contains { element in
                guard let thread = element as? Thread, let name = thread.name else { return false }
                return name.contains("Converting RTSTRUCT in ROIs")
            }

            if !hasConversion {
                progressController?.append("ROI conversion completed.")
                return true
            }

            Thread.sleep(forTimeInterval: 0.25)
        }

        return false
    }

    /// Persists the ROIs in the viewer to storage.
    fileprivate func persistROIs(from viewer: ViewerController) {
        let maxIndex = Int(viewer.maxMovieIndex())
        if maxIndex >= 0 {
            for index in 0...maxIndex {
                viewer.saveROI(Int(index))
            }
        } else {
            viewer.saveROI(Int(viewer.curMovieIndex()))
        }
    }

    /// Removes duplicate TotalSegmentator ROIs from a viewer by name within each slice.
    /// - Parameters:
    ///   - labelNames: Acceptable ROI names to deduplicate; if empty, all names are considered.
    ///   - roiComment: The comment identifying TotalSegmentator ROIs.
    /// - Returns: The number of duplicate ROIs removed.
    @discardableResult
    fileprivate func deduplicateTotalSegmentatorROIs(in viewer: ViewerController, labelNames: Set<String>, roiComment: String) -> Int {
        guard let roiSeriesList = viewer.roiList() else {
            return 0
        }

        var removedCount = 0
        for case let sliceList as NSMutableArray in roiSeriesList {
            var seenNames = Set<String>()
            var duplicateIndexes = IndexSet()

            for (index, element) in sliceList.enumerated() {
                let comments = stringValue(forKey: "comments", from: element)
                guard comments == roiComment else {
                    continue
                }

                guard let name = stringValue(forKey: "name", from: element), !name.isEmpty else {
                    continue
                }

                if !labelNames.isEmpty && !labelNames.contains(where: { $0 == name }) {
                    continue
                }

                if seenNames.contains(name) {
                    duplicateIndexes.insert(index)
                } else {
                    seenNames.insert(name)
                }
            }

            if !duplicateIndexes.isEmpty {
                removedCount += duplicateIndexes.count
                sliceList.removeObjects(at: duplicateIndexes)
            }
        }

        return removedCount
    }

    /// Removes TotalSegmentator ROIs for the current job from a viewer.
    /// - Returns: The number of generated ROIs removed.
    @discardableResult
    fileprivate func removeTotalSegmentatorROIs(in viewer: ViewerController, labelNames: Set<String>, roiComment: String) -> Int {
        guard let roiSeriesList = viewer.roiList() else {
            return 0
        }

        var removedCount = 0
        for case let sliceList as NSMutableArray in roiSeriesList {
            for index in (0..<sliceList.count).reversed() {
                let element = sliceList[index]
                guard isTotalSegmentatorROI(element, labelNames: labelNames, roiComment: roiComment) else {
                    continue
                }
                sliceList.removeObject(at: index)
                removedCount += 1
            }
        }

        return removedCount
    }

    /// Applies opacity to TotalSegmentator-generated ROIs matching the specified criteria.
    /// - Parameters:
    ///   - viewer: The viewer containing the ROIs to update.
    ///   - labelNames: Label names to filter ROIs by; an empty set matches all ROIs with the specified comment.
    ///   - roiComment: The provenance comment identifying TotalSegmentator ROIs.
    /// - Returns: The number of ROIs that had opacity applied.
    @discardableResult
    fileprivate func applyTotalSegmentatorROIOpacity(in viewer: ViewerController, labelNames: Set<String>, roiComment: String) -> Int {
        guard let roiSeriesList = viewer.roiList() else {
            return 0
        }

        var updatedCount = 0
        for case let sliceList as NSArray in roiSeriesList {
            for element in sliceList where isTotalSegmentatorROI(element, labelNames: labelNames, roiComment: roiComment) {
                guard let roi = element as? ROI else {
                    continue
                }
                roi.setOpacity(totalSegmentatorROIDisplayOpacity, globally: false)
                updatedCount += 1
            }
        }

        return updatedCount
    }

    /// Removes duplicate TotalSegmentator ROIs and applies opacity across compatible displayed viewers.
    /// - Returns: The total count of ROI duplicates removed.
    @discardableResult
    fileprivate func deduplicateDisplayedTotalSegmentatorROIs(labelNames: Set<String>, jobManifest: SegmentationJobManifest, roiComment: String) -> Int {
        let displayedViewers = compatibleDisplayedSourceViewers(for: jobManifest)
        var removedCount = 0

        for viewer in displayedViewers {
            let removedFromViewer = deduplicateTotalSegmentatorROIs(in: viewer, labelNames: labelNames, roiComment: roiComment)
            let opacityUpdatedCount = applyTotalSegmentatorROIOpacity(in: viewer, labelNames: labelNames, roiComment: roiComment)
            guard removedFromViewer > 0 || opacityUpdatedCount > 0 else {
                continue
            }

            removedCount += removedFromViewer
            persistROIs(from: viewer)
            viewer.refresh()
            viewer.needsDisplayUpdate()
        }

        return removedCount
    }

    /// Extracts TotalSegmentator label names from a volumetric ROI manifest.
    /// - Returns: A set of trimmed, non-empty label names; an empty set if the manifest is unavailable or invalid.
    fileprivate func totalSegmentatorLabelNames(from manifestPath: String?) -> Set<String> {
        guard let manifestPath, !manifestPath.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let labels = json["labels"] as? [[String: Any]] else {
            return []
        }

        return Set(labels.compactMap { label in
            (label["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
    }

    /// Determines whether an ROI element is a TotalSegmentator-generated ROI matching the specified provenance comment and label criteria.
    /// - Parameters:
    ///   - element: The ROI element to evaluate.
    ///   - labelNames: A set of acceptable label names; an empty set accepts any name.
    ///   - roiComment: The expected ROI provenance comment.
    /// - Returns: `true` if the element's comments match `roiComment` and its name satisfies the label filter, `false` otherwise.
    fileprivate func isTotalSegmentatorROI(_ element: Any, labelNames: Set<String>, roiComment: String) -> Bool {
        let comments = stringValue(forKey: "comments", from: element)
        guard comments == roiComment else {
            return false
        }

        guard let name = stringValue(forKey: "name", from: element) else {
            return labelNames.isEmpty
        }

        return labelNames.isEmpty || labelNames.contains(where: { $0 == name })
    }

    /// Determines whether a viewer contains any TotalSegmentator ROIs matching the given criteria.
    /// - Parameters:
    ///   - labelNames: ROI label names to match; if empty, all TotalSegmentator ROIs are considered.
    ///   - roiComment: The provenance comment identifying TotalSegmentator ROIs.
    /// - Returns: `true` if any matching TotalSegmentator ROIs are present, `false` otherwise.
    fileprivate func viewerHasTotalSegmentatorROIs(_ viewer: ViewerController, labelNames: Set<String>, roiComment: String) -> Bool {
        guard let roiSeriesList = viewer.roiList() else {
            return false
        }

        for case let sliceList as NSArray in roiSeriesList {
            for roi in sliceList {
                if isTotalSegmentatorROI(roi, labelNames: labelNames, roiComment: roiComment) {
                    return true
                }
            }
        }

        return false
    }

    /// Prepares a volumetric projection request from viewer geometry and segmentation manifest.
    /// - Parameters:
    ///   - viewer: The viewer providing plane geometry.
    ///   - manifestPath: Path to the volumetric manifest JSON.
    ///   - executable: The Python executable for projection.
    /// - Returns: A volumetric projection request with prepared artifacts, or `nil` if manifest validation fails, geometry cannot be extracted, or artifact preparation encounters an error.
    fileprivate func makeVolumetricProjectionRequest(
        viewer: ViewerController,
        manifestPath: String,
        executable: ExecutableResolution
    ) -> VolumetricProjectionRequest? {
        guard !manifestPath.isEmpty,
              let manifest = volumetricManifest(at: manifestPath),
              let sourcePath = manifest["source_segmentation_path"] as? String,
              !sourcePath.isEmpty,
              FileManager.default.fileExists(atPath: sourcePath) else {
            return nil
        }

        let planes = viewerGeometryPlanes(for: viewer)
        guard !planes.isEmpty,
              let planeData = try? JSONSerialization.data(withJSONObject: planes, options: [.sortedKeys]) else {
            return nil
        }

        let geometryHash = SHA256.hash(data: planeData)
            .map { String(format: "%02x", $0) }
            .joined()
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let roiRoot = manifestURL.deletingLastPathComponent()
        let outputDirectory = roiRoot
            .appendingPathComponent("projections", isDirectory: true)
            .appendingPathComponent(geometryHash, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let scriptURL = try prepareVolumetricProjectionScript(at: outputDirectory)
            let configurationURL = try writeVolumetricProjectionConfiguration(
                to: outputDirectory,
                manifestPath: manifestPath,
                outputDirectory: outputDirectory,
                planes: planes
            )
            let resultURL = outputDirectory.appendingPathComponent(
                "TotalSegmentatorVolumetricProjectionResult.json",
                isDirectory: false
            )
            return VolumetricProjectionRequest(
                scriptURL: scriptURL,
                configurationURL: configurationURL,
                resultURL: resultURL,
                executable: executable,
                geometryHash: geometryHash
            )
        } catch {
            logToConsole("Failed to prepare volumetric ROI projection: \(error.localizedDescription)")
            return nil
        }
    }

    /// Generates a volumetric projection manifest from a projection request.
    /// - Parameter request: The projection configuration and paths.
    /// - Returns: The path to the generated volumetric projection manifest, or nil if generation failed.
    fileprivate func generateProjectedVolumetricManifest(request: VolumetricProjectionRequest) -> String? {
        let result = runPythonProcess(
            using: request.executable,
            arguments: [
                request.scriptURL.path,
                "--config",
                request.configurationURL.path,
                "--result",
                request.resultURL.path
            ],
            progressController: nil
        )

        if let error = result.error {
            logToConsole("Volumetric ROI projection failed: \(error.localizedDescription)")
            return nil
        }

        guard result.terminationStatus == 0 else {
            if FileManager.default.fileExists(atPath: request.resultURL.path) {
                do {
                    _ = try readBridgeResult(from: request.resultURL, expectedStage: "volumetric_projection")
                } catch {
                    logToConsole("Volumetric ROI projection failed: \(error.localizedDescription)")
                    return nil
                }
            }
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            logToConsole("Volumetric ROI projection failed with status \(result.terminationStatus): \(stderr)")
            return nil
        }

        guard let payload = try? readBridgeResult(from: request.resultURL, expectedStage: "volumetric_projection"),
              let manifestPath = payload["manifest_path"] as? String,
              !manifestPath.isEmpty else {
            logToConsole("Volumetric ROI projection returned an invalid response.")
            return nil
        }

        return manifestPath
    }

    fileprivate func viewerGeometryPlanes(for viewer: ViewerController) -> [[String: Any]] {
        guard let pixList = viewer.pixList() else {
            return []
        }

        var planes: [[String: Any]] = []
        planes.reserveCapacity(pixList.count)

        for (index, element) in pixList.enumerated() {
            guard let pix = element as? DCMPix else {
                continue
            }

            var orientation = [Double](repeating: 0, count: 9)
            orientation.withUnsafeMutableBufferPointer { buffer in
                pix.orientationDouble(buffer.baseAddress)
            }

            let rowCosine = Array(orientation[0..<3])
            let columnCosine = Array(orientation[3..<6])
            let rows = Int(pix.pheight)
            let columns = Int(pix.pwidth)
            guard rows > 0, columns > 0 else {
                continue
            }

            planes.append([
                "slice_index": index,
                "sop_instance_uid": "viewer_slice_\(index)",
                "rows": rows,
                "columns": columns,
                "row_spacing": Double(pix.pixelSpacingY),
                "column_spacing": Double(pix.pixelSpacingX),
                "image_position": [Double(pix.originX), Double(pix.originY), Double(pix.originZ)],
                "row_cosine": rowCosine,
                "column_cosine": columnCosine
            ])
        }

        return planes
    }

    /// Checks whether the displayed viewer planes still match the original exported source geometry.
    fileprivate func viewerGeometryMatchesSource(_ viewer: ViewerController, jobManifest: SegmentationJobManifest) -> Bool {
        let planes = viewerGeometryPlanes(for: viewer)
        guard !planes.isEmpty,
              let firstPlane = planes.first else {
            return false
        }

        if let expectedFrameCount = jobManifest.geometry.numberOfFrames,
           planes.count != expectedFrameCount {
            return false
        }

        if let expectedRows = jobManifest.geometry.rows,
           (firstPlane["rows"] as? Int) != expectedRows {
            return false
        }

        if let expectedColumns = jobManifest.geometry.columns,
           (firstPlane["columns"] as? Int) != expectedColumns {
            return false
        }

        if let expectedPixelSpacing = jobManifest.geometry.pixelSpacing,
           expectedPixelSpacing.count == 2 {
            guard let rowSpacing = firstPlane["row_spacing"] as? Double,
                  let columnSpacing = firstPlane["column_spacing"] as? Double,
                  approximatelyEqual(rowSpacing, expectedPixelSpacing[0]),
                  approximatelyEqual(columnSpacing, expectedPixelSpacing[1]) else {
                return false
            }
        }

        if let expectedOrientation = jobManifest.geometry.imageOrientationPatient,
           expectedOrientation.count >= 6 {
            guard let rowCosine = firstPlane["row_cosine"] as? [Double],
                  let columnCosine = firstPlane["column_cosine"] as? [Double],
                  vectorsApproximatelyEqual(rowCosine, Array(expectedOrientation[0..<3])),
                  vectorsApproximatelyEqual(columnCosine, Array(expectedOrientation[3..<6])) else {
                return false
            }
        }

        return true
    }

    private func approximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private func vectorsApproximatelyEqual(_ lhs: [Double], _ rhs: [Double], tolerance: Double = 0.001) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        return zip(lhs, rhs).allSatisfy { approximatelyEqual($0, $1, tolerance: tolerance) }
    }

    /// Loads a JSON file and returns its contents as a dictionary.
    /// - Returns: A dictionary representation of the JSON file contents, or `nil` if the file cannot be read or is not valid JSON.
    private func volumetricManifest(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// Normalizes a string by removing leading and trailing whitespace, returning `nil` if empty.
    /// - Returns: The trimmed string, or `nil` if the input is empty or contains only whitespace.
    private func normalizedViewerString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Extracts the SOP Instance UID from a DICOM object.
    /// - Parameter object: The DICOM object or image to query.
    /// - Returns: The SOP Instance UID from the object, or `nil` if not found or empty after normalization.
    private func sopInstanceUID(from object: Any) -> String? {
        if let image = object as? DicomImage {
            return normalizedViewerString(image.sopInstanceUID())
                ?? normalizedViewerString(image.value(forKey: "sopInstanceUID") as? String)
                ?? normalizedViewerString(image.value(forKey: "UID") as? String)
        }

        return stringValue(forAnyKey: ["sopInstanceUID", "SOPInstanceUID", "sopInstanceUid", "UID"], from: object)
    }

    /// Extracts the Study Instance UID from a DICOM object.
    /// - Parameter object: The DICOM object to extract the UID from.
    /// - Returns: The Study Instance UID if present, nil otherwise.
    private func studyInstanceUID(from object: Any) -> String? {
        if let image = object as? DicomImage {
            return normalizedViewerString(image.series?.study?.studyInstanceUID)
        }

        return stringValue(forAnyKey: ["studyInstanceUID", "StudyInstanceUID"], from: object)
    }

    /// Extracts the series instance UID from an object, trying type-specific pathways before falling back to key-based lookup.
    /// - Returns: The series instance UID, or `nil` if not found or empty.
    private func seriesInstanceUID(from object: Any) -> String? {
        if let image = object as? DicomImage {
            return normalizedViewerString(image.series?.seriesInstanceUID)
                ?? normalizedViewerString(image.value(forKey: "seriesInstanceUID") as? String)
        }

        return stringValue(forAnyKey: ["seriesInstanceUID", "SeriesInstanceUID"], from: object)
    }

    /// Extracts a string value from an object by trying multiple keys.
    /// - Parameters:
    ///   - keys: Keys to attempt in order.
    ///   - object: The object from which to extract the value.
    /// - Returns: The first string value found, or `nil` if no keys yield a value.
    private func stringValue(forAnyKey keys: [String], from object: Any) -> String? {
        for key in keys {
            if let value = stringValue(forKey: key, from: object) {
                return value
            }
        }
        return nil
    }

    /// Extracts a normalized string value from an object using key-value coding.
    /// - Parameters:
    ///   - key: The property key to access via KVC.
    ///   - object: The object from which to extract the value.
    /// - Returns: A non-empty trimmed string value, or nil if the key is not accessible, the value is not a string, or the string is empty after trimming.
    private func stringValue(forKey key: String, from object: Any) -> String? {
        guard let object = object as? NSObject else {
            return nil
        }
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else {
            return nil
        }
        return normalizedViewerString(object.value(forKey: key) as? String)
    }

    /// Validates that segmentation output contains required artifacts.
    ///
    /// Checks for the presence of at least one NIfTI artifact. If the job requires canonical
    /// multilabel output, also verifies that `segmentation.nii.gz` and `label-map.json` exist.
    ///
    /// - Parameters:
    ///   - outputDirectory: The directory containing segmentation output artifacts.
    ///   - jobManifest: The job manifest used to determine additional validation requirements.
    /// - Returns: Array of validated artifact records from the output directory.
    /// - Throws: `SegmentationValidationError` if required artifacts are missing.
    func validateSegmentationOutput(at outputDirectory: URL, for jobManifest: SegmentationJobManifest) throws -> [SegmentationArtifactRecord] {
        let artifacts = try collectValidatedRunArtifacts(in: outputDirectory, rootDirectory: outputDirectory)
        let niftiArtifacts = artifacts.filter { $0.kind == "nifti" }
        guard !niftiArtifacts.isEmpty else {
            throw SegmentationValidationError.expectedArtifactMissing("NIfTI segmentation")
        }

        if requiresCanonicalMultilabelOutput(for: jobManifest) {
            guard FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("segmentation.nii.gz").path) else {
                throw SegmentationValidationError.expectedArtifactMissing("segmentation.nii.gz")
            }
            guard FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("label-map.json").path) else {
                throw SegmentationValidationError.expectedArtifactMissing("label-map.json")
            }
        }

        return artifacts
    }

    /// Checks whether the task supports multilabel output based on its capability.
    /// - Returns: `true` if the task supports multilabel, `false` otherwise.
    private func requiresCanonicalMultilabelOutput(for jobManifest: SegmentationJobManifest) -> Bool {
        guard let taskIdentifier = jobManifest.runSnapshot?.capabilityTaskIdentifier else {
            return Self.taskCapabilityManifest.capability(for: nil)?.supportsMultilabel == true
        }
        return Self.taskCapabilityManifest.capability(for: taskIdentifier)?.supportsMultilabel == true
    }

    /// Collects and validates output artifacts from a segmentation run.
    /// - Parameters:
    ///   - rootDirectory: The root directory used to compute relative artifact paths.
    /// - Returns: An array of validated artifact records, sorted by relative path.
    /// - Throws: `SegmentationValidationError` if the output directory is missing, any artifact is empty, or no artifacts are found.
    func collectValidatedRunArtifacts(in outputDirectory: URL, rootDirectory: URL) throws -> [SegmentationArtifactRecord] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: outputDirectory.path) else {
            throw SegmentationValidationError.outputDirectoryMissing
        }

        let enumerator = fileManager.enumerator(
            at: outputDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var artifacts: [SegmentationArtifactRecord] = []
        while let element = enumerator?.nextObject() as? URL {
            guard let values = try? element.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }

            let relativePath = relativeRunArtifactPath(from: rootDirectory, to: element)
            let byteCount = Int64(values.fileSize ?? 0)
            if byteCount <= 0 {
                throw SegmentationValidationError.outputArtifactEmpty(relativePath)
            }

            artifacts.append(
                SegmentationArtifactRecord(
                    relativePath: relativePath,
                    kind: runArtifactKind(for: element),
                    sha256: try sha256ForRunArtifact(of: element),
                    byteCount: byteCount
                )
            )
        }

        guard !artifacts.isEmpty else {
            throw SegmentationValidationError.outputDirectoryEmpty
        }

        return artifacts.sorted { $0.relativePath < $1.relativePath }
    }

    /// Persists segmentation run completion metadata to a JSON file.
    /// - Parameters:
    ///   - jobManifest: The segmentation job metadata to include in the manifest.
    ///   - outputDirectory: The output directory path for reference in the manifest.
    ///   - completionManifestURL: The file location where the manifest JSON will be written.
    ///   - artifacts: The segmentation artifacts to include in the manifest.
    /// - Returns: The constructed completion manifest.
    /// - Throws: If JSON encoding or file writing fails.
    @discardableResult
    func persistRunCompletionManifest(
        for jobManifest: SegmentationJobManifest,
        outputDirectory: URL,
        completionManifestURL: URL,
        artifacts: [SegmentationArtifactRecord]
    ) throws -> SegmentationRunCompletionManifest {
        let manifest = SegmentationRunCompletionManifest(
            schemaVersion: SegmentationRunCompletionManifest.currentSchemaVersion,
            completedAt: Date(),
            jobUUID: jobManifest.jobUUID,
            sourceIdentityHash: jobManifest.sourceIdentityHash,
            validationVersion: "nifti-output-v1",
            outputDirectory: outputDirectory.path,
            artifactCount: artifacts.count,
            artifacts: artifacts
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: completionManifestURL, options: .atomic)
        return manifest
    }

    /// Determines the artifact type classification for a file.
    /// - Returns: The artifact type as a string: `"label-map"`, `"nifti"`, `"rtstruct"`, `"dicom"`, `"volumetric-roi-manifest"`, `"volumetric-roi-mask"`, or `"derived"`.
    private func runArtifactKind(for url: URL) -> String {
        if url.lastPathComponent == "label-map.json" {
            return "label-map"
        }

        if isLikelyNiftiFile(at: url) {
            return "nifti"
        }

        if url.lastPathComponent == "manifest.json", url.path.contains("volumetric_rois") {
            return "volumetric-roi-manifest"
        }

        if url.pathExtension.lowercased() == "raw" {
            return "volumetric-roi-mask"
        }

        if isLikelyDicomFile(at: url) {
            if isLikelyRTStruct(at: url) {
                return "rtstruct"
            }
            return "dicom"
        }

        return "derived"
    }

    /// Computes the relative path from a root directory to a file.
    /// - Parameters:
    ///   - rootDirectory: The root directory to compute the path relative to.
    ///   - fileURL: The file URL to make relative.
    /// - Returns: The relative path if the file is under the root directory; otherwise the file's last path component.
    private func relativeRunArtifactPath(from rootDirectory: URL, to fileURL: URL) -> String {
        let rootPath = rootDirectory.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return fileURL.lastPathComponent
    }

    /// Computes the SHA256 hash of a file.
    /// - Parameter fileURL: The URL of the file to hash.
    /// - Returns: The hash as a lowercase hexadecimal string.
    /// - Throws: File I/O errors during reading.
    private func sha256ForRunArtifact(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Translates a process error output and exit status into a user-friendly error message.
    /// - Parameters:
    ///   - output: The process error output or stderr.
    ///   - status: The process exit status code.
    /// - Returns: A user-facing error message describing the failure.
    func translateErrorOutput(_ output: String, status: Int32) -> String {
        let lowercased = output.lowercased()

        if lowercased.contains("no module named") || lowercased.contains("command not found") {
            return "TotalSegmentator could not be executed. Please verify the Python environment and executable path."
        }

        if lowercased.contains("weights") {
            return "The required model weights were not found. Please download them using TotalSegmentator's CLI before running the plugin."
        }

        if lowercased.contains("license") {
            return "A TotalSegmentator license is required for this task. Please configure your license and try again."
        }

        if lowercased.contains("permission denied") {
            return "The configured TotalSegmentator executable is not readable or lacks execution permissions."
        }

        return "Segmentation failed (status \(status)). Please review the TotalSegmentator logs for more details."
    }

    private func isLikelyDicomFile(at url: URL) -> Bool {
        if DicomFile.isDICOMFile(url.path) {
            return true
        }

        let ext = url.pathExtension.lowercased()
        return ext == "dcm" || ext == "dicom"
    }

    private func isLikelyNiftiFile(at url: URL) -> Bool {
        if DicomFile.isNIfTIFile(url.path) {
            return true
        }

        let lowercased = url.lastPathComponent.lowercased()
        return lowercased.hasSuffix(".nii") || lowercased.hasSuffix(".nii.gz")
    }

    private func isLikelyRTStruct(at url: URL) -> Bool {
        let dicomIndicatesRTStruct: Bool = autoreleasepool(invoking: { () -> Bool in
            guard let dicomFile = DicomFile(url.path) else {
                return false
            }

            if dicomFile.getDicomFile() != 0 {
                return false
            }

            guard let elements = dicomFile.dicomElements() as? [AnyHashable: Any] else {
                return false
            }

            if let sopClassUID = elements["SOPClassUID"] as? String,
               sopClassUID == "1.2.840.10008.5.1.4.1.1.481.3" {
                return true
            }

            if let modality = (elements["Modality"] ?? elements["modality"]) as? String,
               modality.uppercased() == "RTSTRUCT" {
                return true
            }

            if let description = (elements["SeriesDescription"] ?? elements["seriesDescription"]) as? String {
                let normalized = description.lowercased()
                if normalized.contains("rtstruct") || normalized.contains("rt struct") {
                    return true
                }
            }

            return false
        })

        if dicomIndicatesRTStruct {
            return true
        }

        return url.lastPathComponent.lowercased().contains("rtstruct")
    }
}

struct VolumetricProjectionRequest {
    let scriptURL: URL
    let configurationURL: URL
    let resultURL: URL
    let executable: ExecutableResolution
    let geometryHash: String
}

final class TotalSegmentatorROIResyncCoordinator {
    static let generatedROICommentPrefix = "Generated by TotalSegmentator volumetric ROI importer"
    static let generatedROIComment = generatedROICommentPrefix

    private final class Context {
        var viewer: ViewerController?
        let owner: TotalSegmentatorHorosPlugin
        let importResult: SegmentationImportResult
        let executable: ExecutableResolution
        let jobManifest: SegmentationJobManifest
        let labelNames: Set<String>
        let expectedROIComment: String
        var lastProjectionGeometryHash: String?
        var projectionInProgress = false

        init(
            viewer: ViewerController,
            owner: TotalSegmentatorHorosPlugin,
            importResult: SegmentationImportResult,
            executable: ExecutableResolution,
            jobManifest: SegmentationJobManifest,
            labelNames: Set<String>
        ) {
            self.viewer = viewer
            self.owner = owner
            self.importResult = importResult
            self.executable = executable
            self.jobManifest = jobManifest
            self.labelNames = labelNames
            self.expectedROIComment = owner.roiProvenanceComment(for: jobManifest)
        }
    }

    private let projectionQueue = DispatchQueue(label: "org.totalsegmentator.horos.roi-resync", qos: .utility)
    private var context: Context?
    private var observerTokens: [NSObjectProtocol] = []
    private var pendingResync: DispatchWorkItem?
    private var lostROIProbeTimer: DispatchSourceTimer?
    private var forcedResyncViewer: ViewerController?

    /// Initializes ROI resynchronization coordination with the given viewer and segmentation context.
    ///
    /// Sets up continuous monitoring for lost ROIs across compatible viewers and starts periodic probing to maintain ROI overlay consistency.
    ///
    /// - Parameters:
    ///   - viewer: The viewer to track and resynchronize ROIs for.
    ///   - importResult: The result of the volumetric ROI import, containing the manifest path and imported metadata.
    ///   - executable: The resolved Python executable for running projection operations.
    ///   - jobManifest: The segmentation job metadata for viewer identity validation.
    ///   - owner: The plugin instance responsible for ROI operations.
    func register(
        viewer: ViewerController,
        importResult: SegmentationImportResult,
        executable: ExecutableResolution,
        jobManifest: SegmentationJobManifest,
        owner: TotalSegmentatorHorosPlugin
    ) {
        let labels = owner.totalSegmentatorLabelNames(from: importResult.volumetricROIManifestPath)
        context = Context(
            viewer: viewer,
            owner: owner,
            importResult: importResult,
            executable: executable,
            jobManifest: jobManifest,
            labelNames: labels
        )
        startObservingIfNeeded()
        startLostROIProbeIfNeeded()
    }

    private func startObservingIfNeeded() {
        guard observerTokens.isEmpty else {
            return
        }

        let center = NotificationCenter.default
        let names = [
            NSNotification.Name.OsirixLLMPRReslice,
            NSNotification.Name.OsirixViewerDidChange,
            NSNotification.Name.OsirixViewerControllerDidLoadImages,
            NSNotification.Name.OsirixDCMViewIndexChanged,
            NSNotification.Name.OsirixDCMUpdateCurrentImage,
            NSNotification.Name.OsirixUpdateView,
            NSNotification.Name.OsirixCloseViewer,
            NSWindow.didBecomeKeyNotification
        ]

        observerTokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handle(notification)
            }
        }
    }

    private func stopObserving() {
        let center = NotificationCenter.default
        observerTokens.forEach { center.removeObserver($0) }
        observerTokens.removeAll()
        pendingResync?.cancel()
        pendingResync = nil
        forcedResyncViewer = nil
        lostROIProbeTimer?.cancel()
        lostROIProbeTimer = nil
    }

    private func startLostROIProbeIfNeeded() {
        guard lostROIProbeTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.probeForLostROIs()
        }
        timer.resume()
        lostROIProbeTimer = timer
    }

    /// Processes notifications to maintain viewer lifecycle and trigger ROI resynchronization.
    ///
    /// Handles viewer closure by reassigning to a compatible viewer when the current viewer or its window closes. For other notifications, schedules resynchronization. Stops observing and clears state when the context becomes invalid or no compatible viewers remain.
    private func handle(_ notification: Notification) {
        guard let context else {
            stopObserving()
            return
        }

        if notification.name == NSNotification.Name.OsirixCloseViewer {
            let compatibleViewers = context.owner.compatibleDisplayedSourceViewers(for: context.jobManifest)
            guard !compatibleViewers.isEmpty else {
                self.context = nil
                stopObserving()
                return
            }

            if let object = notification.object as AnyObject? {
                if let viewer = context.viewer,
                   object === viewer {
                    context.viewer = compatibleViewers.first
                    if context.viewer != nil {
                        scheduleResync()
                    }
                    return
                }

                if let window = object as? NSWindow,
                   let viewerWindow = context.viewer?.window,
                   window === viewerWindow {
                    context.viewer = compatibleViewers.first
                    if context.viewer != nil {
                        scheduleResync()
                    }
                    return
                }
            }
            return
        }

        scheduleResync()
    }

    /// Checks compatible displayed viewers for missing TotalSegmentator ROIs and schedules resynchronization when detected.
    private func probeForLostROIs() {
        guard let context else {
            stopObserving()
            return
        }

        let owner = context.owner
        let displayedViewers = owner.compatibleDisplayedSourceViewers(for: context.jobManifest)

        for viewer in displayedViewers where !owner.viewerHasTotalSegmentatorROIs(viewer, labelNames: context.labelNames, roiComment: context.expectedROIComment) {
            scheduleResync(targetViewer: viewer)
            return
        }

        guard let viewer = currentViewer(for: context) else {
            return
        }

        if !owner.viewerHasTotalSegmentatorROIs(viewer, labelNames: context.labelNames, roiComment: context.expectedROIComment) {
            scheduleResync(targetViewer: viewer)
        }
    }

    /// Determines the active viewer for resynchronization.
    /// - Returns: The active viewer, or `nil` if no compatible displayed viewers exist. Updates `context.viewer` when assigning a different viewer.
    private func currentViewer(for context: Context) -> ViewerController? {
        let displayedViewers = (ViewerController.getDisplayed2DViewers() as? [ViewerController]) ?? []

        if let viewer = context.viewer,
           displayedViewers.contains(where: { $0 === viewer }) {
            return viewer
        }

        if let firstCompatible = displayedViewers.first(where: {
            context.owner.viewerSeriesIdentityMatch(for: $0, jobManifest: context.jobManifest).isCompatible
        }) {
            context.viewer = firstCompatible
            return firstCompatible
        }

        return nil
    }

    /// Schedules a resynchronization of ROI overlays.
    /// - Parameter targetViewer: If provided, uses this viewer as the resynchronization target instead of automatically selecting one.
    private func scheduleResync(targetViewer: ViewerController? = nil) {
        if let targetViewer {
            forcedResyncViewer = targetViewer
            context?.viewer = targetViewer
        }

        pendingResync?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.resync()
        }
        pendingResync = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// Restores ROI consistency in a viewer by reloading, deduplicating, and persisting TotalSegmentator ROIs, including volumetric import if necessary.
    private func resync() {
        guard let context else {
            stopObserving()
            return
        }

        let targetViewer = forcedResyncViewer
        forcedResyncViewer = nil

        guard let viewer = targetViewer ?? currentViewer(for: context) else {
            self.context = nil
            stopObserving()
            return
        }
        let owner = context.owner

        guard let manifestPath = context.importResult.volumetricROIManifestPath,
              !manifestPath.isEmpty else {
            return
        }

        let sourceMatch = owner.viewerSeriesIdentityMatch(for: viewer, jobManifest: context.jobManifest)
        guard sourceMatch.isCompatible else {
            resyncProjectedROIs(for: viewer, manifestPath: manifestPath, context: context)
            return
        }

        if !owner.viewerGeometryMatchesSource(viewer, jobManifest: context.jobManifest) {
            resyncProjectedROIs(for: viewer, manifestPath: manifestPath, context: context)
            return
        }

        owner.reloadROIs(in: viewer)
        owner.deduplicateTotalSegmentatorROIs(in: viewer, labelNames: context.labelNames, roiComment: context.expectedROIComment)
        owner.applyTotalSegmentatorROIOpacity(in: viewer, labelNames: context.labelNames, roiComment: context.expectedROIComment)
        viewer.refresh()
        viewer.needsDisplayUpdate()

        if owner.viewerHasTotalSegmentatorROIs(viewer, labelNames: context.labelNames, roiComment: context.expectedROIComment) {
            owner.persistROIs(from: viewer)
            return
        }

        owner.removeTotalSegmentatorROIs(in: viewer, labelNames: context.labelNames, roiComment: context.expectedROIComment)
        importROIs(from: manifestPath, into: viewer, context: context)
    }

    private func resyncProjectedROIs(for viewer: ViewerController, manifestPath: String, context: Context) {
        let owner = context.owner
        guard let request = owner.makeVolumetricProjectionRequest(viewer: viewer, manifestPath: manifestPath, executable: context.executable) else {
            return
        }

        if context.lastProjectionGeometryHash == request.geometryHash,
           owner.viewerHasTotalSegmentatorROIs(viewer, labelNames: context.labelNames, roiComment: context.expectedROIComment) {
            owner.persistROIs(from: viewer)
            viewer.refresh()
            viewer.needsDisplayUpdate()
            return
        }

        guard !context.projectionInProgress else {
            return
        }

        context.projectionInProgress = true
        projectionQueue.async { [weak self, weak viewer] in
            let projectedManifestPath = context.owner.generateProjectedVolumetricManifest(request: request)

            DispatchQueue.main.async { [weak self, weak viewer] in
                guard let self, let viewer else {
                    return
                }
                guard let activeContext = self.context, activeContext === context else {
                    return
                }

                context.projectionInProgress = false
                guard let projectedManifestPath else {
                    return
                }

                if let currentRequest = context.owner.makeVolumetricProjectionRequest(viewer: viewer, manifestPath: manifestPath, executable: context.executable),
                   currentRequest.geometryHash != request.geometryHash {
                    self.scheduleResync(targetViewer: viewer)
                    return
                }

                context.lastProjectionGeometryHash = request.geometryHash
                context.owner.removeTotalSegmentatorROIs(in: viewer, labelNames: context.labelNames, roiComment: context.expectedROIComment)
                self.importROIs(from: projectedManifestPath, into: viewer, context: context)
            }
        }
    }

    private func importROIs(from manifestPath: String, into viewer: ViewerController, context: Context) {
        let owner = context.owner
        let summary = TSVolumetricROIImporter.importVolumetricROIs(fromManifest: manifestPath, into: viewer)
        let importedROICount = (summary["roi_count"] as? NSNumber)?.intValue ?? 0
        guard importedROICount > 0 else {
            return
        }

        context.viewer = viewer
        owner.deduplicateTotalSegmentatorROIs(in: viewer, labelNames: context.labelNames, roiComment: context.expectedROIComment)
        owner.applyTotalSegmentatorROIOpacity(in: viewer, labelNames: context.labelNames, roiComment: context.expectedROIComment)
        owner.persistROIs(from: viewer)
        viewer.refresh()
        viewer.needsDisplayUpdate()
    }
}
