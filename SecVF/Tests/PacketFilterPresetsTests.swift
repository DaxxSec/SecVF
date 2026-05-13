//
//  PacketFilterPresetsTests.swift
//  SecVFTests
//
//  Tests for the shared malware-analysis filter catalog used by both
//  the PacketAnalysisWindowController dropdown and the library
//  window's "Filter" button. These tests pin the catalog's shape and
//  the lookup contract so a future preset addition / typo can't
//  silently break either consumer.
//

import XCTest
@testable import SecVF

@MainActor
final class PacketFilterPresetsTests: XCTestCase {

    // MARK: - Catalog shape

    func testSectionsAreNonEmpty() {
        XCTAssertFalse(PacketFilterPresets.sections.isEmpty,
                       "Catalog must define at least one section")
        for section in PacketFilterPresets.sections {
            XCTAssertFalse(section.presets.isEmpty,
                           "Section '\(section.title)' must have at least one preset")
        }
    }

    func testSectionHeadersUseConsistentMarkers() {
        // Section headers are rendered as disabled menu items with the
        // "── TITLE ──" decoration. Any new section that drops the
        // markers would show up plain in the menu — fail loudly.
        for section in PacketFilterPresets.sections {
            XCTAssertTrue(section.title.hasPrefix("──") && section.title.hasSuffix("──"),
                          "Section title '\(section.title)' must use ── markers")
        }
    }

    func testEveryPresetHasNonEmptyTitleAndFilter() {
        for section in PacketFilterPresets.sections {
            for preset in section.presets {
                XCTAssertFalse(preset.title.isEmpty,
                               "Preset in '\(section.title)' has empty title")
                XCTAssertFalse(preset.filter.isEmpty,
                               "Preset '\(preset.title)' has empty filter expression")
            }
        }
    }

    func testPresetTitlesAreUnique() {
        var seen = Set<String>()
        for section in PacketFilterPresets.sections {
            for preset in section.presets {
                XCTAssertFalse(seen.contains(preset.title),
                               "Duplicate preset title: '\(preset.title)' — filter(for:) lookup would be ambiguous")
                seen.insert(preset.title)
            }
        }
    }

    // MARK: - Lookup

    func testFilterLookupReturnsNilForUnknownTitle() {
        XCTAssertNil(PacketFilterPresets.filter(for: "not a real preset"))
        XCTAssertNil(PacketFilterPresets.filter(for: ""))
    }

    func testFilterLookupHitsForKnownPresets() {
        // Spot-check a handful of presets the UI relies on.
        XCTAssertEqual(PacketFilterPresets.filter(for: "All DNS Traffic"), "dns")
        XCTAssertEqual(PacketFilterPresets.filter(for: "All TCP"), "tcp")
        XCTAssertEqual(PacketFilterPresets.filter(for: "All ARP"), "arp")
    }

    func testFilterLookupIsCaseSensitive() {
        // Lookup is exact-match; the menu builder emits the same titles
        // the lookup expects, so case-sensitivity is fine. This test
        // documents the contract so a fuzzy-match refactor can't slip
        // in without updating both sides.
        XCTAssertNotNil(PacketFilterPresets.filter(for: "All DNS Traffic"))
        XCTAssertNil(PacketFilterPresets.filter(for: "all dns traffic"))
    }

    // MARK: - Menu builder

    func testBuildMenuHasSeparatorBetweenSections() {
        let menu = PacketFilterPresets.buildMenu(target: nil, action: #selector(NSResponder.becomeFirstResponder))
        let separatorCount = menu.items.filter { $0.isSeparatorItem }.count
        let sectionCount = PacketFilterPresets.sections.count
        XCTAssertEqual(separatorCount, sectionCount - 1,
                       "Menu should have N-1 separators between N sections")
    }

    func testBuildMenuHasDisabledHeaderForEachSection() {
        let menu = PacketFilterPresets.buildMenu(target: nil, action: #selector(NSResponder.becomeFirstResponder))
        let disabledHeaders = menu.items.filter { item in
            !item.isSeparatorItem && !item.isEnabled
        }
        XCTAssertEqual(disabledHeaders.count, PacketFilterPresets.sections.count,
                       "Each section needs a disabled header item")
    }

    func testBuildMenuItemsCarryPresetTitles() {
        let menu = PacketFilterPresets.buildMenu(target: nil, action: #selector(NSResponder.becomeFirstResponder))
        // Every preset title from the catalog should appear as an
        // enabled menu item.
        let enabledTitles = Set(menu.items
            .filter { !$0.isSeparatorItem && $0.isEnabled }
            .map { $0.title })
        for section in PacketFilterPresets.sections {
            for preset in section.presets {
                XCTAssertTrue(enabledTitles.contains(preset.title),
                              "Preset '\(preset.title)' missing from built menu")
            }
        }
    }

    func testBuildMenuWiresActionAndTargetOnEnabledItems() {
        // A dummy NSResponder so we have a real AnyObject to wire as target.
        let target = NSResponder()
        let action = #selector(NSResponder.becomeFirstResponder)
        let menu = PacketFilterPresets.buildMenu(target: target, action: action)
        let presetItems = menu.items.filter { !$0.isSeparatorItem && $0.isEnabled }
        XCTAssertFalse(presetItems.isEmpty)
        for item in presetItems {
            XCTAssertTrue(item.target === target,
                          "Preset item '\(item.title)' should target the supplied responder")
            XCTAssertEqual(item.action, action,
                           "Preset item '\(item.title)' should wire the supplied action")
        }
    }
}
