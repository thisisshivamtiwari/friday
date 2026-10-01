import Foundation

/// Combines the mic and system-audio PCM16 streams into one real waveform before either
/// reaches Gemini. AudioCaptureManager and SystemAudioCaptureManager each produce their own
/// independently-timed stream of chunks - their own hardware taps/capture buffers, with sizes
/// and callback cadence unrelated to each other. Forwarding both straight through to the same
/// Live session (as this app used to do) does NOT approximate "both sources heard at once" -
/// Gemini's realtimeInput.audio treats every incoming chunk as the next slice of ONE
/// continuous timeline for the session, so interleaving two unrelated streams on the wire
/// chops the "true" audio into out-of-order fragments from two different sources. This was
/// diagnosed as the cause of severely garbled, language-mixing hallucinated transcription (a
/// question asked entirely over system audio, with the mic still open picking up room
/// silence, came back as nonsense unrelated to what was said). Mixing in the sample domain on
/// a fixed cadence produces one coherent waveform instead, the way any real audio mixer would.
final class AudioMixer {
    /// Fires with a mixed, still 16-bit/16kHz/mono PCM chunk, ready for
    /// GeminiLiveClient.sendAudioChunk
    var onMixedPCM16Chunk: ((Data) -> Void)?

    private let sampleRate = 16000.0
    /// Short enough to stay imperceptible for a "live" assistant, long enough to be worth
    /// the timer/allocation overhead per emitted chunk.
    private let windowSeconds = 0.05
    private var samplesPerWindow: Int { Int(sampleRate * windowSeconds) }

    private let queue = DispatchQueue(label: "com.founderoffice.copilot.audiomixer")
    private var micBuffer: [Int16] = []
    private var systemBuffer: [Int16] = []
    private var timer: DispatchSourceTimer?

    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + windowSeconds, repeating: windowSeconds)
        timer.setEventHandler { [weak self] in self?.emitWindow() }
        timer.resume()
        self.timer = timer
    }

    func addMicChunk(_ data: Data) {
        queue.async { [weak self] in self?.micBuffer.append(contentsOf: data.int16Samples) }
    }

    func addSystemChunk(_ data: Data) {
        queue.async { [weak self] in self?.systemBuffer.append(contentsOf: data.int16Samples) }
    }

    /// Runs on `queue` (the timer's own queue) - pulls one fixed window of samples from each
    /// source (silence if a source has nothing buffered right now, e.g. nobody's talking into
    /// the mic this instant), sums them sample-by-sample with clamping to avoid wraparound,
    /// and emits exactly one mixed chunk representing that slice of real time.
    private func emitWindow() {
        let count = samplesPerWindow
        let mic = takeSamples(from: &micBuffer, count: count)
        let system = takeSamples(from: &systemBuffer, count: count)
        guard !mic.isEmpty || !system.isEmpty else { return }

        var mixed = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let a = i < mic.count ? Int32(mic[i]) : 0
            let b = i < system.count ? Int32(system[i]) : 0
            mixed[i] = Int16(clamping: a + b)
        }

        let data = mixed.withUnsafeBufferPointer { Data(buffer: $0) }
        onMixedPCM16Chunk?(data)
    }

    private func takeSamples(from buffer: inout [Int16], count: Int) -> [Int16] {
        guard !buffer.isEmpty else { return [] }
        let taken = Array(buffer.prefix(count))
        buffer.removeFirst(min(count, buffer.count))
        return taken
    }
}

private extension Data {
    var int16Samples: [Int16] {
        withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Int16.self))
        }
    }
}
