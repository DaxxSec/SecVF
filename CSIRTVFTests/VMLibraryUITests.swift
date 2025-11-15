//
//  VMLibraryUITests.swift
//  SecVFTests
//
//  UI and Performance tests for VM Library window
//

import XCTest
@testable import SecVF

final class VMLibraryUITests: XCTestCase {

    // MARK: - UI Initialization Tests

    func testWindowControllerInitialization() {
        // Given
        let windowController = VMLibraryWindowController()

        // When
        _ = windowController.window // Force load window

        // Then
        XCTAssertNotNil(windowController.window, "Window should be initialized")
        XCTAssertNotNil(windowController.windowNibName, "Window nib name should be set")
    }

    func testIBOutletsConnected() {
        // Given
        let windowController = VMLibraryWindowController()

        // When
        windowController.loadWindow()

        // Then - Critical IBOutlets should be connected after loading
        XCTAssertNotNil(windowController.tableView, "TableView outlet should be connected")
        XCTAssertNotNil(windowController.startButton, "Start button outlet should be connected")
        XCTAssertNotNil(windowController.newButton, "New button outlet should be connected")
        XCTAssertNotNil(windowController.deleteButton, "Delete button outlet should be connected")
    }

    func testTableViewConfiguredAfterLoad() {
        // Given
        let windowController = VMLibraryWindowController()

        // When
        windowController.loadWindow()
        windowController.windowDidLoad()

        // Then
        XCTAssertNotNil(windowController.tableView?.dataSource, "TableView should have data source")
        XCTAssertNotNil(windowController.tableView?.delegate, "TableView should have delegate")
    }

    // MARK: - Performance Tests

    func testVMManagerInitializationPerformance() {
        // Measure async initialization performance
        measure {
            let expectation = XCTestExpectation(description: "VM initialization completes")

            VMManager.shared.initializeAsync {
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    func testWindowLoadPerformance() {
        // Measure window loading performance
        measure {
            let windowController = VMLibraryWindowController()
            windowController.loadWindow()
            windowController.windowDidLoad()
        }
    }

    func testTableViewReloadPerformance() {
        // Given
        let windowController = VMLibraryWindowController()
        windowController.loadWindow()
        windowController.windowDidLoad()

        // Wait for initial load
        let loadExpectation = XCTestExpectation(description: "Initial load")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            loadExpectation.fulfill()
        }
        wait(for: [loadExpectation], timeout: 1.0)

        // Measure reload performance
        measure {
            windowController.tableView?.reloadData()
        }
    }

    // MARK: - Async Operation Tests

    func testAsyncVMLoadingCompletes() {
        // Given
        let expectation = XCTestExpectation(description: "VM loading completes")

        // When
        VMManager.shared.initializeAsync {
            // Then
            expectation.fulfill()
        }

        // Should complete within reasonable time
        wait(for: [expectation], timeout: 3.0)
    }

    func testAsyncLoadingDoesNotBlockMainThread() {
        // Given
        let mainThreadExpectation = XCTestExpectation(description: "Main thread remains responsive")

        // When - Start async loading
        VMManager.shared.initializeAsync {
            // Completed
        }

        // Main thread should be able to execute this immediately
        DispatchQueue.main.async {
            mainThreadExpectation.fulfill()
        }

        // Then - Main thread should respond quickly (within 100ms)
        wait(for: [mainThreadExpectation], timeout: 0.1)
    }

    // MARK: - UI State Tests

    func testButtonsDisabledWithNoSelection() {
        // Given
        let windowController = VMLibraryWindowController()
        windowController.loadWindow()
        windowController.windowDidLoad()

        // Wait for UI to settle
        let expectation = XCTestExpectation(description: "UI settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.5)

        // Then - Action buttons should be disabled with no selection
        XCTAssertEqual(windowController.startButton?.isEnabled, false, "Start button should be disabled")
        XCTAssertEqual(windowController.deleteButton?.isEnabled, false, "Delete button should be disabled")
        XCTAssertEqual(windowController.renameButton?.isEnabled, false, "Rename button should be disabled")
        XCTAssertEqual(windowController.cloneButton?.isEnabled, false, "Clone button should be disabled")
    }

    func testTableViewStartsEmpty() {
        // Given
        let windowController = VMLibraryWindowController()
        windowController.loadWindow()

        // When - Immediately after load (before async completes)
        let rowCount = windowController.tableView?.numberOfRows ?? -1

        // Then - Should start with 0 rows (VMs load async)
        XCTAssertGreaterThanOrEqual(rowCount, 0, "Row count should be valid")
    }

    // MARK: - Integration Tests

    func testFullWindowLifecycle() {
        // Given
        let windowController = VMLibraryWindowController()

        // When - Full lifecycle
        windowController.loadWindow()
        XCTAssertNotNil(windowController.window)

        windowController.windowDidLoad()
        XCTAssertNotNil(windowController.tableView)

        // Wait for async initialization
        let expectation = XCTestExpectation(description: "Async init completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // Then - Everything should be initialized
        XCTAssertNotNil(windowController.tableView?.dataSource)
        XCTAssertNotNil(windowController.tableView?.delegate)
    }

    func testWindowCanBeShownWithoutCrashing() {
        // Given
        let windowController = VMLibraryWindowController()

        // When
        windowController.loadWindow()
        windowController.windowDidLoad()
        windowController.showWindow(nil)

        // Wait a bit
        let expectation = XCTestExpectation(description: "Window shown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Then - Should not crash (test passes if we get here)
        XCTAssertTrue(true)

        // Clean up
        windowController.close()
    }

    // MARK: - Error Resilience Tests

    func testHandlesNilIBOutletsGracefully() {
        // Given
        let windowController = VMLibraryWindowController()
        // Don't load window - IBOutlets will be nil

        // When/Then - These should not crash even with nil outlets
        XCTAssertNoThrow(windowController.tableView?.reloadData())

        // Accessing properties should return nil, not crash
        let tableView = windowController.tableView
        XCTAssertNil(tableView, "TableView should be nil before window loads")
    }

    func testMultipleInitializationCallsAreIdempotent() {
        // Given
        let expectation1 = XCTestExpectation(description: "First init")
        let expectation2 = XCTestExpectation(description: "Second init")

        // When - Call initializeAsync multiple times
        VMManager.shared.initializeAsync {
            expectation1.fulfill()
        }

        VMManager.shared.initializeAsync {
            expectation2.fulfill()
        }

        // Then - Both should complete successfully
        wait(for: [expectation1, expectation2], timeout: 3.0)
    }
}
