//
// PluginTests.swift
// TotalSegmentatorTests
//
// Tests for Plugin.swift behavior, including MenuAction dispatch strings, the
// task and device option lists, and SegmentationOutputType (used by the Segmentation
// extension that is also part of the same PR).
//
// NOTE: Tests that instantiate TotalSegmentatorHorosPlugin directly require
// Horos.framework to be linked into the test target.  The tests below that work
// with plain value types (SegmentationOutputType, option tuples) can run without
// the framework.
//

import XCTest
@testable import TotalSegmentatorHorosPlugin

// MARK: - SegmentationOutputType Tests
// SegmentationOutputType is a value type defined in TotalSegmentatorPluginTypes.swift
// and used extensively in TotalSegmentatorHorosPlugin+Segmentation.swift.

final class SegmentationOutputTypeTests: XCTestCase {

    // MARK: - Initialisation from argument value

    func test_init_nilArgumentValue_producesDicom() {
        XCTAssertEqual(SegmentationOutputType(argumentValue: nil), .dicom)
    }

    func test_init_emptyString_producesDicom() {
        XCTAssertEqual(SegmentationOutputType(argumentValue: ""), .dicom)
    }

    func test_init_whitespaceOnly_producesDicom() {
        XCTAssertEqual(SegmentationOutputType(argumentValue: "   "), .dicom)
    }

    func test_init_dicomLowercase_producesDicom() {
        XCTAssertEqual(SegmentationOutputType(argumentValue: "dicom"), .dicom)
    }

    func test_init_dicomUppercase_producesDicom() {
        XCTAssertEqual(SegmentationOutputType(argumentValue: "DICOM"), .dicom)
    }

    func test_init_dicomMixedCase_producesDicom() {
        XCTAssertEqual(SegmentationOutputType(argumentValue: "DiCoM"), .dicom)
    }

    func test_init_niftiLowercase_producesNifti() {
        XCTAssertEqual(SegmentationOutputType(argumentValue: "nifti"), .nifti)
    }

    func test_init_niftiUppercase_producesNifti() {
        XCTAssertEqual(SegmentationOutputType(argumentValue: "NIFTI"), .nifti)
    }

    func test_init_niftiGz_producesNifti() {
        XCTAssertEqual(SegmentationOutputType(argumentValue: "nifti_gz"), .nifti)
    }

    func test_init_nii_producesNifti() {
        XCTAssertEqual(SegmentationOutputType(argumentValue: "nii"), .nifti)
    }

    func test_init_niiGz_producesNifti() {
        XCTAssertEqual(SegmentationOutputType(argumentValue: "nii.gz"), .nifti)
    }

    func test_init_unknownValue_producesOther() {
        if case .other(let v) = SegmentationOutputType(argumentValue: "custom_format") {
            XCTAssertEqual(v, "custom_format")
        } else {
            XCTFail("Expected .other for unknown value")
        }
    }

    func test_init_unknownValueWithLeadingWhitespace_normalizesToOther() {
        // Leading/trailing whitespace is stripped via trimmingCharacters before matching
        let result = SegmentationOutputType(argumentValue: "  unknown  ")
        if case .other = result {
            // Expected; "unknown" does not match any known case
        } else {
            XCTFail("Expected .other for unrecognised trimmed value")
        }
    }

    // MARK: - description

    func test_description_dicom_returnsDicom() {
        XCTAssertEqual(SegmentationOutputType.dicom.description, "dicom")
    }

    func test_description_nifti_returnsNifti() {
        XCTAssertEqual(SegmentationOutputType.nifti.description, "nifti")
    }

    func test_description_otherWithValue_returnsValue() {
        XCTAssertEqual(SegmentationOutputType.other("custom").description, "custom")
    }

    func test_description_otherWithNilValue_returnsUnknown() {
        XCTAssertEqual(SegmentationOutputType.other(nil).description, "unknown")
    }

    // MARK: - Equatability

    func test_equatable_sameCases_areEqual() {
        XCTAssertEqual(SegmentationOutputType.dicom, SegmentationOutputType.dicom)
        XCTAssertEqual(SegmentationOutputType.nifti, SegmentationOutputType.nifti)
    }

