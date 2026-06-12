//
// TotalSegmentatorHorosPlugin+Import.swift
// TotalSegmentator
//

import Cocoa
import CoreData
import CryptoKit

private let totalSegmentatorROIDisplayOpacity: Float = 0.30

extension TotalSegmentatorHorosPlugin {
    func integrateSegmentationOutput(
        at url: URL,
        outputType: SegmentationOutputType,
        exportContext: ExportResult,
        preferences: SegmentationPreferences.State,
        executable: ExecutableResolution,
        progressController: SegmentationProgressReporting?
    ) throws -> SegmentationImportResult {
        let normalizedOutput = outputType.description.uppercased()
        progressController?.append("Importing TotalSegmentator outputs (\(normalizedOutput))…")
        let importResult: SegmentationImportResult
        let auditOutputType: SegmentationOutputType
        let convertedFromNifti: Bool

        switch outputType {
        case .dicom:
            importResult = try importDicomOutputs(from: url)
            auditOutputType = .dicom
            convertedFromNifti = false
        case .nifti:
            let conversionOutput = try convertNiftiOutputsToDicom(
                from: url,
                exportContext: exportContext,
                preferences: preferences,
                executable: executable,
                progressController: progressController
            )
            importResult = try importDicomOutputs(
                from: conversionOutput.directory,
                volumetricROIManifestPath: conversionOutput.volumetricROIManifestPath
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

    private func importDicomOutputs(from directory: URL, volumetricROIManifestPath: String? = nil) throws -> SegmentationImportResult {
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
            volumetricROIManifestPath: volumetricROIManifestPath
        )
    }

    private struct NiftiConversionManifest: Decodable {
        let rtStructPaths: [String]
        let dicomSeriesDirectories: [String]
        let volumetricROIManifestPath: String?

        enum CodingKeys: String, CodingKey {
            case rtStructPaths = "rtstruct_paths"
            case dicomSeriesDirectories = "dicom_series_directories"
            case volumetricROIManifestPath = "volumetric_roi_manifest_path"
        }
    }

    private struct NiftiConversionOutput {
        let directory: URL
        let volumetricROIManifestPath: String?
    }

    private func convertNiftiOutputsToDicom(
        from directory: URL,
        exportContext: ExportResult,
        preferences: SegmentationPreferences.State,
        executable: ExecutableResolution,
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

        let scriptURL = try prepareNiftiConversionScript(at: directory)
        let configurationURL = try writeNiftiConversionConfiguration(
            to: directory,
            niftiDirectory: directory,
            referenceDirectory: referenceSeries.exportedDirectory,
            outputDirectory: conversionDirectory,
            preferences: preferences
        )

        let result = runPythonProcess(
            using: executable,
            arguments: [scriptURL.path, "--config", configurationURL.path],
            progressController: progressController
        )

        if let error = result.error {
            throw error
        }

        if result.terminationStatus != 0 {
            let stderrString = String(data: result.stderr, encoding: .utf8) ?? ""
            throw NiftiConversionError.scriptFailed(
                status: result.terminationStatus,
                stderr: stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        guard let stdoutString = String(data: result.stdout, encoding: .utf8) else {
            throw NiftiConversionError.responseParsingFailed
        }

        let meaningfulLines = stdoutString
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let lastLine = meaningfulLines.last,
              let manifestData = lastLine.data(using: .utf8) else {
            throw NiftiConversionError.responseParsingFailed
        }

        let manifest = try JSONDecoder().decode(NiftiConversionManifest.self, from: manifestData)

        let hasVolumetricManifest = manifest.volumetricROIManifestPath?.isEmpty == false
        if manifest.rtStructPaths.isEmpty && manifest.dicomSeriesDirectories.isEmpty && !hasVolumetricManifest {
            throw NiftiConversionError.noOutputsProduced
        }

        progressController?.append("Converted NIfTI segmentation output to DICOM-compatible artifacts.")
        logToConsole("Converted NIfTI segmentation output to DICOM-compatible artifacts at \(conversionDirectory.path)")

        return NiftiConversionOutput(
            directory: conversionDirectory,
            volumetricROIManifestPath: manifest.volumetricROIManifestPath
        )
    }

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
            volumetricROIManifestPath: nil
        )
    }

    private func updateVisualization(
        with importResult: SegmentationImportResult,
        exportContext: ExportResult,
        preferences: SegmentationPreferences.State,
        executable: ExecutableResolution,
        progressController: SegmentationProgressReporting?
    ) {
        let hasRTStructOverlays = importResult.outputType == .dicom && !importResult.rtStructPaths.isEmpty
        let hasVolumetricManifest = importResult.volumetricROIManifestPath?.isEmpty == false

        guard hasRTStructOverlays || hasVolumetricManifest else {
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

            let viewer: ViewerController?
            if hasRTStructOverlays {
                viewer = self.preferredDisplayed2DViewer() ?? self.openViewer(for: exportContext, browser: browser)
            } else {
                viewer = self.openViewer(for: exportContext, browser: browser) ?? self.preferredDisplayed2DViewer()
            }

            guard let activeViewer = viewer else {
                progressController?.append("Unable to open a viewer for ROI overlay.")
                semaphore.signal()
                return
            }

            var importedVolumetricROICount = 0
            var importedVolumetricLabelCount = 0
            var skippedVolumetricSliceCount = 0
            var appliedOverlayCount = 0

            for path in importResult.rtStructPaths {
                if self.applyRTStructOverlay(from: path, to: activeViewer) {
                    appliedOverlayCount += 1
                } else {
                    let filename = URL(fileURLWithPath: path).lastPathComponent
                    progressController?.append("Failed to apply RT Struct overlay from \(filename).")
                    self.logToConsole("Failed to apply RT Struct overlay from \(path)")
                }
            }

            if appliedOverlayCount > 0 && hasVolumetricManifest {
                progressController?.append("RT Struct overlay applied; volumetric brush ROI import remains available as fallback but was not needed.")
            }

            if appliedOverlayCount == 0,
               let manifestPath = importResult.volumetricROIManifestPath,
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

            if importedVolumetricROICount == 0 && appliedOverlayCount == 0 {
                progressController?.append("No segmentation ROIs could be applied to the active viewer.")
                semaphore.signal()
                return
            }

            let finishVisualization: () -> Void = {
                let labelNames = self.totalSegmentatorLabelNames(from: importResult.volumetricROIManifestPath)
                if appliedOverlayCount > 0 {
                    self.reloadROIs(in: activeViewer)
                    self.deduplicateTotalSegmentatorROIs(in: activeViewer, labelNames: labelNames)
                    self.persistROIs(from: activeViewer)
                } else if importedVolumetricROICount > 0 {
                    self.deduplicateTotalSegmentatorROIs(in: activeViewer, labelNames: labelNames)
                    self.persistROIs(from: activeViewer)
                }

                let removedDuplicateROIs = self.deduplicateDisplayedTotalSegmentatorROIs(labelNames: labelNames)
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
                    owner: self
                )

                if importedVolumetricROICount > 0 {
                    progressController?.append("Stored volumetric brush ROIs in Horos.")
                } else {
                    progressController?.append("Applied \(appliedOverlayCount) RT Struct overlay(s) and stored the corresponding ROIs in Horos.")
                }

                semaphore.signal()
            }

            if appliedOverlayCount > 0 {
                progressController?.append("Waiting for Horos to finish converting RT Struct overlays into ROIs…")

                DispatchQueue.global(qos: .userInitiated).async {
                    let conversionCompleted = self.waitForRTStructConversionsToFinish(progressController: progressController)

                    DispatchQueue.main.async {
                        if conversionCompleted {
                            finishVisualization()
                        } else {
                            progressController?.append("Timed out while waiting for Horos to finish converting RT Struct overlays.")
                            self.logToConsole("Timed out while waiting for Horos to convert RT Struct overlays.")
                            semaphore.signal()
                        }
                    }
                }
            } else {
                finishVisualization()
            }
        }

        semaphore.wait()
    }

    private func openViewer(for exportContext: ExportResult, browser: BrowserController) -> ViewerController? {
        for exportedSeries in exportContext.series {
            if let viewer = browser.loadSeries(exportedSeries.series, nil, true, keyImagesOnly: false) {
                return viewer
            }
        }

        return nil
    }

    fileprivate func preferredDisplayed2DViewer() -> ViewerController? {
        let displayedViewers = (ViewerController.getDisplayed2DViewers() as? [ViewerController]) ?? []
        if let keyViewer = displayedViewers.first(where: { $0.window?.isKeyWindow == true }) {
            return keyViewer
        }

        return ViewerController.frontMostDisplayed2DViewer() ?? displayedViewers.first
    }

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

    @discardableResult
    fileprivate func deduplicateTotalSegmentatorROIs(in viewer: ViewerController, labelNames: Set<String>) -> Int {
        guard let roiSeriesList = viewer.roiList() else {
            return 0
        }

        var removedCount = 0
        for case let sliceList as NSMutableArray in roiSeriesList {
            var seenNames = Set<String>()
            var duplicateIndexes = IndexSet()

            for (index, element) in sliceList.enumerated() {
                let comments = stringValue(forKey: "comments", from: element)
                guard comments == TotalSegmentatorROIResyncCoordinator.generatedROIComment else {
                    continue
                }

                guard let name = stringValue(forKey: "name", from: element), !name.isEmpty else {
                    continue
                }

                if !labelNames.isEmpty && !labelNames.contains(name) {
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

    @discardableResult
    fileprivate func deduplicateDisplayedTotalSegmentatorROIs(labelNames: Set<String>) -> Int {
        let displayedViewers = (ViewerController.getDisplayed2DViewers() as? [ViewerController]) ?? []
        var removedCount = 0

        for viewer in displayedViewers {
            let removedFromViewer = deduplicateTotalSegmentatorROIs(in: viewer, labelNames: labelNames)
            guard removedFromViewer > 0 else {
                continue
            }

            removedCount += removedFromViewer
            persistROIs(from: viewer)
            viewer.refresh()
            viewer.needsDisplayUpdate()
        }

        return removedCount
    }

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

    fileprivate func viewerHasTotalSegmentatorROIs(_ viewer: ViewerController, labelNames: Set<String>) -> Bool {
        guard let roiSeriesList = viewer.roiList() else {
            return false
        }

        for case let sliceList as NSArray in roiSeriesList {
            for roi in sliceList {
                let name = stringValue(forKey: "name", from: roi)
                let comments = stringValue(forKey: "comments", from: roi)
                if comments == TotalSegmentatorROIResyncCoordinator.generatedROIComment {
                    return true
                }
                if let name, labelNames.contains(name) {
                    return true
                }
            }
        }

        return false
    }

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
            return VolumetricProjectionRequest(
                scriptURL: scriptURL,
                configurationURL: configurationURL,
                executable: executable,
                geometryHash: geometryHash
            )
        } catch {
            logToConsole("Failed to prepare volumetric ROI projection: \(error.localizedDescription)")
            return nil
        }
    }

    fileprivate func generateProjectedVolumetricManifest(request: VolumetricProjectionRequest) -> String? {
        let result = runPythonProcess(
            using: request.executable,
            arguments: [request.scriptURL.path, "--config", request.configurationURL.path],
            progressController: nil
        )

        if let error = result.error {
            logToConsole("Volumetric ROI projection failed: \(error.localizedDescription)")
            return nil
        }

        guard result.terminationStatus == 0,
              let stdout = String(data: result.stdout, encoding: .utf8) else {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            logToConsole("Volumetric ROI projection failed with status \(result.terminationStatus): \(stderr)")
            return nil
        }

        let lines = stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let lastLine = lines.last,
              let data = lastLine.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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

    private func volumetricManifest(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func stringValue(forKey key: String, from object: Any) -> String? {
        guard let object = object as? NSObject else {
            return nil
        }
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else {
            return nil
        }
        return object.value(forKey: key) as? String
    }

    func validateSegmentationOutput(at url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw SegmentationValidationError.outputDirectoryMissing
        }

        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])

        while let element = enumerator?.nextObject() as? URL {
            if let values = try? element.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true {
                return
            }
        }

        throw SegmentationValidationError.outputDirectoryEmpty
    }

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
    let executable: ExecutableResolution
    let geometryHash: String
}

final class TotalSegmentatorROIResyncCoordinator {
    static let generatedROIComment = "Generated by TotalSegmentator volumetric ROI importer"

    private final class Context {
        var viewer: ViewerController?
        let owner: TotalSegmentatorHorosPlugin
        let importResult: SegmentationImportResult
        let executable: ExecutableResolution
        let labelNames: Set<String>
        var lastProjectionGeometryHash: String?
        var projectionInProgress = false

        init(
            viewer: ViewerController,
            owner: TotalSegmentatorHorosPlugin,
            importResult: SegmentationImportResult,
            executable: ExecutableResolution,
            labelNames: Set<String>
        ) {
            self.viewer = viewer
            self.owner = owner
            self.importResult = importResult
            self.executable = executable
            self.labelNames = labelNames
        }
    }

    private let projectionQueue = DispatchQueue(label: "org.totalsegmentator.horos.roi-resync", qos: .utility)
    private var context: Context?
    private var observerTokens: [NSObjectProtocol] = []
    private var pendingResync: DispatchWorkItem?
    private var lostROIProbeTimer: DispatchSourceTimer?
    private var forcedResyncViewer: ViewerController?

    func register(
        viewer: ViewerController,
        importResult: SegmentationImportResult,
        executable: ExecutableResolution,
        owner: TotalSegmentatorHorosPlugin
    ) {
        let labels = owner.totalSegmentatorLabelNames(from: importResult.volumetricROIManifestPath)
        context = Context(
            viewer: viewer,
            owner: owner,
            importResult: importResult,
            executable: executable,
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
            NSNotification.Name.OsirixCloseViewer,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didUpdateNotification
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

    private func handle(_ notification: Notification) {
        guard let context else {
            stopObserving()
            return
        }

        if notification.name == NSNotification.Name.OsirixCloseViewer {
            let displayedViewers = (ViewerController.getDisplayed2DViewers() as? [ViewerController]) ?? []
            guard !displayedViewers.isEmpty else {
                self.context = nil
                stopObserving()
                return
            }

            if let object = notification.object as AnyObject? {
                if let viewer = context.viewer,
                   object === viewer {
                    context.viewer = displayedViewers.first
                    scheduleResync()
                    return
                }

                if let window = object as? NSWindow,
                   let viewerWindow = context.viewer?.window,
                   window === viewerWindow {
                    context.viewer = displayedViewers.first
                    scheduleResync()
                    return
                }
            }
            return
        }

        scheduleResync()
    }

    private func probeForLostROIs() {
        guard let context else {
            stopObserving()
            return
        }

        let owner = context.owner
        let displayedViewers = (ViewerController.getDisplayed2DViewers() as? [ViewerController]) ?? []

        for viewer in displayedViewers where !owner.viewerHasTotalSegmentatorROIs(viewer, labelNames: context.labelNames) {
            scheduleResync(targetViewer: viewer)
            return
        }

        guard let viewer = currentViewer(for: context) else {
            return
        }

        if !owner.viewerHasTotalSegmentatorROIs(viewer, labelNames: context.labelNames) {
            scheduleResync(targetViewer: viewer)
        }
    }

    private func currentViewer(for context: Context) -> ViewerController? {
        let displayedViewers = (ViewerController.getDisplayed2DViewers() as? [ViewerController]) ?? []

        if let keyViewer = displayedViewers.first(where: { $0.window?.isKeyWindow == true }) {
            context.viewer = keyViewer
            return keyViewer
        }

        if let frontMost = context.owner.preferredDisplayed2DViewer() {
            context.viewer = frontMost
            return frontMost
        }

        if let viewer = context.viewer,
           displayedViewers.contains(where: { $0 === viewer }) {
            return viewer
        }

        if let firstDisplayed = displayedViewers.first {
            context.viewer = firstDisplayed
            return firstDisplayed
        }

        return context.viewer
    }

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

        owner.reloadROIs(in: viewer)
        owner.deduplicateTotalSegmentatorROIs(in: viewer, labelNames: context.labelNames)
        viewer.refresh()
        viewer.needsDisplayUpdate()

        if owner.viewerHasTotalSegmentatorROIs(viewer, labelNames: context.labelNames) {
            owner.persistROIs(from: viewer)
            return
        }

        guard let manifestPath = context.importResult.volumetricROIManifestPath,
              let request = owner.makeVolumetricProjectionRequest(
                  viewer: viewer,
                  manifestPath: manifestPath,
                  executable: context.executable
              ) else {
            return
        }

        if context.projectionInProgress {
            return
        }

        context.projectionInProgress = true
        context.lastProjectionGeometryHash = request.geometryHash

        projectionQueue.async { [weak self, weak owner, weak viewer] in
            let projectedManifestPath = owner?.generateProjectedVolumetricManifest(request: request)

            DispatchQueue.main.async {
                guard let self,
                      let context = self.context,
                      let activeViewer = viewer else {
                    return
                }

                context.projectionInProgress = false
                let displayedViewers = (ViewerController.getDisplayed2DViewers() as? [ViewerController]) ?? []
                guard displayedViewers.contains(where: { $0 === activeViewer }) else {
                    return
                }

                guard let projectedManifestPath else {
                    return
                }

                context.viewer = activeViewer
                _ = TSVolumetricROIImporter.importVolumetricROIs(fromManifest: projectedManifestPath, into: activeViewer)
                context.owner.deduplicateTotalSegmentatorROIs(in: activeViewer, labelNames: context.labelNames)
                context.owner.persistROIs(from: activeViewer)
                activeViewer.refresh()
                activeViewer.needsDisplayUpdate()
            }
        }
    }
}
