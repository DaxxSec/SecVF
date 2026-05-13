//
//  AppColorsTests.swift
//  SecVFTests
//
//  Invariant tests for the tactical color palette. These pin the
//  *shape* of the palette — backward-compat aliases, alpha ranges,
//  status-pill contrast, and the tactical theme's core invariant
//  (no cyan/blue in primary accents — OD-green replaces them).
//

import XCTest
@testable import SecVF

@MainActor
final class AppColorsTests: XCTestCase {

    // MARK: - Backward-compat aliases (cyan → OD-green)

    func testCyanAliasesPointToODGreen() {
        // The redesign renamed the cyan tokens to OD but kept the cyan
        // names as aliases so existing callers compile. The aliases
        // must resolve to colors with identical components — not a
        // re-color that happens to look similar — so any future "drop
        // the alias" refactor is a single-grep operation, not a hunt.
        //
        // Asserting on RGBA components rather than NSColor instance
        // equality so the test still passes if the alias is later
        // expressed as two independently-defined NSColor literals with
        // matching values; what we care about is the *visible* color
        // contract, not the Swift-level reference equality.
        assertSameColor(AppColors.accentOD, AppColors.accentCyan,
                        "accentOD must alias accentCyan")
        assertSameColor(AppColors.accentODGlow, AppColors.accentNeonCyan,
                        "accentODGlow must alias accentNeonCyan")
        assertSameColor(AppColors.borderOD, AppColors.borderCyan,
                        "borderOD must alias borderCyan")
        assertSameColor(AppColors.borderODEmphasis, AppColors.borderCyanEmphasis,
                        "borderODEmphasis must alias borderCyanEmphasis")
    }