    func test_equatable_differentCases_areNotEqual() {
        XCTAssertNotEqual(SegmentationOutputType.dicom, SegmentationOutputType.nifti)
    }

    func test_equatable_otherWithSameValue_areEqual() {
        XCTAssertEqual(SegmentationOutputType.other("x"), SegmentationOutputType.other("x"))
    }

    func test_equatable_otherWithDifferentValues_areNotEqual() {
        XCTAssertNotEqual(SegmentationOutputType.other("x"), SegmentationOutputType.other("y"))
    }

    func test_equatable_otherNilValues_areEqual() {
        XCTAssertEqual(SegmentationOutputType.other(nil), SegmentationOutputType.other(nil))
    }
}

// MARK: - Plugin MenuAction String Constants
// These assertions use the canonical menu-title constants exported by Plugin.swift,
// so menu dispatch tests cannot drift from the runtime values.

final class PluginMenuActionStringTests: XCTestCase {

    func test_settingsMenuTitle_isNonEmpty() {
        XCTAssertFalse(TotalSegmentatorHorosPlugin.settingsMenuTitle.isEmpty)
    }

    func test_runMenuTitle_isNonEmpty() {
        XCTAssertFalse(TotalSegmentatorHorosPlugin.runMenuTitle.isEmpty)
    }

    func test_toolbarMenuTitle_isNonEmpty() {
        XCTAssertFalse(TotalSegmentatorHorosPlugin.toolbarMenuTitle.isEmpty)
    }

    func test_settingsMenuTitle_containsSettings() {
        XCTAssertTrue(TotalSegmentatorHorosPlugin.settingsMenuTitle.lowercased().contains("settings"))
    }

    func test_runMenuTitle_startsWithRun() {
        XCTAssertTrue(TotalSegmentatorHorosPlugin.runMenuTitle.lowercased().hasPrefix("run"))
    }

    func test_allMenuTitles_containPluginName() {
        for title in TotalSegmentatorHorosPlugin.menuTitles {
            XCTAssertTrue(title.contains(TotalSegmentatorHorosPlugin.pluginDisplayName))
        }
    }

    func test_menuTitles_areDistinct() {
        let titles = TotalSegmentatorHorosPlugin.menuTitles
        XCTAssertEqual(Set(titles).count, titles.count, "All menu titles must be unique")
    }

    func test_filterImage_returnValueRequiresHorosRuntime() throws {
        // Plugin.swift documents filterImage(_:) as returning 0 for every dispatch path,
        // but calling it here presents Horos/AppKit UI and requires the plugin runtime.
        throw XCTSkip("filterImage(_:) requires the Horos plugin runtime; see Plugin.swift filterImage(_:) documentation.")
    }
}

// MARK: - Plugin Certification Properties
// These properties are new in this PR and encode the plugin's medical-imaging
// certification status. They are read from the bundle's Info.plist with explicit
// fallback defaults, so they must be deterministic in tests.

final class PluginCertificationTests: XCTestCase {

    // MARK: Certification status identifier

    func test_certificationStatusIdentifier_isNonEmpty() {
        XCTAssertFalse(TotalSegmentatorHorosPlugin.certificationStatusIdentifier.isEmpty)
    }

    func test_certificationStatusIdentifier_defaultsToResearchNonDiagnostic() {
        // The bundled Info.plist ships with "research-non-diagnostic"; the static
        // property falls back to this value when the key is absent or empty.
        XCTAssertEqual(
            TotalSegmentatorHorosPlugin.certificationStatusIdentifier,
            "research-non-diagnostic"
        )
    }

    func test_certificationStatusIdentifier_doesNotContainWhitespace() {
        let id = TotalSegmentatorHorosPlugin.certificationStatusIdentifier
        XCTAssertFalse(
            id.contains(" ") || id.contains("\t") || id.contains("\n"),
            "certificationStatusIdentifier must not contain whitespace (it is used as a key)"
        )
    }

    // MARK: Certification status display name

