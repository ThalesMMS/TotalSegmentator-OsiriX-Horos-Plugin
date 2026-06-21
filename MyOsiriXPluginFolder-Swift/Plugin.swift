//
// Plugin.swift
// TotalSegmentator
//
// Main Horos plugin that exports DICOM series, runs the TotalSegmentator CLI, and imports masks back as overlays.
//
// Thales Matheus Mendonça Santos - November 2025
//

import Cocoa
import CoreData

// Plugin that bridges TotalSegmentator (the Python CLI) with Horos/OsiriX.
// It exports the open DICOM series, runs the model, and brings the masks back as overlays.

/// Main implementation of the Horos filter.
/// Orchestrates DICOM export, TotalSegmentator execution, and mask reimport.
@objc(TotalSegmentatorHorosPlugin)
class TotalSegmentatorHorosPlugin: PluginFilter {
    static let pluginDisplayName = "TotalSegmentator"
    static let settingsMenuTitle = "TotalSegmentator Settings"
    static let runMenuTitle = "Run TotalSegmentator"
    static let toolbarMenuTitle = "TotalSegmentator"
    static let menuTitles = [settingsMenuTitle, runMenuTitle, toolbarMenuTitle]
    static let certificationStatusIdentifier = pluginBundleString(
        for: "TotalSegmentatorCertificationStatusIdentifier",
        defaultValue: "research-non-diagnostic"
    )
    static let certificationStatusDisplayName = pluginBundleString(
        for: "TotalSegmentatorCertificationStatusDisplayName",
        defaultValue: "Research/non-diagnostic"
    )
    static let validationEvidenceVersion = pluginBundleString(
        for: "TotalSegmentatorValidationEvidenceVersion",
        defaultValue: "none"
    )
    static let medicalImagingCertified: Bool = {
        let configuredClaim = Bundle(for: TotalSegmentatorHorosPlugin.self)
            .object(forInfoDictionaryKey: "TotalSegmentatorMedicalImagingCertified") as? Bool ?? false
        guard configuredClaim else { return false }

        let evidenceVersion = validationEvidenceVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard certificationStatusIdentifier == "production-validation",
              !evidenceVersion.isEmpty,
              evidenceVersion.lowercased() != "none" else {
            return false
        }

        return configuredClaim
    }()
    static let certificationNotice = "Research/non-diagnostic build: not certified for diagnostic medical imaging use."

    static let groupedTaskOptions: [TaskGroup] = taskGroupsFromCapabilityManifest(taskCapabilityManifest)

    static let canonicalTaskOptions: [(title: String, value: String?)] = groupedTaskOptions.flatMap { group in
        group.tasks.map { task in
            (title: task.title, value: task.value)
        }
    }

    static let canonicalDeviceOptions: [(title: String, value: String?)] = runtimeDeviceOptions(
        from: fallbackRuntimeCapabilityProbe()
    )

    @IBOutlet weak var settingsWindow: NSWindow!
    @IBOutlet weak var executablePathField: NSTextField!
    @IBOutlet weak var taskPopupButton: NSPopUpButton!
    @IBOutlet weak var devicePopupButton: NSPopUpButton!
    @IBOutlet weak var fastModeCheckbox: NSButton!
    @IBOutlet weak var hideROIsCheckbox: NSButton!
    @IBOutlet weak var additionalArgumentsField: NSTextField!
    @IBOutlet weak var licenseKeyField: NSTextField!
    @IBOutlet weak var classSelectionSummaryField: NSTextField!
    @IBOutlet weak var classSelectionButton: NSButton!

    private enum MenuAction {
        case showSettings
        case runSegmentation
        case toolbarAction

        init?(menuTitle: String) {
            switch menuTitle {
            case TotalSegmentatorHorosPlugin.settingsMenuTitle:
                self = .showSettings
            case TotalSegmentatorHorosPlugin.runMenuTitle:
                self = .runSegmentation
            case TotalSegmentatorHorosPlugin.toolbarMenuTitle:
                self = .toolbarAction
            default:
                return nil
            }
        }
    }

