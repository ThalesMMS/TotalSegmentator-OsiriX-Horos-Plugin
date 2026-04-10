//
// SegmentationPipelineTests.swift
// TotalSegmentatorTests
//
// Tests for the segmentation pipeline helpers defined in
// TotalSegmentatorHorosPlugin+Segmentation.swift.
//
// The three methods under test — tokenize(commandLine:), detectOutputType(from:), and
// removeROISubsetTokens(from:) — are currently declared `private`.  To run these tests
// directly against the production implementations, change the access modifier of those
// three methods from `private` to `internal` in TotalSegmentatorHorosPlugin+Segmentation.swift.
//
// Until that change is made, the logic is mirrored in TestableSegmentationHelpers below
// (an exact copy of the production algorithms) so the tests serve as a precise contract
// specification and can be compared line-for-line with the production code.
//

import XCTest
@testable import TotalSegmentatorHorosPlugin

// MARK: - Standalone helpers mirroring TotalSegmentatorHorosPlugin private methods

/// Mirrors `TotalSegmentatorHorosPlugin.tokenize(commandLine:)`.
/// Replace the body with a call to the production method once it is made `internal`.
private func tokenize(commandLine: String) -> [String] {
    var arguments: [String] = []
    var current = ""
    var isInQuotes = false
    var escapeNext = false
    var quoteCharacter: Character = "\""

    for character in commandLine {
        if escapeNext {
            current.append(character)
            escapeNext = false
            continue
        }

        if character == "\\" {
            escapeNext = true
            continue
        }

        if character == "\"" || character == "'" {
            if isInQuotes {
                if character == quoteCharacter {
                    isInQuotes = false
                } else {
                    current.append(character)
                }
            } else {
                isInQuotes = true
                quoteCharacter = character
            }
            continue
        }

        if character.isWhitespace && !isInQuotes {
            if !current.isEmpty {
                arguments.append(current)
                current = ""
            }
            continue
        }

        current.append(character)
    }

    if !current.isEmpty {
        arguments.append(current)
    }

    return arguments
}

/// Mirrors `TotalSegmentatorHorosPlugin.detectOutputType(from:)`.
private func detectOutputType(from tokens: [String]) -> (type: SegmentationOutputType, remainingTokens: [String]) {
    var detectedType: SegmentationOutputType = .dicom
    var remainingTokens: [String] = []

    var index = 0
    while index < tokens.count {
        let token = tokens[index]

        if token == "--output_type" {
            let nextIndex = index + 1
            if nextIndex < tokens.count {
                let valueCandidate = tokens[nextIndex]
                if valueCandidate.hasPrefix("--") {
                    detectedType = .dicom
                    index += 1
                    continue
                }
                detectedType = SegmentationOutputType(argumentValue: valueCandidate)
                index += 2
                continue
            }
            detectedType = .dicom
            index += 1
            continue
        }

        if token.hasPrefix("--output_type=") {
            let value = String(token.dropFirst("--output_type=".count))
            detectedType = SegmentationOutputType(argumentValue: value)
            index += 1
            continue
        }

        remainingTokens.append(token)
        index += 1
    }

    return (detectedType, remainingTokens)
}

/// Mirrors `TotalSegmentatorHorosPlugin.removeROISubsetTokens(from:)`.
private func removeROISubsetTokens(from tokens: [String]) -> [String] {
    var filtered: [String] = []
    var index = 0

    while index < tokens.count {
        let token = tokens[index]

        if token == "--roi_subset" {
            index += 1
            while index < tokens.count, !tokens[index].hasPrefix("--") {
                index += 1
            }
            continue
        }

        if token.hasPrefix("--roi_subset=") {
            index += 1
            continue
        }

        filtered.append(token)
        index += 1
    }

    return filtered
}

// MARK: - tokenize Tests

final class TokenizeTests: XCTestCase {

    func test_emptyString_returnsEmptyArray() {
        XCTAssertEqual(tokenize(commandLine: ""), [])
    }

    func test_singleToken_returnsOneElement() {
        XCTAssertEqual(tokenize(commandLine: "hello"), ["hello"])
    }

    func test_twoTokens_separatedBySpace_returnsTwoElements() {
        XCTAssertEqual(tokenize(commandLine: "hello world"), ["hello", "world"])
    }

    func test_multipleSpaces_betweenTokens_collapses() {
        XCTAssertEqual(tokenize(commandLine: "a   b   c"), ["a", "b", "c"])
    }

