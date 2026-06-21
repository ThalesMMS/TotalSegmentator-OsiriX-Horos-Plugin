//
// TotalSegmentatorHorosPlugin+Settings.swift
// TotalSegmentator
//

import Cocoa

extension TotalSegmentatorHorosPlugin {
    func presentSettingsWindow() {
        guard let window = settingsWindow else {
            NSLog("Settings window has not been loaded. Did initPlugin run?")
            return
        }

        let currentPreferences = preferences.effectivePreferences()
        let runtimeDeviceOptions = settingsDeviceOptions(for: currentPreferences)
        configureSettingsInterfaceIfNeeded(deviceOptions: runtimeDeviceOptions)
        populateSettingsUI(deviceOptions: runtimeDeviceOptions)

        if window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard let browserWindow = BrowserController.currentBrowser()?.window else {
            NSLog("Unable to determine current browser window to display settings sheet.")
            window.makeKeyAndOrderFront(nil)
            return
        }

        browserWindow.beginSheet(window, completionHandler: nil)
    }

    @IBAction func closeSettings(_ sender: Any) {
        persistPreferencesFromUI()
        settingsWindow?.close()
    }

    @objc func runSegmentationFromToolbar(_ sender: Any?) {
        startSegmentationFlow()
    }

    /// Prompts the user to select a Python interpreter or TotalSegmentator executable.
    @IBAction func browseForExecutable(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select Python interpreter or TotalSegmentator executable"
        panel.prompt = "Choose"

        if let existingPath = executablePathField?.stringValue,
           !existingPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (existingPath as NSString).deletingLastPathComponent)
        }

        if panel.runModal() == .OK, let url = panel.url {
            executablePathField?.stringValue = url.path
        }
    }

    /// Initializes the settings window interface, configuring title, dropdowns, and field properties.
    func configureSettingsInterfaceIfNeeded(deviceOptions availableDeviceOptions: [(title: String, value: String?)]? = nil) {
        settingsWindow?.title = "\(Self.settingsMenuTitle) - \(Self.certificationStatusDisplayName)"

        if let taskPopupButton = taskPopupButton,
           taskPopupButton.numberOfItems == 0 {
            taskPopupButton.removeAllItems()
            for option in taskOptions {
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.representedObject = option.value
                taskPopupButton.menu?.addItem(item)
            }
            taskPopupButton.target = self
            taskPopupButton.action = #selector(settingsTaskSelectionChanged(_:))

            if let menu = taskPopupButton.menu, !menu.items.isEmpty {
                taskPopupButton.select(menu.items.first)
            }
        }

        populateDevicePopupButton(with: availableDeviceOptions ?? deviceOptions)
        additionalArgumentsField?.placeholderString = "--roi_subset liver --statistics"
        classSelectionSummaryField?.isEditable = false
        classSelectionSummaryField?.isSelectable = false
        classSelectionSummaryField?.usesSingleLineMode = true
        classSelectionSummaryField?.lineBreakMode = .byTruncatingTail
        classSelectionSummaryField?.placeholderString = NSLocalizedString("All classes", comment: "Placeholder for class selection summary")
        classSelectionButton?.title = NSLocalizedString("Select Classes…", comment: "Button title for class selection")
        updateClassSelectionSummary()
        updateSettingsCapabilityControls()
    }

    /// Populates the settings interface with saved preference values.
    func populateSettingsUI(deviceOptions availableDeviceOptions: [(title: String, value: String?)]? = nil) {
        let current = preferences.effectivePreferences()
        executablePathField?.stringValue = current.executablePath ?? ""
        additionalArgumentsField?.stringValue = current.additionalArguments ?? ""
        licenseKeyField?.stringValue = current.licenseKey ?? ""
        fastModeCheckbox?.state = current.useFast ? .on : .off
        hideROIsCheckbox?.state = current.hideROIs ? .on : .off
        selectedClassNames = Set(current.selectedClassNames)

        if let task = current.task,
           let menuItem = taskPopupButton?.menu?.items.first(where: { ($0.representedObject as? String) == task }) {
            taskPopupButton?.select(menuItem)
        } else {
            taskPopupButton?.selectItem(at: 0)
        }
        updateSettingsCapabilityControls()

        if let availableDeviceOptions,
           !Self.deviceValueIsSelectable(current.device, in: availableDeviceOptions) {
            devicePopupButton?.selectItem(at: 0)
            return
        }

        if let device = current.device,
           let menuItem = devicePopupButton?.menu?.items.first(where: { ($0.representedObject as? String) == device }) {
            devicePopupButton?.select(menuItem)
        } else {
            devicePopupButton?.selectItem(at: 0)
        }
    }

    /// Clears selected classes and updates capability-dependent controls when the task selection changes.
    @objc func settingsTaskSelectionChanged(_ sender: Any?) {
        selectedClassNames.removeAll()
        updateClassSelectionSummary()
        updateSettingsCapabilityControls()
    }

    private func settingsDeviceOptions(for preferencesState: SegmentationPreferences.State) -> [(title: String, value: String?)] {
        guard let runtimeExecutable = resolvePythonInterpreter(using: preferencesState) else {
            return deviceOptions
        }

        let runtimeProbe = probeRuntimeCapabilities(using: runtimeExecutable)
        for failure in runtimeProbe.failures {
            logToConsole("Runtime capability probe warning: \(failure)")
        }
        return Self.runtimeDeviceOptions(from: runtimeProbe)
    }

    private func populateDevicePopupButton(with availableDeviceOptions: [(title: String, value: String?)]) {
        devicePopupButton?.removeAllItems()
        guard let deviceMenu = devicePopupButton?.menu else { return }

        for option in availableDeviceOptions {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.value
            deviceMenu.addItem(item)
        }
        devicePopupButton?.select(deviceMenu.items.first)
    }

    /// Gets the identifier of the currently selected task.
    /// - Returns: The currently selected task identifier, or `nil` if unavailable.
    private func currentSettingsTask() -> String? {
        return taskPopupButton?.selectedItem?.representedObject as? String
    }

    /// Updates which settings controls are enabled based on the capabilities of the currently selected task.
    /// Clears incompatible selections when their supporting task features are disabled, and updates placeholder text for license-dependent fields.
    private func updateSettingsCapabilityControls() {
        let task = currentSettingsTask()

        let supportsClasses = supportsClassSelection(for: task)
        classSelectionButton?.isEnabled = supportsClasses
        if !supportsClasses, !selectedClassNames.isEmpty {
            selectedClassNames.removeAll()
            updateClassSelectionSummary()
        }

        let supportsFast = supportsFastMode(for: task)
        fastModeCheckbox?.isEnabled = supportsFast
        if !supportsFast {
            fastModeCheckbox?.state = .off
        }

        let taskRequiresLicense = requiresLicense(for: task)
        licenseKeyField?.isEnabled = taskRequiresLicense
        licenseKeyField?.placeholderString = taskRequiresLicense
            ? NSLocalizedString("Required for selected task", comment: "License placeholder for commercial TotalSegmentator tasks")
            : NSLocalizedString("Not required for selected task", comment: "License placeholder for non-commercial TotalSegmentator tasks")
    }

    /// Persists the current settings from the UI to preferences and handles related updates.
    ///
    /// When the executable path changes, clears the cached class options and resets selected classes.
    /// When the license key changes, initiates license configuration synchronization.
    func persistPreferencesFromUI() {
        var updated = preferences.effectivePreferences()
        let previousExecutable = updated.executablePath
        let previousLicense = updated.licenseKey
        let executablePath = executablePathField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.executablePath = executablePath?.isEmpty == false ? executablePath : nil

        let normalizeExecutablePath: (String?) -> String? = { path in
            guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return (trimmed as NSString).expandingTildeInPath
        }

        let normalizedPreviousExecutable = normalizeExecutablePath(previousExecutable)
        let normalizedUpdatedExecutable = normalizeExecutablePath(updated.executablePath)

        if normalizedPreviousExecutable != normalizedUpdatedExecutable {
            availableClassOptionsCache.removeAll()
            selectedClassNames.removeAll()
            updateClassSelectionSummary()
        }

        if let selectedTask = taskPopupButton?.selectedItem?.representedObject as? String {
            updated.task = selectedTask
        } else {
            updated.task = nil
        }

        updated.useFast = (fastModeCheckbox?.state == .on) && supportsFastMode(for: updated.task)
        updated.hideROIs = hideROIsCheckbox?.state == .on

        if let selectedDevice = devicePopupButton?.selectedItem?.representedObject as? String {
            updated.device = selectedDevice
        } else {
            updated.device = nil
        }

        let additionalArgs = additionalArgumentsField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.additionalArguments = additionalArgs?.isEmpty == false ? additionalArgs : nil
        let licenseKey = licenseKeyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.licenseKey = licenseKey?.isEmpty == false ? licenseKey : nil
        if supportsClassSelection(for: updated.task) {
            updated.selectedClassNames = Array(selectedClassNames).sorted()
        } else {
            updated.selectedClassNames = []
        }

        preferences.store(updated)

        if updated.licenseKey != previousLicense {
            synchronizeLicenseConfiguration(using: updated)
        }
    }

    func synchronizeLicenseConfiguration(using preferences: SegmentationPreferences.State) {
        let trimmedLicense = preferences.licenseKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLicense = trimmedLicense?.isEmpty == false ? trimmedLicense : nil

        guard let resolution = resolvePythonInterpreter(using: preferences) else {
            let message = NSLocalizedString(
                "Unable to configure the TotalSegmentator license because the Python environment could not be resolved.",
                comment: "License configuration failure message when interpreter is unavailable"
            )
            logToConsole(message)
            presentAlert(title: "TotalSegmentator", message: message)
            return
        }

        let script = """
import sys
from totalsegmentator.config import set_license_number
license_value = sys.argv[1]
skip_validation = sys.argv[2].lower() == "true"
set_license_number(license_value, skip_validation=skip_validation)
"""
        let shouldSkipValidation = normalizedLicense == nil
        let result = runPythonProcess(
            using: resolution,
            arguments: [
                "-c",
                script,
                normalizedLicense ?? "",
                shouldSkipValidation ? "true" : "false"
            ],
            progressController: nil
        )

        if let error = result.error {
            let message = String(
                format: NSLocalizedString(
                    "Failed to configure the TotalSegmentator license: %@",
                    comment: "License configuration failure message with error description"
                ),
                error.localizedDescription
            )
            logToConsole(message)
            presentAlert(title: "TotalSegmentator", message: message)
            return
        }

        if result.terminationStatus == 0 {
            let message: String
            if normalizedLicense == nil {
                message = NSLocalizedString(
                    "The TotalSegmentator license was cleared successfully.",
                    comment: "Success message after clearing license"
                )
            } else {
                message = NSLocalizedString(
                    "The TotalSegmentator license was updated successfully.",
                    comment: "Success message after updating license"
                )
            }

            if let stdoutString = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !stdoutString.isEmpty {
                logToConsole(stdoutString)
            }

            logToConsole(message)
            presentAlert(title: "TotalSegmentator", message: message)
        } else {
            let stderrString = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdoutString = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            var messageComponents: [String] = []
            if let stderrString, !stderrString.isEmpty {
                messageComponents.append(stderrString)
            }
            if let stdoutString, !stdoutString.isEmpty {
                messageComponents.append(stdoutString)
            }

            if messageComponents.isEmpty {
                messageComponents.append(
                    String(
                        format: NSLocalizedString(
                            "Failed to configure the TotalSegmentator license (exit code %d).",
                            comment: "License configuration failure message with exit status"
                        ),
                        result.terminationStatus
                    )
                )
            }

            let message = messageComponents.joined(separator: "\n")
            logToConsole(message)
            presentAlert(title: "TotalSegmentator", message: message)
        }
    }
}

extension TotalSegmentatorHorosPlugin: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == settingsWindow else {
            return
        }

        persistPreferencesFromUI()
    }
}

extension TotalSegmentatorHorosPlugin: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        return true
    }
}
