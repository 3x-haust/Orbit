import CoreAudio
import Darwin
import Foundation
import Synchronization

/// 10-band graphic EQ math (RBJ Audio EQ Cookbook peaking filters, octave spacing).
enum GraphicEQ {
    static let frequencies: [Double] = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let range: ClosedRange<Float> = -12...12
    static let bands = 10
    /// ≈ one octave wide, so neighbouring bands overlap smoothly.
    static let q = 1.41

    struct Coefficients { var b0, b1, b2, a1, a2: Double }

    static func peaking(gain dB: Double, frequency: Double, sampleRate: Double) -> Coefficients {
        let f = min(frequency, sampleRate * 0.45)
        let a = pow(10, dB / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        return Coefficients(b0: (1 + alpha * a) / a0, b1: -2 * cosw / a0, b2: (1 - alpha * a) / a0,
                            a1: -2 * cosw / a0, a2: (1 - alpha / a) / a0)
    }

    /// Combined response of all bands at `frequency`, in dB — drives the curve in the editor.
    static func response(_ gains: [Float], at frequency: Double, sampleRate: Double = 48_000) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        var total = 0.0
        for (i, g) in gains.enumerated() where abs(g) > 0.01 {
            let k = peaking(gain: Double(g), frequency: frequencies[i], sampleRate: sampleRate)
            let nr = k.b0 + k.b1 * c1 + k.b2 * c2, ni = -(k.b1 * s1 + k.b2 * s2)
            let dr = 1 + k.a1 * c1 + k.a2 * c2, di = -(k.a1 * s1 + k.a2 * s2)
            total += 10 * log10((nr * nr + ni * ni) / max(1e-12, dr * dr + di * di))
        }
        return total
    }
}

// MARK: - Real-time render state

/// Parameter block layout: [gain, 10 × (b0 b1 b2 a1 a2), 10 × active flag].
private enum Layout {
    static let gain = 0
    static let coeffs = 1
    static let active = 1 + GraphicEQ.bands * 5
    static let count = active + GraphicEQ.bands
    static let state = 2 * GraphicEQ.bands * 2 // 2 channels × bands × (z1, z2)
}

/// Everything the IOProc touches. All memory is allocated up front; the audio thread only reads and
/// writes through these pointers — no locks, allocation, ARC or Objective-C on the render path.
struct TapRenderContext {
    /// Seqlock guarding `pending`: odd while the main thread is writing.
    var sequence: UnsafeMutablePointer<Atomic<UInt32>>
    var pending: UnsafeMutablePointer<Float>
    var scratch: UnsafeMutablePointer<Float>
    var working: UnsafeMutablePointer<Float>
    var filterState: UnsafeMutablePointer<Float>
    var currentGain: UnsafeMutablePointer<Float>
    var lastSequence: UnsafeMutablePointer<UInt32>
    /// Peak of the processed signal since the UI last read it (Float bit pattern).
    var peak: UnsafeMutablePointer<Atomic<UInt32>>
    /// Input channels that belong to the output device itself (e.g. a headset mic) come before the tap.
    var inputOffset: Int
}

@inline(__always)
private func softClip(_ x: Float) -> Float {
    let a = abs(x)
    guard a > 0.9 else { return x }
    let y = 0.9 + 0.1 * tanhf((a - 0.9) / 0.1)
    return x < 0 ? -y : y
}

@inline(__always)
private func readSample(_ list: UnsafeMutableAudioBufferListPointer, frame: Int, channel: Int) -> Float {
    var base = 0
    for i in 0..<list.count {
        let b = list[i]
        let n = Int(b.mNumberChannels)
        if channel < base + n {
            guard let data = b.mData else { return 0 }
            return data.assumingMemoryBound(to: Float.self)[frame * n + (channel - base)]
        }
        base += n
    }
    return 0
}

private func frameCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
    guard list.count > 0 else { return 0 }
    let b = list[0]
    return Int(b.mDataByteSize) / (MemoryLayout<Float>.size * max(1, Int(b.mNumberChannels)))
}

