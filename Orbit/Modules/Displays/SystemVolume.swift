import AppKit
import CoreAudio

/// The current sound output's own volume — MacBook speakers, AirPods, USB — for Orbit's volume HUD.
/// Devices whose volume macOS can't set (HDMI audio, some interfaces) are left to macOS.
enum SystemVolume {
    struct Output {
        let device: AudioObjectID
        let name: String
        /// The main element, or the left and right channels when there's no master control.
        let elements: [AudioObjectPropertyElement]
    }

    static func current() -> Output? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        let elements: [AudioObjectPropertyElement]
        if settable(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain) {
            elements = [kAudioObjectPropertyElementMain]
        } else {
            elements = [1, 2].filter { settable(device, kAudioDevicePropertyVolumeScalar, $0) }
        }
        guard !elements.isEmpty else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address = Self.address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        return Output(device: device, name: (name?.takeRetainedValue() as String?) ?? "", elements: elements)
    }

    static func volume(_ o: Output) -> Double {
        let values = o.elements.compactMap { element -> Float32? in
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            var a = address(kAudioDevicePropertyVolumeScalar, element: element)
            return AudioObjectGetPropertyData(o.device, &a, 0, nil, &size, &v) == noErr ? v : nil
        }
        return values.isEmpty ? 0 : Double(values.reduce(0, +)) / Double(values.count)
    }

    static func setVolume(_ o: Output, _ value: Double) {
        var v = Float32(min(max(value, 0), 1))
        for element in o.elements {
            var a = address(kAudioDevicePropertyVolumeScalar, element: element)
            AudioObjectSetPropertyData(o.device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    static func isMuted(_ o: Output) -> Bool {
        var a = address(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(o.device, &a) else { return false }
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(o.device, &a, 0, nil, &size, &m) == noErr && m != 0
    }

    /// False when the device has no mute; volume 0 stands in for it then.
    @discardableResult
    static func setMuted(_ o: Output, _ muted: Bool) -> Bool {
        var m: UInt32 = muted ? 1 : 0
        var done = false
        for element in [kAudioObjectPropertyElementMain] + o.elements where settable(o.device, kAudioDevicePropertyMute, element) {
            var a = address(kAudioDevicePropertyMute, element: element)
            if AudioObjectSetPropertyData(o.device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) == noErr { done = true }
            if element == kAudioObjectPropertyElementMain && done { break }
        }
        return done
    }

    private static let feedback = NSSound(contentsOfFile: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff", byReference: true)

    /// The little "pop" — only when the user turned on "Play feedback when volume is changed".
    static func playFeedbackIfWanted() {
        guard UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.sound.beep.feedback"] as? Int == 1,
              let feedback else { return }
        feedback.stop()
        feedback.play()
    }

    private static func settable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Bool {
        var a = address(selector, element: element)
        guard AudioObjectHasProperty(device, &a) else { return false }
        var ok: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &a, &ok) == noErr && ok.boolValue
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}
