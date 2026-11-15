import AppKit
@main struct WaterSurfaceTests {
    static func main() {
        _ = NSApplication.shared
        for compact in [false, true] {
            let size = compact ? NSSize(width: 366, height: 116) : NSSize(width: 340, height: 226)
            let surface = WaterReminderSurface(size: size, compact: compact, theme: ["blur": true, "background": NSColor.clear])
            guard let mask = surface.effect.maskImage, let tiff = mask.tiffRepresentation, let pixels = NSBitmapImageRep(data: tiff) else { preconditionFailure("Missing effect mask") }
            for point in [(0, 0), (pixels.pixelsWide - 1, 0), (0, pixels.pixelsHigh - 1), (pixels.pixelsWide - 1, pixels.pixelsHigh - 1)] {
                precondition(pixels.colorAt(x: point.0, y: point.1)!.alphaComponent == 0, "Backdrop corner must be transparent")
            }
            precondition(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)!.alphaComponent == 1)
            let clear = WaterReminderSurface(size: size, compact: compact, theme: ["blur": false, "background": NSColor.clear])
            precondition(clear.effect.isHidden && !clear.isOpaque && clear.layer?.backgroundColor?.alpha == 0)
            precondition(clear.subviews.last?.layer?.backgroundColor?.alpha == 0, "Clear theme must not acquire an opaque tint")
        }
        print("PASS: both reminder styles have transparent backdrop corners; blur-off clear themes have no fallback background")
    }
}
