import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SafariBrowser

/// #29: unit tests for the pure image-cropping helpers.
/// The split between `scale`, `pixelRect`, and `cropPNG` exists so the
/// HiDPI math can be tested without touching the filesystem; only the
/// roundtrip test in this file writes/reads a real PNG.
final class ImageCroppingTests: XCTestCase {

    // MARK: - scale(imagePixelWidth:windowPointWidth:)

    func testScale1x() {
        // Non-retina: captured image width equals window point width.
        XCTAssertEqual(
            ImageCropping.scale(imagePixelWidth: 1200, windowPointWidth: 1200),
            1.0,
            accuracy: 1e-9
        )
    }

    func testScale2x() {
        // Retina: 2x backingScaleFactor means captured pixels are 2x point width.
        XCTAssertEqual(
            ImageCropping.scale(imagePixelWidth: 2400, windowPointWidth: 1200),
            2.0,
            accuracy: 1e-9
        )
    }

    func testScale1_5x() {
        // macOS Display Scaling 1.5x — scale is non-integer.
        XCTAssertEqual(
            ImageCropping.scale(imagePixelWidth: 2400, windowPointWidth: 1600),
            1.5,
            accuracy: 1e-9
        )
    }

    // Defensive: division-by-zero must not trap. Return 1.0 so the
    // downstream pixelRect call produces sensible output (identity-ish)
    // and ScreenshotCommand's upstream validation — which already rejects
    // zero-size windows — catches the real bug. We don't want
    // `cropPNG` crashing before the better error can surface.
    func testScaleNonPositiveWindow() {
        XCTAssertEqual(
            ImageCropping.scale(imagePixelWidth: 2400, windowPointWidth: 0),
            1.0,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            ImageCropping.scale(imagePixelWidth: 2400, windowPointWidth: -1),
            1.0,
            accuracy: 1e-9
        )
    }

    // MARK: - pixelRect(from:scale:)

    func testPixelRectAt1x() {
        let r = ImageCropping.pixelRect(
            from: CGRect(x: 0, y: 100, width: 1200, height: 800),
            scale: 1.0
        )
        XCTAssertEqual(r, CGRect(x: 0, y: 100, width: 1200, height: 800))
    }

    func testPixelRectAt2x() {
        // Design example: retina crop multiplies all four components by 2.
        let r = ImageCropping.pixelRect(
            from: CGRect(x: 0, y: 100, width: 1200, height: 800),
            scale: 2.0
        )
        XCTAssertEqual(r, CGRect(x: 0, y: 200, width: 2400, height: 1600))
    }

    func testPixelRectAt1_5xRoundsToIntegral() {
        // At 1.5x, a point rect of {0, 130, 1600, 870} → raw pixel rect
        // {0, 195, 2400, 1305}. All four values happen to be integral
        // here, so .integral is a no-op — assertion confirms we don't
        // accidentally shrink the rect.
        let r = ImageCropping.pixelRect(
            from: CGRect(x: 0, y: 130, width: 1600, height: 870),
            scale: 1.5
        )
        XCTAssertEqual(r, CGRect(x: 0, y: 195, width: 2400, height: 1305))
    }

    func testPixelRectFractionalRoundsUp() {
        // Sub-pixel origin/size at 1.25x scale must round outward so
        // `CGImage.cropping(to:)` doesn't lose a sliver of content.
        // Raw: {0.625, 100.625, 1250.625, 800.625}
        // .integral: {0, 100, 1251, 801}
        let r = ImageCropping.pixelRect(
            from: CGRect(x: 0.5, y: 80.5, width: 1000.5, height: 640.5),
            scale: 1.25
        )
        XCTAssertEqual(r.origin.x, 0)
        XCTAssertEqual(r.origin.y, 100)
        XCTAssertTrue(r.width >= 1251, "width \(r.width) should have rounded outward from 1250.625")
        XCTAssertTrue(r.height >= 801, "height \(r.height) should have rounded outward from 800.625")
    }

    // MARK: - isNoOpCrop

    func testNoOpExactFullscreenMatch() {
        // Fullscreen: AXWebArea bounds identical to window bounds.
        let window = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let webArea = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(ImageCropping.isNoOpCrop(windowBounds: window, webAreaBounds: webArea))
    }

    func testNoOpReaderModeSmallHeightDrift() {
        // Reader Mode: chrome collapsed. Height drift < 4 pts (AX/AS
        // rounding). Width still matches exactly.
        let window = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let webArea = CGRect(x: 0, y: 3, width: 1400, height: 897)
        XCTAssertTrue(ImageCropping.isNoOpCrop(windowBounds: window, webAreaBounds: webArea))
    }

