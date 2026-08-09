import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import AVFoundation

/// Checks and requests the permissions the app actually depends on: microphone
/// (for audio capture), Accessibility (for reading other apps' UI, e.g. Teams roster),
/// and Screen Recording (for the upcoming screen-understanding feature).
final class PermissionsManager {
    static let shared = PermissionsManager()

    /// Current microphone authorization status
    /// https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus-swift.property
    func hasMicrophoneAccess() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Requests microphone permission if not yet determined; reports current status otherwise
    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    /// Current Accessibility permission status, used for reading other apps' UI
    /// (e.g. the Teams participant roster). Does not prompt.
    /// https://developer.apple.com/documentation/applicationservices/1462075-axisprocesstrusted
    func hasAccessibilityAccess() -> Bool {
        AXIsProcessTrusted()
    }

    /// Current Screen Recording permission status, without prompting
    /// https://developer.apple.com/documentation/coregraphics/1595426-cgpreflightscreencaptureaccess
    func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompts for Screen Recording permission if not already granted
    /// https://developer.apple.com/documentation/coregraphics/1595674-cgrequestscreencaptureaccess
    func requestScreenCaptureAccess(completion: @escaping (Bool) -> Void) {
        if CGPreflightScreenCaptureAccess() {
            completion(true)
            return
        }
        let granted = CGRequestScreenCaptureAccess()
        DispatchQueue.main.async { completion(granted) }
    }
}

/// Bundle IDs of apps that are plausibly hosting a meeting right now - used by
/// SystemAudioCaptureManager to scope system-audio capture to just these apps instead of
/// the whole system, so e.g. a YouTube tab in an unrelated app doesn't count as "the
/// meeting". Includes com.microsoft.teams2 (current "Teams work or school" client)
/// alongside the classic com.microsoft.teams - the same fix already applied to
/// TeamsParticipantDetector.
enum MeetingPlatformDetector {
    static let knownMeetingAppBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.cisco.webex.app",
        "com.tinyspeck.slackmacgap",
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.edgemac"
    ]
}
