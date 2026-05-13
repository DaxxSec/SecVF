//
//  VMManagerBundleSizeTests.swift
//  SecVFTests
//
//  Tests for the `VMManager.onDiskBundleSize(for:)` helper introduced by
//  the tactical UI redesign. Verifies cache behaviour, background-refresh
//  scheduling, and the `.vmBundleSizeUpdated` notification contract that
//  drives the selected-VM detail card's Disk cell.
//

import XCTest
@testable import SecVF

@MainActor
final class VMManagerBundleSizeTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMManagerBundleSizeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - Helpers

    /// Build a `VMConfiguration` pointing at a fresh on-disk bundle of a
    /// known size. The bundle contains a single file with `bytesOfData`
    /// bytes so we can predict the allocated-on-disk size.
    private func makeMockVM(bytesOfData: Int) throws -> VMConfiguration {
        let bundleURL = try TestFileSystemHelper.createMockVMBundle(
            at: tempDir, name: "BundleSizeVM-\(UUID().uuidString.prefix(6))")

        // Overwrite the placeholder disk.img with a known-size payload so the
        // size-walker has real bytes to count (the helper's default makes a
        // zero-length file).
        let diskPath = bundleURL.appendingPathComponent("disk.img")
        let data = Data(repeating: 0xAA, count: bytesOfData)
        try data.write(to: diskPath)

        return VMConfiguration(
            name: "BundleSizeVM",
            bundlePath: bundleURL.path,
            cpuCount: 2,
            memorySize: 4_294_967_296,
            diskSize: 21_474_836_480
        )
    }

    // MARK: - Cache behavior

    func testFirstReadReturnsNilThenBackfillsViaNotification() throws {
        let vm = try makeMockVM(bytesOfData: 64_000)
        let mgr = VMManager.shared

        // First read with no cache should return nil and schedule a
        // background scan. The .vmBundleSizeUpdated notification fires
        // with the measured size once the scan finishes.
        let firstRead = mgr.onDiskBundleSize(for: vm)
        XCTAssertNil(firstRead, "Cold cache read must return nil — UI shows '— / total' until the scan completes")

        let exp = XCTestExpectation(description: "background scan posts .vmBundleSizeUpdated")
        var observed: Int64?
        let observer = NotificationCenter.default.addObserver(
            forName: .vmBundleSizeUpdated, object: nil, queue: .main
        ) { note in
            guard (note.object as? UUID) == vm.id else { return }
            observed = note.userInfo?["bytes"] as? Int64
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        wait(for: [exp], timeout: 5.0)
        XCTAssertNotNil(observed)
        // We wrote 64 000 bytes. APFS allocates in 4 KiB blocks, so the
        // reported allocated size should be ≥ 64 000 and within one block
        // worth of slack. (HFS+ test runs may diverge slightly — keep the
        // upper bound generous.)
        XCTAssertGreaterThanOrEqual(observed!, 64_000)
        XCTAssertLessThan(observed!, 64_000 + 16_384,
                          "Allocated size should be within ~one alloc block of payload size")
    }

    func testSecondReadAfterScanReturnsCachedValue() throws {
        let vm = try makeMockVM(bytesOfData: 8_000)
        let mgr = VMManager.shared

        _ = mgr.onDiskBundleSize(for: vm)

        let exp = XCTestExpectation(description: ".vmBundleSizeUpdated fires once")
        let observer = NotificationCenter.default.addObserver(
            forName: .vmBundleSizeUpdated, object: nil, queue: .main
        ) { note in
            if (note.object as? UUID) == vm.id { exp.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        wait(for: [exp], timeout: 5.0)

        // Cache should now contain the result. A read taken right after
        // the notification must NOT return nil.
        let cached = mgr.onDiskBundleSize(for: vm)
        XCTAssertNotNil(cached, "Post-scan read must surface the cached value synchronously")
        XCTAssertGreaterThanOrEqual(cached!, 8_000)
    }

    // MARK: - Notification contract

    func testNotificationCarriesVMIdAsObject() throws {
        // The detail card filters by `note.object as? UUID` matching the
        // currently selected VM. Make sure that contract holds.
        let vm = try makeMockVM(bytesOfData: 1024)

        let exp = XCTestExpectation(description: "object is the VM's UUID")
        let observer = NotificationCenter.default.addObserver(
            forName: .vmBundleSizeUpdated, object: nil, queue: .main
        ) { note in
            XCTAssertEqual(note.object as? UUID, vm.id,
                           ".vmBundleSizeUpdated object must be the VMConfiguration.id (UUID)")
            XCTAssertNotNil(note.userInfo?["bytes"] as? Int64,
                            "userInfo['bytes'] must be Int64")
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = VMManager.shared.onDiskBundleSize(for: vm)
        wait(for: [exp], timeout: 5.0)
    }
}
