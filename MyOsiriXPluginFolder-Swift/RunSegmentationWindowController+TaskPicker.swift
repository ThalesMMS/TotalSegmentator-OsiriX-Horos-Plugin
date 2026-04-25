//
// RunSegmentationWindowController+TaskPicker.swift
// TotalSegmentator
//
// Task picker menu construction and contextual description behavior.
//

import Cocoa

extension RunSegmentationWindowController {
    func configureTaskDescriptionLabel(_ label: NSTextField?) {
        label?.isEditable = false
        label?.isSelectable = false
        label?.isBordered = false
        label?.drawsBackground = false
        label?.usesSingleLineMode = false
        label?.lineBreakMode = .byWordWrapping
        label?.textColor = NSColor.secondaryLabelColor
    }

    func populateTaskPopUpButton(_ button: NSPopUpButton?, with groups: [TaskGroup]) {
        guard let button = button else { return }
        button.removeAllItems()
        guard let menu = button.menu else { return }

        for (index, group) in groups.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }

            menu.addItem(makeTaskGroupHeader(title: group.name))

            for task in group.tasks {
                let item = NSMenuItem(title: task.title, action: nil, keyEquivalent: "")
                item.representedObject = task.value
                menu.addItem(item)
            }
        }

        button.autoenablesItems = false
        selectFirstSelectableItem(in: button)
    }

    func populatePopUpButton(_ button: NSPopUpButton?, with options: [(title: String, value: String?)]) {
        guard let button = button else { return }
        button.removeAllItems()
        for option in options {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.value
            button.menu?.addItem(item)
        }
        selectFirstSelectableItem(in: button)
    }

    func selectItem(in button: NSPopUpButton?, matching value: String?) {
        guard let button = button,
              let menuItems = button.menu?.items else { return }

        let selectableItems = menuItems.filter { isSelectableMenuItem($0) }
        if let item = selectableItems.first(where: { ($0.representedObject as? String) == value }) {
            button.select(item)
        } else {
            selectFirstSelectableItem(in: button)
        }
    }

    func hasValidTaskSelection(in button: NSPopUpButton?) -> Bool {
        guard let item = button?.selectedItem else { return false }
        return isSelectableMenuItem(item)
    }

    func currentSelectedTask(in button: NSPopUpButton?) -> String? {
        guard let item = button?.selectedItem,
              isSelectableMenuItem(item) else {
            return nil
        }
        return item.representedObject as? String
    }

    func updateTaskDescription(_ label: NSTextField?, selectedTask selectedValue: String?, taskGroups: [TaskGroup]) {
        let selectedTask = taskGroups
            .flatMap { $0.tasks }
            .first { $0.value == selectedValue }
        label?.stringValue = selectedTask?.description ?? ""
    }

    private func makeTaskGroupHeader(title: String) -> NSMenuItem {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.target = nil
        header.representedObject = nil
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        return header
    }

    private func selectFirstSelectableItem(in button: NSPopUpButton) {
        if let firstItem = button.menu?.items.first(where: { isSelectableMenuItem($0) }) {
            button.select(firstItem)
        }
    }

    private func isSelectableMenuItem(_ item: NSMenuItem) -> Bool {
        return item.isEnabled && !item.isSeparatorItem
    }
}