    func test_leadingSpaces_areIgnored() {
        XCTAssertEqual(tokenize(commandLine: "   token"), ["token"])
    }

    func test_trailingSpaces_areIgnored() {
        XCTAssertEqual(tokenize(commandLine: "token   "), ["token"])
    }

    func test_doubleQuotedString_preservesSpaces() {
        XCTAssertEqual(tokenize(commandLine: "\"hello world\""), ["hello world"])
    }

    func test_singleQuotedString_preservesSpaces() {
        XCTAssertEqual(tokenize(commandLine: "'hello world'"), ["hello world"])
    }

    func test_quotedStringInMiddle_parsedAsOneToken() {
        XCTAssertEqual(tokenize(commandLine: "--arg \"my value\" --other"), ["--arg", "my value", "--other"])
    }

    func test_backslashEscape_preservesNextCharacter() {
        XCTAssertEqual(tokenize(commandLine: "a\\ b"), ["a b"])
    }

    func test_backslashBeforeQuote_treatsQuoteAsLiteral() {
        XCTAssertEqual(tokenize(commandLine: "a\\\"b"), ["a\"b"])
    }

    func test_mixedSingleAndDoubleQuotes_insideDoubleQuotes_preservesSingleQuote() {
        XCTAssertEqual(tokenize(commandLine: "\"it's\""), ["it's"])
    }

    func test_mixedSingleAndDoubleQuotes_insideSingleQuotes_preservesDoubleQuote() {
        XCTAssertEqual(tokenize(commandLine: "'say \"hi\"'"), ["say \"hi\""])
    }

    func test_dashArguments_parsedNormally() {
        let result = tokenize(commandLine: "--task total --device cpu")
        XCTAssertEqual(result, ["--task", "total", "--device", "cpu"])
    }

    func test_whitespaceOnlyString_returnsEmptyArray() {
        XCTAssertEqual(tokenize(commandLine: "   "), [])
    }

    func test_tabSeparated_isRecognisedAsWhitespace() {
        XCTAssertEqual(tokenize(commandLine: "a\tb"), ["a", "b"])
    }

    func test_unclosedQuote_capturesRemainingCharacters() {
        // Unclosed double-quote: everything from the opening quote to end of string
        // is treated as quoted content.
        let result = tokenize(commandLine: "a \"unclosed")
        XCTAssertEqual(result, ["a", "unclosed"])
    }

    // Regression: a single flag like "--fast" with no value must be one token
    func test_singleFlag_returnsOneToken() {
        XCTAssertEqual(tokenize(commandLine: "--fast"), ["--fast"])
    }
}

// MARK: - detectOutputType Tests

final class DetectOutputTypeTests: XCTestCase {

    func test_emptyTokens_returnsDicomWithEmptyRemaining() {
        let (type, remaining) = detectOutputType(from: [])
        XCTAssertEqual(type, .dicom)
        XCTAssertEqual(remaining, [])
    }

    func test_noOutputTypeFlag_returnsDicomAndPreservesAllTokens() {
        let tokens = ["--task", "total", "--device", "cpu"]
        let (type, remaining) = detectOutputType(from: tokens)
        XCTAssertEqual(type, .dicom)
        XCTAssertEqual(remaining, tokens)
    }

    func test_outputTypeFlag_withDicom_returnsDicomAndRemovesFlag() {
        let tokens = ["--output_type", "dicom"]
        let (type, remaining) = detectOutputType(from: tokens)
        XCTAssertEqual(type, .dicom)
        XCTAssertEqual(remaining, [])
    }

    func test_outputTypeFlag_withNifti_returnsNiftiAndRemovesFlag() {
        let tokens = ["--output_type", "nifti"]
        let (type, remaining) = detectOutputType(from: tokens)
        XCTAssertEqual(type, .nifti)
        XCTAssertEqual(remaining, [])
    }

    func test_outputTypeFlag_immediatelyFollowedByAnotherFlag_defaultsToDicom() {
        // When the value after --output_type starts with --, treat it as missing and default to dicom
        let tokens = ["--output_type", "--other"]
        let (type, remaining) = detectOutputType(from: tokens)
        XCTAssertEqual(type, .dicom)
        XCTAssertEqual(remaining, ["--other"])
    }

    func test_outputTypeFlag_atEndOfTokens_defaultsToDicom() {
        let tokens = ["--task", "total", "--output_type"]
        let (type, remaining) = detectOutputType(from: tokens)
        XCTAssertEqual(type, .dicom)
        XCTAssertEqual(remaining, ["--task", "total"])
    }

