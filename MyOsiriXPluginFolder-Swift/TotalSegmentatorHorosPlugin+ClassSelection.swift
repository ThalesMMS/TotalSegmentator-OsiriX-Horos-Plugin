//
// TotalSegmentatorHorosPlugin+ClassSelection.swift
// TotalSegmentator
//

import Cocoa

extension TotalSegmentatorHorosPlugin {
    @IBAction func selectClasses(_ sender: Any) {
        guard settingsWindow != nil else { return }

        var effectivePreferences = self.preferences.effectivePreferences()

        if let pathValue = executablePathField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !pathValue.isEmpty {
            effectivePreferences.executablePath = pathValue
        }

        if let taskValue = taskPopupButton?.selectedItem?.representedObject as? String {
            effectivePreferences.task = taskValue
        }

        classSelectionButton?.isEnabled = false

        loadClassOptions(
            for: effectivePreferences.task,
            executable: effectivePreferences.executablePath
        ) { [weak self] result in
            guard let self = self else { return }
            self.classSelectionButton?.isEnabled = true

            switch result {
            case .success(let options):
                self.presentClassSelectionWindow(with: options, preselected: self.selectedClassNames)
            case .failure(let error):
                self.presentAlert(
                    title: "TotalSegmentator",
                    message: error.localizedDescription
                )
            }
        }
    }

    func loadClassOptions(
        for task: String?,
        executable executablePath: String?,
        completion: @escaping (Swift.Result<[String], Error>) -> Void
    ) {
        var effectivePreferences = preferences.effectivePreferences()

        if let pathValue = executablePath?.trimmingCharacters(in: .whitespacesAndNewlines), !pathValue.isEmpty {
            effectivePreferences.executablePath = pathValue
        }

        let normalizedTask = task?.trimmingCharacters(in: .whitespacesAndNewlines)
        effectivePreferences.task = normalizedTask?.isEmpty == false ? normalizedTask : nil

        let taskKey = classOptionsCacheKey(for: normalizedTask)
        if let cached = availableClassOptionsCache[taskKey] {
            DispatchQueue.main.async {
                completion(.success(cached))
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let executableResolution = self.resolvePythonInterpreter(using: effectivePreferences) else {
                DispatchQueue.main.async {
                    completion(.failure(ClassSelectionError.retrievalFailed(
                        "Unable to locate a Python interpreter. Please verify the executable path before selecting classes."
                    )))
                }
                return
            }

            do {
                let options = try self.loadClassOptions(
                    for: normalizedTask,
                    executable: executableResolution
                )

                DispatchQueue.main.async {
                    self.availableClassOptionsCache[taskKey] = options
                    completion(.success(options))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private func classOptionsCacheKey(for task: String?) -> String {
        if let normalized = task?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty {
            return normalized
        }

        return "__default__"
    }

    func presentClassSelectionWindow(with options: [String], preselected: Set<String>) {
        guard let settingsWindow = settingsWindow else { return }

        let preselectedArray = Array(preselected.intersection(Set(options)))
        let controller = ClassSelectionWindowController(
            availableClasses: options,
            preselected: preselectedArray
        )

        controller.onSelectionConfirmed = { [weak self] selection in
            guard let self = self else { return }
            self.selectedClassNames = Set(selection)
            self.classSelectionController = nil
            self.persistPreferencesFromUI()
        }

        controller.onSelectionCancelled = { [weak self] in
            self?.classSelectionController = nil
        }

        classSelectionController = controller
        settingsWindow.beginSheet(controller.window!, completionHandler: nil)
    }

    private func loadClassOptions(for task: String?, executable: ExecutableResolution) throws -> [String] {
        let taskLiteral: String
        if let rawTask = task?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTask.isEmpty {
            let escaped = rawTask
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            taskLiteral = "\"" + escaped + "\""
        } else {
            taskLiteral = "None"
        }

        let scriptTemplate = """
import json
from totalsegmentator.map_to_binary import class_map

task = <<TASK>>
candidates = []

if isinstance(task, str) and task.strip():
    normalized = task.strip()
    candidates.append(normalized)
    if normalized.endswith("_fast"):
        candidates.append(normalized[:-5])
    if normalized.endswith("_mr"):
        candidates.append(normalized[:-3])
    if normalized.startswith("total"):
        candidates.append("total")
else:
    candidates.extend(["total", "total_mr"])

fallbacks = ["total", "total_mr"]
for candidate in fallbacks:
    if candidate not in candidates:
        candidates.append(candidate)

mapping = None
for candidate in candidates:
    if candidate in class_map:
        mapping = class_map[candidate]
        break

if mapping is None:
    print(json.dumps({"error": "unavailable"}))
else:
    names = sorted(set(str(value) for value in mapping.values()))
    print(json.dumps({"names": names}))
"""

        let script = scriptTemplate.replacingOccurrences(of: "<<TASK>>", with: taskLiteral)

        let process = Process()
        process.executableURL = executable.executableURL
        process.arguments = executable.leadingArguments + ["-c", script]
        process.environment = executable.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ClassSelectionError.retrievalFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let combinedData = outputData + errorData
            let combinedMessage = String(data: combinedData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fallbackMessage = "Python process exited with status \(process.terminationStatus)"
            let message = combinedMessage.isEmpty ? fallbackMessage : combinedMessage
            throw ClassSelectionError.retrievalFailed(message)
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: outputData, options: []),
              let dictionary = jsonObject as? [String: Any] else {
            throw ClassSelectionError.decodingFailed
        }

        if let errorMessage = dictionary["error"] as? String {
            throw ClassSelectionError.retrievalFailed(errorMessage)
        }

        guard let names = dictionary["names"] as? [String], !names.isEmpty else {
            throw ClassSelectionError.noClassesAvailable
        }

        return names
    }

    func classSelectionSummaryComponents(for names: [String]) -> (text: String, tooltip: String?) {
        return ClassSelectionSummaryFormatter.components(for: names)
    }

    func updateClassSelectionSummary() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let summaryField = self.classSelectionSummaryField else { return }

            let names = Array(self.selectedClassNames)
            let summary = self.classSelectionSummaryComponents(for: names)
            summaryField.stringValue = summary.text
            summaryField.toolTip = summary.tooltip
        }
    }

    func supportsClassSelection(for task: String?) -> Bool {
        guard let normalized = task?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty else {
            return true
        }

        return normalized.hasPrefix("total")
    }
}
