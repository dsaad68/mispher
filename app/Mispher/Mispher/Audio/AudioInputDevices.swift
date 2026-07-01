import CoreAudio
import Foundation

/// One selectable audio input device. `uid` is the Core Audio device UID -- stable across reboots
/// and re-plugs, unlike the numeric `AudioDeviceID` -- so it's what we persist and match on. The
/// empty string is reserved (elsewhere) for "System Default", i.e. no override.
struct AudioInputDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// Core Audio helpers for listing the microphones the user can choose from and resolving a saved
/// UID back to the live device. Read-only: nothing here changes the system default - the choice is
/// applied per-engine in ``MicCapture``.
enum AudioInputDevices {
    /// Every device that currently exposes at least one input channel, with its name + UID.
    static func available() -> [AudioInputDevice] {
        allDeviceIDs()
            .filter { inputChannelCount($0) > 0 }
            .compactMap { id in
                guard let uid = deviceUID(id) else { return nil }
                return AudioInputDevice(uid: uid, name: deviceName(id) ?? uid)
            }
    }

    /// Resolve a persisted UID to the current `AudioDeviceID`, or nil if that device is gone.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &deviceID
            )
        }
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    // MARK: - Private Core Audio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    /// Number of input channels the device exposes (0 means it's output-only).
    private static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr else { return 0 }

        let pointer = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return pointer.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func deviceUID(_ device: AudioDeviceID) -> String? {
        stringProperty(device, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        stringProperty(device, selector: kAudioObjectPropertyName)
    }

    private static func stringProperty(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { valuePtr in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, valuePtr)
        }
        guard status == noErr else { return nil }
        return value as String
    }
}
