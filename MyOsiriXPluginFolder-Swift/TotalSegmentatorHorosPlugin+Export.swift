//
// TotalSegmentatorHorosPlugin+Export.swift
// TotalSegmentator
//

import Cocoa
import CryptoKit

extension TotalSegmentatorHorosPlugin {
    private static let exportMaxConcurrentCopiesCap = 8

    private struct CopyFilesResult: Sendable {
        let copiedFiles: [URL]
        let newCopiesCount: Int
    }

    private struct ExportSourceInstance {
        let sourceURL: URL
        let sourcePathHash: String
        let sopInstanceUID: String
        let studyInstanceUID: String?
        let seriesInstanceUID: String?
        let frameOfReferenceUID: String?
        let modality: String
        let sourceOrderIndex: Int
        let dicomFrameID: Int?
        let frameCount: Int
        let rows: Int?
        let columns: Int?
        let sliceLocation: Double?
        let imagePositionPatient: [Double]?
        let imageOrientationPatient: [Double]?
        let sourceImage: DicomImage
    }

    private struct ValidatedExportedInstance {
        let destinationURL: URL
        let sourceFile: SegmentationJobSourceFile
        let exportInstance: DicomExportedInstance
    }

    private struct PreparedSeriesExport {
        let exportedSeries: ExportedSeries
        let sourceInstances: [ExportSourceInstance]
        let validatedInstances: [ValidatedExportedInstance]
    }

    private enum ExportCopyError: LocalizedError {
        case mismatchedSourceDestinationCounts
        case destinationCollision(String)
        case copiedFileMissing(String)
        case emptyExportedFile(String)

        var errorDescription: String? {
            switch self {
            case .mismatchedSourceDestinationCounts:
                return "The DICOM export source and destination counts do not match."
            case .destinationCollision(let name):
                return "The DICOM export destination '\(name)' already exists."
            case .copiedFileMissing(let name):
                return "The DICOM export destination '\(name)' was not created."
            case .emptyExportedFile(let name):
                return "The DICOM export destination '\(name)' is empty."
            }
        }
    }

    private enum SegmentationJobManifestError: LocalizedError {
        case missingSourceIdentity
        case missingSOPInstanceUID(Int)
        case duplicateSOPInstanceUID(String)
        case mixedStudyInstanceUID(String?)
        case mixedSeriesInstanceUID(String?)
        case mixedFrameOfReferenceUID(String?)
        case unsupportedDerivedSource(String)
        case inconsistentGeometry(String)

        var errorDescription: String? {
            switch self {
            case .missingSourceIdentity:
                return "Unable to create a segmentation job manifest because the source DICOM SOP Instance UIDs could not be resolved."
            case .missingSOPInstanceUID(let index):
                return "Unable to export DICOM instance \(index + 1) because its SOP Instance UID is missing."
            case .duplicateSOPInstanceUID(let uid):
                return "Unable to export DICOM series because SOP Instance UID '\(uid)' appears more than once."
            case .mixedStudyInstanceUID:
                return "Unable to export DICOM series because an instance belongs to a different study."
            case .mixedSeriesInstanceUID:
                return "Unable to export DICOM series because an instance belongs to a different series."
            case .mixedFrameOfReferenceUID:
                return "Unable to export DICOM series because an instance belongs to a different frame of reference."
            case .unsupportedDerivedSource(let reason):
                return "Unable to export DICOM series because the selected source is unsupported: \(reason)"
            case .inconsistentGeometry(let field):
                return "Unable to create a segmentation job manifest because the source DICOM \(field) values are inconsistent."
            }
        }
    }

    private final class CopyFilesTaskResult: @unchecked Sendable {
        private let condition = NSCondition()
        private var storedResult: Result<CopyFilesResult, Error>?

        func store(_ result: Result<CopyFilesResult, Error>) {
            condition.lock()
            storedResult = result
            condition.signal()
            condition.unlock()
        }

        func resolve() throws -> CopyFilesResult {
            condition.lock()
            while storedResult == nil {
                condition.wait()
            }

            let result = storedResult!
            condition.unlock()

            return try result.get()
        }
    }

    // Bounded parallelism: file copying is I/O bound; limiting concurrency avoids disk thrash
    // and excessive file descriptors while still speeding up large exports.
    private var exportMaxConcurrentCopies: Int {
        let cpuCount = max(ProcessInfo.processInfo.activeProcessorCount, 2)
        return min(cpuCount, Self.exportMaxConcurrentCopiesCap)
    }

