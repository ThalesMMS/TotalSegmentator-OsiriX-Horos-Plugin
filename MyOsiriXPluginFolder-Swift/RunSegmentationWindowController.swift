//
// RunSegmentationWindowController.swift
// TotalSegmentator
//
// Window that configures task, device, ROI subset, license, and output path prior to running segmentation.
//
// Thales Matheus Mendonça Santos - November 2025
//

import Cocoa

// Configuration window for running TotalSegmentator inside Horos.
// It centralizes task, device, and output directory choices before launching the pipeline.

final class RunSegmentationWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    typealias PreferencesState = TotalSegmentatorHorosPlugin.SegmentationPreferences.State

    private(set) var fallbackOutputPath: String = {
        let base = "~/temp/TotalSegmentator"
        return (base as NSString).expandingTildeInPath
    }()

    struct Configuration {
        var preferences: PreferencesState
        var taskOptions: [(title: String, value: String?)]
        var deviceOptions: [(title: String, value: String?)]
        var classSummaryText: String
        var classSummaryTooltip: String?
        var outputDirectory: URL?
    }

    struct Result {
        let preferences: PreferencesState
        let outputDirectory: URL?
    }

    @IBOutlet private weak var taskPopupButton: NSPopUpButton!
    @IBOutlet private weak var devicePopupButton: NSPopUpButton!
    @IBOutlet private weak var fastModeCheckbox: NSButton!
    @IBOutlet private weak var classSummaryField: NSTextField!
    @IBOutlet private var selectClassesButton: NSButton!
    @IBOutlet private var licenseField: NSTextField!
    @IBOutlet private var outputPathField: NSTextField!
    @IBOutlet private var launchButton: NSButton!

    var configuration: Configuration? {
        didSet {
            localSelectedClassNames = Set(configuration?.preferences.selectedClassNames ?? [])
            if isWindowLoaded {
                applyConfiguration()
            }
        }
    }

    var onCompletion: ((Result?) -> Void)?
    var onLoadClasses: ((_ task: String?, _ executable: String?, _ completion: @escaping ([String]) -> Void) -> Void)?
    var onCheckTaskSupportsClassSelection: ((_ task: String?) -> Bool)?

    var localSelectedClassNames: Set<String> = [] {
        didSet {
            if isWindowLoaded {
                updateClassSelectionSummary()
            }
        }
    }

    private var hasConfiguredOptions = false
    private var classSelectionController: ClassSelectionWindowController?
    private var currentClassLoadRequestID: UUID?

    init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var windowNibName: NSNib.Name? {
        return NSNib.Name("RunSegmentationWindowController")
    }

    /// Configure the window and its UI elements after the nib has been loaded.
    /// 
    /// Sets a light appearance for the window, assigns delegates for the window and output path field, enables the launch button, pre-fills the output path field with a fallback path if it is empty, ensures non-editable label text is readable, and applies the current configuration to populate controls.
    override func windowDidLoad() {
        super.windowDidLoad()
        // Force light appearance for consistent look
        window?.appearance = NSAppearance(named: .aqua)
        window?.delegate = self
        outputPathField?.delegate = self
        launchButton?.isEnabled = true
        // Pre-fill a default path so the field is not empty the first time the window opens.
        if outputPathField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            outputPathField?.stringValue = fallbackOutputPath
        }
        // Force label colors to be readable on light background
        fixLabelColors()
        applyConfiguration()
    }

    private func fixLabelColors() {
        guard let contentView = window?.contentView else { return }
        for subview in contentView.subviews {
            if let textField = subview as? NSTextField, !textField.isEditable {
                textField.textColor = NSColor.black
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        launchButton?.isEnabled = true
        launchButton?.alphaValue = 1.0
    }

    /// Updates the launch button state when the output path text field changes.
    /// 
    /// If the notification's `object` is the controller's `outputPathField`, this method refreshes the launch button state to reflect the edited path.
    /// - Parameter obj: The `Notification` delivered for a control text change; its `object` is expected to be the sending `NSTextField`.
    func controlTextDidChange(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField, textField == outputPathField else { return }
        // Update the button whenever the user edits the path manually.
        updateLaunchButtonState()
    }

    @IBAction private func taskSelectionChanged(_ sender: Any) {
        currentClassLoadRequestID = nil
        updateClassSelectionPresentation()
    }

    @IBAction private func chooseOutputDirectory(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("Choose", comment: "Choose directory button title")
        panel.title = NSLocalizedString("Select output directory", comment: "Output directory panel title")

        if let window = self.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self = self else { return }
                if response == .OK, let url = panel.url {
                    self.outputPathField?.stringValue = url.path
                    self.updateLaunchButtonState()
                }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            outputPathField?.stringValue = url.path
            updateLaunchButtonState()
        }
    }

    @IBAction private func selectClasses(_ sender: Any) {
        let requestedTask = currentSelectedTask()
        if onCheckTaskSupportsClassSelection?(requestedTask) == false {
            restoreSelectClassesButtonState()
            NSSound.beep()
            return
        }

        guard let window = self.window,
              let onLoadClasses = onLoadClasses else {
            restoreSelectClassesButtonState()
            NSSound.beep()
            return
        }

        let requestID = UUID()
        currentClassLoadRequestID = requestID
        selectClassesButton?.isEnabled = false
        let executable = configuration?.preferences.executablePath

        onLoadClasses(requestedTask, executable) { [weak self] classes in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.currentClassLoadRequestID == requestID else {
                    return
                }
                defer { self.restoreSelectClassesButtonState() }

                guard self.currentSelectedTask() == requestedTask else {
                    self.currentClassLoadRequestID = nil
                    return
                }

                self.currentClassLoadRequestID = nil

                guard !classes.isEmpty else {
                    NSSound.beep()
                    return
                }

                let controller = ClassSelectionWindowController(
                    availableClasses: classes,
                    preselected: Array(self.localSelectedClassNames)
                )

                controller.onSelectionConfirmed = { [weak self] selection in
                    guard let self = self else { return }
                    self.localSelectedClassNames = Set(selection)
                    self.classSelectionController = nil
                    self.updateClassSelectionPresentation()
                }

                controller.onSelectionCancelled = { [weak self] in
                    guard let self = self else { return }
                    self.classSelectionController = nil
                    self.updateClassSelectionPresentation()
                }

                self.classSelectionController = controller
                window.beginSheet(controller.window!, completionHandler: nil)
            }
        }
    }

    @IBAction private func cancel(_ sender: Any) {
        finish(with: nil)
    }

    @IBAction private func launch(_ sender: Any) {
        guard let preferences = gatherPreferencesFromUI() else {
            NSSound.beep()
            return
        }

        let outputDirectory = resolveOutputDirectoryIfProvided()
        finish(with: Result(preferences: preferences, outputDirectory: outputDirectory))
    }

    private func finish(with result: Result?) {
        if let window = window {
            window.sheetParent?.endSheet(window, returnCode: result == nil ? .cancel : .OK)
        }
        onCompletion?(result)
    }

    /// Applies the current `configuration` to the window's UI controls and visual state.
    /// 
    /// Updates the window title and disables standard window buttons, populates task and device pop-up menus (only once per controller lifetime), selects items that match the configured task and device, sets the fast-mode checkbox, fills the class summary and license fields, ensures an output path is present (using the configured output directory or a fallback), and refreshes the launch button state.
    private func applyConfiguration() {
        guard let configuration = configuration else { return }

        if let window = window {
            window.title = NSLocalizedString("Run TotalSegmentator", comment: "Run window title")
            for button in [NSWindow.ButtonType.zoomButton, .miniaturizeButton, .closeButton] {
                window.standardWindowButton(button)?.isEnabled = false
            }
        }

        if !hasConfiguredOptions {
            // Populate the options only once so the user's selection survives when reopening the window.
            populatePopUpButton(taskPopupButton, with: configuration.taskOptions)
            populatePopUpButton(devicePopupButton, with: configuration.deviceOptions)
            hasConfiguredOptions = true
        }

        selectItem(in: taskPopupButton, matching: configuration.preferences.task)
        selectItem(in: devicePopupButton, matching: configuration.preferences.device)
        fastModeCheckbox?.state = configuration.preferences.useFast ? .on : .off

        classSummaryField?.isEditable = false
        classSummaryField?.isSelectable = false
        classSummaryField?.usesSingleLineMode = true
        classSummaryField?.lineBreakMode = .byTruncatingTail
        updateClassSelectionPresentation()

        let license = configuration.preferences.licenseKey ?? ""
        licenseField?.stringValue = license
        licenseField?.placeholderString = NSLocalizedString("Optional", comment: "Optional field placeholder")

        if let outputURL = configuration.outputDirectory {
            outputPathField?.stringValue = outputURL.path
        } else if outputPathField?.stringValue.isEmpty ?? true {
            outputPathField?.stringValue = fallbackOutputPath
        }

        updateLaunchButtonState()
    }

    private func populatePopUpButton(_ button: NSPopUpButton?, with options: [(title: String, value: String?)]) {
        guard let button = button else { return }
        button.removeAllItems()
        for option in options {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.value
            button.menu?.addItem(item)
        }
        button.menu?.items.first.map { button.select($0) }
    }

    private func selectItem(in button: NSPopUpButton?, matching value: String?) {
        guard let menuItems = button?.menu?.items else { return }
        if let value = value,
           let item = menuItems.first(where: { ($0.representedObject as? String) == value }) {
            button?.select(item)
        } else {
            button?.selectItem(at: 0)
        }
    }

    /// Constructs a `PreferencesState` by reading the current UI control values.
    /// 
    /// The returned preferences start from `configuration?.preferences` and are updated with the selected task and device (or `nil` if no selection), the fast-mode checkbox state, and the trimmed license string (empty license becomes `nil`).
    /// - Returns: The updated `PreferencesState` reflecting the UI selections, or `nil` if no base configuration is available.
    private func gatherPreferencesFromUI() -> PreferencesState? {
        guard var preferences = configuration?.preferences else { return nil }

        // Read the user's choice without assuming the menu items are always present.
        preferences.task = taskPopupButton?.selectedItem?.representedObject as? String
        preferences.device = devicePopupButton?.selectedItem?.representedObject as? String

        preferences.useFast = fastModeCheckbox?.state == .on

        let license = licenseField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        preferences.licenseKey = license.isEmpty ? nil : license
        if taskSupportsClassSelection(preferences.task) {
            preferences.selectedClassNames = Array(localSelectedClassNames).sorted()
        } else {
            preferences.selectedClassNames = []
        }

        return preferences
    }

    private func currentSelectedTask() -> String? {
        return taskPopupButton?.selectedItem?.representedObject as? String
    }

    private func taskSupportsClassSelection(_ task: String?) -> Bool {
        return onCheckTaskSupportsClassSelection?(task) ?? true
    }

    private func updateClassSelectionPresentation() {
        updateClassSelectionSummary()
        updateClassSelectionControlState()
    }

    private func updateClassSelectionSummary() {
        if !taskSupportsClassSelection(currentSelectedTask()) {
            classSummaryField?.stringValue = NSLocalizedString(
                "Class selection not supported",
                comment: "Run sheet class summary shown for tasks without ROI subset support"
            )
            classSummaryField?.toolTip = NSLocalizedString(
                "Only total tasks support --roi_subset.",
                comment: "Run sheet class summary tooltip for unsupported ROI subset tasks"
            )
            return
        }

        let summary = ClassSelectionSummaryFormatter.components(for: Array(localSelectedClassNames))
        classSummaryField?.stringValue = summary.text
        classSummaryField?.toolTip = summary.tooltip
    }

    private func updateClassSelectionControlState() {
        let task = currentSelectedTask()
        selectClassesButton?.isEnabled = taskSupportsClassSelection(task)
    }

    private func restoreSelectClassesButtonState() {
        updateClassSelectionPresentation()
    }

    private func resolveOutputDirectoryIfProvided() -> URL? {
        let path = outputPathField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectivePath: String
        if path.isEmpty {
            effectivePath = fallbackOutputPath
        } else {
            effectivePath = (path as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: effectivePath, isDirectory: true)
    }

    private func updateLaunchButtonState() {
        launchButton?.isEnabled = true
        launchButton?.alphaValue = 1.0
    }
}
