//
// TotalSegmentatorHorosPlugin+Preferences.swift
// TotalSegmentator
//

import Cocoa

extension TotalSegmentatorHorosPlugin {
    struct SegmentationPreferences {
        struct State {
            var executablePath: String?
            var task: String?
            var useFast: Bool
            var device: String?
            var additionalArguments: String?
            var licenseKey: String?
            var selectedClassNames: [String]
            var dcm2niixPath: String?
            var hideROIs: Bool = false
            var rtStructExportMode: RTStructExportMode = .disabled
        }

        private enum Keys {
            static let executablePath = "TotalSegmentatorExecutablePath"
            static let task = "TotalSegmentatorTask"
            static let fastMode = "TotalSegmentatorFastMode"
            static let device = "TotalSegmentatorDevice"
            static let additionalArguments = "TotalSegmentatorAdditionalArguments"
            static let licenseKey = "TotalSegmentatorLicenseKey"
            static let selectedClasses = "TotalSegmentatorSelectedClasses"
            static let dcm2niixPath = "TotalSegmentatorDcm2NiixPath"
            static let hideROIs = "TotalSegmentatorHideROIs"
            static let rtStructExportMode = "TotalSegmentatorRTStructExportMode"
        }

        private let defaults = UserDefaults.standard

        /// Retrieves all currently saved segmentation preferences.
        /// - Returns: The current segmentation preferences.
        func effectivePreferences() -> State {
            let savedFastMode = defaults.object(forKey: Keys.fastMode) as? Bool
            return State(
                executablePath: defaults.string(forKey: Keys.executablePath),
                task: defaults.string(forKey: Keys.task),
                useFast: savedFastMode ?? true,
                device: defaults.string(forKey: Keys.device),
                additionalArguments: defaults.string(forKey: Keys.additionalArguments),
                licenseKey: defaults.string(forKey: Keys.licenseKey),
                selectedClassNames: defaults.stringArray(forKey: Keys.selectedClasses) ?? [],
                dcm2niixPath: defaults.string(forKey: Keys.dcm2niixPath),
                hideROIs: defaults.bool(forKey: Keys.hideROIs),
                rtStructExportMode: RTStructExportMode(preferenceValue: defaults.string(forKey: Keys.rtStructExportMode))
            )
        }

        /// Persists all preference settings to `UserDefaults`.
        func store(_ state: State) {
            defaults.setValue(state.executablePath, forKey: Keys.executablePath)
            defaults.setValue(state.task, forKey: Keys.task)
            defaults.setValue(state.useFast, forKey: Keys.fastMode)
            defaults.setValue(state.device, forKey: Keys.device)
            defaults.setValue(state.additionalArguments, forKey: Keys.additionalArguments)
            defaults.setValue(state.licenseKey, forKey: Keys.licenseKey)
            defaults.setValue(state.selectedClassNames, forKey: Keys.selectedClasses)
            defaults.setValue(state.dcm2niixPath, forKey: Keys.dcm2niixPath)
            defaults.setValue(state.hideROIs, forKey: Keys.hideROIs)
            defaults.setValue(state.rtStructExportMode.rawValue, forKey: Keys.rtStructExportMode)
        }

        /// Locates the TotalSegmentator executable.
        /// - Returns: The URL to the TotalSegmentator executable.
        /// - Throws: `SegmentationValidationError.executableNotFound` if the executable is not found.
        func defaultExecutableURL() throws -> URL {
            if let pythonHome = ProcessInfo.processInfo.environment["TOTALSEGMENTATOR_HOME"] {
                let url = URL(fileURLWithPath: pythonHome).appendingPathComponent("bin/TotalSegmentator")
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }

            let defaultPaths = [
                "/opt/homebrew/bin/TotalSegmentator",
                "/usr/local/bin/TotalSegmentator",
                "/usr/bin/TotalSegmentator"
            ]

            for path in defaultPaths where FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }

            throw SegmentationValidationError.executableNotFound
        }
    }
}