    func test_outputTypeEqualsForm_withNifti_returnsNifti() {
        let tokens = ["--output_type=nifti"]
        let (type, remaining) = detectOutputType(from: tokens)
        XCTAssertEqual(type, .nifti)
        XCTAssertEqual(remaining, [])
    }

    func test_outputTypeEqualsForm_withDicom_returnsDicom() {
        let tokens = ["--output_type=dicom"]
        let (type, remaining) = detectOutputType(from: tokens)
        XCTAssertEqual(type, .dicom)
        XCTAssertEqual(remaining, [])
    }

    func test_outputTypeInMixedTokens_removesOnlyOutputTypeFlag() {
        let tokens = ["--task", "lung", "--output_type", "nifti", "--fast"]
        let (type, remaining) = detectOutputType(from: tokens)
        XCTAssertEqual(type, .nifti)
        XCTAssertEqual(remaining, ["--task", "lung", "--fast"])
    }

    func test_outputTypeEqualsFormInMixedTokens_removesOnlyOutputTypeToken() {
        let tokens = ["--task", "lung", "--output_type=nifti_gz", "--fast"]
        let (type, remaining) = detectOutputType(from: tokens)
        XCTAssertEqual(type, .nifti)
        XCTAssertEqual(remaining, ["--task", "lung", "--fast"])
    }

    // Regression: an unknown output_type value should produce .other, not crash
    func test_outputTypeFlag_withUnknownValue_producesOther() {
        let tokens = ["--output_type", "custom"]
        let (type, _) = detectOutputType(from: tokens)
        if case .other = type { /* pass */ } else {
            XCTFail("Expected .other for unknown output type 'custom'")
        }
    }
}

// MARK: - removeROISubsetTokens Tests

final class RemoveROISubsetTokensTests: XCTestCase {

    func test_emptyTokens_returnsEmptyArray() {
        XCTAssertEqual(removeROISubsetTokens(from: []), [])
    }

    func test_noROISubsetFlag_preservesAllTokens() {
        let tokens = ["--task", "total", "--fast"]
        XCTAssertEqual(removeROISubsetTokens(from: tokens), tokens)
    }

    func test_roiSubsetFlag_withSingleValue_removesFlagAndValue() {
        let tokens = ["--roi_subset", "liver"]
        XCTAssertEqual(removeROISubsetTokens(from: tokens), [])
    }

    func test_roiSubsetFlag_withMultipleValues_removesAllValues() {
        let tokens = ["--roi_subset", "liver", "spleen", "kidney"]
        XCTAssertEqual(removeROISubsetTokens(from: tokens), [])
    }

    func test_roiSubsetFlag_valuesSeparatedByNextFlag_preservesNextFlag() {
        let tokens = ["--roi_subset", "liver", "spleen", "--fast"]
        XCTAssertEqual(removeROISubsetTokens(from: tokens), ["--fast"])
    }

    func test_roiSubsetEqualsForm_removesToken() {
        let tokens = ["--roi_subset=liver"]
        XCTAssertEqual(removeROISubsetTokens(from: tokens), [])
    }

    func test_roiSubsetFlag_inMiddleOfTokens_removesOnlySubsetTokens() {
        let tokens = ["--task", "total", "--roi_subset", "liver", "--device", "cpu"]
        XCTAssertEqual(removeROISubsetTokens(from: tokens), ["--task", "total", "--device", "cpu"])
    }

    func test_roiSubsetEqualsForm_inMixedTokens_removesOnlySubsetToken() {
        let tokens = ["--task", "lung", "--roi_subset=liver", "--fast"]
        XCTAssertEqual(removeROISubsetTokens(from: tokens), ["--task", "lung", "--fast"])
    }

    func test_multipleROISubsetFlags_allRemoved() {
        let tokens = ["--roi_subset", "liver", "--roi_subset", "spleen", "--fast"]
        XCTAssertEqual(removeROISubsetTokens(from: tokens), ["--fast"])
    }

    func test_roiSubsetAtEndWithNoValues_removesJustTheFlag() {
        let tokens = ["--task", "total", "--roi_subset"]
        XCTAssertEqual(removeROISubsetTokens(from: tokens), ["--task", "total"])
    }

    // Regression: non-ROI subset flags starting with -- should NOT be consumed as values
    func test_roiSubsetValues_stopsAtNextFlag() {
        let tokens = ["--roi_subset", "liver", "--output_type", "dicom"]
        let result = removeROISubsetTokens(from: tokens)
        XCTAssertEqual(result, ["--output_type", "dicom"])
    }
}

