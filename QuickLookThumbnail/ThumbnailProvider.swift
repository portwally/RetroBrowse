//
//  ThumbnailProvider.swift
//  QuickLookThumbnail
//
//  Finder icons for Apple II disk images and archives: a 5.25" or 3.5" floppy, a hard disk
//  or a box of files, labelled with the volume name.
//

import AppKit
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let filename = url.lastPathComponent
        let disk: LoadedDisk
        do {
            disk = try DiskImageLoader.load(try Data(contentsOf: url, options: .mappedIfSafe), filename: filename)
        } catch {
            // Not an Apple II disk: the Finder keeps its usual icon
            handler(nil, error)
            return
        }

        let side = min(request.maximumSize.width, request.maximumSize.height)
        let artwork = DiskArtwork(medium: disk.medium,
                                  // The box already says archive; the extension would only crowd the label
                                  name: disk.catalog.isFileArchive ? (filename as NSString).deletingPathExtension
                                                                   : disk.displayName(filename: filename),
                                  detail: DiskArtwork.detail(for: disk))
        handler(QLThumbnailReply(contextSize: CGSize(width: side, height: side)) { context in
            artwork.draw(in: context, side: side)
            return true
        }, nil)
    }
}

struct DiskArtwork {
    let medium: LoadedDisk.Medium
    let name: String
    let detail: String

    /// The second label line: the file system, or how many files an archive holds
    static func detail(for disk: LoadedDisk) -> String {
        let catalog = disk.catalog
        if catalog.isFileArchive {
            return catalog.totalFiles == 1 ? "1 file" : "\(catalog.totalFiles) files"
        }
        let format = catalog.diskFormat
        if format.hasPrefix("ProDOS") { return "ProDOS" }
        if format.contains("Pascal") { return "Pascal" }
        return format
    }

