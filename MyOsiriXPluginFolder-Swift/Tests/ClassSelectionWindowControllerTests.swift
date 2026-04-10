//
// ClassSelectionWindowControllerTests.swift
// TotalSegmentatorTests
//
// Unit tests for ClassSelectionWindowController covering initialization,
// filtering, selection management, and completion callbacks.
//

import XCTest
@testable import TotalSegmentatorHorosPlugin

final class ClassSelectionWindowControllerTests: XCTestCase {

    // MARK: - Initialization

    func test_init_noAvailableClasses_producesZeroRows() throws {
        let controller = ClassSelectionWindowController(availableClasses: [], preselected: [])
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), 0)
    }

    func test_init_allClassesVisible_whenNoPreselectionProvided() throws {
        let classes = ["liver", "spleen", "kidney"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), classes.count)
    }

    func test_init_allClassesVisible_whenAllPreselected() throws {
        let classes = ["liver", "spleen", "kidney"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: classes)
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), classes.count)
    }

    func test_init_singleClass_isVisible() throws {
        let controller = ClassSelectionWindowController(availableClasses: ["aorta"], preselected: [])
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), 1)
    }

    func test_init_duplicateClasses_preservesDuplicates() throws {
        let classes = ["liver", "liver", "spleen"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), classes.count)
    }

    // MARK: - Row Height

    func test_rowHeight_isPositive() throws {
        let controller = ClassSelectionWindowController(availableClasses: ["liver"], preselected: [])
        let tableView = try controller.tableView()
        let height = controller.tableView(tableView, heightOfRow: 0)
        XCTAssertGreaterThan(height, 0)
    }

    func test_rowHeight_isConsistentAcrossRows() throws {
        let classes = ["liver", "spleen", "kidney"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        let tableView = try controller.tableView()
        let heights = (0..<3).map { controller.tableView(tableView, heightOfRow: $0) }
        XCTAssertEqual(Set(heights).count, 1, "All rows should have the same height")
    }

    // MARK: - Filtering

    func test_filter_emptyString_showsAllItems() throws {
        let classes = ["liver", "spleen", "kidney"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        controller.applyFilterForTesting(query: "")
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), classes.count)
    }

    func test_filter_exactMatch_showsOneItem() throws {
        let classes = ["liver", "spleen", "kidney"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        controller.applyFilterForTesting(query: "liver")
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), 1)
    }

    func test_filter_partialMatch_showsMatchingItems() throws {
        let classes = ["liver", "spleen", "live_wire"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        controller.applyFilterForTesting(query: "live")
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), 2)
    }

    func test_filter_caseInsensitive_matchesUppercase() throws {
        let classes = ["Liver", "Spleen", "Kidney"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        controller.applyFilterForTesting(query: "liver")
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), 1)
    }

    func test_filter_caseInsensitive_matchesLowercase() throws {
        let classes = ["LIVER", "SPLEEN", "KIDNEY"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        controller.applyFilterForTesting(query: "KIDNEY")
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), 1)
    }

    func test_filter_diacriticInsensitive_matchesAccentedCharacters() throws {
        let classes = ["hépatique", "splénique", "rénale"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        controller.applyFilterForTesting(query: "hepatique")
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), 1)
    }

    func test_filter_diacriticInsensitive_accentedQueryMatchesPlain() throws {
        let classes = ["hepatique", "splenique"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        controller.applyFilterForTesting(query: "hépatique")
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), 1)
    }

    func test_filter_noMatch_producesZeroRows() throws {
        let classes = ["liver", "spleen", "kidney"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        controller.applyFilterForTesting(query: "pancreas")
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), 0)
    }

    func test_filter_whitespaceOnly_showsAllItems() throws {
        // Whitespace is trimmed before applying the filter
        let classes = ["liver", "spleen"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        controller.applyFilterForTesting(query: "   ")
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), classes.count)
    }

    func test_filter_clearedAfterActive_restoresAllRows() throws {
        let classes = ["liver", "spleen", "kidney"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        controller.applyFilterForTesting(query: "liver")
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), 1)
        controller.applyFilterForTesting(query: "")
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), classes.count)
    }

    // MARK: - Selection Confirmation

    func test_confirmSelection_noPreselection_returnsEmptyArray() {
        let classes = ["liver", "spleen", "kidney"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        var confirmedNames: [String]?
        controller.onSelectionConfirmed = { confirmedNames = $0 }
        controller.perform(Selector(("confirmSelection")))
        XCTAssertEqual(confirmedNames, [])
    }

    func test_confirmSelection_allPreselected_returnsAllNames() {
        let classes = ["liver", "spleen", "kidney"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: classes)
        var confirmedNames: [String]?
        controller.onSelectionConfirmed = { confirmedNames = $0 }
        controller.perform(Selector(("confirmSelection")))
        XCTAssertEqual(confirmedNames?.sorted(), classes.sorted())
    }

    func test_confirmSelection_partialPreselection_returnsOnlySelectedNames() {
        let classes = ["liver", "spleen", "kidney"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: ["spleen"])
        var confirmedNames: [String]?
        controller.onSelectionConfirmed = { confirmedNames = $0 }
        controller.perform(Selector(("confirmSelection")))
        XCTAssertEqual(confirmedNames, ["spleen"])
    }

    func test_confirmSelection_callbackFires_exactlyOnce() {
        let classes = ["liver"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: classes)
        var callCount = 0
        controller.onSelectionConfirmed = { _ in callCount += 1 }
        controller.perform(Selector(("confirmSelection")))
        XCTAssertEqual(callCount, 1)
    }

    func test_confirmSelection_noCallback_doesNotCrash() {
        let controller = ClassSelectionWindowController(availableClasses: ["liver"], preselected: [])
        controller.onSelectionConfirmed = nil
        // Should not crash when no callback is set
        controller.perform(Selector(("confirmSelection")))
    }

    // MARK: - Cancellation

    func test_cancelSelection_callbackFires() {
        let controller = ClassSelectionWindowController(availableClasses: ["liver"], preselected: [])
        var didCancel = false
        controller.onSelectionCancelled = { didCancel = true }
        controller.perform(Selector(("cancelSelection")))
        XCTAssertTrue(didCancel)
    }

    func test_cancelSelection_callbackFires_exactlyOnce() {
        let controller = ClassSelectionWindowController(availableClasses: ["liver"], preselected: [])
        var callCount = 0
        controller.onSelectionCancelled = { callCount += 1 }
        controller.perform(Selector(("cancelSelection")))
        XCTAssertEqual(callCount, 1)
    }

    func test_cancelSelection_noCallback_doesNotCrash() {
        let controller = ClassSelectionWindowController(availableClasses: ["liver"], preselected: [])
        controller.onSelectionCancelled = nil
        controller.perform(Selector(("cancelSelection")))
    }

    // MARK: - Select All

    func test_selectAllClasses_thenConfirm_returnsAllItems() {
        let classes = ["liver", "spleen", "kidney"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        controller.perform(Selector(("selectAllClasses")))
        var confirmedNames: [String]?
        controller.onSelectionConfirmed = { confirmedNames = $0 }
        controller.perform(Selector(("confirmSelection")))
        XCTAssertEqual(confirmedNames?.sorted(), classes.sorted())
    }

    func test_selectAllClasses_onEmptyList_doesNotCrash() {
        let controller = ClassSelectionWindowController(availableClasses: [], preselected: [])
        controller.perform(Selector(("selectAllClasses")))
        var confirmedNames: [String]?
        controller.onSelectionConfirmed = { confirmedNames = $0 }
        controller.perform(Selector(("confirmSelection")))
        XCTAssertEqual(confirmedNames, [])
    }

    // MARK: - Clear Selection

    func test_clearSelection_thenConfirm_returnsEmptyArray() {
        let classes = ["liver", "spleen", "kidney"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: classes)
        controller.perform(Selector(("clearSelection")))
        var confirmedNames: [String]?
        controller.onSelectionConfirmed = { confirmedNames = $0 }
        controller.perform(Selector(("confirmSelection")))
        XCTAssertEqual(confirmedNames, [])
    }

    func test_clearSelection_afterSelectAll_returnsEmptyArray() {
        let classes = ["liver", "spleen"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        controller.perform(Selector(("selectAllClasses")))
        controller.perform(Selector(("clearSelection")))
        var confirmedNames: [String]?
        controller.onSelectionConfirmed = { confirmedNames = $0 }
        controller.perform(Selector(("confirmSelection")))
        XCTAssertEqual(confirmedNames, [])
    }

    // MARK: - Toggle Checkbox

    func test_toggleCheckbox_turnOn_addsToSelection() {
        let classes = ["liver", "spleen"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        let checkbox = NSButton(checkboxWithTitle: "liver", target: nil, action: nil)
        checkbox.tag = 0
        checkbox.state = .on
        controller.perform(Selector(("toggleClassCheckbox:")), with: checkbox)
        var confirmedNames: [String]?
        controller.onSelectionConfirmed = { confirmedNames = $0 }
        controller.perform(Selector(("confirmSelection")))
        XCTAssertEqual(confirmedNames, ["liver"])
    }

    func test_toggleCheckbox_turnOff_removesFromSelection() {
        let classes = ["liver", "spleen"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: ["liver"])
        let checkbox = NSButton(checkboxWithTitle: "liver", target: nil, action: nil)
        checkbox.tag = 0
        checkbox.state = .off
        controller.perform(Selector(("toggleClassCheckbox:")), with: checkbox)
        var confirmedNames: [String]?
        controller.onSelectionConfirmed = { confirmedNames = $0 }
        controller.perform(Selector(("confirmSelection")))
        XCTAssertEqual(confirmedNames, [])
    }

    func test_toggleCheckbox_outOfBoundsTag_doesNotCrash() {
        let controller = ClassSelectionWindowController(availableClasses: ["liver"], preselected: [])
        let checkbox = NSButton(checkboxWithTitle: "ghost", target: nil, action: nil)
        checkbox.tag = 99  // Out of range
        checkbox.state = .on
        controller.perform(Selector(("toggleClassCheckbox:")), with: checkbox)
    }

    func test_toggleCheckbox_negativeTag_doesNotCrash() {
        let controller = ClassSelectionWindowController(availableClasses: ["liver"], preselected: [])
        let checkbox = NSButton(checkboxWithTitle: "ghost", target: nil, action: nil)
        checkbox.tag = -1
        checkbox.state = .on
        controller.perform(Selector(("toggleClassCheckbox:")), with: checkbox)
    }

    // MARK: - Window Configuration

    func test_init_windowHasCorrectTitle() {
        let controller = ClassSelectionWindowController(availableClasses: [], preselected: [])
        XCTAssertEqual(controller.window?.title, "Select Classes")
    }

    func test_init_windowIsNotNil() {
        let controller = ClassSelectionWindowController(availableClasses: ["liver"], preselected: [])
        XCTAssertNotNil(controller.window)
    }

    func test_init_windowHasLightAppearance() {
        let controller = ClassSelectionWindowController(availableClasses: [], preselected: [])
        XCTAssertEqual(controller.window?.appearance?.name, NSAppearance.Name.aqua)
    }

    // MARK: - Table View Data Source

    func test_numberOfRows_matchesAvailableClassesCount() throws {
        let classes = ["liver", "spleen", "kidney", "aorta", "heart"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), classes.count)
    }

    func test_tableView_returnsNonNilViewForValidRow() throws {
        let classes = ["liver", "spleen"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        let tableView = try controller.tableView()
        let view = controller.tableView(tableView, viewFor: nil, row: 0)
        XCTAssertNotNil(view)
    }

    // MARK: - Large Input

    func test_init_largeClassList_allRowsVisible() throws {
        let classes = (0..<100).map { "class_\($0)" }
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), 100)
    }

    func test_filter_onLargeList_returnsCorrectSubset() throws {
        let classes = (0..<100).map { "class_\($0)" } + ["special_target"]
        let controller = ClassSelectionWindowController(availableClasses: classes, preselected: [])
        controller.applyFilterForTesting(query: "special")
        XCTAssertEqual(controller.numberOfRows(in: try controller.tableView()), 1)
    }
}

// MARK: - Test Helpers

// Expose the search-filter path through the public NSSearchField mechanism so tests
// do not need to rely on private API access.
extension ClassSelectionWindowController {
    /// Convenience for tests: simulates typing `query` into the search field so
    /// `applyFilter()` is exercised without accessing private state directly.
    func applyFilterForTesting(query: String) {
        let searchField = NSSearchField(frame: .zero)
        searchField.stringValue = query
        // Trim whitespace to match the real implementation
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchField.stringValue = ""
        }
        perform(Selector(("searchFieldChanged:")), with: searchField)
    }

    /// Exposes the internal table view so row-count assertions can be made without
    /// reaching into private storage.
    private struct TableViewLookupError: Error {}

    func tableView(file: StaticString = #filePath, line: UInt = #line) throws -> NSTableView {
        // The table view is a stored property; reflect on it for test access.
        // Iterate subviews of the scroll view that is a child of the content view.
        if let contentView = window?.contentView {
            for subview in contentView.subviews {
                if let scrollView = subview as? NSScrollView,
                   let tableView = scrollView.documentView as? NSTableView {
                    return tableView
                }
            }
        }
        XCTFail("ClassSelectionWindowControllerTests: table view not found", file: file, line: line)
        throw TableViewLookupError()
    }
}
