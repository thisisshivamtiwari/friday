import Foundation
import CoreGraphics
import CoreImage
import ScreenCaptureKit

// MARK: - Screen Frame Provider
/// The seam `AIEngineController` depends on, never the concrete ScreenCaptureKit
/// implementation - the same pattern as `ExtractionLLMClientProtocol`/`RetrievalProvider`, and
/// for the same reason: real capture needs TCC permission and a physical display, so tests
/// inject a stub instead of ever touching ScreenCaptureKit.
protocol ScreenFrameProviding {
    /// One downscaled JPEG frame of the current screen, or nil when unavailable for ANY reason
    /// (permission denied, no display, capture error). Never throws: a missing frame is a normal
    /// outcome that must degrade to the existing text-only response, not an error path.
    func captureCurrentFrameJPEG() async -> Data?
}

// MARK: - Screen Capture Manager
/// Phase 3 (Option B): captures a SINGLE frame on demand, at the moment a response is
/// requested - deliberately NOT a persistent `SCStream` and NOT continuous streaming.
///
/// Why one-shot: the frame only has to answer "what's on screen right now" for one ⌘⇧R press.
/// A persistent stream would keep a second `SCStream` alive alongside
/// `SystemAudioCaptureManager`'s audio stream for the whole session, stream the user's entire
/// screen continuously to a third party, and cost an image's worth of tokens every second - all
/// to serve a question that is only ever asked at response time.
///
/// Nothing is ever written to disk: `SCScreenshotManager` hands back a `CGImage`, it is
/// downscaled and JPEG-encoded entirely in memory, and the returned `Data` is released by the
/// caller as soon as the request is built.
final class ScreenCaptureManager: ScreenFrameProviding {
    /// Longest edge of the encoded frame. A retina display is ~3456pt wide and would encode to
    /// multiple megabytes; 1280 keeps UI text legible to the model while keeping one frame in
    /// the low hundreds of KB.
    private let maximumPixelDimension: CGFloat
    /// 0.6 is the usual legibility/size trade-off point for screenshots of text.
    private let jpegQuality: CGFloat

    private let permissions: PermissionsManager
    private let context = CIContext(options: nil)

    init(maximumPixelDimension: CGFloat = 1280, jpegQuality: CGFloat = 0.6, permissions: PermissionsManager = .shared) {
        self.maximumPixelDimension = maximumPixelDimension
        self.jpegQuality = jpegQuality
        self.permissions = permissions
    }

    /// Checks permission WITHOUT prompting - `SystemAudioCaptureManager` already owns the one
    /// place that prompts (it needs the same TCC grant for system audio), so a response request
    /// never interrupts the user with a permission dialog mid-conversation.
    func captureCurrentFrameJPEG() async -> Data? {
        guard permissions.hasScreenCaptureAccess() else { return nil }
        guard let image = await captureDisplayImage() else { return nil }
        return Self.jpegData(from: image, maximumPixelDimension: maximumPixelDimension, quality: jpegQuality, context: context)
    }

    /// `SCScreenshotManager` is macOS 14+, while this app deploys to macOS 13. Rather than raise
    /// the deployment target for one feature, an older OS simply produces no frame - the exact
    /// same silent degradation as a denied permission, and one fewer capture path to maintain.
    private func captureDisplayImage() async -> CGImage? {
        guard #available(macOS 14.0, *) else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            // A single still frame - no stream is started, so there is no frame interval, no
            // output handler, and nothing to tear down.
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            // Denied, no display, or a capture failure - all degrade identically to "no frame".
            return nil
        }
    }

    /// Downscale-then-encode, entirely in memory. Static and dependency-injected so the encoding
    /// rules (bounded dimensions, JPEG output, aspect ratio preserved, no upscaling) are unit
    /// testable against a synthetic `CGImage` without any ScreenCaptureKit or TCC involvement.
    static func jpegData(from image: CGImage, maximumPixelDimension: CGFloat, quality: CGFloat, context: CIContext) -> Data? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }

        // Never upscale a small image - `min(1, ...)` keeps an already-small frame at 1:1.
        let scale = min(1, maximumPixelDimension / max(width, height))
        let ciImage = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        return context.jpegRepresentation(
            of: ciImage,
            colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }
}
