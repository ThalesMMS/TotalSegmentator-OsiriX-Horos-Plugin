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

    static let groupedTaskOptions: [TaskGroup] = [
        TaskGroup(
            name: NSLocalizedString("Automatic", comment: "Task group header for automatic task selection"),
            tasks: [
                TaskOption(
                    title: NSLocalizedString("Automatic (default)", comment: "Default task option"),
                    value: nil,
                    description: NSLocalizedString("Leaves --task unset so TotalSegmentator uses its default task for the input images. Recommended for most workflows.", comment: "Task description for automatic task selection")
                )
            ]
        ),
        TaskGroup(
            name: NSLocalizedString("Whole Body", comment: "Task group header for whole body tasks"),
            tasks: [
                TaskOption(
                    title: "Total (multi-organ)",
                    value: "total",
                    description: NSLocalizedString("Segments 104 anatomical structures including organs, bones, and vessels. Best for comprehensive whole-body analysis.", comment: "Task description for total task")
                ),
                TaskOption(
                    title: "Body (fat & muscles)",
                    value: "body",
                    description: NSLocalizedString("Segments body composition structures such as fat and muscle compartments. Useful for body composition measurements rather than organ mapping.", comment: "Task description for body task")
                )
            ]
        ),
        TaskGroup(
            name: NSLocalizedString("Thorax & Cardiac", comment: "Task group header for thorax and cardiac tasks"),
            tasks: [
                TaskOption(
                    title: "Lung",
                    value: "lung",
                    description: NSLocalizedString("Segments the lungs and major pulmonary regions. Choose this when the study focus is thoracic anatomy.", comment: "Task description for lung task")
                ),
                TaskOption(
                    title: "Lung (vessels)",
                    value: "lung_vessels",
                    description: NSLocalizedString("Segments lung vessels in addition to lung structures. Use when vascular detail matters more than a broad body inventory.", comment: "Task description for lung vessels task")
                ),
                TaskOption(
                    title: "Heart",
                    value: "heart",
                    description: NSLocalizedString("Segments the heart as a focused thoracic structure. Use for a simpler cardiac target than chamber-level segmentation.", comment: "Task description for heart task")
                ),
                TaskOption(
                    title: "Cardiac (chambers)",
                    value: "cardiac",
                    description: NSLocalizedString("Segments cardiac chambers and related cardiac anatomy. Best for workflows that need chamber-level labels.", comment: "Task description for cardiac task")
                ),
                TaskOption(
                    title: "Coronary Arteries",
                    value: "coronary_arteries",
                    description: NSLocalizedString("Segments coronary artery structures. Use for focused cardiac vessel analysis when image quality supports it.", comment: "Task description for coronary arteries task")
                )
            ]
        ),
        TaskGroup(
            name: NSLocalizedString("Abdomen", comment: "Task group header for abdomen tasks"),
            tasks: [
                TaskOption(
                    title: "Kidneys",
                    value: "kidney",
                    description: NSLocalizedString("Segments kidney anatomy. Use for renal-focused studies where a full multi-organ run is unnecessary.", comment: "Task description for kidney task")
                ),
                TaskOption(
                    title: "Liver",
                    value: "liver",
                    description: NSLocalizedString("Segments liver anatomy. Use for liver-focused studies or when you want a narrower abdominal target.", comment: "Task description for liver task")
                ),
                TaskOption(
                    title: "Pelvis",
                    value: "pelvis",
                    description: NSLocalizedString("Segments pelvic anatomy. Useful when the field of view is centered on the pelvis.", comment: "Task description for pelvis task")
                ),
                TaskOption(
                    title: "Prostate",
                    value: "prostate",
                    description: NSLocalizedString("Segments prostate anatomy. Use for prostate-focused pelvic workflows.", comment: "Task description for prostate task")
                ),
                TaskOption(
                    title: "Spleen",
                    value: "spleen",
                    description: NSLocalizedString("Segments spleen anatomy. Use for spleen-focused abdominal studies.", comment: "Task description for spleen task")
                ),
                TaskOption(
                    title: "Pancreas",
                    value: "pancreas",
                    description: NSLocalizedString("Segments pancreas anatomy. Use for pancreas-focused abdominal workflows.", comment: "Task description for pancreas task")
                )
            ]
        ),
        TaskGroup(
            name: NSLocalizedString("Neuro", comment: "Task group header for neuro tasks"),
            tasks: [
                TaskOption(
                    title: "Head & Neck",
                    value: "headneck",
                    description: NSLocalizedString("Segments head and neck structures. Choose this for studies focused above the thorax.", comment: "Task description for head and neck task")
                ),
                TaskOption(
                    title: "Cerebral Bleed",
                    value: "cerebral_bleed",
                    description: NSLocalizedString("Segments suspected cerebral hemorrhage regions. Use for focused neuro workflows rather than general anatomy.", comment: "Task description for cerebral bleed task")
                ),
                TaskOption(
                    title: "Brain (structures)",
                    value: "brain_structures",
                    description: NSLocalizedString("Segments brain structures. Best for studies where intracranial anatomy is the primary target.", comment: "Task description for brain task")
                )
            ]
        ),
        TaskGroup(
            name: NSLocalizedString("Musculoskeletal", comment: "Task group header for musculoskeletal tasks"),
            tasks: [
                TaskOption(
                    title: "Femur",
                    value: "femur",
                    description: NSLocalizedString("Segments femur anatomy. Use for lower-extremity or hip-adjacent musculoskeletal studies.", comment: "Task description for femur task")
                ),
                TaskOption(
                    title: "Hip",
                    value: "hip",
                    description: NSLocalizedString("Segments hip anatomy. Useful for pelvic and proximal femur workflows.", comment: "Task description for hip task")
                ),
                TaskOption(
                    title: "Spine (vertebrae)",
                    value: "vertebrae",
                    description: NSLocalizedString("Segments vertebral structures. Use for spine-focused studies where vertebra labels are needed.", comment: "Task description for vertebrae task")
                )
            ]
        )
    ]

    static let canonicalTaskOptions: [(title: String, value: String?)] = groupedTaskOptions.flatMap { group in
        group.tasks.map { task in
            (title: task.title, value: task.value)
        }
    }

    static let canonicalDeviceOptions: [(title: String, value: String?)] = [
        (NSLocalizedString("Auto", comment: "Automatic device selection"), nil),
        ("cpu", "cpu"),
        ("gpu", "gpu"),
        ("mps", "mps")
    ]

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
    let roiResyncCoordinator = TotalSegmentatorROIResyncCoordinator()
    var classSelectionController: ClassSelectionWindowController?
    var runConfigurationController: RunSegmentationWindowController?
    var availableClassOptionsCache: [String: [String]] = [:]
    var selectedClassNames: Set<String> = [] {
        didSet { updateClassSelectionSummary() }
    }

    let taskOptions = TotalSegmentatorHorosPlugin.canonicalTaskOptions
    let taskGroups = TotalSegmentatorHorosPlugin.groupedTaskOptions
    let deviceOptions = TotalSegmentatorHorosPlugin.canonicalDeviceOptions

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

        NSLog("TotalSegmentatorHorosPlugin loaded and ready.")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.performInitialSetupIfNeeded()
        }
    }

    override func isCertifiedForMedicalImaging() -> Bool {
        return true
    }
}
