//
//  SplashScreenWindow.swift
//  SecVF
//
//  SPLASH SCREEN
//  Displays animated SecVF logo on application launch
//

import Cocoa

@MainActor
class SplashScreenWindow: NSWindow {

    private var logoImageView: NSImageView!
    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var statusLabel: NSTextField?
    private var versionPulseTimer: Timer?
    private var isDismissing = false
    private var pulseHigh = false

    init() {
        // Create frameless window in center of screen
        let size = NSSize(width: 500, height: 400)
        let screenFrame = NSScreen.main?.frame ?? NSRect.zero
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )

        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = false

        setupUI()
        animateEntrance()
    }

    // Splash screen should not become key window
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }

    private func setupUI() {
        guard let contentView = contentView else { return }

        // Dark gradient background — tactical/cybersecurity aesthetic
        let backgroundView = GradientView(frame: contentView.bounds)
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.colors = [
            AppColors.backgroundPrimary.withAlphaComponent(0.98),
            AppColors.backgroundSecondary.withAlphaComponent(0.98)
        ]
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = LayoutConstants.cornerRadiusLG
        contentView.addSubview(backgroundView)

        // Logo container with OD glow effect
        let logoContainer = NSView(frame: NSRect(x: 100, y: 180, width: 300, height: 150))
        logoContainer.wantsLayer = true
        logoContainer.layer?.shadowColor = AppColors.accentODGlow.cgColor
        logoContainer.layer?.shadowOpacity = 1.0
        logoContainer.layer?.shadowOffset = CGSize.zero
        logoContainer.layer?.shadowRadius = 40
        contentView.addSubview(logoContainer)

        // SecVF Logo
        logoImageView = NSImageView(frame: logoContainer.bounds)
        logoImageView.imageScaling = .scaleProportionallyUpOrDown
        logoImageView.image = createSecVFLogo()
        logoImageView.alphaValue = 0  // Start invisible for fade-in animation
        logoImageView.wantsLayer = true
        logoContainer.addSubview(logoImageView)

        // Title - Two-tone: "Sec" in light gray, "VF" in medium gray
        titleLabel = NSTextField()
        titleLabel.frame = NSRect(x: 0, y: 120, width: 500, height: 50)
        titleLabel.alignment = .center
        titleLabel.isBordered = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false
        titleLabel.alphaValue = 0

        // Create attributed string with two colors and center alignment
        let attributedTitle = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 48, weight: .heavy)

        // Create paragraph style for centering
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        // "Sec" in light text
        let secPart = NSAttributedString(string: "Sec", attributes: [
            .font: font,
            .foregroundColor: AppColors.textLight,
            .paragraphStyle: paragraphStyle
        ])
        attributedTitle.append(secPart)

        // "VF" in muted text
        let vfPart = NSAttributedString(string: "VF", attributes: [
            .font: font,
            .foregroundColor: AppColors.textMuted,
            .paragraphStyle: paragraphStyle
        ])
        attributedTitle.append(vfPart)

        titleLabel.attributedStringValue = attributedTitle
        contentView.addSubview(titleLabel)

        // Subtitle - subtle gray
        subtitleLabel = NSTextField(labelWithString: "Security Virtualization Framework\nBuilt on Apple Virtualization Framework")
        subtitleLabel.frame = NSRect(x: 0, y: 60, width: 500, height: 50)
        subtitleLabel.alignment = .center
        subtitleLabel.font = NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeSmall, weight: .medium)
        subtitleLabel.textColor = AppColors.textSubtle
        subtitleLabel.alphaValue = 0
        contentView.addSubview(subtitleLabel)

        // Version/Loading label - light text
        let versionLabel = NSTextField(labelWithString: "[ INITIALIZING SANDBOX ]")
        self.statusLabel = versionLabel
        versionLabel.frame = NSRect(x: 0, y: 20, width: 500, height: 20)
        versionLabel.alignment = .center
        versionLabel.font = NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeBody, weight: .medium)
        versionLabel.textColor = AppColors.textLight
        versionLabel.alphaValue = 0
        contentView.addSubview(versionLabel)

        // Pulse the version label — use target/selector to stay on MainActor
        versionPulseTimer = Timer.scheduledTimer(
            timeInterval: 0.5, target: self,
            selector: #selector(pulseTick), userInfo: nil, repeats: true
        )
    }

    private func createSecVFLogo() -> NSImage {
        // Create cybersecurity/hacker themed logo
        let size = CGSize(width: 300, height: 150)
        let image = NSImage(size: size)

        image.lockFocus()

        let centerX = size.width / 2
        let centerY = size.height / 2

        // Hexagonal border (cybersecurity theme)
        let hexPath = NSBezierPath()
        let hexRadius: CGFloat = 60
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3.0
            let x = centerX + hexRadius * cos(angle)
            let y = centerY + hexRadius * sin(angle)
            if i == 0 {
                hexPath.move(to: CGPoint(x: x, y: y))
            } else {
                hexPath.line(to: CGPoint(x: x, y: y))
            }
        }
        hexPath.close()
        hexPath.lineWidth = 3.0

        // Light gray stroke
        NSColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1.0).setStroke()
        hexPath.stroke()

        // Digital lock icon in center
        let lockWidth: CGFloat = 30
        let lockHeight: CGFloat = 35
        let lockX = centerX - lockWidth / 2
        let lockY = centerY - lockHeight / 2

        // Lock body
        let lockBody = NSBezierPath(roundedRect: NSRect(x: lockX, y: lockY, width: lockWidth, height: lockHeight * 0.6), xRadius: 3, yRadius: 3)
        NSColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 0.8).setFill()
        lockBody.fill()

        // Lock shackle (top arc)
        let shacklePath = NSBezierPath()
        shacklePath.appendArc(
            withCenter: CGPoint(x: centerX, y: lockY + lockHeight * 0.6),
            radius: lockWidth * 0.35,
            startAngle: 0,
            endAngle: 180,
            clockwise: false
        )
        shacklePath.lineWidth = 4.0
        NSColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1.0).setStroke()
        shacklePath.stroke()

        // Keyhole
        let keyholePath = NSBezierPath(ovalIn: NSRect(x: centerX - 3, y: lockY + 8, width: 6, height: 6))
        let keyholeSlot = NSBezierPath(rect: NSRect(x: centerX - 1.5, y: lockY + 3, width: 3, height: 8))
        NSColor.black.setFill()
        keyholePath.fill()
        keyholeSlot.fill()

        // Circuit board pattern in corners (hacker aesthetic)
        NSColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 0.6).setStroke()

        // Top-left circuit
        let circuit1 = NSBezierPath()
        circuit1.move(to: CGPoint(x: 50, y: 110))
        circuit1.line(to: CGPoint(x: 80, y: 110))
        circuit1.line(to: CGPoint(x: 80, y: 95))
        circuit1.lineWidth = 1.5
        circuit1.stroke()

        // Draw nodes
        NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.8).setFill()
        NSBezierPath(ovalIn: NSRect(x: 48, y: 108, width: 4, height: 4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 78, y: 108, width: 4, height: 4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 78, y: 93, width: 4, height: 4)).fill()

        // Bottom-right circuit
        let circuit2 = NSBezierPath()
        circuit2.move(to: CGPoint(x: 250, y: 40))
        circuit2.line(to: CGPoint(x: 220, y: 40))
        circuit2.line(to: CGPoint(x: 220, y: 55))
        circuit2.lineWidth = 1.5
        NSColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 0.6).setStroke()
        circuit2.stroke()

        NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.8).setFill()
        NSBezierPath(ovalIn: NSRect(x: 248, y: 38, width: 4, height: 4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 218, y: 38, width: 4, height: 4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 218, y: 53, width: 4, height: 4)).fill()

        image.unlockFocus()
        return image
    }

    private func animateEntrance() {
        guard !isDismissing else { return }

        // Skip all NSAnimationContext animator proxies — they create dangling
        // references that crash when the window deallocates mid-animation.
        // Just snap to final state immediately.
        logoImageView.alphaValue = 1.0
        titleLabel.alphaValue = 1.0
        subtitleLabel.alphaValue = 1.0
    }

    @objc private func pulseTick() {
        guard !isDismissing else { return }
        pulseHigh.toggle()
        statusLabel?.alphaValue = pulseHigh ? 0.6 : 0.3
    }

    func setStatusMessage(_ message: String) {
        guard !isDismissing else { return }
        statusLabel?.stringValue = message
    }

    func fadeOut() {
        guard !isDismissing else { return }

        isDismissing = true

        versionPulseTimer?.invalidate()
        versionPulseTimer = nil

        // Cancel any running layer animations
        logoImageView?.layer?.removeAllAnimations()
        contentView?.subviews.forEach { $0.layer?.removeAllAnimations() }

        // Hide the window — use orderOut instead of close to avoid
        // deferred AppKit teardown callbacks that crash after dealloc.
        self.alphaValue = 0

        self.orderOut(nil)

    }

    deinit {
        versionPulseTimer?.invalidate()

    }
}

// Custom gradient view
@MainActor
class GradientView: NSView {
    var colors: [NSColor] = [] {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard colors.count >= 2 else { return }

        let gradient = NSGradient(colors: colors)
        gradient?.draw(in: bounds, angle: -45)
    }
}
