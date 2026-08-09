import Foundation
import AVFoundation
import Speech

/// What AIEngineController actually needs from a transcript source - lets tests inject a
/// no-op stub instead of the real SpeechRecognitionEngine, which calls
/// SFSpeechRecognizer.requestAuthorization (a privacy-gated API macOS hard-crashes any
/// process for calling without an Info.plist usage-description key, e.g. a CLI test binary).
protocol TranscriptSource: AnyObject {
    var onTranscriptUpdate: ((String) -> Void)? { get set }
    func start()
    func stop()
}

// MARK: - Speech Recognition Engine
/// Provides real-time speech-to-text transcription
/// Uses Apple's Speech Recognition framework
/// https://developer.apple.com/documentation/speech
final class SpeechRecognitionEngine: NSObject, SFSpeechRecognizerDelegate, TranscriptSource {
    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Set right before audioEngine.start() - lets the first-partial-result log below
    /// report a hard mic-to-transcript latency number instead of a guess.
    private var recognitionStartedAt: Date?

    var onTranscriptUpdate: ((String) -> Void)?

    /// Starts on-device speech recognition (mic tap + AVAudioEngine). Deliberately NOT
    /// done in init(): constructing this class should never touch real audio hardware -
    /// among other things, that makes it safe to construct in headless/CLI contexts (e.g.
    /// unit tests), and it ties mic usage to the same explicit Start/Stop lifecycle as the
    /// rest of the app instead of running from the moment the app launches. Safe to call
    /// more than once - a second call while already running is a no-op.
    func start() {
        guard recognitionTask == nil else { return }
        requestSpeechAuthorization()
        setupSpeechRecognizer()
    }

    /// Requests user permission for speech recognition
    private func requestSpeechAuthorization() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            switch authStatus {
            case .authorized:
                print("Speech recognition authorized")
            case .denied, .notDetermined, .restricted:
                print("Speech recognition not authorized")
            @unknown default:
                break
            }
        }
    }

    /// Sets up the speech recognizer with audio engine
    private func setupSpeechRecognizer() {
        // Built fresh from the current Settings locale each start() - not a stored
        // property fixed at init time - so a language change in Settings takes effect on
        // the next "Start listening" without needing to relaunch the app. SFSpeechRecognizer
        // is locked to whatever single locale it's constructed with for its whole lifetime;
        // it cannot auto-detect or switch languages mid-session the way Gemini's own
        // transcription does, so this must match what the user actually speaks.
        let localeID = SettingsStore.shared.transcriptionLocale
        let recognizerInstance = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        speechRecognizer = recognizerInstance

        guard let recognizer = recognizerInstance, recognizer.isAvailable else {
            print("Speech recognizer not available for locale \(localeID)")
            return
        }

        recognizer.delegate = self

        // Pin to the built-in mic - see PreferredAudioInputDevice for why (keeps a connected
        // AirPods/Bluetooth output device in high-quality A2DP mode instead of getting
        // dragged into low-quality bidirectional SCO by our own tap)
        PreferredAudioInputDevice.pinToBuiltInMicrophone(audioEngine)

        let inputNode = audioEngine.inputNode

        // NOTE: deliberately NOT using AVAudioInputNode.setVoiceProcessingEnabled(true)
        // here - see the matching note in AudioCaptureManager.swift. On macOS it engages
        // full-duplex Voice-Processing I/O, which ducks system output volume and lowers
        // mic gain as a side effect (confirmed Apple Developer Forums issue:
        // https://developer.apple.com/forums/thread/721535) - it broke the ability to
        // hear/be heard as soon as Start listening was clicked, worse than the echo
        // bleed it was meant to fix.

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let recognitionRequest = recognitionRequest else {
            print("Unable to create recognition request")
            return
        }

        // Configure for continuous recognition
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation

        // Without this, SFSpeechRecognizer is free to silently use server-based
        // recognition (a network round trip per partial result) even when a fast
        // on-device model is available - which is invisible until you switch to a
        // locale where the OS makes that call differently and everything gets
        // noticeably slower. Force on-device whenever the locale supports it so
        // transcription latency is consistent and never depends on network conditions.
        if recognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
            print("[Speech] On-device recognition available for \(localeID) - forcing it on to avoid network latency")
        } else {
            print("[Speech] On-device recognition NOT available for \(localeID) - transcription will use the network and may be noticeably slower")
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        // installTap throws an uncatchable Objective-C exception (not a Swift Error, so
        // do/catch can't guard it) if the format is invalid - which happens whenever there's
        // no usable audio input (mic permission denied, no input hardware, or a headless
        // process with no audio session at all). Check first instead of crashing the app.
        guard recordingFormat.channelCount > 0, recordingFormat.sampleRate > 0 else {
            print("Speech recognizer: no usable audio input (channelCount=\(recordingFormat.channelCount)) - skipping")
            return
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        audioEngine.prepare()

        do {
            recognitionStartedAt = Date()
            try audioEngine.start()
            startRecognition()
        } catch {
            print("Audio engine error: \(error)")
        }
    }

    /// Starts the recognition task
    private func startRecognition() {
        var hasLoggedFirstResultLatency = false
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest!) { result, error in
            if let result = result {
                let transcript = result.bestTranscription.formattedString
                if !hasLoggedFirstResultLatency, !transcript.isEmpty {
                    hasLoggedFirstResultLatency = true
                    if let startedAt = self.recognitionStartedAt {
                        let elapsed = Date().timeIntervalSince(startedAt)
                        print(String(format: "[Speech] First partial transcript after %.2fs", elapsed))
                    }
                }
                DispatchQueue.main.async {
                    self.onTranscriptUpdate?(transcript)
                }
            }

            if error != nil || (result?.isFinal ?? false) {
                self.audioEngine.stop()
                self.recognitionRequest?.endAudio()
                self.recognitionTask?.cancel()
                self.recognitionTask = nil
            }
        }
    }

    /// Stops the speech recognition
    func stop() {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
    }
}