    let preferences = SegmentationPreferences()
    var errorLogWindowController: SegmentationProgressWindowController?
    let auditQueue = DispatchQueue(label: "org.totalsegmentator.horos.audit", qos: .utility)
    private static let sharedEnvironmentLifecycleManager = EnvironmentLifecycleManager()
    var environmentLifecycleManager: EnvironmentLifecycleManager { Self.sharedEnvironmentLifecycleManager }
    private static let sharedROIResyncCoordinator = TotalSegmentatorROIResyncCoordinator()
    var roiResyncCoordinator: TotalSegmentatorROIResyncCoordinator { Self.sharedROIResyncCoordinator }
    var classSelectionController: ClassSelectionWindowController?
    var runConfigurationController: RunSegmentationWindowController?
    var availableClassOptionsCache: [String: [String]] = [:]
    var selectedClassNames: Set<String> = [] {
        didSet { updateClassSelectionSummary() }
    }

    let taskOptions = TotalSegmentatorHorosPlugin.canonicalTaskOptions
    let taskGroups = TotalSegmentatorHorosPlugin.groupedTaskOptions
    let deviceOptions = TotalSegmentatorHorosPlugin.canonicalDeviceOptions

    private static func pluginBundleString(for key: String, defaultValue: String) -> String {
        let value = Bundle(for: TotalSegmentatorHorosPlugin.self).object(forInfoDictionaryKey: key) as? String
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? defaultValue : trimmedValue
    }

    /// Handle a Horos menu action by dispatching the corresponding plugin behavior.
    /// - Parameters:
    ///   - menuName: The title of the invoked menu item that identifies the action to perform; may be `nil` or unrecognized.
    /// - Returns: An integer status code (always `0`). If `menuName` is `nil` or not a supported action, an alert is presented and the function returns `0`.
    override func filterImage(_ menuName: String!) -> Int {
        logToConsole("filterImage invoked for menu action: \(menuName ?? "nil")")
        guard let menuName = menuName,
              let action = MenuAction(menuTitle: menuName) else {
            NSLog("TotalSegmentatorHorosPlugin received unsupported menu action: %@", menuName ?? "nil")
            presentAlert(title: "TotalSegmentator", message: "Unsupported action selected.")
            return 0
        }

        guard Self.capabilityManifestIsAvailable else {
            presentCapabilityManifestLoadFailure()
            return 0
        }

        switch action {
        case .showSettings:
            presentSettingsWindow()
        case .runSegmentation, .toolbarAction:
            startSegmentationFlow()
        }

        return 0
    }

    override func initPlugin() {
        let bundle = Bundle(for: type(of: self))
        bundle.loadNibNamed("Settings", owner: self, topLevelObjects: nil)
        // Force light appearance for consistent look
        settingsWindow?.appearance = NSAppearance(named: .aqua)
        settingsWindow?.delegate = self
        configureSettingsInterfaceIfNeeded()

        selectedClassNames = Set(preferences.effectivePreferences().selectedClassNames)

        guard Self.capabilityManifestIsAvailable else {
            presentCapabilityManifestLoadFailure()
            return
        }

        NSLog("TotalSegmentatorHorosPlugin loaded and ready.")
        NSLog("[TotalSegmentator] %@", Self.certificationNotice)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let result = self.prepareEnvironmentIfNeeded()
            if !result.isReady {
                self.presentEnvironmentSetupFailureInstructions(for: result)
            }
        }
    }

    override func isCertifiedForMedicalImaging() -> Bool {
        return Self.medicalImagingCertified
    }

    func presentCapabilityManifestLoadFailure() {
        let message = Self.capabilityManifestLoadFailureMessage
        logToConsole(message)
        DispatchQueue.main.async {
            self.presentAlert(title: "TotalSegmentator", message: message)
        }
    }
}
