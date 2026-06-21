//
// TotalSegmentatorRuntimeCapabilities.swift
// TotalSegmentator
//
// Runtime capability probing and execution policy helpers.
//

import Cocoa

struct RuntimeTorchCapability: Codable {
    let version: String?
    let cudaVersion: String?

    enum CodingKeys: String, CodingKey {
        case version
        case cudaVersion = "cuda_version"
    }
}

struct RuntimeDeviceCapability: Codable {
    let value: String
    let available: Bool
    let validated: Bool
    let experimental: Bool
    let reason: String
    let name: String?
    let deviceCount: Int?
    let computeCapability: String?
    let usableMemoryMB: Int?

    enum CodingKeys: String, CodingKey {
        case value
        case available
        case validated
        case experimental
        case reason
        case name
        case deviceCount = "device_count"
        case computeCapability = "compute_capability"
        case usableMemoryMB = "usable_memory_mb"
    }
}

struct RuntimeCapabilityProbe: Codable {
    static let currentSchemaVersion = 1
    static let currentProbeVersion = "2026.06.runtime-capabilities.v1"

    let schemaVersion: Int
    let probeVersion: String
    let pythonVersion: String?
    let pythonExecutable: String?
    let architecture: String
    let cpuArchitecture: String
    let availableMemoryMB: Int?
    let torch: RuntimeTorchCapability
    let backendRecognizedDeviceValues: [String]
    let devices: [RuntimeDeviceCapability]
    let resamplingBackends: [String: Bool]
    let failures: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case probeVersion = "probe_version"
        case pythonVersion = "python_version"
        case pythonExecutable = "python_executable"
        case architecture
        case cpuArchitecture = "cpu_architecture"
        case availableMemoryMB = "available_memory_mb"
        case torch
        case backendRecognizedDeviceValues = "backend_recognized_device_values"
        case devices
        case resamplingBackends = "resampling_backends"
        case failures
    }

    /// Retrieves the capability information for the specified device.
    /// - Returns: The capability information if a device with a matching value is found, `nil` otherwise.
    func capability(for device: String) -> RuntimeDeviceCapability? {
        devices.first { $0.value == device }
    }
}

struct RuntimeExecutionPolicy {
    let runtimeProbe: RuntimeCapabilityProbe
    let requestedDevice: String?
    let effectiveDevice: String
    let requestedQuality: String
    let effectiveQuality: String
    let sanitizedAdditionalArguments: [String]
    let cliArguments: [String]
    let selectionReason: String
    let warnings: [String]
    let fallbackUsed: Bool
    let probeFailures: [String]
}

enum RuntimeCapabilityPolicyError: LocalizedError {
    case unsupportedDevice(String)
    case unavailableDevice(device: String, reason: String)
    case unsupportedQuality(task: String, quality: String)
    case insufficientMemory(availableMB: Int, requiredMB: Int)
    case noValidatedDevice

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice(let device):
            return "The selected execution device '\(device)' is not recognized by the pinned TotalSegmentator runtime."
        case .unavailableDevice(let device, let reason):
            return "The selected execution device '\(device)' is not available for this TotalSegmentator runtime. \(reason)"
        case .unsupportedQuality(let task, let quality):
            return "The selected TotalSegmentator task '\(task)' does not support '\(quality)' quality mode according to the capability policy."
        case .insufficientMemory(let availableMB, let requiredMB):
            return "The system has \(availableMB) MB of available memory, below the \(requiredMB) MB minimum required before launching TotalSegmentator."
        case .noValidatedDevice:
            return "No validated TotalSegmentator execution device is available."
        }
    }
}

