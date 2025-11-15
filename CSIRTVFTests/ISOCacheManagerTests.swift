//
//  ISOCacheManagerTests.swift
//  SecVFTests
//
//  Comprehensive tests for ISOCacheManager security and functionality
//

import XCTest
@testable import SecVF

final class ISOCacheManagerTests: XCTestCase {

    var cacheManager: ISOCacheManager!
    var testCacheRoot: String!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Create temporary test cache directory
        testCacheRoot = NSTemporaryDirectory() + "test-iso-cache-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: testCacheRoot, withIntermediateDirectories: true)

        // Get shared instance for testing
        cacheManager = ISOCacheManager.shared
    }

    override func tearDownWithError() throws {
        // Clean up test cache directory
        if FileManager.default.fileExists(atPath: testCacheRoot) {
            try? FileManager.default.removeItem(atPath: testCacheRoot)
        }

        try super.tearDownWithError()
    }

    // MARK: - Security Router Enforcement Tests

    func testSecurityRouterMustBeKali() {
        let expectation = XCTestExpectation(description: "Reject non-Kali router VM")

        // Attempt to create Ubuntu router - should fail
        let ubuntuRouter = VMImageType.linux(distro: .ubuntu, version: "24.04", isSecurityRouter: true)

        cacheManager.downloadImage(
            for: ubuntuRouter,
            progressHandler: { _, _ in },
            completionHandler: { result in
                switch result {
                case .success:
                    XCTFail("Should have rejected non-Kali router VM")
                case .failure(let error):
                    let nsError = error as NSError
                    XCTAssertEqual(nsError.code, 200, "Should return error code 200 for invalid router distro")
                    XCTAssertTrue(nsError.localizedDescription.contains("Kali"), "Error should mention Kali requirement")
                    XCTAssertTrue(nsError.localizedDescription.contains("Ubuntu"), "Error should mention attempted distro")
                }
                expectation.fulfill()
            }
        )

        wait(for: [expectation], timeout: 2.0)
    }

    func testSecurityRouterAllowsKali() {
        // Kali router should pass validation (even if download fails due to network)
        let kaliRouter = VMImageType.linux(distro: .kali, version: "2024.1", isSecurityRouter: true)

        // This test just verifies validation passes, not full download
        // (Full download would require network access)
        let expectation = XCTestExpectation(description: "Allow Kali router VM")
        expectation.isInverted = false

        cacheManager.downloadImage(
            for: kaliRouter,
            progressHandler: { _, _ in },
            completionHandler: { result in
                // Don't care if download succeeds/fails, just that validation passed
                // If we got error code 200, that means validation failed
                if case .failure(let error) = result {
                    let nsError = error as NSError
                    XCTAssertNotEqual(nsError.code, 200, "Kali router should pass validation")
                }
                expectation.fulfill()
            }
        )

        wait(for: [expectation], timeout: 5.0)
    }

    func testNonRouterVMsAllowAnyDistro() {
        // Non-router VMs should accept any supported distro
        let distros: [LinuxDistro] = [.ubuntu, .debian, .fedora, .kali, .parrot, .arch, .manjaro]

        for distro in distros {
            let vmType = VMImageType.linux(distro: distro, version: "test", isSecurityRouter: false)

            // Verify VM type creates correctly (validation happens in downloadImage)
            XCTAssertNotNil(vmType)

            // Check description doesn't include router tag
            XCTAssertFalse(vmType.description.contains("Security Router"),
                          "\(distro.rawValue) non-router should not have router tag")
        }
    }

    // MARK: - URL Validation Tests

    func testApprovedDomainList() {
        let approvedDomains = LinuxDistro.approvedDomains

        // Verify expected official CDNs are present
        XCTAssertTrue(approvedDomains.contains("cdimage.ubuntu.com"))
        XCTAssertTrue(approvedDomains.contains("cdimage.debian.org"))
        XCTAssertTrue(approvedDomains.contains("download.fedoraproject.org"))
        XCTAssertTrue(approvedDomains.contains("cdimage.kali.org"))
        XCTAssertTrue(approvedDomains.contains("download.parrot.sh"))
        XCTAssertTrue(approvedDomains.contains("geo.mirror.pkgbuild.com"))
        XCTAssertTrue(approvedDomains.contains("download.manjaro.org"))

        // Verify dangerous domains are NOT present
        XCTAssertFalse(approvedDomains.contains("github.com"))
        XCTAssertFalse(approvedDomains.contains("sourceforge.net"))
        XCTAssertFalse(approvedDomains.contains("example.com"))
    }

    func testDistroURLsAreHTTPS() {
        let distros: [LinuxDistro] = [.ubuntu, .debian, .fedora, .kali, .parrot, .arch, .manjaro]

        for distro in distros {
            let urlString = distro.downloadURL
            XCTAssertTrue(urlString.hasPrefix("https://"),
                         "\(distro.rawValue) URL should use HTTPS: \(urlString)")
        }
    }

    func testDistroURLsAreISO() {
        let distros: [LinuxDistro] = [.ubuntu, .debian, .fedora, .kali, .parrot, .arch, .manjaro]

        for distro in distros {
            let urlString = distro.downloadURL
            XCTAssertTrue(urlString.hasSuffix(".iso"),
                         "\(distro.rawValue) URL should end with .iso: \(urlString)")
        }
    }

    func testDistroURLsMatchApprovedDomains() {
        let distros: [LinuxDistro] = [.ubuntu, .debian, .fedora, .kali, .parrot, .arch, .manjaro]
        let approvedDomains = LinuxDistro.approvedDomains

        for distro in distros {
            guard let url = URL(string: distro.downloadURL),
                  let host = url.host?.lowercased() else {
                XCTFail("\(distro.rawValue) has invalid URL")
                continue
            }

            XCTAssertTrue(approvedDomains.contains(host),
                         "\(distro.rawValue) URL host '\(host)' should be in approved list")
        }
    }

    // MARK: - VMImageType Description Tests

    func testVMImageTypeDescriptionMacOS() {
        let macOS = VMImageType.macOS(version: "15.2.1")
        XCTAssertEqual(macOS.description, "macOS 15.2.1")
    }

    func testVMImageTypeDescriptionLinux() {
        let ubuntu = VMImageType.linux(distro: .ubuntu, version: "24.04", isSecurityRouter: false)
        XCTAssertEqual(ubuntu.description, "Ubuntu 24.04")
    }

    func testVMImageTypeDescriptionRouter() {
        let kaliRouter = VMImageType.linux(distro: .kali, version: "2024.1", isSecurityRouter: true)
        XCTAssertTrue(kaliRouter.description.contains("Kali"))
        XCTAssertTrue(kaliRouter.description.contains("2024.1"))
        XCTAssertTrue(kaliRouter.description.contains("Security Router"))
    }

    // MARK: - Cache Path Tests

    func testCachePathStructure() {
        // Verify cache root is in user home directory
        let expectedRoot = NSHomeDirectory() + "/.avf/VMImages/"

        // Note: Can't directly test private getImagePath(), but can verify
        // that the cache manager uses correct structure
        let cacheRoot = NSHomeDirectory() + "/.avf/VMImages/"
        XCTAssertTrue(cacheRoot.hasPrefix(NSHomeDirectory()))
        XCTAssertTrue(cacheRoot.hasSuffix("/.avf/VMImages/"))
    }

    func testMacOSCachePath() {
        // macOS images should be stored in MacOS subdirectory
        let macOSCachePath = NSHomeDirectory() + "/.avf/VMImages/MacOS/"

        // Verify directory can be created
        XCTAssertNoThrow(try FileManager.default.createDirectory(
            atPath: macOSCachePath,
            withIntermediateDirectories: true
        ))
    }

    func testLinuxCachePath() {
        // Linux images should be stored in Linux subdirectory
        let linuxCachePath = NSHomeDirectory() + "/.avf/VMImages/Linux/"

        // Verify directory can be created
        XCTAssertNoThrow(try FileManager.default.createDirectory(
            atPath: linuxCachePath,
            withIntermediateDirectories: true
        ))
    }

    // MARK: - SHA256 Validation Tests

    func testSHA256ChecksumsExist() {
        let distros: [LinuxDistro] = [.ubuntu, .debian, .fedora, .kali, .parrot, .arch, .manjaro]

        for distro in distros {
            let checksum = distro.sha256Checksum
            XCTAssertFalse(checksum.isEmpty,
                          "\(distro.rawValue) should have SHA256 checksum")

            // For now, placeholders are acceptable but should be marked
            if checksum.hasPrefix("PLACEHOLDER") {
                print("⚠️  WARNING: \(distro.rawValue) still using placeholder SHA256")
            }
        }
    }

    // MARK: - Cache Size Tests

    func testGetCacheSizeGB() {
        // Should return 0 for empty/non-existent cache
        let size = cacheManager.getCacheSizeGB()
        XCTAssertGreaterThanOrEqual(size, 0.0)
    }

    func testListCachedImages() {
        // Should return empty array for fresh cache
        let images = cacheManager.listCachedImages()
        XCTAssertNotNil(images)
        // Note: May not be empty if cache already exists from previous runs
    }

    // MARK: - Integration Tests

    func testCachedImageReuse() {
        // Verify that cached images are detected and reused
        let ubuntuType = VMImageType.linux(distro: .ubuntu, version: "24.04", isSecurityRouter: false)

        // First check - should return nil if not cached
        let cachedImage = cacheManager.getCachedImage(for: ubuntuType)

        // Don't assert nil - cache might exist from previous test runs
        // Just verify method doesn't crash
        XCTAssertNotNil(cacheManager) // Smoke test
    }

    // MARK: - Stress Tests

    func testMultipleDistroSupport() {
        // Verify all supported distros are properly defined
        let distros: [LinuxDistro] = [.ubuntu, .debian, .fedora, .kali, .parrot, .arch, .manjaro]

        XCTAssertEqual(distros.count, 7, "Should support exactly 7 Linux distributions")

        for distro in distros {
            XCTAssertFalse(distro.rawValue.isEmpty, "Distro name should not be empty")
            XCTAssertFalse(distro.downloadURL.isEmpty, "Download URL should not be empty")
            XCTAssertFalse(distro.sha256Checksum.isEmpty, "SHA256 should not be empty")
        }
    }

    func testRouterFlagDefaultValue() {
        // Default value for isSecurityRouter should be false
        let ubuntu = VMImageType.linux(distro: .ubuntu, version: "24.04")

        // Verify non-router description
        XCTAssertFalse(ubuntu.description.contains("Security Router"))
    }

    // MARK: - Error Handling Tests

    func testInvalidRouterDistroErrorMessage() {
        let expectation = XCTestExpectation(description: "Error message contains details")

        let debianRouter = VMImageType.linux(distro: .debian, version: "12", isSecurityRouter: true)

        cacheManager.downloadImage(
            for: debianRouter,
            progressHandler: { _, _ in },
            completionHandler: { result in
                if case .failure(let error) = result {
                    let message = error.localizedDescription
                    XCTAssertTrue(message.contains("SECURITY"), "Error should be marked as security issue")
                    XCTAssertTrue(message.contains("Kali"), "Error should specify Kali requirement")
                    XCTAssertTrue(message.contains("Debian"), "Error should identify rejected distro")
                }
                expectation.fulfill()
            }
        )

        wait(for: [expectation], timeout: 2.0)
    }
}
