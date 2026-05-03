//
// TotalSegmentatorHorosPlugin+Export.swift
// TotalSegmentator
//

import Cocoa

extension TotalSegmentatorHorosPlugin {
    private static let exportMaxConcurrentCopiesCap = 8

    private struct CopyFilesResult: Sendable {
        let copiedFiles: [URL]
        let newCopiesCount: Int
    }

    private enum ExportCopyError: LocalizedError {
        case mismatchedSourceDestinationCounts

        var errorDescription: String? {
            switch self {
            case .mismatchedSourceDestinationCounts:
                return "The DICOM export source and destination counts do not match."
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

    @discardableResult
    private static func copyDicomFileIfNeeded(from sourceURL: URL, to destinationURL: URL) throws -> Bool {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return false
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return true
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == CocoaError.Code.fileWriteFileExists.rawValue {
                return false
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

        let paths = normalizePaths(from: series.paths())
        guard !paths.isEmpty else {
            throw ActiveSeriesExportError.missingSlices
        }

        let exportDirectory = try makeExportDirectory()
        let seriesIdentifierSource = series.seriesInstanceUID
            ?? (series.value(forKey: "seriesInstanceUID") as? String)
        let seriesIdentifier = seriesIdentifierSource.map { sanitizePathComponent($0) } ?? UUID().uuidString

        let seriesDirectory = exportDirectory.appendingPathComponent(seriesIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: seriesDirectory, withIntermediateDirectories: true)

        // Preserve deterministic output ordering regardless of parallel copy completion order.
        let sourceURLs = paths.map { URL(fileURLWithPath: $0) }
        let destinationURLs = sourceURLs.map { seriesDirectory.appendingPathComponent($0.lastPathComponent) }
        let copyResult: CopyFilesResult
        do {
            copyResult = try copyFilesInParallel(sources: sourceURLs, destinations: destinationURLs)
        } catch {
            throw ActiveSeriesExportError.exportFailed(underlying: error)
        }

        guard !copyResult.copiedFiles.isEmpty else {
            throw ActiveSeriesExportError.missingSlices
        }

        let exportedSeries = ExportedSeries(
            series: series,
            modality: modality,
            exportedDirectory: seriesDirectory,
            exportedFiles: copyResult.copiedFiles,
            seriesInstanceUID: seriesIdentifierSource,
            studyInstanceUID: series.study?.studyInstanceUID
        )

        return ExportResult(directory: exportDirectory, series: [exportedSeries])
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

        let compatibleSeries = seriesArray.compactMap { series -> (series: DicomSeries, modality: String, paths: [String])? in
            let rawModality = series.modality ?? (series.value(forKey: "modality") as? String)
            let normalizedModality = rawModality?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

            guard let modality = normalizedModality, supportedModalities.contains(modality) else {
                return nil
            }

            let paths = normalizePaths(from: series.paths())

            guard !paths.isEmpty else {
                return nil
            }

            return (series, modality, paths)
        }

        guard !compatibleSeries.isEmpty else {
            throw ExportError.noCompatibleSeries
        }

        let exportDirectory = try makeExportDirectory()

        var exportedSeries: [ExportedSeries] = []

        do {
            for entry in compatibleSeries {
                let identifierSource = entry.series.seriesInstanceUID
                    ?? (entry.series.value(forKey: "seriesInstanceUID") as? String)
                let seriesIdentifier = identifierSource.map { sanitizePathComponent($0) } ?? UUID().uuidString

                let seriesDirectory = exportDirectory.appendingPathComponent(seriesIdentifier, isDirectory: true)
                try FileManager.default.createDirectory(at: seriesDirectory, withIntermediateDirectories: true)

                // Preserve deterministic output ordering regardless of parallel copy completion order.
                let sourceURLs = entry.paths.map { URL(fileURLWithPath: $0) }
                let destinationURLs = sourceURLs.map { seriesDirectory.appendingPathComponent($0.lastPathComponent) }
                let copyResult = try copyFilesInParallel(sources: sourceURLs, destinations: destinationURLs)
                guard !copyResult.copiedFiles.isEmpty else { continue }

                let seriesInfo = ExportedSeries(
                    series: entry.series,
                    modality: entry.modality,
                    exportedDirectory: seriesDirectory,
                    exportedFiles: copyResult.copiedFiles,
                    seriesInstanceUID: entry.series.seriesInstanceUID
                        ?? (entry.series.value(forKey: "seriesInstanceUID") as? String),
                    studyInstanceUID: entry.series.study?.studyInstanceUID ?? study.studyInstanceUID
                )
                exportedSeries.append(seriesInfo)
            }
        } catch {
            throw ExportError.exportFailed(underlying: error)
        }

        guard !exportedSeries.isEmpty else {
            throw ExportError.noCompatibleSeries
        }

        return ExportResult(directory: exportDirectory, series: exportedSeries)
    }

    private func normalizeSeriesCollection(_ value: Any?) -> [DicomSeries] {
        if let series = value as? [DicomSeries] {
            return series
        }

        if let series = value as? [Any] {
            return series.compactMap { $0 as? DicomSeries }
        }

        if let orderedSet = value as? NSOrderedSet {
            return orderedSet.array.compactMap { $0 as? DicomSeries }
        }

        if let nsSet = value as? NSSet {
            return nsSet.allObjects.compactMap { $0 as? DicomSeries }
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
        if let paths = value as? [String] {
            return paths
        }

        if let paths = value as? [Any] {
            return paths.compactMap { $0 as? String }
        }

        if let orderedSet = value as? NSOrderedSet {
            return orderedSet.array.compactMap { $0 as? String }
        }

        if let nsSet = value as? NSSet {
            return nsSet.allObjects.compactMap { $0 as? String }
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
