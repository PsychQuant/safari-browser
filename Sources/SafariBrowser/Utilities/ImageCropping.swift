import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pure image-cropping helpers used by `screenshot --content-only` (#29).
///
/// The type intentionally has no Safari / AppKit / AX dependencies so
/// the HiDPI math and PNG I/O can be unit-tested without spinning up
/// Safari. `ScreenshotCommand` calls `cropPNG` after a capture step and
/// passes the window width in points; `cropPNG` derives the pixel scale
/// dynamically from the captured image (see design.md §"HiDPI scale").
enum ImageCropping {

    /// #29: decide whether a `--content-only` crop is a no-op because
    /// the web content area effectively fills the window (fullscreen,
    /// Reader Mode, Stage Manager with chrome auto-hidden). Caller
    /// skips the crop step when this returns true and writes the
    /// captured PNG unchanged.
    ///
    /// **Tolerance is absolute, not percentage** (design.md §"No-op
    /// threshold"):
    ///   - Width: < 0.5 points drift (effectively exact — Safari chrome
    ///     only lives on the y-axis; x-axis difference implies AX read
    ///     mismatched elements)
    ///   - Height: < 4 points drift (covers AX/AS rounding, retina
    ///     subpixel, window server integer truncation)
    ///
    /// A percentage threshold (e.g. 98%) would falsely match
    /// near-fullscreen windows with small 5–10pt toolbars, producing
    /// silently wrong output.
    static func isNoOpCrop(windowBounds: CGRect, webAreaBounds: CGRect) -> Bool {
        let widthDiff = abs(windowBounds.width - webAreaBounds.width)
        let heightDiff = abs(windowBounds.height - webAreaBounds.height)
        return widthDiff < 0.5 && heightDiff < 4
    }

    /// Derive the points-to-pixels scale factor from a captured image
    /// width and the window's point-space width. Assumes uniform scale
    /// in x/y — macOS's window server always produces uniform scale.
    ///
    /// Returns 1.0 if `windowPointWidth` is non-positive. This is a
    /// defensive fallback to avoid division-by-zero; real window widths
    /// should always be positive, and ScreenshotCommand's upstream AX
    /// bounds validation already rejects zero-size windows.
    static func scale(imagePixelWidth: Int, windowPointWidth: Double) -> Double {
        guard windowPointWidth > 0 else { return 1.0 }
        return Double(imagePixelWidth) / windowPointWidth
    }

    /// Convert a point-space rectangle to an integer-pixel rectangle
    /// using the given scale. The result is rounded via `CGRect.integral`
    /// so sub-pixel origins/sizes don't drift when `CGImage.cropping(to:)`
    /// snaps to integer pixels.
    static func pixelRect(from rectPoints: CGRect, scale: Double) -> CGRect {
        let scaled = CGRect(
            x: rectPoints.origin.x * scale,
            y: rectPoints.origin.y * scale,
            width: rectPoints.size.width * scale,
            height: rectPoints.size.height * scale
        )
        return scaled.integral
    }

    /// Crop a PNG in-place to the window-relative rectangle specified
    /// in points. Reads `path`, computes the pixel scale from the
    /// captured image width and `windowWidthPoints`, crops, and writes
    /// the cropped PNG back to `path`.
    ///
    /// - Parameters:
    ///   - path: PNG file path (both source and destination).
    ///   - rectPoints: rectangle to retain, in window-relative points.
    ///     Origin is top-left per AppKit image coordinates.
    ///   - windowWidthPoints: window width in points. Used only to
    ///     derive the scale factor — not the window height, because
    ///     uniform scale means x-axis width suffices.
    /// - Throws: `SafariBrowserError.imageCroppingFailed` with a
    ///   descriptive reason on any failure (read, out-of-bounds rect,
    ///   crop returning nil, or write).
    static func cropPNG(at path: String, rectPoints: CGRect, windowWidthPoints: Double) throws {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw SafariBrowserError.imageCroppingFailed(reason: "could not open PNG at \(path)")
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SafariBrowserError.imageCroppingFailed(reason: "could not decode PNG at \(path)")
        }

        let scale = Self.scale(imagePixelWidth: cgImage.width, windowPointWidth: windowWidthPoints)
        let pxRect = Self.pixelRect(from: rectPoints, scale: scale)

        // Guard against out-of-bounds crop — CGImage.cropping(to:) returns
        // nil on OOB, which is unusably opaque for diagnostics.
        let imageRect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        guard !pxRect.isEmpty, imageRect.contains(pxRect) else {
            throw SafariBrowserError.imageCroppingFailed(
                reason: "crop rect \(pxRect) outside captured image bounds \(imageRect)"
            )
        }

        guard let cropped = cgImage.cropping(to: pxRect) else {
            throw SafariBrowserError.imageCroppingFailed(reason: "CGImage.cropping returned nil for \(pxRect)")
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw SafariBrowserError.imageCroppingFailed(reason: "could not create PNG destination at \(path)")
        }
        CGImageDestinationAddImage(destination, cropped, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SafariBrowserError.imageCroppingFailed(reason: "could not finalize PNG write at \(path)")
        }
    }
}
