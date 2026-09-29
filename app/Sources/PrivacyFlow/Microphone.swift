import AudioToolbox
import CaptureBuffer
import CoreAudio
import Foundation
import os
import PrivacyFlowCore

/// A finished recording, copied out of the capture buffer once the unit stopped.
struct CapturedAudio: Sendable {
    var samples: [Float]
    var sampleRate: Double
    /// The buffer filled before the user stopped, so this is only the start.
    var truncated: Bool

    var seconds: Double { Double(samples.count) / sampleRate }
}

/// A microphone opened ahead of the keypress and kept open until it is no
/// longer the device to record from, or its device goes away.
///
/// Opening a device costs over a hundred milliseconds, and paying that on the
/// keypress spent it out of the first words. So the audio unit is built and
/// initialised here, once, and a keypress only starts it. It is stopped
/// whenever PrivacyFlow is not recording, so the microphone is not live
/// between dictations, or before the first one.
///
/// It is bound to one device, not to whatever the system input is at the
/// moment, so it remembers which device and why, and `isCurrent` answers
/// whether it is still the right thing to record from.
/// Owns the capture buffer. Anything that may still touch it after the
/// microphone closes, such as a device listener block already queued, holds
/// this rather than the raw pointer, so the buffer cannot be freed under it.
private final class CaptureStorage: @unchecked Sendable {
    let pointer: OpaquePointer
    private let interruption = OSAllocatedUnfairLock<Microphone.Interruption?>(initialState: nil)

    init?(channels: UInt32, maximumFrames: UInt32, capacity: Int) {
        guard let pointer = pf_capture_create(channels, maximumFrames, capacity) else { return nil }
        self.pointer = pointer
    }

    deinit {
        pf_capture_destroy(pointer)
    }

    /// Stop capture for good, remembering the first reason. From this moment
    /// the callback appends nothing more, so audio from after the change never
    /// joins the recording.
    func interrupt(_ why: Microphone.Interruption) {
        interruption.withLock { current in
            if current == nil { current = why }
        }
        pf_capture_mark_failed(pointer)
    }

    var reason: Microphone.Interruption? {
        if let why = interruption.withLock({ $0 }) { return why }
        // The callback marks the capture failed itself when rendering fails.
        return pf_capture_failed(pointer) ? .stopped : nil
    }
}

final class Microphone {
    /// Why capture stopped without being asked to.
    enum Interruption: Equatable {
        /// The device went away.
        case disconnected
        /// The device's sample rate changed, so what it delivers no longer
        /// matches the rate the recording is converted from.
        case formatChanged
        /// The device stopped delivering audio for another reason.
        case stopped
    }

    /// The capture ceiling. Preallocated, so it costs its memory up front: five
    /// minutes of mono float at 48 kHz is about 58 MB.
    static let maximumSeconds: Double = 300
    /// The requested device buffer. The smaller it is, the sooner the first
    /// callback arrives after a start: measured at about 57 ms for the device
    /// default, 33 ms for 128 frames and 29 ms for 64, and 128 leaves the
    /// callback twice the time for almost the same gain.
    static let targetBufferFrames: UInt32 = 128

    let binding: MicrophoneBinding
    let sampleRate: Double
    private let device: AudioDeviceID
    private let unit: AudioUnit
    private let storage: CaptureStorage
    private var capture: OpaquePointer { storage.pointer }
    /// The device's disconnection and sample rate, watched while it is open.
    private var watch: DevicePropertyWatch?
    private var running = false

    /// Open the preferred microphone, or the system input when there is no
    /// preference or the preferred one is not connected.
    init(preferred: String?) throws {
        let (device, route) = try Self.chooseDevice(preferred: preferred)
        let deviceName = AudioDevices.name(of: device) ?? "Unnamed input device"
        self.device = device
        binding = MicrophoneBinding(preferred: preferred, route: route, deviceName: deviceName)

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioProblem("macOS has no audio input unit")
        }
        var instance: AudioUnit?
        try AudioDevices.check(AudioComponentInstanceNew(component, &instance), "create the microphone unit")
        guard let unit = instance else {
            throw AudioProblem("macOS did not create the microphone unit")
        }
        self.unit = unit

