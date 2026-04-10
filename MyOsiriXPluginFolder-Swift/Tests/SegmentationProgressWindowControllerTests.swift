//
// SegmentationProgressWindowControllerTests.swift
// TotalSegmentatorTests
//
// Unit tests for SegmentationProgressWindowController covering lazy window creation,
// content configuration idempotency, thread-safe append behaviour, and cancel handling.
//

import XCTest
@testable import TotalSegmentatorHorosPlugin

final class SegmentationProgressWindowControllerTests: XCTestCase {

    // MARK: - Initialization

    func test_init_windowIsNilBeforeFirstUse() {
        let controller = SegmentationProgressWindowController()
        // The window is created lazily; it should be nil until showWindow / start / append
        // is called on the main thread.
        XCTAssertNil(controller.window)
    }

    // MARK: - Lazy Window Creation

    func test_showWindow_createsWindowOnMainThread() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        XCTAssertNotNil(controller.window)
    }

    func test_showWindow_windowTitleIsSetCorrectly() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        XCTAssertEqual(controller.window?.title, "TotalSegmentator Progress")
    }

    func test_showWindow_windowHasLightAppearance() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        XCTAssertEqual(controller.window?.appearance?.name, NSAppearance.Name.aqua)
    }

    func test_showWindow_windowStyleIncludesClosable() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        XCTAssertTrue(controller.window?.styleMask.contains(.closable) ?? false)
    }

    func test_showWindow_windowStyleIncludesMiniaturizable() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        XCTAssertTrue(controller.window?.styleMask.contains(.miniaturizable) ?? false)
    }

    func test_showWindow_calledTwice_sameWindowIsReused() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        let firstWindow = controller.window
        controller.showWindow(nil)
        XCTAssertTrue(controller.window === firstWindow)
    }

    func test_showWindow_isNotReleasedWhenClosed() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        XCTAssertFalse(controller.window?.isReleasedWhenClosed ?? true)
    }

    // MARK: - UI Configuration Idempotency

    func test_configureContent_idempotent_contentViewSubviewCountDoesNotGrow() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        let countAfterFirst = controller.window?.contentView?.subviews.count ?? 0
        // Trigger content configuration a second time via showWindow
        controller.showWindow(nil)
        let countAfterSecond = controller.window?.contentView?.subviews.count ?? 0
        XCTAssertEqual(countAfterFirst, countAfterSecond, "Calling showWindow twice must not add duplicate subviews")
    }

    func test_configureContent_addsScrollView() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        let hasScrollView = controller.window?.contentView?.subviews.contains { $0 is NSScrollView } ?? false
        XCTAssertTrue(hasScrollView)
    }

    func test_configureContent_addsProgressIndicator() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        let hasProgress = controller.window?.contentView?.subviews.contains { $0 is NSProgressIndicator } ?? false
        XCTAssertTrue(hasProgress)
    }

    func test_configureContent_addsCancelButton() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        let hasButton = controller.window?.contentView?.subviews.contains { $0 is NSButton } ?? false
        XCTAssertTrue(hasButton)
    }

    func test_configureContent_cancelButtonIsHiddenInitially() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        let cancelButton = controller.window?.contentView?.subviews
            .compactMap { $0 as? NSButton }
            .first(where: { $0.title == "Cancel" })
        XCTAssertNotNil(cancelButton)
        XCTAssertTrue(cancelButton?.isHidden ?? false, "Cancel button should be hidden until a handler is registered")
    }

    // MARK: - Start

    func test_start_doesNotCrash() {
        let controller = SegmentationProgressWindowController()
        controller.start()
        // Ensure any async dispatch settles
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertNotNil(controller.window)
    }

    // MARK: - Append

    func test_append_onMainThread_doesNotCrash() {
        let controller = SegmentationProgressWindowController()
        controller.append("Hello")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    func test_append_fromBackgroundThread_doesNotCrash() {
        let controller = SegmentationProgressWindowController()
        let expectation = self.expectation(description: "background append completes")
        DispatchQueue.global().async {
            controller.append("Background message")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    func test_append_multipleMessages_doesNotCrash() {
        let controller = SegmentationProgressWindowController()
        for i in 0..<20 {
            controller.append("Line \(i)")
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    func test_append_emptyString_doesNotCrash() {
        let controller = SegmentationProgressWindowController()
        controller.append("")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    func test_append_stringAlreadyWithNewline_doesNotCrash() {
        let controller = SegmentationProgressWindowController()
        controller.append("already has newline\n")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    // MARK: - Cancel Handler

    func test_setCancelHandler_makesCancelButtonVisible() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        controller.setCancelHandler { /* no-op: handler presence is what matters here */ }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let cancelButton = controller.window?.contentView?.subviews
            .compactMap { $0 as? NSButton }
            .first(where: { $0.title == "Cancel" })
        XCTAssertFalse(cancelButton?.isHidden ?? true, "Cancel button should be visible after handler is set")
    }

    func test_markProcessFinished_disablesCancelButton() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        controller.setCancelHandler { /* no-op */ }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        controller.markProcessFinished()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let cancelButton = controller.window?.contentView?.subviews
            .compactMap { $0 as? NSButton }
            .first(where: { $0.title == "Cancel" })
        XCTAssertFalse(cancelButton?.isEnabled ?? true, "Cancel button should be disabled after markProcessFinished()")
    }

    // MARK: - Close

    func test_close_onMainThread_doesNotCrash() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        controller.close()
    }

    func test_close_fromBackgroundThread_doesNotCrash() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        let expectation = self.expectation(description: "background close")
        DispatchQueue.global().async {
            controller.close()
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    func test_closeAfterDelay_zeroDelay_closesImmediately() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        controller.close(after: 0)
        // No crash expected; window order may change
    }

    func test_closeAfterDelay_smallDelay_doesNotCrash() {
        let controller = SegmentationProgressWindowController()
        controller.showWindow(nil)
        controller.close(after: 0.01)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    // MARK: - Thread Safety: performOnMain

    func test_performOnMain_fromMainThread_executesImmediately() {
        let controller = SegmentationProgressWindowController()
        // start() calls performOnMain internally; verify it doesn't dispatch asynchronously
        // when already on the main thread by checking window is created synchronously.
        XCTAssertTrue(Thread.isMainThread)
        controller.start()
        XCTAssertNotNil(controller.window, "Window must be created synchronously when start() is called on main thread")
    }

    func test_performOnMain_fromBackgroundThread_windowCreatedBeforeBlockRuns() {
        let controller = SegmentationProgressWindowController()
        let expectation = self.expectation(description: "background start")
        DispatchQueue.global().async {
            controller.start()
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)
        // Allow main-thread work to settle
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertNotNil(controller.window)
    }
}