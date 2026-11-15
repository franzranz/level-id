// MacTalkbackBridge.swift – Audio-Bruecke: eingebautes Mac-Mikrofon -> ID14, nur Ausgangskanal 6 (DAW 6).
// Zwei AUHAL-Units (Eingang: Mikrofon, Ausgang: ID14) mit einem kleinen Ringpuffer dazwischen.
// Ausgangskanal 6 wird direkt adressiert: Die Output-Unit bekommt ein N-kanaliges, nicht verschachteltes
// Float-Format (N = Kanalzahl des Geraets); der Render-Callback schreibt Stille in alle Puffer und das
// Mono-Signal NUR in Puffer Index 5 (= Kanal 6). Kein ChannelMap noetig.
// Laeuft nur zwischen start() und stop(); im Ruhezustand gibt es keine Audio-Threads.
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Ringpuffer (ein Schreiber, ein Leser; trylock statt Blockieren in den Audio-Threads)

private final class AudioRing: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let capacity: Int
    private let buf: UnsafeMutablePointer<Float>
    private var readIdx = 0
    private var count = 0

    init(capacity: Int) {
        self.capacity = capacity
        buf = .allocate(capacity: capacity)
        buf.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }
    deinit { buf.deallocate(); lock.deallocate() }

    /// Haengt n Samples an. Bei vollem Puffer werden die aeltesten verworfen. Ohne Lock: Block faellt weg.
    func write(_ p: UnsafePointer<Float>, _ n: Int) {
        guard os_unfair_lock_trylock(lock) else { return }
        defer { os_unfair_lock_unlock(lock) }
        for i in 0..<n {
            if count == capacity { readIdx = (readIdx + 1) % capacity; count -= 1 }
            buf[(readIdx + count) % capacity] = p[i]
            count += 1
        }
    }

    /// Liest genau n Samples oder nichts. Rueckgabe: gelesen (n oder 0).
    func read(_ out: UnsafeMutablePointer<Float>, _ n: Int, dropTo target: Int) -> Int {
        guard os_unfair_lock_trylock(lock) else { return 0 }
        defer { os_unfair_lock_unlock(lock) }
        // Latenz begrenzen: zu viel Vorrat verwerfen
        if count > target + n {
            let drop = count - (target + n)
            readIdx = (readIdx + drop) % capacity
            count -= drop
        }
        guard count >= n else { return 0 }
        for i in 0..<n { out[i] = buf[(readIdx + i) % capacity] }
        readIdx = (readIdx + n) % capacity
        count -= n
        return n
    }

    func reset() {
        os_unfair_lock_lock(lock)
        readIdx = 0; count = 0
        os_unfair_lock_unlock(lock)
    }
}

// MARK: - Audio-Pfad (Kontext fuer die C-Callbacks)

private final class TalkbackPipe: @unchecked Sendable {
    static let maxFrames = 8192
    static let signalChannelIndex = 5      // Kanal 6

    let ring: AudioRing
    let inRate: Double
    let outRate: Double
    let outChannels: Int
    var inUnit: AudioUnit?
    var outUnit: AudioUnit?

    private let inBuf: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    private var last: Float = 0
    private var frac = 0.0
    private let targetFill: Int

    init(inRate: Double, outRate: Double, outChannels: Int) {
        self.inRate = inRate
        self.outRate = outRate
        self.outChannels = outChannels
        ring = AudioRing(capacity: Int(inRate / 4))      // 250 ms Obergrenze
        targetFill = Int(inRate * 0.012)                 // ca. 12 ms Vorrat
        inBuf = .allocate(capacity: Self.maxFrames)
        inBuf.initialize(repeating: 0, count: Self.maxFrames)
        scratch = .allocate(capacity: Self.maxFrames * 2 + 8)
        scratch.initialize(repeating: 0, count: Self.maxFrames * 2 + 8)
    }
    deinit { inBuf.deallocate(); scratch.deallocate() }