    func test_certificationStatusDisplayName_isNonEmpty() {
        XCTAssertFalse(TotalSegmentatorHorosPlugin.certificationStatusDisplayName.isEmpty)
    }

    func test_certificationStatusDisplayName_defaultsToResearchNonDiagnostic() {
        XCTAssertEqual(
            TotalSegmentatorHorosPlugin.certificationStatusDisplayName,
            "Research/non-diagnostic"
        )
    }

    // MARK: Validation evidence version

    func test_validationEvidenceVersion_isNonEmpty() {
        XCTAssertFalse(TotalSegmentatorHorosPlugin.validationEvidenceVersion.isEmpty)
    }

    func test_validationEvidenceVersion_defaultsToNone() {
        // The bundled Info.plist ships with "none"; production builds with real
        // evidence would supply a non-"none" version string here.
        XCTAssertEqual(TotalSegmentatorHorosPlugin.validationEvidenceVersion, "none")
    }

    // MARK: Medical imaging certification claim

    func test_medicalImagingCertified_isFalseInDefaultBuild() {
        // The bundled Info.plist sets TotalSegmentatorMedicalImagingCertified = false,
        // so this property must be false without a valid production certification setup.
        XCTAssertFalse(TotalSegmentatorHorosPlugin.medicalImagingCertified)
    }

    func test_medicalImagingCertificationClaim_matchesMedicalImagingCertified() {
        XCTAssertEqual(
            TotalSegmentatorHorosPlugin.medicalImagingCertificationClaim,
            TotalSegmentatorHorosPlugin.medicalImagingCertified
        )
    }

    // MARK: Certification notice

    func test_certificationNotice_isNonEmpty() {
        XCTAssertFalse(TotalSegmentatorHorosPlugin.certificationNotice.isEmpty)
    }

    func test_certificationNotice_mentionsNonDiagnostic() {
        XCTAssertTrue(
            TotalSegmentatorHorosPlugin.certificationNotice
                .lowercased().contains("non-diagnostic"),
            "The certification notice must mention 'non-diagnostic' to communicate the usage restriction"
        )
    }

    // MARK: Consistency between certification fields

    func test_whenMedicalImagingCertifiedIsFalse_statusIdentifierShouldNotBeProductionValidation() {
        // When the plugin is not certified, the certification status identifier
        // must not claim production-validation status.
        if !TotalSegmentatorHorosPlugin.medicalImagingCertified {
            XCTAssertNotEqual(
                TotalSegmentatorHorosPlugin.certificationStatusIdentifier,
                "production-validation",
                "Non-certified builds must not carry a 'production-validation' status identifier"
            )
        }
    }

    func test_certificationStatusIdentifierAndDisplayName_areBothNonEmpty() {
        XCTAssertFalse(TotalSegmentatorHorosPlugin.certificationStatusIdentifier.isEmpty)
        XCTAssertFalse(TotalSegmentatorHorosPlugin.certificationStatusDisplayName.isEmpty)
    }
}

// MARK: - Device and Task Options
// These option arrays are defined in Plugin.swift and represent the full list of
// segmentation tasks and compute devices exposed to the user.

final class PluginOptionListTests: XCTestCase {

    private var taskOptions: [(title: String, value: String?)] {
        TotalSegmentatorHorosPlugin.canonicalTaskOptions
    }

    private var taskGroups: [TaskGroup] {
        TotalSegmentatorHorosPlugin.groupedTaskOptions
    }

    private var deviceOptions: [(title: String, value: String?)] {
        TotalSegmentatorHorosPlugin.canonicalDeviceOptions
    }

    // MARK: Task Options

    func test_taskOptions_firstEntry_hasNilValue() {
        XCTAssertNil(taskOptions.first?.value, "First task option should be automatic (nil value)")
    }

    func test_taskOptions_firstEntry_titleIsNonEmpty() {
        XCTAssertFalse(taskOptions.first?.title.isEmpty ?? true)
    }

    func test_taskOptions_allTitlesAreNonEmpty() {
        for option in taskOptions {
            XCTAssertFalse(option.title.isEmpty, "Option with value '\(option.value ?? "nil")' has empty title")
        }
    }

