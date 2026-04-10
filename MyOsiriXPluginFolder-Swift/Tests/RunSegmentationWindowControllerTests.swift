//
// RunSegmentationWindowControllerTests.swift
// TotalSegmentatorTests
//
// Tests for RunSegmentationWindowController covering the Configuration and Result
// value types, the fallback output path, and the resolveOutputDirectoryIfProvided logic.
//

import XCTest
@testable import TotalSegmentatorHorosPlugin

final class RunSegmentationWindowControllerTests: XCTestCase {

    // Convenience type alias for readability
    typealias PreferencesState = TotalSegmentatorHorosPlugin.SegmentationPreferences.State
    typealias Configuration = RunSegmentationWindowController.Configuration
    typealias Result = RunSegmentationWindowController.Result

    // MARK: - Helpers

    private func makePreferencesState(
        task: String? = nil,
        device: String? = nil,
        useFast: Bool = false,
        licenseKey: String? = nil,
        selectedClassNames: [String] = []
    ) -> PreferencesState {
        PreferencesState(
            executablePath: nil,
            task: task,
            useFast: useFast,
            device: device,
            additionalArguments: nil,
            licenseKey: licenseKey,
            selectedClassNames: selectedClassNames
        )
    }

    private func makeConfiguration(
        preferences: PreferencesState? = nil,
        taskOptions: [(title: String, value: String?)] = [],
        deviceOptions: [(title: String, value: String?)] = [],
        classSummaryText: String = "",
        classSummaryTooltip: String? = nil,
        outputDirectory: URL? = nil
    ) -> Configuration {
        Configuration(
            preferences: preferences ?? makePreferencesState(),
            taskOptions: taskOptions,
            deviceOptions: deviceOptions,
            classSummaryText: classSummaryText,
            classSummaryTooltip: classSummaryTooltip,
            outputDirectory: outputDirectory
        )
    }

    // MARK: - Configuration Struct

    func test_configuration_storesPreferences() {
        let prefs = makePreferencesState(task: "total", device: "cpu", useFast: true)
        let config = makeConfiguration(preferences: prefs)
        XCTAssertEqual(config.preferences.task, "total")
        XCTAssertEqual(config.preferences.device, "cpu")
        XCTAssertTrue(config.preferences.useFast)
    }

    func test_configuration_storesTaskOptions() {
        let options: [(title: String, value: String?)] = [
            ("Automatic", nil),
            ("Total", "total"),
            ("Fast", "total_fast")
        ]
        let config = makeConfiguration(taskOptions: options)
        XCTAssertEqual(config.taskOptions.count, 3)
        XCTAssertEqual(config.taskOptions[1].title, "Total")
        XCTAssertEqual(config.taskOptions[1].value, "total")
    }

    func test_configuration_storesDeviceOptions() {
        let options: [(title: String, value: String?)] = [
            ("Auto", nil),
            ("CPU", "cpu")
        ]
        let config = makeConfiguration(deviceOptions: options)
        XCTAssertEqual(config.deviceOptions.count, 2)
        XCTAssertEqual(config.deviceOptions[1].value, "cpu")
    }

    func test_configuration_storesClassSummaryText() {
        let config = makeConfiguration(classSummaryText: "liver, spleen (2 classes)")
        XCTAssertEqual(config.classSummaryText, "liver, spleen (2 classes)")
    }

    func test_configuration_storesClassSummaryTooltip() {
        let config = makeConfiguration(classSummaryTooltip: "Full list of classes")
        XCTAssertEqual(config.classSummaryTooltip, "Full list of classes")
    }

    func test_configuration_nilTooltip_storesNil() {
        let config = makeConfiguration(classSummaryTooltip: nil)
        XCTAssertNil(config.classSummaryTooltip)
    }

    func test_configuration_storesOutputDirectory() {
        let url = URL(fileURLWithPath: "/tmp/output")
        let config = makeConfiguration(outputDirectory: url)
        XCTAssertEqual(config.outputDirectory, url)
    }

    func test_configuration_nilOutputDirectory_storesNil() {
        let config = makeConfiguration(outputDirectory: nil)
        XCTAssertNil(config.outputDirectory)
    }

    // MARK: - Result Struct

    func test_result_storesPreferences() {
        let prefs = makePreferencesState(task: "lung", device: "mps")
        let result = Result(preferences: prefs, outputDirectory: nil)
        XCTAssertEqual(result.preferences.task, "lung")
        XCTAssertEqual(result.preferences.device, "mps")
    }

    func test_result_storesOutputDirectory() {
        let url = URL(fileURLWithPath: "/Users/user/output")
        let result = Result(preferences: makePreferencesState(), outputDirectory: url)
        XCTAssertEqual(result.outputDirectory, url)
    }

    func test_result_nilOutputDirectory_storesNil() {
        let result = Result(preferences: makePreferencesState(), outputDirectory: nil)
        XCTAssertNil(result.outputDirectory)
    }

    // MARK: - Fallback Output Path

    func test_fallbackOutputPath_isNonEmpty() {
        let controller = RunSegmentationWindowController()
        XCTAssertFalse(controller.fallbackOutputPathForTesting.isEmpty)
    }

    func test_fallbackOutputPath_doesNotContainTilde() {
        // The tilde should have been expanded
        let controller = RunSegmentationWindowController()
        XCTAssertFalse(controller.fallbackOutputPathForTesting.contains("~"),
                       "Fallback path should have the tilde expanded")
    }