    /// Eingang: Mikrofon-Samples holen und in den Ring schreiben.
    func capture(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, ts: UnsafePointer<AudioTimeStamp>,
                 bus: UInt32, frames: UInt32) -> OSStatus {
        guard let unit = inUnit, Int(frames) <= Self.maxFrames else { return noErr }
        var abl = AudioBufferList(mNumberBuffers: 1,
                                  mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4,
                                                        mData: UnsafeMutableRawPointer(inBuf)))
        let st = AudioUnitRender(unit, flags, ts, bus, frames, &abl)
        if st == noErr { ring.write(inBuf, Int(frames)) }
        return st
    }

    /// Ausgang: Stille auf allen Kanaelen, Mono-Signal nur auf Kanal 6 (mit linearer Abtastratenumsetzung).
    func render(frames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        for b in list where b.mData != nil { memset(b.mData, 0, Int(b.mDataByteSize)) }
        let n = Int(frames)
        guard list.count > Self.signalChannelIndex, let raw = list[Self.signalChannelIndex].mData,
              n <= Self.maxFrames else { return noErr }
        let out = raw.assumingMemoryBound(to: Float.self)
        let ratio = inRate / outRate
        let total = frac + Double(n) * ratio
        let consumed = Int(total)
        scratch[0] = last
        guard consumed > 0 ? ring.read(scratch + 1, consumed, dropTo: targetFill) == consumed : true else {
            return noErr   // Unterlauf: Stille
        }
        for i in 0..<n {
            let p = frac + Double(i) * ratio
            let i0 = Int(p)
            let f = Float(p - Double(i0))
            let a = scratch[min(i0, consumed)], b = scratch[min(i0 + 1, consumed)]
            out[i] = a + (b - a) * f
        }
        last = scratch[consumed]
        frac = total - Double(consumed)
        return noErr
    }
}

private let captureProc: AURenderCallback = { refCon, flags, ts, bus, frames, _ in
    Unmanaged<TalkbackPipe>.fromOpaque(refCon).takeUnretainedValue()
        .capture(flags: flags, ts: ts, bus: bus, frames: frames)
}

private let renderProc: AURenderCallback = { refCon, _, _, _, frames, ioData in
    Unmanaged<TalkbackPipe>.fromOpaque(refCon).takeUnretainedValue().render(frames: frames, ioData: ioData)
}

// MARK: - CoreAudio-Helfer

enum HAL {
    static func address(_ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func deviceIDs() -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    static func channels(_ dev: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func transportType(_ dev: AudioDeviceID) -> UInt32 {
        var a = address(kAudioDevicePropertyTransportType)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : 0
    }

    static func string(_ dev: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String {
        var a = address(sel)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &ref) == noErr, let r = ref else { return "" }
        return r.takeRetainedValue() as String
    }

    static func sampleRate(_ dev: AudioDeviceID) -> Double {
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var v = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : 0
    }

    /// Eingebautes Mikrofon (nicht das Standard-Eingabegeraet)
    static func builtInMic() -> AudioDeviceID? {
        deviceIDs().first { channels($0, scope: kAudioObjectPropertyScopeInput) > 0
            && transportType($0) == kAudioDeviceTransportTypeBuiltIn }
    }

    /// macOS-Standardausgabegeraet (guenstige Einzelabfrage, ohne Geraetesuche)
    static func defaultOutputDevice() -> AudioDeviceID? {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return nil }
        return dev
    }

    /// Ist das macOS-Standardausgabegeraet das ID14? (mit voller Geraetesuche; MediaKeyTap cached die ID)
    static func defaultOutputIsID14() -> Bool {
        guard let dev = defaultOutputDevice(), let id14 = id14Output() else { return false }
        return dev == id14
    }

    /// ID14: Name oder UID enthaelt "iD14", mindestens 6 Ausgangskanaele
    static func id14Output() -> AudioDeviceID? {
        deviceIDs().first { dev in
            guard channels(dev, scope: kAudioObjectPropertyScopeOutput) >= 6 else { return false }
            let key = "id14"
            return string(dev, kAudioObjectPropertyName).lowercased().contains(key)
                || string(dev, kAudioDevicePropertyDeviceUID).lowercased().contains(key)
        }
    }
}

// MARK: - Bruecke

final class MacTalkbackBridge: TalkbackBridge, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.levelid.talkback")
    // Nur auf `queue`
    private var wanted = false
    private var pipe: TalkbackPipe?
    private var accessRequested = false