    /// Copies a DICOM file to a specified destination.
    /// - Parameters:
    ///   - sourceURL: The source file to copy.
    ///   - destinationURL: The destination file path.
    /// - Returns: `true` if the file was copied.
    /// - Throws: `ExportCopyError.destinationCollision` if the destination already exists, or any error from the copy operation.
    @discardableResult
    private static func copyDicomFileIfNeeded(from sourceURL: URL, to destinationURL: URL) throws -> Bool {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            throw ExportCopyError.destinationCollision(destinationURL.lastPathComponent)
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return true
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == CocoaError.Code.fileWriteFileExists.rawValue {
                throw ExportCopyError.destinationCollision(destinationURL.lastPathComponent)
            }

            throw error
        }
    }

    private func copyFilesInParallel(sources sourceURLs: [URL], destinations destinationURLs: [URL]) throws -> CopyFilesResult {
        guard sourceURLs.count == destinationURLs.count else {
            throw ExportCopyError.mismatchedSourceDestinationCounts
        }

        let maxConcurrentCopies = exportMaxConcurrentCopies
        let resultBox = CopyFilesTaskResult()

        Task.detached(priority: .utility) {
            do {
                let result = try await Self.copyFilesInParallelAsync(
                    sources: sourceURLs,
                    destinations: destinationURLs,
                    maxConcurrentCopies: maxConcurrentCopies
                )
                resultBox.store(.success(result))
            } catch {
                resultBox.store(.failure(error))
            }
        }

        return try resultBox.resolve()
    }

    /// Concurrently copies DICOM files to destination URLs, respecting a maximum concurrency limit.
    /// - Returns: A result containing the list of copied file URLs and the count of newly created files.
    /// - Throws: `ExportCopyError` if a copy fails or validation cannot complete.
    private static func copyFilesInParallelAsync(
        sources sourceURLs: [URL],
        destinations destinationURLs: [URL],
        maxConcurrentCopies: Int
    ) async throws -> CopyFilesResult {
        let copyLimit = max(maxConcurrentCopies, 1)
        var copiedFiles = Array<URL?>(repeating: nil, count: destinationURLs.count)
        var newCopiesCount = 0
        var nextIndex = 0

        return try await withThrowingTaskGroup(of: (index: Int, destination: URL, didCreateFile: Bool).self) { group in
            func enqueueNextCopy() {
                let index = nextIndex
                nextIndex += 1

                let sourceURL = sourceURLs[index]
                let destinationURL = destinationURLs[index]

                group.addTask(priority: .utility) {
                    try Task.checkCancellation()
                    let didCreateFile = try copyDicomFileIfNeeded(from: sourceURL, to: destinationURL)
                    try Task.checkCancellation()
                    return (index, destinationURL, didCreateFile)
                }
            }

            let initialCopyCount = min(copyLimit, sourceURLs.count)
            for _ in 0..<initialCopyCount {
                enqueueNextCopy()
            }

            do {
                while let copyResult = try await group.next() {
                    copiedFiles[copyResult.index] = copyResult.destination
                    if copyResult.didCreateFile {
                        newCopiesCount += 1
                    }

                    if nextIndex < sourceURLs.count {
                        enqueueNextCopy()
                    }
                }
            } catch {
                group.cancelAll()
                throw error
            }

            return CopyFilesResult(
                copiedFiles: copiedFiles.compactMap { $0 },
                newCopiesCount: newCopiesCount
            )
        }
    }

    func exportActiveSeries(from viewer: ViewerController) throws -> ExportResult {
        enum ActiveSeriesExportError: LocalizedError {
            case missingSeries
            case unsupportedModality(String?)
            case missingSlices
            case exportFailed(underlying: Error)

            var errorDescription: String? {
                switch self {
                case .missingSeries:
                    return "The active viewer does not reference a DICOM series."
                case .unsupportedModality(let value):
                    if let value = value, !value.isEmpty {
                        return "The active series modality '\(value)' is not supported by TotalSegmentator."
                    }
                    return "The active series modality is not supported by TotalSegmentator."
                case .missingSlices:
                    return "Unable to locate the DICOM slices for the active series."
                case .exportFailed(let underlying):
                    return "Failed to export the active DICOM series: \(underlying.localizedDescription)"
                }
            }
        }

        let supportedModalities: Set<String> = ["CT", "MR"]

        guard let series = viewer.imageView()?.seriesObj() as? DicomSeries else {
            throw ActiveSeriesExportError.missingSeries
        }

        let rawModality = (series.modality as String?) ?? (series.value(forKey: "modality") as? String)
        let normalizedModality = rawModality?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).uppercased()

        guard let modality = normalizedModality, supportedModalities.contains(modality) else {
            throw ActiveSeriesExportError.unsupportedModality(normalizedModality)
        }

        let pixList = normalizePixList(viewer.imageView()?.dcmPixList)
        let sourceInstances = try makeExportSourceInstances(
            series: series,
            modality: modality,
            sourceImages: sortedImages(from: series),
            pixList: pixList
        )
        guard !sourceInstances.isEmpty else {
            throw ActiveSeriesExportError.missingSlices
        }

        let exportDirectory = try makeExportDirectory()
        do {
            let preparedSeries = try exportSeries(
                series: series,
                modality: modality,
                exportDirectory: exportDirectory,
                sourceInstances: sourceInstances
            )

            let exportManifestURL = exportDirectory.appendingPathComponent("dicom-export-manifest.json", isDirectory: false)
            let jobManifestURL = exportDirectory.appendingPathComponent("segmentation-job.json", isDirectory: false)
            let jobManifest = try makeSegmentationJobManifest(
                exportDirectory: exportDirectory,
                primarySeries: preparedSeries.exportedSeries,
                sourceInstances: preparedSeries.sourceInstances,
                validatedInstances: preparedSeries.validatedInstances,
                pixList: pixList,
                hostHints: makeHostHints(for: series, viewer: viewer)
            )
            let exportManifest = makeDicomExportManifest(
                jobManifest: jobManifest,
                validatedInstances: preparedSeries.validatedInstances
            )
            try persistDicomExportManifest(exportManifest, to: exportManifestURL)
            try persistSegmentationJobManifest(jobManifest, to: jobManifestURL)
            try persistExportCompletionMarker(
                exportManifest: exportManifest,
                exportManifestURL: exportManifestURL,
                in: exportDirectory
            )

            return ExportResult(
                directory: exportDirectory,
                series: [preparedSeries.exportedSeries],
                exportManifestURL: exportManifestURL,
                jobManifestURL: jobManifestURL,
                jobManifest: jobManifest
            )
        } catch {
            cleanupTemporaryDirectory(exportDirectory)
            throw ActiveSeriesExportError.exportFailed(underlying: error)
        }
    }

    private func exportCompatibleSeries(from study: DicomStudy) throws -> ExportResult {
        enum ExportError: LocalizedError {
            case noSeries
            case noCompatibleSeries
            case exportFailed(underlying: Error)

            var errorDescription: String? {
                switch self {
                case .noSeries:
                    return "The selected study does not contain any series to export."
                case .noCompatibleSeries:
                    return "The selected study does not contain CT or MR series compatible with TotalSegmentator."
                case .exportFailed(let underlying):
                    return "Failed to export DICOM files: \(underlying.localizedDescription)"
                }
            }
        }

        let supportedModalities: Set<String> = ["CT", "MR"]

        let seriesCollection = study.value(forKey: "series")
        let seriesArray = normalizeSeriesCollection(seriesCollection)

        guard !seriesArray.isEmpty else {
            throw ExportError.noSeries
        }

        let compatibleSeries = seriesArray.compactMap { series -> (series: DicomSeries, modality: String, paths: [String], sourceImages: [DicomImage])? in
            let rawModality = series.modality ?? (series.value(forKey: "modality") as? String)
            let normalizedModality = rawModality?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

            guard let modality = normalizedModality, supportedModalities.contains(modality) else {
                return nil
            }

            let sourceImages = sortedImages(from: series)
            let paths = orderedPaths(for: series, preferredImages: sourceImages)

            guard !paths.isEmpty else {
                return nil
            }

            return (series, modality, paths, sourceImages)
        }

        guard !compatibleSeries.isEmpty else {
            throw ExportError.noCompatibleSeries
        }

        let exportDirectory = try makeExportDirectory()

        var preparedSeries: [PreparedSeriesExport] = []

        do {
            for entry in compatibleSeries {
                let sourceInstances = try makeExportSourceInstances(
                    series: entry.series,
                    modality: entry.modality,
                    sourceImages: entry.sourceImages,
                    pixList: []
                )
                guard !sourceInstances.isEmpty else { continue }
                let seriesExport = try exportSeries(
                    series: entry.series,
                    modality: entry.modality,
                    exportDirectory: exportDirectory,
                    sourceInstances: sourceInstances
                )
                preparedSeries.append(seriesExport)
            }
        } catch {
            cleanupTemporaryDirectory(exportDirectory)
            throw ExportError.exportFailed(underlying: error)
        }

        guard !preparedSeries.isEmpty else {
            cleanupTemporaryDirectory(exportDirectory)
            throw ExportError.noCompatibleSeries
        }

        let primaryPreparedSeries = preparedSeries[0]

        do {
            let exportManifestURL = exportDirectory.appendingPathComponent("dicom-export-manifest.json", isDirectory: false)
            let jobManifestURL = exportDirectory.appendingPathComponent("segmentation-job.json", isDirectory: false)
            let jobManifest = try makeSegmentationJobManifest(
                exportDirectory: exportDirectory,
                primarySeries: primaryPreparedSeries.exportedSeries,
                sourceInstances: primaryPreparedSeries.sourceInstances,
                validatedInstances: primaryPreparedSeries.validatedInstances,
                pixList: [],
                hostHints: makeHostHints(for: primaryPreparedSeries.exportedSeries.series, viewer: nil)
            )
            let exportManifest = makeDicomExportManifest(
                jobManifest: jobManifest,
                validatedInstances: primaryPreparedSeries.validatedInstances
            )
            try persistDicomExportManifest(exportManifest, to: exportManifestURL)
            try persistSegmentationJobManifest(jobManifest, to: jobManifestURL)
            try persistExportCompletionMarker(
                exportManifest: exportManifest,
                exportManifestURL: exportManifestURL,
                in: exportDirectory
            )

            return ExportResult(
                directory: exportDirectory,
                series: preparedSeries.map { $0.exportedSeries },
                exportManifestURL: exportManifestURL,
                jobManifestURL: jobManifestURL,
                jobManifest: jobManifest
            )
        } catch {
            cleanupTemporaryDirectory(exportDirectory)
            throw ExportError.exportFailed(underlying: error)
        }
    }

    private func exportSeries(
        series: DicomSeries,
        modality: String,
        exportDirectory: URL,
        sourceInstances: [ExportSourceInstance]
    ) throws -> PreparedSeriesExport {
        let seriesIdentifierSource = series.seriesInstanceUID
            ?? (series.value(forKey: "seriesInstanceUID") as? String)
        let seriesIdentifier = seriesIdentifierSource.map { sanitizePathComponent($0) } ?? UUID().uuidString

        let seriesDirectory = exportDirectory.appendingPathComponent(seriesIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: seriesDirectory, withIntermediateDirectories: true)

        // Preserve deterministic output ordering regardless of parallel copy completion order.
        let sourceURLs = sourceInstances.map { $0.sourceURL }
        let destinationURLs = sourceInstances.map { instance in
            seriesDirectory.appendingPathComponent(destinationFileName(for: instance), isDirectory: false)
        }
        let copyResult = try copyFilesInParallel(sources: sourceURLs, destinations: destinationURLs)
        let validatedInstances = try validateCopiedExportFiles(
            copiedFiles: copyResult.copiedFiles,
            sourceInstances: sourceInstances,
            expectedDestinationURLs: destinationURLs,
            exportDirectory: exportDirectory
        )

        let exportedSeries = ExportedSeries(
            series: series,
            modality: modality,
            exportedDirectory: seriesDirectory,
            exportedFiles: validatedInstances.map { $0.destinationURL },
            seriesInstanceUID: seriesIdentifierSource,
            studyInstanceUID: series.study?.studyInstanceUID
        )

        return PreparedSeriesExport(
            exportedSeries: exportedSeries,
            sourceInstances: sourceInstances,
            validatedInstances: validatedInstances
        )
    }

    private func makeExportSourceInstances(
        series: DicomSeries,
        modality: String,
        sourceImages: [DicomImage],
        pixList: [DCMPix]
    ) throws -> [ExportSourceInstance] {
        if pixList.contains(where: { $0.generated }) {
            throw SegmentationJobManifestError.unsupportedDerivedSource(
                "MPR or generated viewer images require an explicit source-to-derived transform contract."
            )
        }

        let uniqueImages = orderedUniqueImagesByPath(sourceImages)
        let fallbackFrameOfReferenceUID = pixList.compactMap { normalizedString($0.frameofReferenceUID) }.first

        let instances = try uniqueImages.enumerated().map { index, image -> ExportSourceInstance in
            guard let sourcePath = resolvedPath(for: image) else {
                throw SegmentationJobManifestError.missingSourceIdentity
            }

            guard let sopInstanceUID = sopInstanceUID(for: image) else {
                throw SegmentationJobManifestError.missingSOPInstanceUID(index)
            }

            let pix = index < pixList.count ? pixList[index] : nil
            let imageSeries = image.series ?? series
            let studyInstanceUID = imageSeries.study?.studyInstanceUID ?? series.study?.studyInstanceUID
            let seriesInstanceUID = imageSeries.seriesInstanceUID
                ?? (imageSeries.value(forKey: "seriesInstanceUID") as? String)
                ?? series.seriesInstanceUID
                ?? (series.value(forKey: "seriesInstanceUID") as? String)
            let frameOfReferenceUID = normalizedString(pix?.frameofReferenceUID) ?? fallbackFrameOfReferenceUID
            let imageModality = normalizedString(image.modality) ?? modality

            return ExportSourceInstance(
                sourceURL: URL(fileURLWithPath: sourcePath),
                sourcePathHash: sha256String(sourcePath),
                sopInstanceUID: sopInstanceUID,
                studyInstanceUID: studyInstanceUID,
                seriesInstanceUID: seriesInstanceUID,
                frameOfReferenceUID: frameOfReferenceUID,
                modality: imageModality,
                sourceOrderIndex: index,
                dicomFrameID: intValue(image.value(forKey: "frameID")),
                frameCount: max(intValue(image.value(forKey: "numberOfFrames")) ?? 1, 1),
                rows: intValue(image.value(forKey: "height")),
                columns: intValue(image.value(forKey: "width")),
                sliceLocation: doubleValue(image.value(forKey: "sliceLocation")),
                imagePositionPatient: pix.map { [$0.originX, $0.originY, $0.originZ] },
                imageOrientationPatient: pix.flatMap { orientationPatient(from: $0) },
                sourceImage: image
            )
        }

        try validateSourceInstances(
            instances,
            expectedStudyInstanceUID: series.study?.studyInstanceUID,
            expectedSeriesInstanceUID: series.seriesInstanceUID ?? (series.value(forKey: "seriesInstanceUID") as? String),
            expectedFrameOfReferenceUID: fallbackFrameOfReferenceUID,
            expectedModality: modality
        )
        return instances
    }

    private func validateSourceInstances(
        _ instances: [ExportSourceInstance],
        expectedStudyInstanceUID: String?,
        expectedSeriesInstanceUID: String?,
        expectedFrameOfReferenceUID: String?,
        expectedModality: String
    ) throws {
        guard !instances.isEmpty else {
            throw SegmentationJobManifestError.missingSourceIdentity
        }

        var seenSOPInstanceUIDs = Set<String>()
        for instance in instances {
            if !seenSOPInstanceUIDs.insert(instance.sopInstanceUID).inserted {
                throw SegmentationJobManifestError.duplicateSOPInstanceUID(instance.sopInstanceUID)
            }

            if let expectedStudyInstanceUID,
               let studyInstanceUID = instance.studyInstanceUID,
               studyInstanceUID != expectedStudyInstanceUID {
                throw SegmentationJobManifestError.mixedStudyInstanceUID(studyInstanceUID)
            }

            if let expectedSeriesInstanceUID,
               let seriesInstanceUID = instance.seriesInstanceUID,
               seriesInstanceUID != expectedSeriesInstanceUID {
                throw SegmentationJobManifestError.mixedSeriesInstanceUID(seriesInstanceUID)
            }

            if let expectedFrameOfReferenceUID,
               let frameOfReferenceUID = instance.frameOfReferenceUID,
               frameOfReferenceUID != expectedFrameOfReferenceUID {
                throw SegmentationJobManifestError.mixedFrameOfReferenceUID(frameOfReferenceUID)
            }

            if instance.modality.uppercased() != expectedModality.uppercased() {
                throw SegmentationJobManifestError.unsupportedDerivedSource(
                    "Instance modality \(instance.modality) does not match active modality \(expectedModality)."
                )
            }
        }

        let sourceIdentityHash = SegmentationJobManifest.computeSourceIdentityHash(
            studyInstanceUID: expectedStudyInstanceUID,
            seriesInstanceUID: expectedSeriesInstanceUID,
            frameOfReferenceUID: expectedFrameOfReferenceUID,
            orderedSOPInstanceUIDs: instances.map { $0.sopInstanceUID }
        )
        guard !sourceIdentityHash.isEmpty else {
            throw SegmentationJobManifestError.missingSourceIdentity
        }
    }

    private func validateCopiedExportFiles(
        copiedFiles: [URL],
        sourceInstances: [ExportSourceInstance],
        expectedDestinationURLs: [URL],
        exportDirectory: URL
    ) throws -> [ValidatedExportedInstance] {
        guard copiedFiles.count == sourceInstances.count,
              expectedDestinationURLs.count == sourceInstances.count else {
            throw ExportCopyError.mismatchedSourceDestinationCounts
        }

        return try sourceInstances.enumerated().map { index, instance in
            let fileURL = copiedFiles[index]
            let expectedURL = expectedDestinationURLs[index]
            guard fileURL.standardizedFileURL.path == expectedURL.standardizedFileURL.path,
                  FileManager.default.fileExists(atPath: fileURL.path),
                  FileManager.default.isReadableFile(atPath: fileURL.path) else {
                throw ExportCopyError.copiedFileMissing(expectedURL.lastPathComponent)
            }

            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            let byteCount = Int64(values.fileSize ?? 0)
            guard byteCount > 0 else {
                throw ExportCopyError.emptyExportedFile(fileURL.lastPathComponent)
            }

            let fileHash = try sha256(of: fileURL)
            let sourceFile = SegmentationJobSourceFile(
                relativePath: relativePath(from: exportDirectory, to: fileURL),
                sha256: fileHash,
                byteCount: byteCount,
                sopInstanceUID: instance.sopInstanceUID
            )
            let exportInstance = DicomExportedInstance(
                sourcePathHash: instance.sourcePathHash,
                destinationName: fileURL.lastPathComponent,
                sopInstanceUID: instance.sopInstanceUID,
                studyInstanceUID: instance.studyInstanceUID,
                seriesInstanceUID: instance.seriesInstanceUID,
                frameOfReferenceUID: instance.frameOfReferenceUID,
                modality: instance.modality,
                sourceOrderIndex: instance.sourceOrderIndex,
                dicomFrameID: instance.dicomFrameID,
                frameCount: instance.frameCount,
                byteCount: byteCount,
                sha256: fileHash,
                rows: instance.rows,
                columns: instance.columns,
                sliceLocation: instance.sliceLocation,
                imagePositionPatient: instance.imagePositionPatient,
                imageOrientationPatient: instance.imageOrientationPatient
            )

            return ValidatedExportedInstance(
                destinationURL: fileURL,
                sourceFile: sourceFile,
                exportInstance: exportInstance
            )
        }
    }

    private func makeDicomExportManifest(
        jobManifest: SegmentationJobManifest,
        validatedInstances: [ValidatedExportedInstance]
    ) -> DicomExportManifest {
        DicomExportManifest(
            schemaVersion: DicomExportManifest.currentSchemaVersion,
            createdAt: Date(),
            jobUUID: jobManifest.jobUUID,
            sourceIdentityHash: jobManifest.sourceIdentityHash,
            studyInstanceUID: jobManifest.studyInstanceUID,
            seriesInstanceUID: jobManifest.seriesInstanceUID,
            frameOfReferenceUID: jobManifest.frameOfReferenceUID,
            modality: jobManifest.modality,
            sourceInstanceCount: jobManifest.orderedSOPInstanceUIDs.count,
            exportedFileCount: validatedInstances.count,
            exportComplete: true,
            instances: validatedInstances.map { $0.exportInstance }
        )
    }

    private func persistDicomExportManifest(_ manifest: DicomExportManifest, to exportManifestURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: exportManifestURL, options: .atomic)
    }

    private func persistExportCompletionMarker(
        exportManifest: DicomExportManifest,
        exportManifestURL: URL,
        in exportDirectory: URL
    ) throws {
        let payload: [String: Any] = [
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "exportManifest": exportManifestURL.lastPathComponent,
            "jobUUID": exportManifest.jobUUID,
            "sourceIdentityHash": exportManifest.sourceIdentityHash,
            "exportedFileCount": exportManifest.exportedFileCount
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let completeURL = exportDirectory.appendingPathComponent("export-complete.json", isDirectory: false)
        try data.write(to: completeURL, options: .atomic)
    }

    func persistSegmentationJobManifest(_ manifest: SegmentationJobManifest, to jobManifestURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: jobManifestURL, options: .atomic)
    }

    private func makeSegmentationJobManifest(
        exportDirectory: URL,
        primarySeries: ExportedSeries,
        sourceInstances: [ExportSourceInstance],
        validatedInstances: [ValidatedExportedInstance],
        pixList: [DCMPix],
        hostHints: SegmentationJobHostHints
    ) throws -> SegmentationJobManifest {
        let orderedSOPInstanceUIDs = sourceInstances.map { $0.sopInstanceUID }
        guard !orderedSOPInstanceUIDs.isEmpty else {
            throw SegmentationJobManifestError.missingSourceIdentity
        }

        let frameOfReferenceUID = sourceInstances.compactMap { normalizedString($0.frameOfReferenceUID) }.first
            ?? pixList.compactMap { normalizedString($0.frameofReferenceUID) }.first
        let sourceFiles = validatedInstances.map { $0.sourceFile }
        let geometry = try makeSegmentationJobGeometry(
            sourceImages: sourceInstances.map { $0.sourceImage },
            pixList: pixList
        )
        let pluginBundle = Bundle(for: TotalSegmentatorHorosPlugin.self)
        let pluginVersion = pluginBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let pluginBuild = pluginBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let sourceIdentityHash = SegmentationJobManifest.computeSourceIdentityHash(
            studyInstanceUID: primarySeries.studyInstanceUID,
            seriesInstanceUID: primarySeries.seriesInstanceUID,
            frameOfReferenceUID: frameOfReferenceUID,
            orderedSOPInstanceUIDs: orderedSOPInstanceUIDs
        )

        return SegmentationJobManifest(
            schemaVersion: SegmentationJobManifest.currentSchemaVersion,
            jobUUID: UUID().uuidString,
            createdAt: Date(),
            pluginVersion: pluginVersion,
            pluginBuild: pluginBuild,
            studyInstanceUID: primarySeries.studyInstanceUID,
            seriesInstanceUID: primarySeries.seriesInstanceUID,
            frameOfReferenceUID: frameOfReferenceUID,
            modality: primarySeries.modality,
            orderedSOPInstanceUIDs: orderedSOPInstanceUIDs,
            sourceIdentityHash: sourceIdentityHash,
            sourceFileCount: sourceFiles.count,
            sourceFiles: sourceFiles,
            geometry: geometry,
            frameIdentities: makeFrameIdentities(
                sourceInstances: sourceInstances,
                validatedInstances: validatedInstances,
                frameOfReferenceUID: frameOfReferenceUID
            ),
            derivedGeometry: SegmentationJobDerivedGeometry(
                kind: "source",
                sourceToDerivedTransform: identityAffineTransform(),
                notes: "No MPR or derived transform was applied during export."
            ),
            hostHints: hostHints,
            runSnapshot: nil,
            environmentSnapshot: nil,
            canonicalOutputPaths: SegmentationJobCanonicalOutputPaths(
                exportDirectory: exportDirectory.path,
                dicomInputDirectory: primarySeries.exportedDirectory.path,
                exportManifestPath: exportDirectory.appendingPathComponent("dicom-export-manifest.json", isDirectory: false).path,
                runWorkspaceDirectory: nil,
                runCompletionManifestPath: nil,
                outputDirectory: nil,
                publishedOutputDirectory: nil,
                bridgeScriptPath: nil,
                bridgeConfigurationPath: nil
            ),
            runState: "exported"
        )
    }

    private func makeFrameIdentities(
        sourceInstances: [ExportSourceInstance],
        validatedInstances: [ValidatedExportedInstance],
        frameOfReferenceUID: String?
    ) -> [SegmentationJobFrameIdentity] {
        sourceInstances.enumerated().map { index, instance in
            let validated = index < validatedInstances.count ? validatedInstances[index] : nil
            return SegmentationJobFrameIdentity(
                sopInstanceUID: instance.sopInstanceUID,
                frameIndex: index,
                dicomFrameID: instance.dicomFrameID,
                sourceFileRelativePath: validated?.sourceFile.relativePath,
                frameOfReferenceUID: instance.frameOfReferenceUID ?? frameOfReferenceUID
            )
        }
    }

    private func makeSegmentationJobGeometry(sourceImages: [DicomImage], pixList: [DCMPix]) throws -> SegmentationJobGeometry {
        let imageRows = sourceImages.compactMap { intValue($0.value(forKey: "height")) }
        let imageColumns = sourceImages.compactMap { intValue($0.value(forKey: "width")) }
        let rows = try consistentValue(in: imageRows, field: "rows") ?? pixList.first.map { Int($0.pheight) }
        let columns = try consistentValue(in: imageColumns, field: "columns") ?? pixList.first.map { Int($0.pwidth) }
        let frameCounts = sourceImages.compactMap { intValue($0.value(forKey: "numberOfFrames")) }
        let numberOfFrames = frameCounts.isEmpty ? sourceImages.count : frameCounts.reduce(0) { $0 + max($1, 1) }
        let firstPix = pixList.first
        let pixelSpacings = pixList.compactMap { self.pixelSpacing(from: $0) }
        let pixelSpacing = try consistentValue(in: pixelSpacings, field: "pixelSpacing")
        let sliceSpacings = pixList.compactMap { self.sliceSpacing(from: $0) }
        let sliceSpacing = try consistentValue(in: sliceSpacings, field: "sliceSpacing")
        let imageOrientationPatients = pixList.compactMap { orientationPatient(from: $0) }
        let imageOrientationPatient = try consistentValue(in: imageOrientationPatients, field: "imageOrientationPatient")
        let imagePositionPatient = firstPix.map { [$0.originX, $0.originY, $0.originZ] }
        let pixSlicePositions = pixList.map { $0.sliceLocation }
        let imageSlicePositions = sourceImages.compactMap { doubleValue($0.value(forKey: "sliceLocation")) }
        let slicePositions = pixSlicePositions.isEmpty ? imageSlicePositions : pixSlicePositions

        return SegmentationJobGeometry(
            rows: rows,
            columns: columns,
            numberOfFrames: numberOfFrames,
            pixelSpacing: pixelSpacing,
            sliceSpacing: sliceSpacing,
            slicePositions: slicePositions,
            imageOrientationPatient: imageOrientationPatient,
            imagePositionPatient: imagePositionPatient,
            normalizedAffine: normalizedAffine(
                orientation: imageOrientationPatient,
                position: imagePositionPatient,
                pixelSpacing: pixelSpacing,
                sliceSpacing: sliceSpacing
            ),
            coordinateSystemConvention: SegmentationJobManifest.dicomLPSCoordinateSystem
        )
    }

    private func sortedImages(from series: DicomSeries) -> [DicomImage] {
        (series.sortedImages() ?? []).compactMap { $0 as? DicomImage }
    }

    private func orderedUniqueImagesByPath(_ images: [DicomImage]) -> [DicomImage] {
        var seen = Set<String>()
        return images.filter { image in
            guard let path = resolvedPath(for: image) else {
                return true
            }
            return seen.insert(path).inserted
        }
    }

    private func orderedPaths(for series: DicomSeries, preferredImages: [DicomImage]) -> [String] {
        let imagePaths = orderedUniqueStrings(preferredImages.compactMap { resolvedPath(for: $0) })
        if !imagePaths.isEmpty {
            return imagePaths
        }

        return orderedUniqueStrings(normalizePaths(from: series.paths()).sorted())
    }

    private func resolvedPath(for image: DicomImage) -> String? {
        if let resolved = normalizedString(image.completePathResolved()) {
            return resolved
        }

        if let complete = normalizedString(image.completePath()) {
            return complete
        }

        return normalizedString(image.path())
    }

    private func sopInstanceUID(for image: DicomImage) -> String? {
        if let uid = normalizedString(image.sopInstanceUID()) {
            return uid
        }

        return normalizedString(image.value(forKey: "sopInstanceUID") as? String)
    }

    private func makeHostHints(for series: DicomSeries, viewer: ViewerController?) -> SegmentationJobHostHints {
        SegmentationJobHostHints(
            hostApplication: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
            hostSeriesObjectURI: series.objectID.uriRepresentation().absoluteString,
            hostViewerDescription: viewer.map { String(describing: type(of: $0)) }
        )
    }

    private func normalizePixList(_ value: Any?) -> [DCMPix] {
        if let pixList = value as? [DCMPix] {
            return pixList
        }

        if let array = value as? NSArray {
            return array.compactMap { $0 as? DCMPix }
        }

        return []
    }

    private func pixelSpacing(from pix: DCMPix) -> [Double]? {
        guard pix.pixelSpacingY > 0, pix.pixelSpacingX > 0 else { return nil }
        return [pix.pixelSpacingY, pix.pixelSpacingX]
    }

    private func sliceSpacing(from pix: DCMPix) -> Double? {
        if pix.spacingBetweenSlices > 0 { return pix.spacingBetweenSlices }
        if pix.sliceInterval > 0 { return pix.sliceInterval }
        if pix.sliceThickness > 0 { return pix.sliceThickness }
        return nil
    }

    private func orientationPatient(from pix: DCMPix) -> [Double]? {
        var orientation = Array(repeating: 0.0, count: 9)
        orientation.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            pix.orientationDouble(baseAddress)
        }

        guard orientation.contains(where: { abs($0) > 0.000_001 }) else {
            return nil
        }

        return Array(orientation.prefix(6))
    }

    private func normalizedAffine(
        orientation: [Double]?,
        position: [Double]?,
        pixelSpacing: [Double]?,
        sliceSpacing: Double?
    ) -> [Double]? {
        guard let orientation = orientation, orientation.count >= 6,
              let position = position, position.count == 3,
              let pixelSpacing = pixelSpacing, pixelSpacing.count == 2 else {
            return nil
        }

        let row = Array(orientation[0..<3])
        let column = Array(orientation[3..<6])
        let normal = [
            row[1] * column[2] - row[2] * column[1],
            row[2] * column[0] - row[0] * column[2],
            row[0] * column[1] - row[1] * column[0]
        ]
        let rowSpacing = pixelSpacing[0]
        let columnSpacing = pixelSpacing[1]
        let throughPlaneSpacing = sliceSpacing ?? 1.0

        return [
            column[0] * columnSpacing, row[0] * rowSpacing, normal[0] * throughPlaneSpacing, position[0],
            column[1] * columnSpacing, row[1] * rowSpacing, normal[1] * throughPlaneSpacing, position[1],
            column[2] * columnSpacing, row[2] * rowSpacing, normal[2] * throughPlaneSpacing, position[2],
            0, 0, 0, 1
        ]
    }

    private func identityAffineTransform() -> [Double] {
        [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        ]
    }

    private func consistentValue<T: Equatable>(in values: [T], field: String) throws -> T? {
        guard let first = values.first else { return nil }
        guard values.allSatisfy({ $0 == first }) else {
            throw SegmentationJobManifestError.inconsistentGeometry(field)
        }
        return first
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }

        if let intValue = value as? Int {
            return intValue
        }

        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }

        if let doubleValue = value as? Double {
            return doubleValue
        }

        return nil
    }

    private func normalizedString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed = trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func relativePath(from root: URL, to fileURL: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }

        return fileURL.lastPathComponent
    }

    private func orderedUniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func destinationFileName(for instance: ExportSourceInstance) -> String {
        let sopComponent = sanitizePathComponent(instance.sopInstanceUID)
        return String(format: "%06d_%@.dcm", instance.sourceOrderIndex + 1, sopComponent)
    }

    private func sha256String(_ value: String) -> String {
        let data = Data(value.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256(of fileURL: URL) throws -> String {
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

    private func normalizeSeriesCollection(_ value: Any?) -> [DicomSeries] {
        if let nsSet = value as? NSSet {
            return nsSet.allObjects.compactMap { $0 as? DicomSeries }
        }

        if let series = value as? [DicomSeries] {
            return series
        }

        if let series = value as? [Any] {
            return series.compactMap { $0 as? DicomSeries }
        }

        if let orderedSet = value as? NSOrderedSet {
            return orderedSet.array.compactMap { $0 as? DicomSeries }
        }

        if let set = value as? Set<DicomSeries> {
            return Array(set)
        }

        if let set = value as? Set<AnyHashable> {
            return set.compactMap { $0.base as? DicomSeries }
        }

        if let single = value as? DicomSeries {
            return [single]
        }

        return []
    }

    private func normalizePaths(from value: Any?) -> [String] {
        if let nsSet = value as? NSSet {
            return nsSet.allObjects.compactMap { $0 as? String }
        }

        if let paths = value as? [String] {
            return paths
        }

        if let paths = value as? [Any] {
            return paths.compactMap { $0 as? String }
        }

        if let orderedSet = value as? NSOrderedSet {
            return orderedSet.array.compactMap { $0 as? String }
        }

        if let set = value as? Set<String> {
            return Array(set)
        }

        if let set = value as? Set<AnyHashable> {
            return set.compactMap { $0.base as? String }
        }

        if let single = value as? String {
            return [single]
        }

        return []
    }

    private func makeExportDirectory() throws -> URL {
        let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("TotalSegmentator", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let exportDirectory = baseDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        return exportDirectory
    }

    func cleanupTemporaryDirectory(_ url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            NSLog("[TotalSegmentator] Failed to clean temporary directory %@: %@", url.path, error.localizedDescription)
        }
    }

    private func sanitizePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let result = value.unicodeScalars.reduce(into: "") { partialResult, scalar in
            if allowed.contains(scalar) {
                partialResult.append(Character(scalar))
            } else {
                partialResult.append("_")
            }
        }

        return result.isEmpty ? UUID().uuidString : result
    }
}