    /// Compare two colors by their device-RGB components rather than by
    /// NSColor instance equality. Two `static let` aliases like
    /// `static let accentOD = accentCyan` produce instance-equal values
    /// today, but a future refactor to independently-defined NSColors
    /// would break instance equality even when the components match.
    /// Use a small per-channel tolerance to ride out floating-point
    /// representation drift from explicit-literal restatements.
    private func assertSameColor(_ a: NSColor, _ b: NSColor,
                                 _ message: String,
                                 tolerance: CGFloat = 0.001,
                                 file: StaticString = #file, line: UInt = #line) {
        guard let aRGB = a.usingColorSpace(.deviceRGB),
              let bRGB = b.usingColorSpace(.deviceRGB) else {
            XCTFail("Color components unavailable for comparison", file: file, line: line)
            return
        }
        XCTAssertEqual(aRGB.redComponent,   bRGB.redComponent,   accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(aRGB.greenComponent, bRGB.greenComponent, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(aRGB.blueComponent,  bRGB.blueComponent,  accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(aRGB.alphaComponent, bRGB.alphaComponent, accuracy: tolerance, message, file: file, line: line)
    }

    func testTacticalAccentsAreActuallyGreen() {
        // The "OD" rename is meaningful — the underlying color MUST be
        // greenish (green channel > blue channel), not the original
        // cyan it replaced. If a future refactor accidentally re-tunes
        // these toward blue, the tactical aesthetic collapses.
        let od = AppColors.accentOD.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(od.greenComponent, od.blueComponent,
                             "accentOD must lean green, not blue (got G=\(od.greenComponent) vs B=\(od.blueComponent))")

        let glow = AppColors.accentODGlow.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(glow.greenComponent, glow.blueComponent,
                             "accentODGlow must lean green, not blue")
    }

    // MARK: - Status-pill palette

    func testStatusColorsAreDistinguishable() {
        // The four status colors must be visually distinct — collapsing
        // any pair would make Running/Paused/Stopped/Error
        // indistinguishable in the inline pill.
        let palette = [
            AppColors.statusRunning,
            AppColors.statusPaused,
            AppColors.statusStopped,
            AppColors.statusError,
        ].map { $0.usingColorSpace(.deviceRGB)! }

        for (i, a) in palette.enumerated() {
            for (j, b) in palette.enumerated() where j > i {
                let distance = colorDistance(a, b)
                XCTAssertGreaterThan(distance, 0.15,
                                     "Status colors at index \(i) and \(j) are too similar (distance \(distance))")
            }
        }
    }

    func testStatusRunningIsGreenAndStatusErrorIsRed() {
        // Anchor the semantics: green = good, red = bad. A swap here
        // would be a critical bug in a security-research UI where
        // operators react to color before reading text.
        let running = AppColors.statusRunning.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(running.greenComponent, running.redComponent,
                             "statusRunning must be greener than red")

        let error = AppColors.statusError.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(error.redComponent, error.greenComponent,
                             "statusError must be redder than green")
    }

    // MARK: - Border alpha contract

    func testBorderColorsAreSemiTransparent() {
        // Border tokens are intentionally translucent so they blend
        // into the layered backgrounds. Setting them to fully opaque
        // would paint hard outlines and break the tactical aesthetic.
        let borders = [
            AppColors.borderOD,
            AppColors.borderODEmphasis,
            AppColors.borderYellow,
            AppColors.borderOrange,
            AppColors.borderMagenta,
            AppColors.borderRed,
        ].map { $0.usingColorSpace(.deviceRGB)! }

        for color in borders {
            XCTAssertLessThan(color.alphaComponent, 1.0,
                              "Border color alpha=\(color.alphaComponent) — must be semi-transparent")
            XCTAssertGreaterThan(color.alphaComponent, 0.0,
                                 "Border color alpha=\(color.alphaComponent) — must be visible")
        }
    }

    func testBorderEmphasisIsMoreOpaqueThanBaseBorder() {
        let base = AppColors.borderOD.usingColorSpace(.deviceRGB)!
        let emphasis = AppColors.borderODEmphasis.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(emphasis.alphaComponent, base.alphaComponent,
                             "borderODEmphasis must be more opaque than borderOD")
    }

    // MARK: - Background hierarchy

    func testBackgroundColorsAreDarkThemeAndFullyOpaque() {
        // Tactical theme is dark — every solid-background token must
        // have low luminance and full opacity (no see-through panels
        // accidentally letting cell text bleed up).
        let backgrounds = [
            AppColors.backgroundPrimary,
            AppColors.backgroundSecondary,
            AppColors.backgroundTertiary,
            AppColors.backgroundButton,
            AppColors.backgroundPanel,
        ].map { $0.usingColorSpace(.deviceRGB)! }

        for bg in backgrounds {
            XCTAssertEqual(bg.alphaComponent, 1.0,
                           "Background must be fully opaque (got alpha=\(bg.alphaComponent))")
            let luminance = 0.2126 * bg.redComponent +
                            0.7152 * bg.greenComponent +
                            0.0722 * bg.blueComponent
            XCTAssertLessThan(luminance, 0.5,
                              "Background luminance \(luminance) must be < 0.5 (dark theme)")
        }
    }

    func testButtonHoverIsLighterThanButtonRest() {
        let rest = AppColors.backgroundButton.usingColorSpace(.deviceRGB)!
        let hover = AppColors.backgroundButtonHover.usingColorSpace(.deviceRGB)!
        let restLum   = 0.2126 * rest.redComponent +   0.7152 * rest.greenComponent +   0.0722 * rest.blueComponent
        let hoverLum  = 0.2126 * hover.redComponent +  0.7152 * hover.greenComponent +  0.0722 * hover.blueComponent
        XCTAssertGreaterThan(hoverLum, restLum,
                             "Button hover background must be lighter than rest")
    }

    // MARK: - Text contrast

    func testTextPrimaryContrastsAgainstBackgroundPrimary() {
        // The most common text + background pair must have at least
        // 4.5:1 contrast (WCAG AA for body text). Anything less makes
        // the library window unreadable on dim monitors.
        let text = AppColors.textPrimary.usingColorSpace(.deviceRGB)!
        let bg = AppColors.backgroundPrimary.usingColorSpace(.deviceRGB)!
        let ratio = contrastRatio(text, bg)
        XCTAssertGreaterThan(ratio, 4.5,
                             "textPrimary on backgroundPrimary contrast \(ratio) must exceed WCAG AA (4.5:1)")
    }

    // MARK: - Helpers

    private func colorDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let dr = a.redComponent   - b.redComponent
        let dg = a.greenComponent - b.greenComponent
        let db = a.blueComponent  - b.blueComponent
        return sqrt(dr * dr + dg * dg + db * db)
    }

    /// WCAG 2.1 relative luminance contrast ratio. Returns the higher
    /// luminance over the lower (so always ≥ 1.0).
    private func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        let lighter = max(la, lb)
        let darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ c: NSColor) -> CGFloat {
        let r = linearize(c.redComponent)
        let g = linearize(c.greenComponent)
        let b = linearize(c.blueComponent)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func linearize(_ channel: CGFloat) -> CGFloat {
        return channel <= 0.03928
            ? channel / 12.92
            : pow((channel + 0.055) / 1.055, 2.4)
    }
}
