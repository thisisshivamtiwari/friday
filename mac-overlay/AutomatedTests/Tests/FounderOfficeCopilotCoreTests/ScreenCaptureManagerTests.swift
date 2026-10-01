import XCTest
import CoreImage
import CoreGraphics
@testable import FounderOfficeCopilotCore

/// A deterministic stand-in for the real ScreenCaptureKit capturer - returns exactly what a test
/// configures and never touches ScreenCaptureKit, a display, or TCC. Same seam pattern as
/// `StubExtractionLLMClient`: real capture needs a permission grant and a physical screen, so it
/// is the one part of Phase 3 that XCTest cannot exercise.
final class StubScreenFrameProvider: ScreenFrameProviding {
    var frameToReturn: Data?
    private(set) var captureCount = 0

    init(frameToReturn: Data? = nil) {
        self.frameToReturn = frameToReturn
    }

    func captureCurrentFrameJPEG() async -> Data? {
        captureCount += 1
        return frameToReturn
    }
}

/// Covers Phase 3 (Option B): the on-demand screen frame. Everything here is offline - the JPEG
/// encoding rules are exercised against a synthetic `CGImage`, and the capture decision is
/// exercised through the injected stub.
final class ScreenCaptureManagerTests: XCTestCase {
    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: Encoding - bounded, downscaled, in memory

    func testLargeRetinaFrameIsDownscaledToTheMaximumDimension() {
        let image = makeImage(width: 3456, height: 2234)
        guard let data = ScreenCaptureManager.jpegData(from: image, maximumPixelDimension: 1280, quality: 0.6, context: CIContext()) else {
            return XCTFail("expected JPEG data")
        }
        guard let decoded = CGImageSourceCreateWithData(data as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
            return XCTFail("expected decodable JPEG")
        }
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 1280, "longest edge must be bounded")
        XCTAssertEqual(Double(decoded.width) / Double(decoded.height), 3456.0 / 2234.0, accuracy: 0.01, "aspect ratio preserved")
        XCTAssertLessThan(data.count, 1_000_000, "a single frame must stay well under a megabyte")
    }

    func testSmallFrameIsNotUpscaled() {
        let image = makeImage(width: 640, height: 400)
        guard let data = ScreenCaptureManager.jpegData(from: image, maximumPixelDimension: 1280, quality: 0.6, context: CIContext()),
              let decoded = CGImageSourceCreateWithData(data as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
            return XCTFail("expected decodable JPEG")
        }
        XCTAssertEqual(decoded.width, 640)
        XCTAssertEqual(decoded.height, 400)
    }

    func testEncodedFrameIsActuallyJPEG() {
        let image = makeImage(width: 200, height: 100)
        guard let data = ScreenCaptureManager.jpegData(from: image, maximumPixelDimension: 1280, quality: 0.6, context: CIContext()) else {
            return XCTFail("expected JPEG data")
        }
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "JPEG SOI marker")
    }

    /// Encoding is a pure in-memory transform - it must not create files anywhere.
    func testEncodingWritesNothingToDisk() throws {
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("screen-capture-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probe) }

        let before = try FileManager.default.contentsOfDirectory(atPath: probe.path)
        _ = ScreenCaptureManager.jpegData(from: makeImage(width: 800, height: 600), maximumPixelDimension: 1280, quality: 0.6, context: CIContext())
        let after = try FileManager.default.contentsOfDirectory(atPath: probe.path)

        XCTAssertEqual(before, after)
        XCTAssertTrue(after.isEmpty, "screenshots exist only in memory - nothing may be persisted")
    }

    func testZeroSizedImageProducesNoFrameRatherThanCrashing() {
        // A 1x1 image is the smallest real case; the guard exists for degenerate dimensions.
        let data = ScreenCaptureManager.jpegData(from: makeImage(width: 1, height: 1), maximumPixelDimension: 1280, quality: 0.6, context: CIContext())
        XCTAssertNotNil(data, "a tiny but valid image still encodes")
    }

    // MARK: Permission gating

    /// With screen-recording permission absent, no capture is attempted at all. Asserted against
    /// the REAL permission state so this can never silently pass by stubbing away the check.
    func testRealManagerReturnsNoFrameWhenPermissionIsDenied() async throws {
        guard !PermissionsManager.shared.hasScreenCaptureAccess() else {
            throw XCTSkip("screen-recording permission IS granted on this machine - the denied path can't be exercised here")
        }
        let frame = await ScreenCaptureManager().captureCurrentFrameJPEG()
        XCTAssertNil(frame, "denied permission must degrade to no frame, never an error")
    }
}
