import Foundation
import ScreenCaptureKit
import AVFoundation

/// Captures macOS system audio OUTPUT - what's actually playing through the speakers or a
/// connected Bluetooth device - rather than the microphone. In a real meeting, this is where
/// other participants' voices actually come from (Zoom/Teams/Meet render remote audio to the
/// system output), so this is the correct source to feed Gemini for "what did the meeting say"
/// suggestions. The user's own mic is handled entirely separately (see AudioCaptureManager /
/// SpeechRecognitionEngine) and is never sent here.
/// https://developer.apple.com/documentation/screencapturekit
final class SystemAudioCaptureManager: NSObject {
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let liveAPIFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var hasLoggedFirstChunk = false
    private var buffersReceived = 0
    private let sampleQueue = DispatchQueue(label: "com.founderoffice.copilot.systemaudio")

    /// Guards against firing multiple overlapping start attempts - and multiple stacked
    /// permission prompts - if "Start listening" gets clicked more than once (e.g. because
    /// nothing visibly happens while the first attempt is still in flight)
    private var isStarting = false
    /// Only actively PROMPT for Screen Recording once per app launch. If it's still denied
    /// after that, every subsequent start() just checks silently and logs - it does not
    /// keep re-triggering the system permission dialog on every click.
    private var hasPromptedForScreenCaptureThisLaunch = false

    /// Fires with 16-bit PCM, 16kHz, mono audio - other participants' voices only
    var onPCM16Chunk: ((Data) -> Void)?

    /// Starts capturing system audio output. Requires Screen Recording permission (the same
    /// permission ScreenCaptureKit always requires, even for audio-only capture).
    func start() {
        guard !isStarting, stream == nil else {
            print("[SystemAudio] start() called while already starting/running - ignoring")
            return
        }
        isStarting = true

        Task {
            defer { isStarting = false }

            if !PermissionsManager.shared.hasScreenCaptureAccess() {
                if !hasPromptedForScreenCaptureThisLaunch {
                    hasPromptedForScreenCaptureThisLaunch = true
                    print("[SystemAudio] Screen Recording permission not yet granted - requesting now (this will only prompt once per launch).")
                    await withCheckedContinuation { continuation in
                        PermissionsManager.shared.requestScreenCaptureAccess { _ in continuation.resume() }
                    }
                }
                // IMPORTANT macOS quirk: unlike microphone/speech, a freshly-granted Screen
                // Recording permission does NOT take effect for an already-running process.
                // If you just approved it, this run will keep failing regardless - quit and
                // relaunch the app instead of clicking Start listening again.
                if !PermissionsManager.shared.hasScreenCaptureAccess() {
                    print("[SystemAudio] Not authorized. If you just approved the Screen Recording prompt, fully QUIT and relaunch the app - clicking Start listening again in this run will not help, this permission doesn't apply to an already-running process.")
                    return
                }
            }

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    print("[SystemAudio] No display available to anchor the capture filter")
                    return
                }
                print("[SystemAudio] Using display \(display.displayID), \(display.width)x\(display.height)")

                // Scope capture to whatever meeting app(s) are actually running, so e.g. a
                // YouTube tab in an unrelated app isn't picked up as "the meeting". Falls
                // back to whole-display capture if no known meeting app is running (so ad
                // hoc testing without a real call still works).
                let meetingApps = content.applications.filter {
                    MeetingPlatformDetector.knownMeetingAppBundleIDs.contains($0.bundleIdentifier)
                }
                let filter: SCContentFilter
                if meetingApps.isEmpty {
                    print("[SystemAudio] No known meeting app running - capturing whole-system audio instead (fine for ad hoc testing, e.g. a YouTube tab)")
                    filter = SCContentFilter(display: display, excludingWindows: [])
                } else {
                    let names = meetingApps.map(\.bundleIdentifier).joined(separator: ", ")
                    print("[SystemAudio] Scoping capture to running meeting app(s): \(names)")
                    filter = SCContentFilter(display: display, including: meetingApps, exceptingWindows: [])
                }

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                // We only care about audio, but keep real display dimensions - degenerate
                // sizes (e.g. 2x2) have been observed to make startCapture() throw on some
                // macOS versions even though only the .audio stream output is registered
                config.width = display.width
                config.height = display.height
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
                try await stream.startCapture()
                self.stream = stream
                print("[SystemAudio] Capture started - play some audio and watch for '[SystemAudio] First PCM16 chunk' below")
            } catch {
                print("[SystemAudio] Failed to start capture: \(error)")
            }
        }
    }

    func stop() {
        let streamToStop = stream
        stream = nil
        Task {
            try? await streamToStop?.stopCapture()
        }
    }

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

        if let conversionError {
            print("[SystemAudio] Conversion error: \(conversionError)")
            return
        }
        guard let channelData = outputBuffer.int16ChannelData else { return }
        let frameLength = Int(outputBuffer.frameLength)
        guard frameLength > 0 else { return }
        let data = Data(bytes: channelData[0], count: frameLength * MemoryLayout<Int16>.size)

        if !hasLoggedFirstChunk {
            hasLoggedFirstChunk = true
            print("[SystemAudio] First PCM16 chunk forwarded: \(data.count) bytes")
        }
        onPCM16Chunk(data)
    }
}

extension SystemAudioCaptureManager: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        buffersReceived += 1
        if buffersReceived == 1 {
            print("[SystemAudio] First raw audio sample buffer received from the stream")
        } else if buffersReceived % 200 == 0 {
            print("[SystemAudio] Heartbeat: \(buffersReceived) raw audio buffers received so far")
        }

        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }
        guard let sourceAVFormat = AVAudioFormat(streamDescription: asbd) else { return }

        // A bare MemoryLayout<AudioBufferList>.size only fits ONE AudioBuffer (mono or
        // interleaved audio) - Teams' system audio is multi-channel, so that fixed size
        // was too small on every single call, failing with -12737
        // (kCMSampleBufferError_ArrayTooSmall) and silently dropping every buffer before
        // any audio ever reached Gemini. Ask for the real required size first, then
        // allocate exactly that much - the standard, format-agnostic pattern for this API.
        var neededSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, neededSize > 0 else { return }

        let rawBufferList = UnsafeMutableRawPointer.allocate(byteCount: neededSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawBufferList.deallocate() }
        let audioBufferListPointer = rawBufferList.assumingMemoryBound(to: AudioBufferList.self)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPointer,
            bufferListSize: neededSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: sourceAVFormat, bufferListNoCopy: audioBufferListPointer) else { return }

        if converter == nil || sourceFormat != sourceAVFormat {
            sourceFormat = sourceAVFormat
            converter = AVAudioConverter(from: sourceAVFormat, to: liveAPIFormat)
            print("[SystemAudio] Source format: \(sourceAVFormat), converter created: \(converter != nil)")
        }

        emitPCM16Chunk(from: pcmBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[SystemAudio] Stream stopped with error: \(error)")
    }
}