extension TotalSegmentatorHorosPlugin {
    /// Constructs a fallback runtime capability probe when probing is unavailable.
    /// - Parameters:
    ///   - failures: Probe failure messages to include in the returned probe.
    /// - Returns: A runtime capability probe with CPU as the only validated device and GPU/MPS marked as unprobed.
    static func fallbackRuntimeCapabilityProbe(failures: [String] = []) -> RuntimeCapabilityProbe {
        RuntimeCapabilityProbe(
            schemaVersion: RuntimeCapabilityProbe.currentSchemaVersion,
            probeVersion: RuntimeCapabilityProbe.currentProbeVersion,
            pythonVersion: nil,
            pythonExecutable: nil,
            architecture: currentSwiftArchitecture(),
            cpuArchitecture: currentSwiftArchitecture(),
            availableMemoryMB: nil,
            torch: RuntimeTorchCapability(version: nil, cudaVersion: nil),
            backendRecognizedDeviceValues: ["cpu", "gpu", "mps"],
            devices: [
                RuntimeDeviceCapability(
                    value: "cpu",
                    available: true,
                    validated: true,
                    experimental: false,
                    reason: "CPU fallback policy is available without accelerator probing.",
                    name: nil,
                    deviceCount: nil,
                    computeCapability: nil,
                    usableMemoryMB: nil
                ),
                RuntimeDeviceCapability(
                    value: "gpu",
                    available: false,
                    validated: false,
                    experimental: false,
                    reason: "CUDA was not probed yet.",
                    name: nil,
                    deviceCount: nil,
                    computeCapability: nil,
                    usableMemoryMB: nil
                ),
                RuntimeDeviceCapability(
                    value: "mps",
                    available: false,
                    validated: false,
                    experimental: false,
                    reason: "MPS was not probed yet.",
                    name: nil,
                    deviceCount: nil,
                    computeCapability: nil,
                    usableMemoryMB: nil
                )
            ],
            resamplingBackends: [:],
            failures: failures
        )
    }

    /// Produces UI-selectable device options from runtime capability data.
    /// - Returns: An array of tuples with display title and device identifier. Begins with an "Auto" option, followed by available validated devices.
    static func runtimeDeviceOptions(from probe: RuntimeCapabilityProbe) -> [(title: String, value: String?)] {
        var options: [(title: String, value: String?)] = [
            (NSLocalizedString("Auto", comment: "Automatic device selection"), nil)
        ]

        for value in ["cpu", "gpu", "mps"] {
            guard let capability = probe.capability(for: value),
                  capability.available,
                  capability.validated,
                  !capability.experimental else {
                continue
            }

            let title: String
            switch value {
            case "cpu":
                title = "CPU"
            case "gpu":
                title = capability.name?.isEmpty == false ? "GPU (\(capability.name!))" : "GPU"
            case "mps":
                title = "MPS"
            default:
                title = value
            }
            options.append((title: title, value: value))
        }

        return options
    }

    /// Determines whether a device value is selectable in the given options.
    /// - Parameters:
    ///   - value: The device value to validate.
    ///   - options: The list of available device options.
    /// - Returns: `true` if the value is `nil`, empty, or matches an option value; `false` otherwise.
    static func deviceValueIsSelectable(_ value: String?, in options: [(title: String, value: String?)]) -> Bool {
        guard let value = value, !value.isEmpty else { return true }
        return options.contains { $0.value == value }
    }