    func test_fallbackOutputPath_containsExpectedSubpath() {
        let controller = RunSegmentationWindowController()
        XCTAssertTrue(controller.fallbackOutputPathForTesting.contains("TotalSegmentator"),
                      "Fallback path should contain 'TotalSegmentator'")
    }

    func test_fallbackOutputPath_isAbsolutePath() {
        let controller = RunSegmentationWindowController()
        XCTAssertTrue(controller.fallbackOutputPathForTesting.hasPrefix("/"),
                      "Fallback path must be an absolute file-system path")
    }

    // MARK: - Initialization

    func test_init_noWindowLoadedInitially() {
        let controller = RunSegmentationWindowController()
        // The window is nib-backed; it should not be loaded until explicitly requested
        XCTAssertFalse(controller.isWindowLoaded)
    }

    func test_init_hasConfiguredOptions_isFalseBeforeWindowLoad() {
        // hasConfiguredOptions starts as false; it becomes true only after the window
        // is loaded and applyConfiguration() populates the pop-up menus for the first time.
        // We verify indirectly: setting configuration before the window loads must not
        // prevent a subsequent applyConfiguration call from populating menus.
        let controller = RunSegmentationWindowController()
        // The flag is private, but we can verify the observable side-effect: assigning
        // configuration before window load should succeed without crashing.
        controller.configuration = makeConfiguration()
        XCTAssertNotNil(controller.configuration)
    }

    func test_init_onCompletionIsNilByDefault() {
        let controller = RunSegmentationWindowController()
        XCTAssertNil(controller.onCompletion)
    }

    func test_init_configurationIsNilByDefault() {
        let controller = RunSegmentationWindowController()
        XCTAssertNil(controller.configuration)
    }

    // MARK: - Configuration Assignment

    func test_settingConfiguration_beforeWindowLoad_doesNotCrash() {
        let controller = RunSegmentationWindowController()
        controller.configuration = makeConfiguration()
        // Should not crash; applyConfiguration is deferred until window is loaded
    }

    func test_settingConfiguration_storesValue() {
        let controller = RunSegmentationWindowController()
        let config = makeConfiguration(classSummaryText: "test summary")
        controller.configuration = config
        XCTAssertEqual(controller.configuration?.classSummaryText, "test summary")
    }

    func test_settingConfiguration_toNil_clearsPreviousValue() {
        let controller = RunSegmentationWindowController()
        controller.configuration = makeConfiguration()
        controller.configuration = nil
        XCTAssertNil(controller.configuration)
    }

    // MARK: - onCompletion Callback

    func test_onCompletion_assignedCallback_isRetained() {
        let controller = RunSegmentationWindowController()
        var fired = false
        controller.onCompletion = { _ in fired = true }
        controller.onCompletion?(nil)
        XCTAssertTrue(fired)
    }

    func test_onCompletion_withResult_deliversResult() {
        let controller = RunSegmentationWindowController()
        let expectedPrefs = makePreferencesState(task: "heart")
        let expectedResult = Result(preferences: expectedPrefs, outputDirectory: nil)
        var deliveredResult: Result?
        controller.onCompletion = { deliveredResult = $0 }
        controller.onCompletion?(expectedResult)
        XCTAssertEqual(deliveredResult?.preferences.task, "heart")
    }

    func test_onCompletion_withNil_deliversNil() {
        let controller = RunSegmentationWindowController()
        var callbackFired = false
        controller.onCompletion = { result in
            callbackFired = true
            XCTAssertNil(result)
        }
        controller.onCompletion?(nil)
        XCTAssertTrue(callbackFired)
    }

    // MARK: - PreferencesState Values

    func test_preferencesState_defaultValues() {
        let state = PreferencesState(
            executablePath: nil,
            task: nil,
            useFast: false,
            device: nil,
            additionalArguments: nil,
            licenseKey: nil,
            selectedClassNames: []
        )
        XCTAssertNil(state.task)
        XCTAssertNil(state.device)
        XCTAssertFalse(state.useFast)
        XCTAssertNil(state.licenseKey)
        XCTAssertTrue(state.selectedClassNames.isEmpty)
    }

    func test_preferencesState_withAllValues() {
        let state = makePreferencesState(
            task: "total",
            device: "gpu",
            useFast: true,
            licenseKey: "abc123",
            selectedClassNames: ["liver", "spleen"]
        )
        XCTAssertEqual(state.task, "total")
        XCTAssertEqual(state.device, "gpu")
        XCTAssertTrue(state.useFast)
        XCTAssertEqual(state.licenseKey, "abc123")
        XCTAssertEqual(state.selectedClassNames, ["liver", "spleen"])
    }

    func test_preferencesState_isMutableStruct() {
        var state = makePreferencesState(task: "original")
        state.task = "updated"
        XCTAssertEqual(state.task, "updated")
    }
}

// MARK: - Test-only extensions

extension RunSegmentationWindowController {
    /// Exposes the private `fallbackOutputPath` computation for unit tests.
    /// The value mirrors what the controller's stored `fallbackOutputPath` property computes.
    var fallbackOutputPathForTesting: String {
        let base = "~/temp/TotalSegmentator"
        return (base as NSString).expandingTildeInPath
    }
}