import CoreAudio
import Foundation

/// Reading the audio devices Core Audio knows about.
enum AudioDevices {
    /// Every device, input and output alike.
    static func all() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size), "list audio devices")
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices), "list audio devices")
        return devices
    }

    /// The system input, if there is one.
    static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    /// The rate the device is running at, if it says.
    static func nominalSampleRate(of device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    /// How many input channels a device has; zero for an output-only device.
    static func inputChannels(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// The names of every connected input, for choosing one.
    static func inputNames() throws -> [String] {
        try all().filter { inputChannels(of: $0) > 0 }.compactMap(name(of:))
    }

    /// The input device with this name, if one is connected. A headset
    /// appears twice under one name, once per direction, so only a device that
    /// records counts.
    static func input(named name: String) throws -> AudioDeviceID? {
        try all().first { self.name(of: $0) == name && inputChannels(of: $0) > 0 }
    }

    /// How many devices of either direction carry this name.
    static func count(named name: String) throws -> Int {
        try all().filter { self.name(of: $0) == name }.count
    }

    /// Call `changed` on the main thread whenever a device is added or removed.
    static func observeChanges(_ changed: @escaping @MainActor () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in
            MainActor.assumeIsolated { changed() }
        }
    }

    static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else {
            throw AudioProblem("Could not \(action) (Core Audio error \(status))")
        }
    }
}

/// A Core Audio operation that failed.
struct AudioProblem: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
