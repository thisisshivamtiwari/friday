import XCTest
@testable import FounderOfficeCopilotCore

/// Covers the sample-domain mixing that replaced sending the mic and system-audio PCM
/// streams straight through as two independently-timed chunk streams (the cause of severely
/// garbled, language-mixing hallucinated transcription - see AudioMixer's doc comment).
final class AudioMixerTests: XCTestCase {
    private func pcm16Data(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func testMicAndSystemAudioAreSummedIntoOneWaveformNotInterleaved() {
        let mixer = AudioMixer()
        let expectation = expectation(description: "mixed chunk emitted")
        var received: Data?
        mixer.onMixedPCM16Chunk = { data in
            received = data
            expectation.fulfill()
        }

        let micSamples = [Int16](repeating: 1000, count: 100)
        let systemSamples = [Int16](repeating: 2000, count: 100)
        mixer.addMicChunk(pcm16Data(micSamples))
        mixer.addSystemChunk(pcm16Data(systemSamples))

        wait(for: [expectation], timeout: 1.0)

        guard let received else { return XCTFail("expected a mixed chunk") }
        let mixedSamples = received.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(mixedSamples[0], 3000, "the two sources must be summed sample-by-sample into one real waveform, not concatenated/interleaved")
    }

    func testClampsInsteadOfWrappingOnOverflow() {
        let mixer = AudioMixer()
        let expectation = expectation(description: "mixed chunk emitted")
        var received: Data?
        mixer.onMixedPCM16Chunk = { data in
            received = data
            expectation.fulfill()
        }

        let micSamples = [Int16](repeating: .max, count: 10)
        let systemSamples = [Int16](repeating: .max, count: 10)
        mixer.addMicChunk(pcm16Data(micSamples))
        mixer.addSystemChunk(pcm16Data(systemSamples))

        wait(for: [expectation], timeout: 1.0)

        guard let received else { return XCTFail("expected a mixed chunk") }
        let mixedSamples = received.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(mixedSamples[0], Int16.max, "overflow must clamp to the valid PCM16 range, never wrap to a negative spike")
    }
}
