//
//  TacticalEmptyStateView.swift
//  SecVF
//
//  Centered empty-state panel shown when the VM table (Standard tab) or
//  the AI Sandbox outline view (Sandbox tab) has no rows. Replaces a
//  plain centered NSTextField with a layered visual:
//
//      ┌───────────────────────────────────┐
//      │                                   │
//      │            ◇ <large glyph>        │
//      │                                   │
//      │       No virtual machines yet     │
//      │                                   │
//      │   Click ⊕ New to create your      │
//      │   first VM, or Import an existing │
//      │   bundle.                         │
//      │                                   │
//      │     [ ⊕  Create your first VM ]   │
//      │                                   │
//      └───────────────────────────────────┘
//
//  The CTA button is optional — pass `nil` for callers that don't have
//  a single-click "do the thing" action (e.g. the AI Sandbox tab where
//  the build is multi-step and lives under Tools → Create AI Sandbox VM).
//

import Cocoa

final class TacticalEmptyStateView: NSView {

    /// Optional callback for the CTA button. The owning controller is
    /// responsible for retaining this; the view does not own the closure
    /// beyond its own lifetime.
    private let onCTA: (() -> Void)?

    /// Centered stack: glyph (huge), title, hint, optional CTA button.
    /// The whole stack sits inside this view and is re-centered on resize
    /// via `autoresizesSubviews` and explicit reposition in `resizeSubviews`.
    private let stack: NSStackView
    private let glyphLabel: NSTextField
    private let titleLabel: NSTextField
    private let hintLabel: NSTextField
    private let ctaButton: TacticalHoverButton?

    init(glyph: String,
         title: String,
         hint: String,
         ctaTitle: String?,
         onCTA: (() -> Void)?)
    {
        self.onCTA = onCTA

        glyphLabel = NSTextField(labelWithString: glyph)
        glyphLabel.font = NSFont.systemFont(ofSize: 48, weight: .light)
        glyphLabel.textColor = AppColors.accentODGlow.withAlphaComponent(0.5)
        glyphLabel.alignment = .center
        glyphLabel.setAccessibilityElement(false)   // decorative

        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.monospacedSystemFont(
            ofSize: LayoutConstants.fontSizeSubtitle, weight: .semibold)
        titleLabel.textColor = AppColors.textPrimary
        titleLabel.alignment = .center

        hintLabel = NSTextField(labelWithString: hint)
        hintLabel.font = NSFont.systemFont(ofSize: LayoutConstants.fontSizeBody,
                                           weight: .regular)
        hintLabel.textColor = AppColors.textMuted
        hintLabel.alignment = .center
        hintLabel.maximumNumberOfLines = 4
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.usesSingleLineMode = false

        if let ctaTitle = ctaTitle {
            let btn = TacticalHoverButton(title: ctaTitle, target: nil, action: nil)
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.backgroundColor = AppColors.backgroundButton.cgColor
            btn.layer?.borderColor = AppColors.borderODEmphasis.cgColor
            btn.layer?.borderWidth = 1.0
            btn.layer?.cornerRadius = LayoutConstants.cornerRadiusSM
            btn.attributedTitle = NSAttributedString(string: "  " + ctaTitle + "  ", attributes: [
                .foregroundColor: AppColors.textPrimary,
                .font: NSFont.systemFont(ofSize: LayoutConstants.fontSizeBody, weight: .medium)
            ])
            btn.setHoverTreatment(hoverBorder: AppColors.accentODGlow)
            ctaButton = btn
        } else {
            ctaButton = nil
        }

        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = LayoutConstants.spacingLG
        stack.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)

        // Hint wraps — give it a tight max width so it doesn't sprawl
        // across the full table width on a wide window.
        hintLabel.preferredMaxLayoutWidth = 320

        stack.addArrangedSubview(glyphLabel)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(hintLabel)
        if let cta = ctaButton {
            cta.target = self
            cta.action = #selector(handleCTA(_:))
            stack.addArrangedSubview(cta)
            stack.setCustomSpacing(LayoutConstants.spacingXL, after: hintLabel)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(glyph:title:hint:ctaTitle:onCTA:)")
    }

    @objc private func handleCTA(_ sender: NSButton) {
        onCTA?()
    }
}