private func render(_ c: TapRenderContext, _ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
    // Pick up new parameters if a complete, untorn write is available.
    let s1 = c.sequence.pointee.load(ordering: .acquiring)
    if s1 & 1 == 0, s1 != c.lastSequence.pointee {
        c.scratch.update(from: c.pending, count: Layout.count)
        atomicMemoryFence(ordering: .acquiring)
        if c.sequence.pointee.load(ordering: .relaxed) == s1 {
            c.working.update(from: c.scratch, count: Layout.count)
            c.lastSequence.pointee = s1
        }
    }

    let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outList = UnsafeMutableAudioBufferListPointer(output)
    var totalIn = 0
    for i in 0..<inList.count { totalIn += Int(inList[i].mNumberChannels) }
    let tapChannels = min(2, max(0, totalIn - c.inputOffset))
    let inFrames = frameCount(inList)
    let outFrames = frameCount(outList)
    let frames = tapChannels > 0 ? min(inFrames, outFrames) : 0

    let target = c.working[Layout.gain]
    var gain = c.currentGain.pointee
    var peak: Float = 0
    let w = c.working, st = c.filterState

    for f in 0..<frames {
        gain += (target - gain) * 0.0015 // ~10 ms glide: no zipper noise or clicks
        var l = readSample(inList, frame: f, channel: c.inputOffset)
        var r = tapChannels > 1 ? readSample(inList, frame: f, channel: c.inputOffset + 1) : l
        for band in 0..<GraphicEQ.bands where w[Layout.active + band] != 0 {
            let k = Layout.coeffs + band * 5
            let b0 = w[k], b1 = w[k + 1], b2 = w[k + 2], a1 = w[k + 3], a2 = w[k + 4]
            // Transposed direct form II, one state pair per channel.
            let sl = band * 2, sr = (GraphicEQ.bands + band) * 2
            let yl = b0 * l + st[sl]
            st[sl] = b1 * l - a1 * yl + st[sl + 1]
            st[sl + 1] = b2 * l - a2 * yl
            l = yl
            let yr = b0 * r + st[sr]
            st[sr] = b1 * r - a1 * yr + st[sr + 1]
            st[sr + 1] = b2 * r - a2 * yr
            r = yr
        }
        l = softClip(l * gain)
        r = softClip(r * gain)
        peak = max(peak, abs(l), abs(r))

        var channel = 0
        for i in 0..<outList.count {
            let b = outList[i]
            let n = Int(b.mNumberChannels)
            guard let data = b.mData?.assumingMemoryBound(to: Float.self) else { channel += n; continue }
            for j in 0..<n { data[f * n + j] = (channel + j) % 2 == 0 ? l : r }
            channel += n
        }
    }
    // Silence whatever the tap didn't fill.
    for i in 0..<outList.count {
        let b = outList[i]
        let n = Int(b.mNumberChannels)
        guard let data = b.mData?.assumingMemoryBound(to: Float.self), outFrames > frames else { continue }
        (data + frames * n).update(repeating: 0, count: (outFrames - frames) * n)
    }
    c.currentGain.pointee = gain
    let previous = Float(bitPattern: c.peak.pointee.load(ordering: .relaxed))
    if peak > previous { c.peak.pointee.store(peak.bitPattern, ordering: .relaxed) }
}

private let ioProc: AudioDeviceIOProc = { _, _, input, _, output, _, client in
    guard let client else { return noErr }
    render(client.assumingMemoryBound(to: TapRenderContext.self).pointee, input, output)
    return noErr
}

// MARK: - Tap

/// One app's audio — or, for the "All Sound" EQ, everything except a few processes — captured with
/// a process tap (which mutes the original), run through gain + EQ, and played on an output device
/// via a private aggregate device.
@MainActor
final class AppTap {
    enum Failure: LocalizedError {
        case step(String, OSStatus)
        var errorDescription: String? {
            if case .step(let what, let status) = self { return "\(what) failed (\(status))" }
            return nil
        }
    }

    let bundleID: String
    let processes: Set<AudioObjectID>
    /// Set for a global tap: every process except these is captured.
    private(set) var excluded: Set<AudioObjectID>?
    let deviceUID: String
    private(set) var sampleRate: Double = 48_000

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let context: UnsafeMutablePointer<TapRenderContext>
    private var stopped = false