    func testNotNoOpNormalSafariLayout() {
        // Normal Safari: ~130pt chrome at top. Height diff well over 4.
        let window = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let webArea = CGRect(x: 0, y: 130, width: 1400, height: 770)
        XCTAssertFalse(ImageCropping.isNoOpCrop(windowBounds: window, webAreaBounds: webArea))
    }

    // Boundary: exactly 4 pt height diff should NOT be no-op — the
    // threshold is strictly less than 4 so 4pt chrome counts as real.
    // This protects against the "5pt toolbar rounds to 4 and disappears"
    // failure mode the design guards against.
    func testNoOpBoundaryHeightDiff4IsCrop() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let webArea = CGRect(x: 0, y: 4, width: 1000, height: 796)
        XCTAssertFalse(
            ImageCropping.isNoOpCrop(windowBounds: window, webAreaBounds: webArea),
            "Height diff exactly 4 should not be no-op (strict <4 boundary)"
        )
    }

    func testNoOpBoundaryHeightDiff3IsNoOp() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let webArea = CGRect(x: 0, y: 3, width: 1000, height: 797)
        XCTAssertTrue(ImageCropping.isNoOpCrop(windowBounds: window, webAreaBounds: webArea))
    }

    // Width drift fails no-op even with matching height — a >0.5pt
    // width difference implies AX gave us mismatched elements and we
    // shouldn't trust the read.
    func testNotNoOpWidthDrift() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let webArea = CGRect(x: 0, y: 0, width: 999, height: 800)  // 1pt narrower
        XCTAssertFalse(ImageCropping.isNoOpCrop(windowBounds: window, webAreaBounds: webArea))
    }

    // MARK: - cropPNG roundtrip

    /// Write a solid-color PNG to a temp file, crop it, assert the
    /// result has the expected dimensions and is readable. Uses 2x
    /// scale to exercise the retina path end-to-end.
    func testCropPNGRoundtrip() throws {
        // Build a 400x300 pixel PNG representing a 200x150 point window
        // (2x scale). Cropping to {0, 30, 200, 120} points should yield
        // a 400x240 pixel output.
        let tempURL = try makeTempPNG(pixelWidth: 400, pixelHeight: 300)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try ImageCropping.cropPNG(
            at: tempURL.path,
            rectPoints: CGRect(x: 0, y: 30, width: 200, height: 120),
            windowWidthPoints: 200
        )

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(tempURL as CFURL, nil))
        let cropped = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(cropped.width, 400, "Width should match rect.width (200pt) × scale (2.0)")
        XCTAssertEqual(cropped.height, 240, "Height should match rect.height (120pt) × scale (2.0)")
    }

    /// A crop rectangle that extends beyond the captured image must
    /// throw `imageCroppingFailed` — silently clipping would produce
    /// a narrower image than the user requested, which is exactly the
    /// silent-wrong-output failure mode the design rejects.
    func testCropPNGOutOfBoundsThrows() throws {
        let tempURL = try makeTempPNG(pixelWidth: 100, pixelHeight: 100)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        XCTAssertThrowsError(
            try ImageCropping.cropPNG(
                at: tempURL.path,
                rectPoints: CGRect(x: 0, y: 0, width: 200, height: 200),  // 2x larger than image
                windowWidthPoints: 100
            )
        ) { error in
            guard case SafariBrowserError.imageCroppingFailed = error else {
                XCTFail("Expected imageCroppingFailed, got \(error)")
                return
            }
        }
    }

    func testCropPNGNonexistentPathThrows() {
        XCTAssertThrowsError(
            try ImageCropping.cropPNG(
                at: "/tmp/definitely-does-not-exist-\(UUID().uuidString).png",
                rectPoints: CGRect(x: 0, y: 0, width: 100, height: 100),
                windowWidthPoints: 100
            )
        ) { error in
            guard case SafariBrowserError.imageCroppingFailed = error else {
                XCTFail("Expected imageCroppingFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Helpers

    /// Create a temporary solid-grey PNG with the given pixel dimensions
    /// and return its URL.
    private func makeTempPNG(pixelWidth: Int, pixelHeight: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "image-cropping-test-\(UUID().uuidString).png"
        )
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(gray: 0.5, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        let image = try XCTUnwrap(context.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "ImageCroppingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not write temp PNG"])
        }
        return url
    }
}