    func draw(in context: CGContext, side: CGFloat) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }

        let s = side
        // Text is unreadable on tiny icons; leave it off
        let showText = s >= 48
        switch medium {
        case .floppy525: drawFloppy525(s, showText: showText)
        case .floppy35: drawFloppy35(s, showText: showText)
        case .hardDisk: drawHardDisk(s, showText: showText)
        case .archive: drawArchive(s, showText: showText)
        }
    }

    // MARK: - Media

    private func drawFloppy525(_ s: CGFloat, showText: Bool) {
        let jacket = NSRect(x: s * 0.04, y: s * 0.04, width: s * 0.92, height: s * 0.92)
        let media = NSColor(calibratedRed: 0.29, green: 0.23, blue: 0.20, alpha: 1)

        // Jacket with the write-protect notch cut into the right edge
        let shape = NSBezierPath(roundedRect: jacket, xRadius: s * 0.025, yRadius: s * 0.025)
        let notch = NSBezierPath(rect: NSRect(x: jacket.maxX - s * 0.035, y: s * 0.70, width: s * 0.035, height: s * 0.07))
        shape.append(notch.reversed)
        shadow(s) { NSColor(calibratedWhite: 0.10, alpha: 1).setFill(); shape.fill() }

        // Hub: the disk shows through, with its reinforcement ring and centre hole
        let c = NSPoint(x: s * 0.5, y: s * 0.46)
        circle(c, s * 0.15).fill(media)
        circle(c, s * 0.115).fill(NSColor(calibratedRed: 0.42, green: 0.35, blue: 0.30, alpha: 1))
        circle(c, s * 0.085).fill(NSColor(calibratedWhite: 0.10, alpha: 1))

        // Index hole and head slot
        circle(NSPoint(x: s * 0.70, y: s * 0.46), s * 0.022).fill(media)
        NSBezierPath(roundedRect: NSRect(x: s * 0.455, y: s * 0.07, width: s * 0.09, height: s * 0.20),
                     xRadius: s * 0.045, yRadius: s * 0.045).fill(media)

        let label = NSRect(x: s * 0.09, y: s * 0.68, width: s * 0.74, height: s * 0.24)
        drawLabel(label, s, showText: showText)
    }

    private func drawFloppy35(_ s: CGFloat, showText: Bool) {
        let body = NSRect(x: s * 0.06, y: s * 0.04, width: s * 0.88, height: s * 0.92)
        let shape = NSBezierPath(roundedRect: body, xRadius: s * 0.03, yRadius: s * 0.03)
        shadow(s) {
            NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.40, blue: 0.47, alpha: 1),
                       ending: NSColor(calibratedRed: 0.24, green: 0.27, blue: 0.32, alpha: 1))?.draw(in: shape, angle: -90)
        }

        // Metal shutter with its window
        let shutter = NSRect(x: s * 0.27, y: s * 0.60, width: s * 0.46, height: s * 0.36)
        NSGradient(starting: NSColor(calibratedWhite: 0.86, alpha: 1),
                   ending: NSColor(calibratedWhite: 0.62, alpha: 1))?.draw(in: NSBezierPath(rect: shutter), angle: -90)
        NSColor(calibratedWhite: 0.38, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: s * 0.50, y: s * 0.66, width: s * 0.11, height: s * 0.25)).fill()

        // Write-protect hole
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: s * 0.11, y: s * 0.08, width: s * 0.06, height: s * 0.06)).fill()

        let label = NSRect(x: s * 0.14, y: s * 0.17, width: s * 0.72, height: s * 0.36)
        drawLabel(label, s, showText: showText)
    }

    private func drawHardDisk(_ s: CGFloat, showText: Bool) {
        let body = NSRect(x: s * 0.06, y: s * 0.20, width: s * 0.88, height: s * 0.60)
        let shape = NSBezierPath(roundedRect: body, xRadius: s * 0.06, yRadius: s * 0.06)
        shadow(s) {
            NSGradient(starting: NSColor(calibratedWhite: 0.93, alpha: 1),
                       ending: NSColor(calibratedWhite: 0.70, alpha: 1))?.draw(in: shape, angle: -90)
        }
        NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
        shape.lineWidth = max(1, s * 0.008)
        shape.stroke()

        // Front strip with the activity light
        let strip = NSRect(x: body.minX + s * 0.05, y: body.minY + s * 0.06, width: body.width - s * 0.10, height: s * 0.10)
        NSColor(calibratedWhite: 0.30, alpha: 1).setFill()
        NSBezierPath(roundedRect: strip, xRadius: s * 0.02, yRadius: s * 0.02).fill()
        circle(NSPoint(x: strip.maxX - s * 0.06, y: strip.midY), s * 0.022)
            .fill(NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.40, alpha: 1))

        let label = NSRect(x: body.minX + s * 0.05, y: strip.maxY + s * 0.05, width: body.width - s * 0.10, height: s * 0.28)
        drawLabel(label, s, showText: showText)
    }

    private func drawArchive(_ s: CGFloat, showText: Bool) {
        let box = NSRect(x: s * 0.10, y: s * 0.06, width: s * 0.80, height: s * 0.64)
        let lid = NSRect(x: s * 0.06, y: s * 0.66, width: s * 0.88, height: s * 0.16)
        shadow(s) {
            NSColor(calibratedRed: 0.78, green: 0.62, blue: 0.40, alpha: 1).setFill()
            NSBezierPath(roundedRect: box, xRadius: s * 0.02, yRadius: s * 0.02).fill()
        }
        NSColor(calibratedRed: 0.70, green: 0.54, blue: 0.33, alpha: 1).setFill()
        NSBezierPath(roundedRect: lid, xRadius: s * 0.02, yRadius: s * 0.02).fill()
        // Tape over the lid
        NSColor(calibratedRed: 0.89, green: 0.81, blue: 0.64, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: s * 0.44, y: s * 0.56, width: s * 0.12, height: s * 0.26)).fill()

        let label = NSRect(x: s * 0.18, y: s * 0.14, width: s * 0.64, height: s * 0.32)
        drawLabel(label, s, showText: showText)
    }

    // MARK: - Helpers

    /// A paper label with the name in bold and the detail below it
    private func drawLabel(_ rect: NSRect, _ s: CGFloat, showText: Bool) {
        NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: s * 0.012, yRadius: s * 0.012).fill()
        guard showText else {
            // Pencil lines instead of text
            NSColor(calibratedRed: 0.55, green: 0.65, blue: 0.85, alpha: 1).setFill()
            for i in 1...2 {
                NSBezierPath(rect: NSRect(x: rect.minX + rect.width * 0.1, y: rect.minY + rect.height * CGFloat(i) / 3,
                                          width: rect.width * 0.8, height: max(1, s * 0.01))).fill()
            }
            return
        }
        let inset = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.10)
        let nameSize = fittedFontSize(name, maximum: rect.height * 0.36, width: inset.width)
        let nameFont = NSFont.monospacedSystemFont(ofSize: nameSize, weight: .bold)
        let detailFont = NSFont.systemFont(ofSize: max(6, rect.height * 0.22))
        let nameHeight = nameFont.ascender - nameFont.descender
        let detailHeight = detailFont.ascender - detailFont.descender
        let top = inset.midY + (nameHeight + detailHeight) / 2

        draw(name, font: nameFont, color: NSColor(calibratedWhite: 0.08, alpha: 1),
             in: NSRect(x: inset.minX, y: top - nameHeight, width: inset.width, height: nameHeight))
        draw(detail, font: detailFont, color: NSColor(calibratedWhite: 0.40, alpha: 1),
             in: NSRect(x: inset.minX, y: top - nameHeight - detailHeight, width: inset.width, height: detailHeight))
    }

    /// The largest size up to `maximum` at which the text fits, but not below 60% of it
    private func fittedFontSize(_ text: String, maximum: CGFloat, width: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: maximum, weight: .bold)
        let natural = (text as NSString).size(withAttributes: [.font: font]).width
        guard natural > width, natural > 0 else { return maximum }
        return max(maximum * 0.6, maximum * width / natural)
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    private func circle(_ center: NSPoint, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// Draws with a soft drop shadow, like the Finder's own icons
    private func shadow(_ s: CGFloat, _ drawing: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        shadow.shadowBlurRadius = s * 0.025
        shadow.set()
        drawing()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private extension NSBezierPath {
    func fill(_ color: NSColor) {
        color.setFill()
        fill()
    }
}
