import AVFoundation
import Foundation

/// Turning a capture into the one WAV format the worker accepts: 16 kHz, mono,
/// 16-bit integer PCM. The worker refuses anything else rather than resampling.
public enum WavEncoding {
    public static let sampleRate: Double = 16_000

    /// Convert mono float samples at the device's rate to 16 kHz 16-bit samples.
    public static func convert(_ samples: [Float], from sourceRate: Double) throws -> [Int16] {
        guard !samples.isEmpty else { return [] }
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw EncodingFailure("Could not build a converter from \(Int(sourceRate)) Hz to 16 kHz")
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw EncodingFailure("Could not allocate the conversion input")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            input.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
        }
        let expected = Double(samples.count) * sampleRate / sourceRate
        // Headroom for the converter's own filter delay and rounding.
        let capacity = AVAudioFrameCount(expected.rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw EncodingFailure("Could not allocate the conversion output")
        }
        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw EncodingFailure("Could not convert the recording to 16 kHz: \(conversionError?.localizedDescription ?? "unknown error")")
        }
        let frames = Int(output.frameLength)
        return Array(UnsafeBufferPointer(start: output.int16ChannelData![0], count: frames))
    }

    /// A complete WAV file for 16 kHz mono 16-bit samples.
    public static func wavData(_ samples: [Int16]) -> Data {
        let dataBytes = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + Int(dataBytes))
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF")
        append32(36 + dataBytes)
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1) // integer PCM
        append16(1) // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate) * 2) // bytes per second
        append16(2) // bytes per frame
        append16(16) // bits per sample
        append("data")
        append32(dataBytes)
        // Appended as they lie in memory, which is already little-endian on
        // the Apple Silicon Macs PrivacyFlow runs on.
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

public struct EncodingFailure: Error, CustomStringConvertible {
    public var description: String

    init(_ description: String) {
        self.description = description
    }
}
