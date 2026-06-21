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
        taskGroups: [TaskGroup] = [],
        deviceOptions: [(title: String, value: String?)] = [],
        classSummaryText: String = "",
        classSummaryTooltip: String? = nil,
        outputDirectory: URL? = nil
    ) -> Configuration {
        Configuration(
            preferences: preferences ?? makePreferencesState(),
            taskGroups: taskGroups,
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

    func test_configuration_storesTaskGroups() {
        let groups = [
            TaskGroup(
                name: "Whole Body",
                tasks: [
                    TaskOption(title: "Total", value: "total", description: "All structures"),
                    TaskOption(title: "Body", value: "body", description: "Body composition")
                ]
            )
        ]
        let config = makeConfiguration(taskGroups: groups)
        XCTAssertEqual(config.taskGroups.count, 1)
        XCTAssertEqual(config.taskGroups[0].name, "Whole Body")
        XCTAssertEqual(config.taskGroups[0].tasks[0].title, "Total")
        XCTAssertEqual(config.taskGroups[0].tasks[0].value, "total")
        XCTAssertEqual(config.taskGroups[0].tasks[0].description, "All structures")
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
        let prefs = makePreferencesState(task: "lung_vessels", device: "mps")
        let result = Result(preferences: prefs, outputDirectory: nil)
        XCTAssertEqual(result.preferences.task, "lung_vessels")
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
        XCTAssertFalse(controller.fallbackOutputPath.isEmpty)
    }

    func test_fallbackOutputPath_doesNotContainTilde() {
        // The tilde should have been expanded
        let controller = RunSegmentationWindowController()
        XCTAssertFalse(controller.fallbackOutputPath.contains("~"),
                       "Fallback path should have the tilde expanded")
    }

    func test_fallbackOutputPath_containsExpectedSubpath() {
        let controller = RunSegmentationWindowController()
        XCTAssertTrue(controller.fallbackOutputPath.contains("TotalSegmentator"),
                      "Fallback path should contain 'TotalSegmentator'")
    }

    func test_fallbackOutputPath_isAbsolutePath() {
        let controller = RunSegmentationWindowController()
        XCTAssertTrue(controller.fallbackOutputPath.hasPrefix("/"),
                      "Fallback path must be an absolute file-system path")
    }

    // MARK: - Initialization

    func test_init_noWindowLoadedInitially() {
        let controller = RunSegmentationWindowController()
        // The window is nib-backed; it should not be loaded until explicitly requested
        XCTAssertFalse(controller.isWindowLoaded)
    }

    func test_init_settingConfigurationBeforeWindowLoad_doesNotLoadWindow() {
        let controller = RunSegmentationWindowController()
        let configuration = makeConfiguration(classSummaryText: "queued configuration")
        controller.configuration = configuration

        XCTAssertFalse(controller.isWindowLoaded)
        XCTAssertEqual(controller.configuration?.classSummaryText, "queued configuration")
    }

    func test_init_onCompletionIsNilByDefault() {
        let controller = RunSegmentationWindowController()
        XCTAssertNil(controller.onCompletion)
    }

    func test_init_classLoadingCallbacksAreNilByDefault() {
        let controller = RunSegmentationWindowController()
        XCTAssertNil(controller.onLoadClasses)
        XCTAssertNil(controller.onCheckTaskSupportsClassSelection)
        XCTAssertNil(controller.onCheckTaskSupportsFastMode)
        XCTAssertNil(controller.onCheckTaskRequiresLicense)
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

    func test_settingConfiguration_initializesLocalSelectedClassNames() {
        let controller = RunSegmentationWindowController()
        let preferences = makePreferencesState(selectedClassNames: ["spleen", "liver"])
        controller.configuration = makeConfiguration(preferences: preferences)

        XCTAssertEqual(controller.localSelectedClassNames, Set(["spleen", "liver"]))
    }

    func test_settingConfiguration_toNil_clearsPreviousValue() {
        let controller = RunSegmentationWindowController()
        controller.configuration = makeConfiguration()
        controller.configuration = nil
        XCTAssertNil(controller.configuration)
        XCTAssertTrue(controller.localSelectedClassNames.isEmpty)
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
        let expectedPrefs = makePreferencesState(task: "heartchambers_highres")
        let expectedResult = Result(preferences: expectedPrefs, outputDirectory: nil)
        var deliveredResult: Result?
        controller.onCompletion = { deliveredResult = $0 }
        controller.onCompletion?(expectedResult)
        XCTAssertEqual(deliveredResult?.preferences.task, "heartchambers_highres")
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

    func test_onLoadClasses_assignedCallbackDeliversClasses() {
        let controller = RunSegmentationWindowController()
        let expectation = expectation(description: "classes loaded")
        var receivedTask: String?
        var receivedExecutable: String?
        var receivedClasses: [String] = []

        controller.onLoadClasses = { task, executable, completion in
            receivedTask = task
            receivedExecutable = executable
            completion(["liver", "spleen"])
        }

        controller.onLoadClasses?("total", "/usr/bin/python3") { classes in
            receivedClasses = classes
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(receivedTask, "total")
        XCTAssertEqual(receivedExecutable, "/usr/bin/python3")
        XCTAssertEqual(receivedClasses, ["liver", "spleen"])
    }

    func test_onCheckTaskSupportsClassSelection_assignedCallbackReturnsValue() {
        let controller = RunSegmentationWindowController()
        var receivedTask: String?

        controller.onCheckTaskSupportsClassSelection = { task in
            receivedTask = task
            return task == "total"
        }

        XCTAssertEqual(controller.onCheckTaskSupportsClassSelection?("total"), true)
        XCTAssertEqual(receivedTask, "total")
    }

    // MARK: - onCheckTaskSupportsFastMode Callback

    func test_onCheckTaskSupportsFastMode_assignedCallbackReturnsTrue() {
        let controller = RunSegmentationWindowController()
        controller.onCheckTaskSupportsFastMode = { task in task == "total" }
        XCTAssertEqual(controller.onCheckTaskSupportsFastMode?("total"), true)
    }

    func test_onCheckTaskSupportsFastMode_assignedCallbackReturnsFalse() {
        let controller = RunSegmentationWindowController()
        controller.onCheckTaskSupportsFastMode = { task in task == "total" }
        XCTAssertEqual(controller.onCheckTaskSupportsFastMode?("lung_vessels"), false)
    }

    func test_onCheckTaskSupportsFastMode_receivesCorrectTaskParameter() {
        let controller = RunSegmentationWindowController()
        var receivedTask: String?
        controller.onCheckTaskSupportsFastMode = { task in
            receivedTask = task
            return true
        }
        _ = controller.onCheckTaskSupportsFastMode?("heartchambers_highres")
        XCTAssertEqual(receivedTask, "heartchambers_highres")
    }

    func test_onCheckTaskSupportsFastMode_receivesNilTask() {
        let controller = RunSegmentationWindowController()
        var receivedTask: String? = "initial"
        controller.onCheckTaskSupportsFastMode = { task in
            receivedTask = task
            return false
        }
        _ = controller.onCheckTaskSupportsFastMode?(nil)
        XCTAssertNil(receivedTask)
    }

    func test_onCheckTaskSupportsFastMode_canBeReplacedWithNewCallback() {
        let controller = RunSegmentationWindowController()
        controller.onCheckTaskSupportsFastMode = { _ in true }
        controller.onCheckTaskSupportsFastMode = { _ in false }
        XCTAssertEqual(controller.onCheckTaskSupportsFastMode?("total"), false)
    }

    func test_onCheckTaskSupportsFastMode_canBeSetToNil() {
        let controller = RunSegmentationWindowController()
        controller.onCheckTaskSupportsFastMode = { _ in true }
        controller.onCheckTaskSupportsFastMode = nil
        XCTAssertNil(controller.onCheckTaskSupportsFastMode)
    }

    // MARK: - onCheckTaskRequiresLicense Callback

    func test_onCheckTaskRequiresLicense_assignedCallbackReturnsTrue() {
        let controller = RunSegmentationWindowController()
        controller.onCheckTaskRequiresLicense = { task in task == "total_mr" }
        XCTAssertEqual(controller.onCheckTaskRequiresLicense?("total_mr"), true)
    }

    func test_onCheckTaskRequiresLicense_assignedCallbackReturnsFalse() {
        let controller = RunSegmentationWindowController()
        controller.onCheckTaskRequiresLicense = { task in task == "total_mr" }
        XCTAssertEqual(controller.onCheckTaskRequiresLicense?("total"), false)
    }

    func test_onCheckTaskRequiresLicense_receivesCorrectTaskParameter() {
        let controller = RunSegmentationWindowController()
        var receivedTask: String?
        controller.onCheckTaskRequiresLicense = { task in
            receivedTask = task
            return false
        }
        _ = controller.onCheckTaskRequiresLicense?("lung_vessels")
        XCTAssertEqual(receivedTask, "lung_vessels")
    }

    func test_onCheckTaskRequiresLicense_receivesNilTask() {
        let controller = RunSegmentationWindowController()
        var receivedTask: String? = "initial"
        controller.onCheckTaskRequiresLicense = { task in
            receivedTask = task
            return false
        }
        _ = controller.onCheckTaskRequiresLicense?(nil)
        XCTAssertNil(receivedTask)
    }

    func test_onCheckTaskRequiresLicense_canBeSetToNil() {
        let controller = RunSegmentationWindowController()
        controller.onCheckTaskRequiresLicense = { _ in true }
        controller.onCheckTaskRequiresLicense = nil
        XCTAssertNil(controller.onCheckTaskRequiresLicense)
    }

    func test_fastModeAndLicenseCallbacks_independentlyAssignable() {
        let controller = RunSegmentationWindowController()
        var fastModeCalled = false
        var licenseCalled = false
        controller.onCheckTaskSupportsFastMode = { _ in fastModeCalled = true; return true }
        controller.onCheckTaskRequiresLicense = { _ in licenseCalled = true; return false }
        _ = controller.onCheckTaskSupportsFastMode?("total")
        _ = controller.onCheckTaskRequiresLicense?("total")
        XCTAssertTrue(fastModeCalled)
        XCTAssertTrue(licenseCalled)
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
