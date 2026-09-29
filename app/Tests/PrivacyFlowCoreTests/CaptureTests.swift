import CaptureBuffer
import Foundation
import Testing
@testable import PrivacyFlowCore

private func tone(seconds: Double, amplitude: Float, rate: Double) -> [Float] {
    (0..<Int(seconds * rate)).map { amplitude * sin(Float($0) * 0.2) }
}

private func verdict(_ samples: [Float], rate: Double = 16_000) -> EnergyFloor.Verdict {
    samples.withUnsafeBufferPointer { EnergyFloor.verdict(samples: $0, sampleRate: rate) }
}

/// The fast "no speech" answer at release.
struct EnergyFloorTests {
    @Test func aTapOfTheKeyIsRefused() {
        guard case .tooQuiet = verdict(tone(seconds: 0.08, amplitude: 0.4, rate: 16_000)) else {
            Issue.record("a tap was sent on as speech")
            return
        }
    }

    /// Whisper answers silence with an invented sentence, so this must never reach it.
    @Test func aLongButSilentCaptureIsRefused() {
        guard case .tooQuiet = verdict([Float](repeating: 0, count: 48_000)) else {
            Issue.record("silence was sent on as speech")
            return
        }
    }

    /// Refusing quiet speech costs the user their words, which is worse than
    /// spending recognition time on noise.
    @Test func quietSpeechJustAboveTheFloorIsStillADictation() {
        guard case .speech = verdict(tone(seconds: 1, amplitude: EnergyFloor.silenceRms * 4, rate: 16_000)) else {
            Issue.record("quiet speech was refused")
            return
        }
    }

    @Test func theWarningAndTheRefusalReadTheBoundaryTheSameWay() {
        #expect(!EnergyFloor.headingForRefusal(held: 0.5, recordedRms: 0))
        #expect(EnergyFloor.headingForRefusal(held: 3.01, recordedRms: 0.0009))
        #expect(!EnergyFloor.headingForRefusal(held: 10, recordedRms: EnergyFloor.silenceRms))
    }
}

/// The real-time capture buffer, driven the way the audio callback drives it.
struct CaptureBufferTests {
    /// The live warning is only a prediction if the running measurement and the
    /// verdict at release are the same number.
    @Test func theRunningMeasurementMatchesTheVerdictItPredicts() throws {
        let samples = (0..<4_000).map { sin(Float($0) * 0.01) * 0.002 }
        let capture = try #require(pf_capture_create(1, 512, 8_000))
        defer { pf_capture_destroy(capture) }
        for start in stride(from: 0, to: samples.count, by: 128) {
            let chunk = Array(samples[start..<min(start + 128, samples.count)])
            chunk.withUnsafeBufferPointer { pointer in
                var channels: [UnsafePointer<Float>] = [pointer.baseAddress!]
                pf_capture_push_for_testing(capture, &channels, UInt32(chunk.count))
            }
        }
        let expected = samples.withUnsafeBufferPointer(EnergyFloor.rootMeanSquare)
        #expect(abs(pf_capture_recorded_rms(capture) - expected) < 1e-6)
        #expect(pf_capture_count(capture) == samples.count)
    }

    @Test func channelsAreDownmixedToMono() throws {
        let capture = try #require(pf_capture_create(2, 16, 16))
        defer { pf_capture_destroy(capture) }
        let left: [Float] = [1.0, 0.5]
        let right: [Float] = [-1.0, 0.5]
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                var channels: [UnsafePointer<Float>] = [l.baseAddress!, r.baseAddress!]
                pf_capture_push_for_testing(capture, &channels, 2)
            }
        }
        let mono = Array(UnsafeBufferPointer(start: pf_capture_samples(capture), count: pf_capture_count(capture)))
        #expect(mono == [0.0, 0.5])
        #expect(!pf_capture_overflowed(capture))
    }

    /// Audio delivered after the device changed its rate would be converted at
    /// the wrong rate, so once capture is stopped nothing more joins it, and
    /// what came before is kept.
    @Test func nothingJoinsTheRecordingAfterCaptureStops() throws {
        let capture = try #require(pf_capture_create(1, 16, 16))
        defer { pf_capture_destroy(capture) }
        let before: [Float] = [0.1, 0.2]
        let after: [Float] = [0.9, 0.9, 0.9]
        before.withUnsafeBufferPointer { pointer in
            var channels: [UnsafePointer<Float>] = [pointer.baseAddress!]
            pf_capture_push_for_testing(capture, &channels, 2)
        }
        pf_capture_mark_failed(capture)
        after.withUnsafeBufferPointer { pointer in
            var channels: [UnsafePointer<Float>] = [pointer.baseAddress!]
            pf_capture_push_for_testing(capture, &channels, 3)
        }
        #expect(Array(UnsafeBufferPointer(start: pf_capture_samples(capture), count: pf_capture_count(capture))) == before)
    }

    /// A full buffer keeps the start of the dictation and says so, rather than
    /// discarding it.
    @Test func aFullBufferKeepsWhatItHasAndSaysSo() throws {
        let capture = try #require(pf_capture_create(1, 16, 4))
        defer { pf_capture_destroy(capture) }
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
        samples.withUnsafeBufferPointer { pointer in
            var channels: [UnsafePointer<Float>] = [pointer.baseAddress!]
            pf_capture_push_for_testing(capture, &channels, 6)
        }
        #expect(pf_capture_count(capture) == 4)
        #expect(pf_capture_overflowed(capture))
        pf_capture_reset(capture)
        #expect(pf_capture_count(capture) == 0 && !pf_capture_overflowed(capture))
    }
}

/// The only audio format the worker accepts.
struct WavEncodingTests {
    @Test func aDeviceRateCaptureBecomesSixteenKilohertzMonoSixteenBit() throws {
        let second = tone(seconds: 1, amplitude: 0.3, rate: 48_000)
        let converted = try WavEncoding.convert(second, from: 48_000)
        #expect(abs(converted.count - 16_000) <= 64, "one second of audio stays one second long")
        #expect(converted.contains { $0 != 0 })

        let wav = WavEncoding.wavData(converted)
        func field16(_ offset: Int) -> UInt16 { wav.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } }
        func field32(_ offset: Int) -> UInt32 { wav.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(field16(20) == 1, "integer PCM")
        #expect(field16(22) == 1, "mono")
        #expect(field32(24) == 16_000)
        #expect(field16(34) == 16)
        #expect(Int(field32(40)) == converted.count * 2)
        #expect(wav.count == 44 + converted.count * 2)
    }
}
