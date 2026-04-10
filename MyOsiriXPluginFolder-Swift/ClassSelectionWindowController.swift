//
// ClassSelectionWindowController.swift
// TotalSegmentator
//
// Shows a sheet to filter and choose segmentation classes before launching TotalSegmentator.
//
// Thales Matheus Mendonça Santos - November 2025
//

import Cocoa

// Simple window that lets the user choose which segmentation classes to import.
// The UI stays compact and focused on quick search plus checkboxes.

final class ClassSelectionWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private struct ClassItem {
        let name: String
        var isSelected: Bool
    }

    var onSelectionConfirmed: (([String]) -> Void)?
    var onSelectionCancelled: (() -> Void)?

    private var items: [ClassItem]
    private var filteredIndices: [Int]
    private var currentFilter: String = ""

    private let tableView = NSTableView(frame: .zero)
    private let searchField = NSSearchField(frame: .zero)

    init(availableClasses: [String], preselected: [String]) {
        let preselectedSet = Set(preselected)
        self.items = availableClasses.map { ClassItem(name: $0, isSelected: preselectedSet.contains($0)) }
        self.filteredIndices = Array(items.indices)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Select Classes", comment: "Title of the class selection sheet")
        window.isReleasedWhenClosed = false
        // Force light appearance for consistent look
        window.appearance = NSAppearance(named: .aqua)

        super.init(window: window)
        configureContent()
        applyFilter()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Configure the window's content view by creating and laying out the search field, table view (inside a scroll view), and action buttons.
    /// 
    /// This builds the UI programmatically (no nibs), sets up behaviors and targets for the search field and buttons, configures the table view and its scroll container, arranges the buttons in an horizontal stack with a flexible spacer, adds these views to the window's content view, and activates Auto Layout constraints to position the controls.
    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        // Build the UI programmatically to avoid depending on external nibs.
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = NSLocalizedString("Filter classes", comment: "Search field placeholder for class selection")
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ClassColumn"))
        column.title = ""
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 24
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .none
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView

        let selectAllButton = NSButton(title: NSLocalizedString("Select All", comment: "Select all classes"), target: self, action: #selector(selectAllClasses))
        let clearButton = NSButton(title: NSLocalizedString("Clear", comment: "Clear class selection"), target: self, action: #selector(clearSelection))
        let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: "Cancel class selection"), target: self, action: #selector(cancelSelection))
        cancelButton.keyEquivalent = "\u{1b}"
        let confirmButton = NSButton(title: NSLocalizedString("Apply", comment: "Confirm class selection"), target: self, action: #selector(confirmSelection))
        confirmButton.keyEquivalent = "\r"

        let spacer = NSView(frame: .zero)
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttonStack = NSStackView(views: [selectAllButton, clearButton, spacer, cancelButton, confirmButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        contentView.addSubview(searchField)
        contentView.addSubview(scrollView)
        contentView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -12),

            buttonStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])
    }

    /// Updates the visible row indices to match `currentFilter` and refreshes the table view.
    /// 
    /// If `currentFilter` is empty, all item indices are included; otherwise only items whose
    /// `name` contains `currentFilter` using case-insensitive and diacritic-insensitive matching
    /// are included. After updating `filteredIndices`, the table view is reloaded.
    private func applyFilter() {
        if currentFilter.isEmpty {
            filteredIndices = Array(items.indices)
        } else {
            // Keep only the indices that match the typed filter, ignoring case and diacritics.
            filteredIndices = items.indices.filter { index in
                items[index].name.range(of: currentFilter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        tableView.reloadData()
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        currentFilter = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        applyFilter()
    }

    /// Updates the selection state of the class corresponding to the given checkbox.
    /// 
    /// Sets the matching `ClassItem`'s `isSelected` to `true` when the checkbox `state` is `.on`, otherwise `false`. If the button's `tag` does not map to an existing item, the method has no effect.
    /// - Parameter sender: The checkbox button whose `tag` is the index into `items`; its `state` determines the new selection value.
    @objc private func toggleClassCheckbox(_ sender: NSButton) {
        let index = sender.tag
        guard items.indices.contains(index) else { return }
        // Rows are controlled via tags so the selection state stays in sync without extra datasource plumbing.
        items[index].isSelected = sender.state == .on
    }

    private func setAllItemsSelected(_ selected: Bool) {
        for index in items.indices {
            items[index].isSelected = selected
        }
        tableView.reloadData()
    }

    @objc private func selectAllClasses() { setAllItemsSelected(true) }
    @objc private func clearSelection() { setAllItemsSelected(false) }

    @objc private func cancelSelection() {
        if let window = window {
            window.sheetParent?.endSheet(window)
        }
        onSelectionCancelled?()
    }

    @objc private func confirmSelection() {
        let selected = items.filter { $0.isSelected }.map { $0.name }
        if let window = window {
            window.sheetParent?.endSheet(window)
        }
        onSelectionConfirmed?(selected)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredIndices.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ClassCell")
        let index = filteredIndices[row]
        let item = items[index]

        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView,
           let button = cell.subviews.first as? NSButton {
            button.title = item.name
            button.state = item.isSelected ? .on : .off
            button.tag = index
            button.target = self
            button.action = #selector(toggleClassCheckbox(_:))
            return cell
        }

        let button = NSButton(checkboxWithTitle: item.name, target: self, action: #selector(toggleClassCheckbox(_:)))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tag = index

        let cell = NSTableCellView(frame: .zero)
        cell.identifier = identifier
        cell.addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            button.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            button.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2)
        ])

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 26
    }
}