    /// Resolves runtime device and quality selection into an execution policy.
    ///
    /// Validates quality against the task's capability constraints, enforces minimum memory requirements, and selects a device based on user request or automatic priority selection.
    ///
    /// - Parameters:
    ///   - requestedDevice: The device requested by the user, or `nil` for automatic selection.
    ///   - requestedUseFast: Whether to use fast quality mode.
    ///   - additionalArguments: Additional arguments that may contain quality flags.
    ///   - taskCapability: The task's supported quality modes and constraints.
    ///   - probe: The runtime probe results containing available devices and their capabilities.
    ///   - allowExperimentalAccelerators: Whether to permit experimental accelerators; defaults to `false`.
    /// - Returns: A `RuntimeExecutionPolicy` containing the resolved device, quality mode, CLI arguments, and warnings.
    /// - Throws: `RuntimeCapabilityPolicyError` if quality is unsupported, the device is unavailable or unvalidated, memory is insufficient, or no validated device is available.
    static func resolveRuntimeExecutionPolicy(
        requestedDevice: String?,
        requestedUseFast: Bool,
        additionalArguments: [String],
        taskCapability: TaskCapability,
        runtimeProbe probe: RuntimeCapabilityProbe,
        allowExperimentalAccelerators: Bool = false
    ) throws -> RuntimeExecutionPolicy {
        let requestedQuality = runtimeQualityMode(useFast: requestedUseFast, additionalArguments: additionalArguments)
        guard taskCapability.qualityModes.contains(requestedQuality) else {
            throw RuntimeCapabilityPolicyError.unsupportedQuality(task: taskCapability.identifier, quality: requestedQuality)
        }

        let sanitizedAdditionalArguments = removeRuntimeQualityTokens(from: additionalArguments)
        if let availableMemoryMB = probe.availableMemoryMB, availableMemoryMB < 2_048 {
            throw RuntimeCapabilityPolicyError.insufficientMemory(availableMB: availableMemoryMB, requiredMB: 2_048)
        }

        var warnings: [String] = []
        if let availableMemoryMB = probe.availableMemoryMB, availableMemoryMB < 8_192 {
            warnings.append("Available memory is \(availableMemoryMB) MB; large TotalSegmentator tasks may fail or run slowly.")
        }
        warnings.append(contentsOf: probe.failures)

        let recognizedDevices = Set(probe.backendRecognizedDeviceValues)
        let effectiveDevice: String
        let selectionReason: String
        let fallbackUsed: Bool

        if let requested = requestedDevice?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            guard recognizedDevices.contains(requested) else {
                throw RuntimeCapabilityPolicyError.unsupportedDevice(requested)
            }
            guard let capability = probe.capability(for: requested),
                  capability.available,
                  capability.validated,
                  (!capability.experimental || allowExperimentalAccelerators) else {
                throw RuntimeCapabilityPolicyError.unavailableDevice(
                    device: requested,
                    reason: probe.capability(for: requested)?.reason ?? "The runtime probe did not validate this device."
                )
            }
            effectiveDevice = requested
            selectionReason = "Using user-selected \(requested) because the runtime probe validated it."
            fallbackUsed = false
        } else if let selected = ["gpu", "mps", "cpu"].compactMap({ probe.capability(for: $0) }).first(where: {
            $0.available && $0.validated && (!$0.experimental || allowExperimentalAccelerators)
        }) {
            effectiveDevice = selected.value
            selectionReason = "Auto selected \(selected.value) because it is the highest-priority validated runtime device."
            fallbackUsed = selected.value == "cpu"
        } else {
            throw RuntimeCapabilityPolicyError.noValidatedDevice
        }

        var cliArguments: [String] = []
        switch requestedQuality {
        case "fast":
            cliArguments.append("--fast")
        case "fastest":
            cliArguments.append("--fastest")
        default:
            break
        }
        cliArguments.append(contentsOf: ["--device", effectiveDevice])

        return RuntimeExecutionPolicy(
            runtimeProbe: probe,
            requestedDevice: requestedDevice,
            effectiveDevice: effectiveDevice,
            requestedQuality: requestedQuality,
            effectiveQuality: requestedQuality,
            sanitizedAdditionalArguments: sanitizedAdditionalArguments,
            cliArguments: cliArguments,
            selectionReason: selectionReason,
            warnings: warnings,
            fallbackUsed: fallbackUsed,
            probeFailures: probe.failures
        )
    }

    /// Resolves the quality mode to use.
    /// - Parameters:
    ///   - useFast: Indicates preference for fast processing.
    ///   - additionalArguments: Arguments to inspect for quality-mode flags.
    /// - Returns: `"fastest"` if `--fastest` is found, `"fast"` if `useFast` is `true` or `--fast` is found, `"normal"` otherwise.
    static func runtimeQualityMode(useFast: Bool, additionalArguments: [String]) -> String {
        if TaskCapabilityManifest.containsFlag("--fastest", in: additionalArguments) {
            return "fastest"
        }
        if useFast || TaskCapabilityManifest.containsFlag("--fast", in: additionalArguments) {
            return "fast"
        }
        return "normal"
    }

    /// Removes runtime quality-related tokens from command-line arguments.
    /// - Returns: The arguments with quality tokens removed.
    static func removeRuntimeQualityTokens(from arguments: [String]) -> [String] {
        arguments.filter { token in
            token != "--fast"
                && token != "--fastest"
                && !token.hasPrefix("--fast=")
                && !token.hasPrefix("--fastest=")
        }
    }
}

/// Identifies the current Swift architecture.
/// - Returns: `"arm64"`, `"x86_64"`, or `"unknown"`.
private func currentSwiftArchitecture() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}