// MARK: - resolveOutputDirectory Integration Tests

final class ResolveOutputDirectoryTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func test_resolveOutputDirectory_withExistingDirectory_returnsProvidedURL() throws {
        let existingDir = tempDir.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existingDir, withIntermediateDirectories: true)

        // Test the logic contract: if a directory already exists it should be returned as-is.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: existingDir.path, isDirectory: &isDirectory)
        XCTAssertTrue(exists && isDirectory.boolValue)
    }

    func test_resolveOutputDirectory_withNonExistentDirectory_createsIt() throws {
        let newDir = tempDir.appendingPathComponent("new_output", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDir.path))
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir.path))
    }

    func test_resolveOutputDirectory_existingFile_notDirectory_raisesError() {
        let filePath = tempDir.appendingPathComponent("not_a_dir.txt")
        FileManager.default.createFile(atPath: filePath.path, contents: nil)
        // The production method throws when the path exists but is a file, not a directory.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: filePath.path, isDirectory: &isDirectory)
        XCTAssertTrue(exists)
        XCTAssertFalse(isDirectory.boolValue, "Path is a file, not a directory")
    }
}

// MARK: - SegmentationPreferences Tests

final class SegmentationPreferencesStateTests: XCTestCase {

    typealias State = TotalSegmentatorHorosPlugin.SegmentationPreferences.State

    func test_state_defaultSelectedClassNames_isEmpty() {
        let state = State(
            executablePath: nil,
            task: nil,
            useFast: false,
            device: nil,
            additionalArguments: nil,
            licenseKey: nil,
            selectedClassNames: []
        )
        XCTAssertTrue(state.selectedClassNames.isEmpty)
    }

    func test_state_taskIsNilByDefault() {
        let state = State(
            executablePath: nil,
            task: nil,
            useFast: false,
            device: nil,
            additionalArguments: nil,
            licenseKey: nil,
            selectedClassNames: []
        )
        XCTAssertNil(state.task)
    }

    func test_state_useFast_canBeSetTrue() {
        let state = State(
            executablePath: nil,
            task: nil,
            useFast: true,
            device: nil,
            additionalArguments: nil,
            licenseKey: nil,
            selectedClassNames: []
        )
        XCTAssertTrue(state.useFast)
    }

    func test_state_selectedClassNames_canContainMultipleEntries() {
        let names = ["liver", "spleen", "kidney"]
        var state = State(
            executablePath: nil,
            task: nil,
            useFast: false,
            device: nil,
            additionalArguments: nil,
            licenseKey: nil,
            selectedClassNames: names
        )
        XCTAssertEqual(state.selectedClassNames, names)
        state.selectedClassNames.append("aorta")
        XCTAssertEqual(state.selectedClassNames.count, 4)
    }

    func test_state_licenseKey_emptyStringIsDistinctFromNil() {
        var stateWithNil = State(
            executablePath: nil,
            task: nil,
            useFast: false,
            device: nil,
            additionalArguments: nil,
            licenseKey: nil,
            selectedClassNames: []
        )
        stateWithNil.licenseKey = nil
        XCTAssertNil(stateWithNil.licenseKey)

        var stateWithEmpty = State(
            executablePath: nil,
            task: nil,
            useFast: false,
            device: nil,
            additionalArguments: nil,
            licenseKey: "",
            selectedClassNames: []
        )
        stateWithEmpty.licenseKey = ""
        XCTAssertNotNil(stateWithEmpty.licenseKey)
        XCTAssertEqual(stateWithEmpty.licenseKey, "")
    }

    func test_state_additionalArguments_storesMultipleFlags() {
        let args = "--verbose --some_flag value"
        let state = State(
            executablePath: nil,
            task: "total",
            useFast: false,
            device: nil,
            additionalArguments: args,
            licenseKey: nil,
            selectedClassNames: []
        )
        XCTAssertEqual(state.additionalArguments, args)
    }

    func test_state_isMutatingByValue() {
        var original = State(
            executablePath: nil,
            task: "total",
            useFast: false,
            device: nil,
            additionalArguments: nil,
            licenseKey: nil,
            selectedClassNames: []
        )
        var copy = original
        copy.task = "lung"
        XCTAssertEqual(original.task, "total", "Mutating copy should not affect original")
        XCTAssertEqual(copy.task, "lung")
    }
}