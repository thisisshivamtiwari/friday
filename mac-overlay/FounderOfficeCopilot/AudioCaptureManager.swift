import Foundation
import AVFoundation

// MARK: - Audio Capture Manager
/// Captures the user's own microphone. This is deliberately NOT sent to Gemini in
/// Meeting mode: the mic is the user's own voice, which is transcribed locally (see
/// SpeechRecognitionEngine) and shown as "You" in the chat feed. What Gemini listens to
/// in Meeting mode is system audio output instead (see SystemAudioCaptureManager) - i.e.
/// other meeting participants, not the user. In Personal Assistant mode, `onPCM16Chunk`
/// IS wired up (by AppDelegate) since the user is deliberately talking to the assistant
/// there.
/// https://developer.apple.com/documentation/avfoundation/avaudioengine
final class AudioCaptureManager: NSObject {
    private var audioEngine: AVAudioEngine?
    private let audioInputBus = 0

    /// Fires with 16-bit PCM, 16kHz, mono audio - only actually consumed in Personal
    /// Assistant mode. In Meeting mode this is left unwired; the mic still only drives
    /// the local on-device transcript ("You" bubbles), never Gemini.
    var onPCM16Chunk: ((Data) -> Void)?

    private var converter: AVAudioConverter?
    private let liveAPIFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    override init() {
        super.init()
        setupAudioEngine()
    }

    /// Initializes the audio engine and tap
    private func setupAudioEngine() {
        print("[Audio] Microphone permission: \(PermissionsManager.shared.hasMicrophoneAccess() ? "granted" : "NOT granted - check System Settings > Privacy & Security > Microphone")")

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        // Pin to the built-in mic BEFORE reading the format - see PreferredAudioInputDevice
        // for why (keeps a connected AirPods/Bluetooth output device in high-quality A2DP
        // mode instead of getting dragged into low-quality bidirectional SCO by our own tap)
        PreferredAudioInputDevice.pinToBuiltInMicrophone(audioEngine)

        let inputNode = audioEngine.inputNode

        // NOTE: deliberately NOT using AVAudioInputNode.setVoiceProcessingEnabled(true)
        // here. It looks like the right fix for mic-picks-up-speaker-bleed, but on macOS
        // it engages the full-duplex Voice-Processing I/O unit, which assumes it owns the
        // whole audio session the way a VoIP app would - it triggers system-wide output
        // ducking and mic gain changes as a side effect, confirmed as a known Apple
        // Developer Forums issue (https://developer.apple.com/forums/thread/721535). In
        // practice this made speaker volume and mic level drop as soon as Start listening
        // was clicked - a worse regression than the echo bleed it was meant to fix. If
        // acoustic echo suppression is revisited, it needs a narrower approach than this.

        // Get output format from input node - read AFTER pinning the device above, since
        // this property does not auto-refresh when the device changes underneath it
        // https://developer.apple.com/documentation/avfoundation/avaudionode/outputformat(forbus:)
        let format = inputNode.outputFormat(forBus: audioInputBus)
        print("[Audio] Input node format (post device-pin): \(format)")

        // installTap throws an uncatchable Objective-C exception (not a Swift Error, so
        // do/catch can't guard it) if the format is invalid - which happens whenever
        // there's no usable audio input (mic permission denied or no input hardware).
        // Check first instead of crashing the app.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            print("[Audio] No usable audio input (channelCount=\(format.channelCount)) - skipping mic tap setup")
            return
        }

        converter = AVAudioConverter(from: format, to: liveAPIFormat)

        // Install a tap to process incoming audio
        // https://developer.apple.com/documentation/avfoundation/avaudionode/installtap(onbus:buffersize:format:block:)
        inputNode.installTap(onBus: audioInputBus, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.emitPCM16Chunk(from: buffer)
        }
    }

    /// Starts the audio engine
    /// https://developer.apple.com/documentation/avfoundation/avaudioengine/start()
    func startListening() {
        guard let audioEngine = audioEngine else { return }
        do {
            try audioEngine.start()
            print("[Audio] Engine started, isRunning=\(audioEngine.isRunning)")
        } catch {
            print("[Audio] Error starting audio engine: \(error)")
        }
    }

    /// Stops the audio engine
    /// https://developer.apple.com/documentation/avfoundation/avaudioengine/stop()
    func stopListening() {
        audioEngine?.stop()
    }

    /// Converts the tap's native-format buffer to 16-bit PCM/16kHz/mono and forwards it.
    /// Cheap no-op when `onPCM16Chunk` isn't wired up (Meeting mode).
    private func emitPCM16Chunk(from buffer: AVAudioPCMBuffer) {
        guard let converter, let onPCM16Chunk else { return }

        let ratio = liveAPIFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: liveAPIFormat, frameCapacity: outputFrameCapacity) else { return }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard conversionError == nil, let channelData = outputBuffer.int16ChannelData else { return }
        let frameLength = Int(outputBuffer.frameLength)
        guard frameLength > 0 else { return }
        let data = Data(bytes: channelData[0], count: frameLength * MemoryLayout<Int16>.size)
        onPCM16Chunk(data)
    }
}