    func test_taskOptions_nonNilValuesAreNonEmpty() {
        for option in taskOptions where option.value != nil {
            XCTAssertFalse(option.value!.isEmpty, "Task value for '\(option.title)' must not be an empty string")
        }
    }

    func test_taskOptions_containsTotal() {
        XCTAssertTrue(taskOptions.contains(where: { $0.value == "total" }))
    }

    func test_taskOptions_doNotContainTotalFastTask() {
        XCTAssertFalse(taskOptions.contains(where: { $0.value == "total_fast" }))
        XCTAssertFalse(taskOptions.contains(where: { $0.title == "Total (fast)" }))
    }

    func test_taskOptions_doNotContainAnatomyAliasesAsTaskValues() {
        let invalidAliases = [
            "lung",
            "heart",
            "kidney",
            "liver",
            "pelvis",
            "prostate",
            "spleen",
            "pancreas",
            "headneck",
            "femur",
            "hip",
            "vertebrae"
        ]

        for alias in invalidAliases {
            XCTAssertFalse(taskOptions.contains(where: { $0.value == alias }))
        }
    }

    func test_taskOptions_containsBackendLungVesselsTask() {
        XCTAssertTrue(taskOptions.contains(where: { $0.value == "lung_vessels" }))
    }

    func test_taskOptions_containsBackendHeartChambersTask() {
        XCTAssertTrue(taskOptions.contains(where: { $0.value == "heartchambers_highres" }))
    }

    func test_taskOptions_nonNilValuesAreUnique() {
        let values = taskOptions.compactMap { $0.value }
        XCTAssertEqual(values.count, Set(values).count, "Task option values must be unique")
    }

    func test_taskOptions_countIsGreaterThanOne() {
        XCTAssertGreaterThan(taskOptions.count, 1)
    }

    func test_groupedTaskOptions_allGroupsHaveNamesAndTasks() {
        for group in taskGroups {
            XCTAssertFalse(group.name.isEmpty, "Task group names must not be empty")
            XCTAssertFalse(group.tasks.isEmpty, "Task group '\(group.name)' must contain at least one task")
        }
    }

    func test_groupedTaskOptions_allDescriptionsAreNonEmpty() {
        for group in taskGroups {
            for task in group.tasks {
                XCTAssertFalse(task.description.isEmpty, "Task '\(task.title)' must have helper text")
            }
        }
    }

    func test_canonicalTaskOptions_areDerivedFromGroupedTaskOptions() {
        let flattened = taskGroups.flatMap { group in
            group.tasks.map { task in
                (title: task.title, value: task.value)
            }
        }

        XCTAssertEqual(taskOptions.count, flattened.count)
        for (index, option) in taskOptions.enumerated() {
            XCTAssertEqual(option.title, flattened[index].title)
            XCTAssertEqual(option.value, flattened[index].value)
        }
    }

    // MARK: Device Options

    func test_deviceOptions_firstEntry_hasNilValue() {
        XCTAssertNil(deviceOptions.first?.value, "First device option should be automatic (nil value)")
    }

    func test_deviceOptions_containsCpu() {
        XCTAssertTrue(deviceOptions.contains(where: { $0.value == "cpu" }))
    }

    func test_deviceOptions_containsGpu() {
        XCTAssertTrue(deviceOptions.contains(where: { $0.value == "gpu" }))
    }

    func test_deviceOptions_containsMps() {
        XCTAssertTrue(deviceOptions.contains(where: { $0.value == "mps" }))
    }

    func test_deviceOptions_allTitlesAreNonEmpty() {
        for option in deviceOptions {
            XCTAssertFalse(option.title.isEmpty, "Device option title must not be empty")
        }
    }

    func test_deviceOptions_nonNilValuesAreUnique() {
        let values = deviceOptions.compactMap { $0.value }
        XCTAssertEqual(values.count, Set(values).count, "Device option values must be unique")
    }

    func test_deviceOptions_exactlyFourEntries() {
        // Auto + cpu + gpu + mps
        XCTAssertEqual(deviceOptions.count, 4)
    }
}
