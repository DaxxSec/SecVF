#!/usr/bin/swift

// SecVF Icon Generator
// Creates application icon matching the splash screen cybersecurity design

import Cocoa

func createCSIRTIcon(size: CGSize) -> NSImage {
    let image = NSImage(size: size)

    image.lockFocus()

    // Clear background
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()

    let centerX = size.width / 2
    let centerY = size.height / 2
    let scale = size.width / 300.0  // Base design is 300pt

    // Dark background circle
    let bgCircle = NSBezierPath(ovalIn: NSRect(
        x: size.width * 0.1,
        y: size.height * 0.1,
        width: size.width * 0.8,
        height: size.height * 0.8
    ))

    // Dark gradient background
    let gradient = NSGradient(colors: [
        NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0),
        NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)
    ])
    gradient?.draw(in: bgCircle, angle: -45)

    // Hexagonal border (cybersecurity theme)
    let hexPath = NSBezierPath()
    let hexRadius = 60.0 * scale
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
    hexPath.lineWidth = 4.0 * scale

    // Neon cyan stroke with glow
    let shadowColor = NSColor(red: 0.0, green: 0.8, blue: 1.0, alpha: 1.0)
    let shadow = NSShadow()
    shadow.shadowColor = shadowColor
    shadow.shadowBlurRadius = 10.0 * scale
    shadow.shadowOffset = .zero
    shadow.set()

    NSColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 1.0).setStroke()
    hexPath.stroke()

    // Digital lock icon in center
    let lockWidth = 30.0 * scale
    let lockHeight = 35.0 * scale
    let lockX = centerX - lockWidth / 2
    let lockY = centerY - lockHeight / 2

    // Lock body
    let lockBody = NSBezierPath(roundedRect: NSRect(
        x: lockX,
        y: lockY,
        width: lockWidth,
        height: lockHeight * 0.6
    ), xRadius: 3 * scale, yRadius: 3 * scale)
    NSColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 0.9).setFill()
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
    shacklePath.lineWidth = 5.0 * scale
    NSColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 1.0).setStroke()

    // Remove shadow for shackle
    let noShadow = NSShadow()
    noShadow.shadowBlurRadius = 0
    noShadow.set()
    shacklePath.stroke()

    // Keyhole
    let keyholePath = NSBezierPath(ovalIn: NSRect(
        x: centerX - 3 * scale,
        y: lockY + 8 * scale,
        width: 6 * scale,
        height: 6 * scale
    ))
    let keyholeSlot = NSBezierPath(rect: NSRect(
        x: centerX - 1.5 * scale,
        y: lockY + 3 * scale,
        width: 3 * scale,
        height: 8 * scale
    ))
    NSColor.black.setFill()
    keyholePath.fill()
    keyholeSlot.fill()

    // Circuit board accents (neon green)
    NSColor(red: 0.0, green: 1.0, blue: 0.5, alpha: 0.6).setStroke()

    // Top-left circuit
    let circuit1 = NSBezierPath()
    circuit1.move(to: CGPoint(x: size.width * 0.2, y: size.height * 0.75))
    circuit1.line(to: CGPoint(x: size.width * 0.3, y: size.height * 0.75))
    circuit1.line(to: CGPoint(x: size.width * 0.3, y: size.height * 0.68))
    circuit1.lineWidth = 2.0 * scale
    circuit1.stroke()

    // Nodes
    NSColor(red: 0.0, green: 1.0, blue: 0.5, alpha: 0.9).setFill()
    NSBezierPath(ovalIn: NSRect(
        x: size.width * 0.195,
        y: size.height * 0.745,
        width: 5 * scale,
        height: 5 * scale
    )).fill()
    NSBezierPath(ovalIn: NSRect(
        x: size.width * 0.295,
        y: size.height * 0.745,
        width: 5 * scale,
        height: 5 * scale
    )).fill()

    // Bottom-right circuit
    NSColor(red: 0.0, green: 1.0, blue: 0.5, alpha: 0.6).setStroke()
    let circuit2 = NSBezierPath()
    circuit2.move(to: CGPoint(x: size.width * 0.8, y: size.height * 0.25))
    circuit2.line(to: CGPoint(x: size.width * 0.7, y: size.height * 0.25))
    circuit2.line(to: CGPoint(x: size.width * 0.7, y: size.height * 0.32))
    circuit2.lineWidth = 2.0 * scale
    circuit2.stroke()

    NSColor(red: 0.0, green: 1.0, blue: 0.5, alpha: 0.9).setFill()
    NSBezierPath(ovalIn: NSRect(
        x: size.width * 0.795,
        y: size.height * 0.245,
        width: 5 * scale,
        height: 5 * scale
    )).fill()
    NSBezierPath(ovalIn: NSRect(
        x: size.width * 0.695,
        y: size.height * 0.245,
        width: 5 * scale,
        height: 5 * scale
    )).fill()

    image.unlockFocus()
    return image
}

func saveIconSet() {
    let sizes: [(size: Int, scale: Int, name: String)] = [
        (16, 1, "icon_16x16"),
        (16, 2, "icon_16x16@2x"),
        (32, 1, "icon_32x32"),
        (32, 2, "icon_32x32@2x"),
        (128, 1, "icon_128x128"),
        (128, 2, "icon_128x128@2x"),
        (256, 1, "icon_256x256"),
        (256, 2, "icon_256x256@2x"),
        (512, 1, "icon_512x512"),
        (512, 2, "icon_512x512@2x")
    ]

    // Detect project directory dynamically (script is in scripts/, assets go to assets/)
    let scriptDir = URL(fileURLWithPath: #file).deletingLastPathComponent().path
    let projectDir = URL(fileURLWithPath: scriptDir).deletingLastPathComponent().path
    let iconsetPath = "\(projectDir)/assets/SecVF.iconset"

    // Create iconset directory
    try? FileManager.default.removeItem(atPath: iconsetPath)
    try! FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

    print("Generating icon images...")

    for (baseSize, scale, name) in sizes {
        let pixelSize = baseSize * scale
        let pointSize = baseSize  // Use points, not pixels
        let image = createCSIRTIcon(size: CGSize(width: CGFloat(pixelSize), height: CGFloat(pixelSize)))

        // Create a bitmap with exact pixel dimensions
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            print("Failed to create bitmap for \(name).png")
            continue
        }

        // Draw into the bitmap at exact size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            print("Failed to create PNG for \(name).png")
            continue
        }

        let filePath = "\(iconsetPath)/\(name).png"
        try! pngData.write(to: URL(fileURLWithPath: filePath))
        print("  ✓ Created \(name).png (\(pixelSize)x\(pixelSize))")
    }

    print("\n✓ Icon set created at: \(iconsetPath)")
    print("\nConverting to .icns format...")

    // Convert iconset to icns
    let task = Process()
    task.launchPath = "/usr/bin/iconutil"
    let icnsPath = "\(projectDir)/assets/SecVF.icns"
    task.arguments = ["-c", "icns", iconsetPath, "-o", icnsPath]
    task.launch()
    task.waitUntilExit()

    if task.terminationStatus == 0 {
        print("✓ SecVF.icns created successfully!")
        print("\nNow updating Xcode project to use the new icon...")
        print("You can manually copy SecVF.icns to SecVF/Assets.xcassets/AppIcon.appiconset/")
    } else {
        print("❌ Failed to create .icns file")
    }
}

saveIconSet()