    func start() {
        queue.async { [self] in
            wanted = true
            guard pipe == nil else { return }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                startAudio()
            case .notDetermined:
                guard !accessRequested else { return }
                accessRequested = true     // erst beim ersten Start fragen, nie blockierend
                AVCaptureDevice.requestAccess(for: .audio) { [self] granted in
                    queue.async { [self] in
                        if granted, wanted, pipe == nil { startAudio() }
                        else if !granted { Diag.event("Talkback: Mikrofon-Zugriff verweigert") }
                    }
                }
            default:
                Diag.event("Talkback: kein Mikrofon-Zugriff")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            wanted = false
            teardown()
        }
    }

    // MARK: Aufbau / Abbau (auf `queue`)

    private func startAudio() {
        guard let mic = HAL.builtInMic() else { Diag.event("Talkback: eingebautes Mikrofon nicht gefunden"); return }
        guard let out = HAL.id14Output() else { Diag.event("Talkback: ID14-Ausgang nicht gefunden"); return }
        let inRate = HAL.sampleRate(mic), outRate = HAL.sampleRate(out)
        let outCh = HAL.channels(out, scope: kAudioObjectPropertyScopeOutput)
        guard inRate > 0, outRate > 0, outCh >= 6 else { Diag.event("Talkback: ungueltiges Audioformat"); return }

        let p = TalkbackPipe(inRate: inRate, outRate: outRate, outChannels: outCh)
        let ctx = Unmanaged.passUnretained(p).toOpaque()

        guard let inU = makeUnit(), let outU = makeUnit() else { Diag.event("Talkback: AUHAL nicht verfuegbar"); return }
        p.inUnit = inU
        p.outUnit = outU
        pipe = p

        var ok = true
        // Eingang: Bus 1 an, Bus 0 aus, Geraet, Mono-Float im Geraetetakt, Callback
        ok = ok && set(inU, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1))
        ok = ok && set(inU, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0))
        ok = ok && set(inU, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, mic)
        ok = ok && set(inU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format(rate: inRate, channels: 1))
        ok = ok && set(inU, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                       AURenderCallbackStruct(inputProc: captureProc, inputProcRefCon: ctx))
        // Ausgang: Geraet, N Kanaele nicht verschachtelt, Render-Callback
        ok = ok && set(outU, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, out)
        ok = ok && set(outU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, format(rate: outRate, channels: outCh))
        ok = ok && set(outU, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                       AURenderCallbackStruct(inputProc: renderProc, inputProcRefCon: ctx))
        ok = ok && AudioUnitInitialize(inU) == noErr && AudioUnitInitialize(outU) == noErr
        ok = ok && AudioOutputUnitStart(inU) == noErr && AudioOutputUnitStart(outU) == noErr
        if !ok {
            Diag.event("Talkback: Audio-Start fehlgeschlagen")
            teardown()
        } else {
            Diag.event("Talkback: Bruecke laeuft (\(Int(inRate)) -> \(Int(outRate)) Hz, Kanal 6 von \(outCh))")
        }
    }

    private func teardown() {
        guard let p = pipe else { return }
        pipe = nil
        for unit in [p.inUnit, p.outUnit] {
            guard let u = unit else { continue }
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        p.inUnit = nil
        p.outUnit = nil
        p.ring.reset()
        Diag.event("Talkback: Bruecke gestoppt")
    }

    private func makeUnit() -> AudioUnit? {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var unit: AudioUnit?
        return AudioComponentInstanceNew(comp, &unit) == noErr ? unit : nil
    }

    private func format(rate: Double, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    private func set<T>(_ unit: AudioUnit, _ prop: AudioUnitPropertyID, _ scope: AudioUnitScope,
                        _ element: AudioUnitElement, _ value: T) -> Bool {
        var v = value
        return withUnsafePointer(to: &v) {
            AudioUnitSetProperty(unit, prop, scope, element, $0, UInt32(MemoryLayout<T>.size))
        } == noErr
    }
}
