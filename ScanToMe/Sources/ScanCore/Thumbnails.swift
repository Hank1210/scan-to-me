import CoreGraphics
import Foundation
import ImageIO

/// Kleine Vorschaubilder, ohne das ganze 300-dpi-Bild zu dekodieren.
public enum Thumbnails {
    public static func make(url: URL, maxPixelSize: Int = 360) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
