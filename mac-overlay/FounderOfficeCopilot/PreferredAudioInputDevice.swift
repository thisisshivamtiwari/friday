import AVFoundation
import CoreAudio

/// Forces an AVAudioEngine's input node onto the Mac's built-in microphone, never a
/// Bluetooth device - specifically to fix AirPods system-audio capture.
///
/// The mechanism (confirmed against known macOS/ScreenCaptureKit reports, not guessed):
/// when ANY app captures microphone input while a Bluetooth headset (e.g. AirPods) is the
/// active output device, macOS downgrades that Bluetooth link from high-quality A2DP
/// (output-only) to low-quality bidirectional HFP/SCO (~8kHz mono) - the same profile
/// phone calls use, because the OS now needs a two-way channel. This both degrades AirPods
/// audio system-wide and is a documented source of ScreenCaptureKit system-audio capture
/// silently producing zero callbacks. This app runs two microphone taps continuously
/// (AudioCaptureManager, SpeechRecognitionEngine) - if either grabs AirPods as the input
/// device (which happens automatically once they're connected, since they become the
/// system default input), it drags AirPods into SCO mode and breaks
/// SystemAudioCaptureManager's ability to read AirPods' own output cleanly. Pinning our
/// mic taps to the built-in mic keeps a connected Bluetooth output device in clean A2DP.
enum PreferredAudioInputDevice {
    static func pinToBuiltInMicrophone(_ engine: AVAudioEngine) {
        guard let builtInDeviceID = builtInMicrophoneDeviceID() else {
            print("[AudioInput] No built-in microphone found - using system default input (may be Bluetooth)")
            return
        }
        do {
            try engine.inputNode.auAudioUnit.setDeviceID(builtInDeviceID)
            print("[AudioInput] Pinned mic input to built-in microphone (deviceID=\(builtInDeviceID)) - keeps Bluetooth output devices in high-quality mode")
        } catch {
            print("[AudioInput] Failed to pin input to built-in microphone: \(error)")
        }
    }

    private static func builtInMicrophoneDeviceID() -> AudioDeviceID? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone],
            mediaType: .audio,
            position: .unspecified
        )
        guard let builtInDevice = discovery.devices.first else { return nil }
        return audioObjectID(forUniqueID: builtInDevice.uniqueID)
    }

    /// AVCaptureDevice only exposes a String uniqueID; Core Audio (which AVAudioEngine's
    /// AUAudioUnit.setDeviceID actually needs) identifies devices by AudioDeviceID, so this
    /// bridges the two via the standard UID->device translation call.
    private static func audioObjectID(forUniqueID uid: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                UInt32(MemoryLayout<CFString?>.size),
                uidPtr,
                &dataSize,
                &deviceID
            )
        }
        return status == noErr ? deviceID : nil
    }
}
