//
//  SplashScreenWindow.swift
//  SecVF
//
//  SPLASH SCREEN
//  Displays animated CSIRT logo on application launch
//

import Cocoa

class SplashScreenWindow: NSWindow {

    private var logoImageView: NSImageView!
    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var fadeOutTimer: Timer?

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

        setupUI()
        animateEntrance()
    }

    private func setupUI() {
        guard let contentView = contentView else { return }

        // Dark gradient background
        let backgroundView = GradientView(frame: contentView.bounds)
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.colors = [
            NSColor(red: 0.08, green: 0.12, blue: 0.24, alpha: 0.95),  // Dark navy blue
            NSColor(red: 0.12, green: 0.16, blue: 0.32, alpha: 0.95)   // Slightly lighter navy
        ]
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 20
        contentView.addSubview(backgroundView)

        // Logo container with glow effect
        let logoContainer = NSView(frame: NSRect(x: 100, y: 180, width: 300, height: 150))
        logoContainer.wantsLayer = true
        logoContainer.layer?.shadowColor = NSColor.systemBlue.cgColor
        logoContainer.layer?.shadowOpacity = 0.8
        logoContainer.layer?.shadowOffset = CGSize.zero
        logoContainer.layer?.shadowRadius = 30
        contentView.addSubview(logoContainer)

        // CSIRT Logo
        logoImageView = NSImageView(frame: logoContainer.bounds)
        logoImageView.imageScaling = .scaleProportionallyUpOrDown
        logoImageView.image = createCSIRTLogo()
        logoImageView.alphaValue = 0  // Start invisible for fade-in animation
        logoContainer.addSubview(logoImageView)

        // Title
        titleLabel = NSTextField(labelWithString: "SecVF")
        titleLabel.frame = NSRect(x: 0, y: 120, width: 500, height: 50)
        titleLabel.alignment = .center
        titleLabel.font = NSFont.systemFont(ofSize: 42, weight: .bold)
        titleLabel.textColor = NSColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)  // Electric blue
        titleLabel.alphaValue = 0
        contentView.addSubview(titleLabel)

        // Subtitle
        subtitleLabel = NSTextField(labelWithString: "Computer Security Incident Response Team\nVirtualization Framework")
        subtitleLabel.frame = NSRect(x: 0, y: 60, width: 500, height: 50)
        subtitleLabel.alignment = .center
        subtitleLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor(red: 0.6, green: 0.7, blue: 0.9, alpha: 1.0)
        subtitleLabel.alphaValue = 0
        contentView.addSubview(subtitleLabel)

        // Version/Loading label
        let versionLabel = NSTextField(labelWithString: "Loading...")
        versionLabel.frame = NSRect(x: 0, y: 20, width: 500, height: 20)
        versionLabel.alignment = .center
        versionLabel.font = NSFont.systemFont(ofSize: 10, weight: .light)
        versionLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
        versionLabel.alphaValue = 0
        contentView.addSubview(versionLabel)

        // Animate version label pulsing
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak versionLabel] _ in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                versionLabel?.animator().alphaValue = versionLabel?.alphaValue == 0.3 ? 0.6 : 0.3
            }
        }
    }

    private func createCSIRTLogo() -> NSImage {
        // Create a stylized shield logo programmatically since we don't have the asset
        let size = CGSize(width: 300, height: 150)
        let image = NSImage(size: size)

        image.lockFocus()

        // Shield shape with gradient
        let shieldPath = NSBezierPath()
        shieldPath.move(to: CGPoint(x: size.width * 0.5, y: size.height * 0.95))
        shieldPath.curve(
            to: CGPoint(x: size.width * 0.1, y: size.height * 0.7),
            controlPoint1: CGPoint(x: size.width * 0.2, y: size.height * 0.9),
            controlPoint2: CGPoint(x: size.width * 0.1, y: size.height * 0.8)
        )
        shieldPath.line(to: CGPoint(x: size.width * 0.1, y: size.height * 0.3))
        shieldPath.curve(
            to: CGPoint(x: size.width * 0.5, y: size.height * 0.05),
            controlPoint1: CGPoint(x: size.width * 0.1, y: size.height * 0.15),
            controlPoint2: CGPoint(x: size.width * 0.3, y: size.height * 0.05)
        )
        shieldPath.curve(
            to: CGPoint(x: size.width * 0.9, y: size.height * 0.3),
            controlPoint1: CGPoint(x: size.width * 0.7, y: size.height * 0.05),
            controlPoint2: CGPoint(x: size.width * 0.9, y: size.height * 0.15)
        )
        shieldPath.line(to: CGPoint(x: size.width * 0.9, y: size.height * 0.7))
        shieldPath.curve(
            to: CGPoint(x: size.width * 0.5, y: size.height * 0.95),
            controlPoint1: CGPoint(x: size.width * 0.9, y: size.height * 0.8),
            controlPoint2: CGPoint(x: size.width * 0.8, y: size.height * 0.9)
        )
        shieldPath.close()

        // Gradient fill
        let gradient = NSGradient(colors: [
            NSColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1.0),
            NSColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 1.0)
        ])
        gradient?.draw(in: shieldPath, angle: -45)

        // Eye/Security symbol in center
        NSColor.black.withAlphaComponent(0.3).setFill()
        let eyePath = NSBezierPath(ovalIn: NSRect(x: size.width * 0.35, y: size.height * 0.35, width: size.width * 0.3, height: size.height * 0.3))
        eyePath.fill()

        NSColor.white.setFill()
        let pupilPath = NSBezierPath(ovalIn: NSRect(x: size.width * 0.45, y: size.height * 0.45, width: size.width * 0.1, height: size.height * 0.1))
        pupilPath.fill()

        image.unlockFocus()
        return image
    }

    private func animateEntrance() {
        // Fade in sequence
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.8
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            logoImageView.animator().alphaValue = 1.0
        }, completionHandler: {
            // Pulse logo
            self.pulseAnimation()

            // Fade in text
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.6
                self.titleLabel.animator().alphaValue = 1.0
                self.subtitleLabel.animator().alphaValue = 1.0
            })
        })

        // Auto-close after 3 seconds
        fadeOutTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }

    private func pulseAnimation() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 1.5
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            logoImageView.layer?.transform = CATransform3DMakeScale(1.1, 1.1, 1.0)
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 1.5
                self.logoImageView.layer?.transform = CATransform3DIdentity
            })
        })
    }

    func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.5
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.close()
        })
    }

    deinit {
        fadeOutTimer?.invalidate()
    }
}

// Custom gradient view
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