    init(bundleID: String, processes: Set<AudioObjectID>, excluding: Set<AudioObjectID>? = nil,
         deviceUID: String, gain: Float, bands: [Float]) throws {
        self.bundleID = bundleID
        self.processes = processes
        self.excluded = excluding
        self.deviceUID = deviceUID

        let sequence = UnsafeMutablePointer<Atomic<UInt32>>.allocate(capacity: 1)
        sequence.initialize(to: Atomic(0))
        let peak = UnsafeMutablePointer<Atomic<UInt32>>.allocate(capacity: 1)
        peak.initialize(to: Atomic(0))
        func floats(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        let last = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        last.initialize(to: 0)
        let device = HAL.device(uid: deviceUID) ?? HAL.defaultOutput
        var deviceInputs = 0
        do {
            var a = HAL.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
            var size: UInt32 = 0
            if AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 {
                let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
                if AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr {
                    deviceInputs = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
                        .reduce(0) { $0 + Int($1.mNumberChannels) }
                }
                raw.deallocate()
            }
        }
        context = .allocate(capacity: 1)
        context.initialize(to: TapRenderContext(
            sequence: sequence, pending: floats(Layout.count), scratch: floats(Layout.count), working: floats(Layout.count),
            filterState: floats(Layout.state), currentGain: floats(1), lastSequence: last, peak: peak, inputOffset: deviceInputs))

        do { try build(device: device, gain: gain, bands: bands) }
        catch { stopped = true; teardown(); free(); throw error }
    }

    private func build(device: AudioObjectID, gain: Float, bands: [Float]) throws {
        let description = makeDescription()
        let tapUUID = UUID()
        description.uuid = tapUUID
        description.name = "Orbit · \(bundleID)"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw Failure.step("Process tap", status) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Orbit Sound · \(bundleID)",
            kAudioAggregateDeviceUIDKey: "com.lyu.orbit.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUUID.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw Failure.step("Aggregate device", status) }

        sampleRate = HAL.sampleRate(aggregateID)
        publish(gain: gain, bands: bands)

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcID(aggregateID, ioProc, UnsafeMutableRawPointer(context), &proc)
        guard status == noErr, let proc else { throw Failure.step("IOProc", status) }
        procID = proc
        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else { throw Failure.step("Start", status) }
    }

    private func makeDescription() -> CATapDescription {
        if let excluded {
            return CATapDescription(__stereoGlobalTapButExcludeProcesses: excluded.sorted().map { NSNumber(value: $0) })
        }
        return CATapDescription(__stereoMixdownOfProcesses: processes.sorted().map { NSNumber(value: $0) })
    }

    /// A global tap's exclusion list changed (an app got its own tap, or let go of it). Updates the
    /// live tap in place so the sound doesn't drop out; false if Core Audio won't, and the caller
    /// rebuilds instead.
    func updateExclusions(_ next: Set<AudioObjectID>) -> Bool {
        guard excluded != nil, tapID != kAudioObjectUnknown else { return false }
        if next == excluded { return true }
        var a = HAL.address(kAudioTapPropertyDescription)
        var current: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        guard AudioObjectGetPropertyData(tapID, &a, 0, nil, &size, &current) == noErr,
              let description = current?.takeRetainedValue() else { return false }
        description.processes = next.sorted()
        var ref: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(description)
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectSetPropertyData(tapID, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size), $0)
        }
        guard status == noErr else { return false }
        excluded = next
        return true
    }

    /// Main thread: hands new settings to the render thread through the seqlock.
    func publish(gain: Float, bands: [Float]) {
        let c = context.pointee
        let s = c.sequence.pointee.load(ordering: .relaxed)
        c.sequence.pointee.store(s &+ 1, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
        c.pending[Layout.gain] = gain
        for band in 0..<GraphicEQ.bands {
            let db = band < bands.count ? bands[band] : 0
            let k = GraphicEQ.peaking(gain: Double(db), frequency: GraphicEQ.frequencies[band], sampleRate: sampleRate)
            let base = Layout.coeffs + band * 5
            c.pending[base] = Float(k.b0)
            c.pending[base + 1] = Float(k.b1)
            c.pending[base + 2] = Float(k.b2)
            c.pending[base + 3] = Float(k.a1)
            c.pending[base + 4] = Float(k.a2)
            c.pending[Layout.active + band] = abs(db) > 0.01 ? 1 : 0
        }
        c.sequence.pointee.store(s &+ 2, ordering: .releasing)
    }

    /// Peak level since the last call, 0…1.
    func takePeak() -> Float {
        Float(bitPattern: context.pointee.peak.pointee.exchange(0, ordering: .relaxed))
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        teardown()
        free()
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Only after AudioDeviceStop has returned — the render thread no longer touches the context.
    private func free() {
        let c = context.pointee
        c.sequence.deinitialize(count: 1); c.sequence.deallocate()
        c.peak.deinitialize(count: 1); c.peak.deallocate()
        [c.pending, c.scratch, c.working, c.filterState, c.currentGain].forEach { $0.deallocate() }
        c.lastSequence.deallocate()
        context.deinitialize(count: 1)
        context.deallocate()
    }
}