        do {
            // Input on, output off: this unit only records.
            var on: UInt32 = 1
            var off: UInt32 = 0
            try Self.set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, "enable recording")
            try Self.set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, "disable playback")
            var chosen = device
            try Self.set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &chosen, "select \(deviceName)")

            var deviceFormat = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try AudioDevices.check(
                AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &size),
                "read the format of \(deviceName)"
            )
            let channels = deviceFormat.mChannelsPerFrame
            guard channels > 0, deviceFormat.mSampleRate > 0 else {
                throw AudioProblem("\(deviceName) reported no input channels")
            }
            sampleRate = deviceFormat.mSampleRate

            // Delivered as one float buffer per channel at the device's own
            // rate; the callback downmixes, and conversion to 16 kHz happens
            // after the recording, off the real-time thread.
            let flags: AudioFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
            var format = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: flags,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: channels,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            try Self.set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, "set the recording format")

            try Self.requestSmallBuffer(on: device)

            var maximumFrames: UInt32 = 4096
            try Self.set(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames, "size the recording buffers")

            let capacity = Int(sampleRate * Self.maximumSeconds)
            guard let storage = CaptureStorage(channels: channels, maximumFrames: maximumFrames, capacity: capacity) else {
                throw AudioProblem("Could not allocate the recording buffer for \(deviceName)")
            }
            self.storage = storage
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }

        pf_capture_set_unit(storage.pointer, unit)
        var callback = AURenderCallbackStruct(inputProc: pf_capture_input, inputProcRefCon: UnsafeMutableRawPointer(storage.pointer))
        do {
            try Self.set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, "install the recording callback")
            try AudioDevices.check(AudioUnitInitialize(unit), "open \(deviceName)")
            watch = try Self.watch(device, storage: storage)
        } catch {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    deinit {
        // Stopped first, so no notification can reach the capture after this.
        watch?.stop()
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        // The capture buffer is freed when the last holder lets go of the
        // storage: this microphone, or a notification handler mid-call.
    }

    /// Start capturing into an empty buffer.
    func startRecording() throws {
        pf_capture_reset(capture)
        try AudioDevices.check(AudioOutputUnitStart(unit), "start \(binding.deviceName)")
        running = true
    }

    /// Stop capturing and hand back everything recorded. A failed unit may
    /// have no device left to be told to stop, but what it captured before
    /// failing is still wanted.
    func stopRecording() -> CapturedAudio {
        if running {
            AudioOutputUnitStop(unit)
            running = false
        }
        let count = pf_capture_count(capture)
        let samples = Array(UnsafeBufferPointer(start: pf_capture_samples(capture), count: count))
        return CapturedAudio(
            samples: samples,
            sampleRate: sampleRate,
            truncated: pf_capture_overflowed(capture)
        )
    }

    /// Whether this is still the microphone to record from under the
    /// preference now. Cheap enough to ask on every keypress. A device that
    /// went away or changed its rate is never current: it is reopened.
    func isCurrent(preferred: String?) -> Bool {
        guard interruption == nil else { return false }
        return binding.isCurrent(
            preferred: preferred,
            systemInputName: { AudioDevices.defaultInput().flatMap(AudioDevices.name(of:)) },
            devicesNamed: { try? AudioDevices.count(named: $0) }
        )
    }

    /// Why capture stopped on its own, if it has.
    var interruption: Interruption? { storage.reason }

    /// The latest callback's level, for the voice meter.
    var level: Float { pf_capture_level(capture) }

    /// What the energy floor would be applied to if the key came up now.
    var recordedRms: Float { pf_capture_recorded_rms(capture) }

    /// Watch the device going away, and its sample rate changing.
    ///
    /// The rate is fixed when the microphone opens, and the recording is later
    /// converted to 16 kHz from that rate. If the device moved to another rate,
    /// the audio it delivers would be converted as if it had not, and come out
    /// sped up or slowed down, so a change ends capture like a disconnect. The
    /// handler runs on a Core Audio thread, so capture stops the moment the
    /// device changes, not when the main thread next gets round to it.
    private static func watch(_ device: AudioDeviceID, storage: CaptureStorage) throws -> DevicePropertyWatch {
        let openedAt = AudioDevices.nominalSampleRate(of: device)
        return try DevicePropertyWatch(device: device, selectors: [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate]) { selector in
            switch selector {
            case kAudioDevicePropertyDeviceIsAlive:
                storage.interrupt(.disconnected)
            case kAudioDevicePropertyNominalSampleRate where AudioDevices.nominalSampleRate(of: device) != openedAt:
                storage.interrupt(.formatChanged)
            default:
                break
            }
        }
    }

    /// A preferred microphone that is not connected stands in as the system
    /// input rather than being refused, and the route says so.
    private static func chooseDevice(preferred: String?) throws -> (AudioDeviceID, MicrophoneBinding.Route) {
        if let preferred, let device = try AudioDevices.input(named: preferred) {
            return (device, .preferred)
        }
        guard let device = AudioDevices.defaultInput(), AudioDevices.inputChannels(of: device) > 0 else {
            throw AudioProblem("No microphone is connected")
        }
        guard let preferred else {
            return (device, .systemDefault)
        }
        return (device, .preferredMissing(devicesNamedPreferred: try AudioDevices.count(named: preferred)))
    }

    /// Ask for a small buffer, but never one the device says it cannot serve.
    private static func requestSmallBuffer(on device: AudioDeviceID) throws {
        var rangeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        // A device that will not state its range keeps its own default.
        guard AudioObjectGetPropertyData(device, &rangeAddress, 0, nil, &size, &range) == noErr else { return }
        var frames = UInt32(min(max(Double(targetBufferFrames), range.mMinimum), range.mMaximum))
        var sizeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try AudioDevices.check(
            AudioObjectSetPropertyData(device, &sizeAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames),
            "set the microphone's buffer size"
        )
    }

    private static func set<Value: BitwiseCopyable>(
        _ unit: AudioUnit,
        _ property: AudioUnitPropertyID,
        _ scope: AudioUnitScope,
        _ element: AudioUnitElement,
        _ value: inout Value,
        _ action: String
    ) throws {
        try AudioDevices.check(AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<Value>.size)), action)
    }
}
