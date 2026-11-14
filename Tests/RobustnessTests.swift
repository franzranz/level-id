// RobustnessTests.swift – Offline-Robustheitstests fuer DeviceController, StateStore und IDStateImporter.
import Foundation

final class HotplugBox { var callback: ((Bool) -> Void)? }

/// Main-RunLoop kurz laufen lassen (Controller und Worker melden ueber die Main-Queue).
@MainActor func spin(_ seconds: Double, until cond: (() -> Bool)? = nil) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        Thread.sleep(forTimeInterval: 0.005)
        if let c = cond, c() { break }
    }
}

let fastTiming = DeviceTiming(attachDelay: 0.02, openRetryMS: 10, readyIntervalMS: 5, readyTimeout: 1.0,
                              pushPauseUS: 0, notifyFastMS: 10, notifyActiveMS: 20, notifyIdleMS: 100,
                              burstSeconds: 0.5, wakeDelay: 0.1, meterMS: 20)

/// Reicht an FaultTransport durch und merkt sich alle erfolgreichen SETs.
final class LoggingTransport: DeviceTransport, @unchecked Sendable {
    let inner = FaultTransport()
    private let lock = NSLock()
    private var log: [SetCommand] = []
    var sent: [SetCommand] { lock.lock(); defer { lock.unlock() }; return log }
    var isOpen: Bool { inner.isOpen }
    func open() -> Bool { inner.open() }
    func close() { inner.close() }
    private var talkbackOn = false
    private var monoValue: UInt8 = 0
    private var volumeOneShot: [UInt8]?
    /// Antwort fuer FU 0x0C Kanal 3 (Kopfhoerer-Mixausgang), nil = Standard des FaultTransport
    var mixOut3: [UInt8]? {
        get { lock.lock(); defer { lock.unlock() }; return mixOut3Stored }
        set { lock.lock(); mixOut3Stored = newValue; lock.unlock() }
    }
    private var mixOut3Stored: [UInt8]?
    /// Tastendruck: Mono-Meldung mit Wert 1
    func pressMono() {
        lock.lock(); monoValue = 1; notifyQueue.append([0x00, 0, 0, 0x36]); lock.unlock()
    }
    /// Reglerdrehung am Geraet: naechster Lesezugriff liefert diese Lautstaerke
    func knobTurn(toDB db: Double) {
        lock.lock(); volumeOneShot = DB.encode(db); notifyQueue.append([0x12, 0, 0, 0x36]); lock.unlock()
    }
    private var notifyQueue: [[UInt8]] = []
    private var cutValue: UInt8 = 0
    /// Simuliert ein leeres Geraet: GET auf Mixer-Sends liefert -128 dB
    var mixerSendsSilent = false
    /// Tastendruck auf die iD-Taste in der Belegung "Stumm": Firmware setzt Cut und meldet es
    func pressCut(_ on: Bool) {
        lock.lock(); cutValue = on ? 1 : 0; notifyQueue.append([0x04, 0, 0, 0x36]); lock.unlock()
    }
    /// Simuliert den Druck auf die iD-Taste (Talkback an/aus) samt Notify
    func triggerTalkback(_ on: Bool) {
        lock.lock(); talkbackOn = on; notifyQueue.append([0x07, 0, 0, 0x36]); lock.unlock()
    }
    func get(_ request: ID14.Request, unit: UInt8, wValue: UInt16, length: Int) -> [UInt8]? {
        lock.lock()
        if unit == ID14.Unit.notify.rawValue, !notifyQueue.isEmpty, inner.isOpen {
            let n = notifyQueue.removeFirst(); lock.unlock(); return n
        }
        if unit == ID14.Monitor.mono.unit, wValue == ID14.Monitor.mono.wValue, inner.isOpen, monoValue != 0 {
            let v = monoValue; monoValue = 0; lock.unlock(); return [v]      // Taste nur einmal gedrueckt
        }
        if unit == ID14.Monitor.volume.unit, wValue == ID14.Monitor.volume.wValue, inner.isOpen, let o = volumeOneShot {
            volumeOneShot = nil; lock.unlock(); return o
        }
        if unit == ID14.mixOutputVolume(channel: 3).unit, wValue == ID14.mixOutputVolume(channel: 3).wValue,
           inner.isOpen, let m = mixOut3Stored {
            lock.unlock(); return m
        }
        if unit == ID14.Monitor.cut.unit, wValue == ID14.Monitor.cut.wValue, inner.isOpen, !log.contains(where: { $0.control == ID14.Monitor.cut && $0.data == [0] }) || cutValue == 1 {
            let v = cutValue; lock.unlock(); return [v]
        }
        if unit == ID14.mixerSend(input: 0, output: 0).unit, inner.isOpen, mixerSendsSilent {
            lock.unlock(); return [0x00, 0x80]      // frisch eingesteckt: alle Sends -128 dB
        }
        if unit == ID14.Monitor.talkback.unit, wValue == ID14.Monitor.talkback.wValue, inner.isOpen {
            let v: UInt8 = talkbackOn ? 1 : 0; lock.unlock(); return [v]
        }
        lock.unlock()
        let r = inner.get(request, unit: unit, wValue: wValue, length: length)
        // Wie am echten Geraet: Monitor-Lautstaerke liefert den zuletzt gesetzten Wert
        if r != nil, unit == ID14.Monitor.volume.unit, wValue == ID14.Monitor.volume.wValue {
            lock.lock(); defer { lock.unlock() }
            if let last = log.last(where: { $0.control == ID14.Monitor.volume }) { return last.data }
        }
        return r
    }
    func set(_ command: SetCommand) -> Bool {
        let ok = inner.set(command)
        if ok { lock.lock(); log.append(command); lock.unlock() }
        return ok
    }
}

final class FakeBridge: TalkbackBridge {
    var starts = 0, stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

@MainActor func makeController(_ t: DeviceTransport, passive: Bool = false, bridge: TalkbackBridge = NoOpTalkbackBridge(),
                               timing: DeviceTiming = fastTiming,
                               configure: (inout DeviceState) -> Void = { _ in }) -> (DeviceController, HotplugBox) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("id14-rob-\(UUID().uuidString)")
    let store = StateStore(url: dir.appendingPathComponent("state.json"))
    var s = DeviceState()
    s.restore.fadeSeconds = 0.4
    configure(&s)
    store.save(s)          // vorhandener Zustand: kein Import aus iD
    let box = HotplugBox()
    let c = DeviceController(transport: t, store: store, watch: { box.callback = $0 },
                             timing: timing, originalAppProbe: { passive }, talkbackBridge: bridge)
    c.start()
    return (c, box)
}

// Kleiner deterministischer Zufall
struct LCG {
    var x: UInt64
    mutating func next() -> UInt64 { x = x &* 6364136223846793005 &+ 1442695040888963407; return x >> 33 }
    mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
}

func mutateJSON(_ v: Any, _ r: inout LCG, _ k: Double = 1) -> Any? {
    switch v {
    case let d as [String: Any]:
        var out: [String: Any] = [:]
        for (key, x) in d {
            if r.chance(0.06 * k) { continue }                       // Feld fehlt
            if let m = mutateJSON(x, &r, k) { out[key] = m }
        }
        return out
    case let a as [Any]:
        if r.chance(0.12 * k) { return Array(a.prefix(r.int(a.count + 1))) }            // zu kurz
        var out = a.compactMap { mutateJSON($0, &r, k) }
        if r.chance(0.10 * k) { for _ in 0..<(1 + r.int(20)) { out.append(r.int(300)) } }   // zu lang
        return out
    case is String:
        return r.chance(0.1 * k) ? "\u{0}\u{FFFD}garbage\(r.int(999))" : v
    case is NSNumber:
        if r.chance(0.12 * k) {
            return [1e300, -1e300, 1e-300, 9.2e18, -9.2e18, 65535, -1][r.int(7)]
        }
        if r.chance(0.04 * k) { return "x" }                                           // falscher Typ
        return v
    default:
        return v
    }
}

@MainActor func runRobustnessTests() {
    print("\n-- Robustheit --")
    if Date().timeIntervalSince1970 < 0 { return }

    // 1. Geraet faellt mitten im Push aus
    do {
        let t = FaultTransport(); t.failAfterRequest = 5 + 30
        let (c, hot) = makeController(t)
        hot.callback?(true)
        spin(2.0, until: { c.connection == .unresponsive })
        check("Ausfall im Push: connection == .unresponsive", c.connection == .unresponsive)
        spin(0.2)
        let n = t.totalRequests
        spin(0.4)
        check("Ausfall im Push: danach keine weitere Anfrage", t.totalRequests == n && n <= 5 + 30 + 4,
              "requests=\(t.totalRequests) (nach Ausfall \(n))")
        check("Ausfall im Push: Transport geschlossen", !t.isOpen)
        // Setter bei .unresponsive: nur lokal
        c.setMonitorVolume(-20)
        spin(0.2)
        check("unresponsive: Setter nur lokal, kein USB", c.state.monitor.volumeDB == -20 && t.totalRequests == n)
        hot.callback?(false)
        spin(0.1)
        check("unresponsive -> Abziehen ergibt .disconnected", c.connection == .disconnected)
    }

    // 2. Abziehen waehrend der Bereitschaftspruefung
    do {
        let t = FaultTransport(); t.getAlwaysNil = true
        let (c, hot) = makeController(t)
        hot.callback?(true)
        spin(0.15)
        check("Bereitschaft: Geraet geoeffnet, noch nicht verbunden", t.isOpen && c.connection == .disconnected)
        hot.callback?(false)
        spin(0.05)
        t.markNow()
        spin(0.4)
        check("Abziehen waehrend Bereitschaft: keine Requests mehr", t.requestsSinceMark == 0 && !t.isOpen,
              "requests=\(t.requestsSinceMark)")
    }

    // 3. Abziehen waehrend des Fades
    do {
        let t = FaultTransport()
        let (c, hot) = makeController(t)
        hot.callback?(true)
        spin(2.0, until: { c.isFading })
        check("Fade laeuft nach dem Anstecken", c.connection == .connected && c.isFading)
        hot.callback?(false)
        spin(0.05)
        t.markNow()
        spin(0.5)
        check("Abziehen waehrend Fade: keine Requests mehr", t.requestsSinceMark == 0, "requests=\(t.requestsSinceMark)")
        check("Abziehen waehrend Fade: isFading false, getrennt", !c.isFading && c.connection == .disconnected)
    }

    // 4. Normaler Ablauf endet verbunden, Fade fertig
    do {
        let t = FaultTransport()
        let (c, hot) = makeController(t)
        hot.callback?(true)
        spin(3.0, until: { c.connection == .connected && !c.isFading && t.sets > 100 })
        check("Normalbetrieb: verbunden, gepusht", c.connection == .connected && t.sets > 100, "sets=\(t.sets)")
        spin(1.0, until: { !c.isFading })
        check("Normalbetrieb: Fade beendet", !c.isFading)
        hot.callback?(false)
        spin(0.1)
    }

    // 5. Passiv: null SETs, auch ueber Setter
    do {
        let t = FaultTransport()
        let (c, hot) = makeController(t, passive: true)
        hot.callback?(true)
        spin(1.0, until: { c.connection == .passive })
        check("Passiv: connection == .passive", c.connection == .passive)
        let before = c.state
        c.setMonitorVolume(-10); c.setDim(true); c.setCut(true); c.setPhonesVolume(-5)
        c.setSendVolume(input: 0, mix: 0, db: -3); c.setInputCut(input: 1, true); c.setCueBlend(mix: 0, 0.3)
        spin(0.5)
        check("Passiv: null SETs", t.sets == 0, "sets=\(t.sets)")
        check("Passiv: Setter aendern den Zustand nicht", c.state.monitor == before.monitor && c.state.inputs == before.inputs)
        hot.callback?(false)
        spin(0.1)
    }

    // 6. Open schlaegt fehl / zu kurze Antworten
    do {
        let t = FaultTransport(); t.openFails = true
        let (c, hot) = makeController(t)
        hot.callback?(true)
        spin(0.6)
        check("Open fehlgeschlagen: bleibt getrennt, nichts gesendet", c.connection == .disconnected && t.totalRequests == 0)
        hot.callback?(false)
        let t2 = FaultTransport(); t2.shortGets = true
        let (c2, hot2) = makeController(t2)
        hot2.callback?(true)
        spin(0.8)
        check("Zu kurze GET-Daten: kein Absturz", true)
        _ = c2
        hot2.callback?(false)
        spin(0.1)
    }

    // 6b. Nachtrag 5: Lautstaerke merken, Cap "Aus", iD-Taste
    do {
        // rememberVolume aus: kein Fade, nie ein SET ueber -128 dB auf Monitor/Kopfhoerer-Lautstaerke
        let t = LoggingTransport()
        let (c, hot) = makeController(t) { $0.restore.rememberVolume = false; $0.monitor.volumeDB = -20 }
        hot.callback?(true)
        spin(2.0, until: { c.connection == .connected })
        spin(0.8)
        let vols = t.sent.filter { $0.control == ID14.Monitor.volume || $0.control.unit == 0x0A && $0.control.cs == 0x02 }
        check("rememberVolume aus: verbunden, Push lief", c.connection == .connected && t.sent.count > 100)
        check("rememberVolume aus: nur -128 dB auf Monitor und Kopfhoerer-Lautstaerke",
              !vols.isEmpty && vols.allSatisfy { DB.decode($0.data) == DB.minimum }, "\(vols)")
        check("rememberVolume aus: kein Fade, gespeicherter Wert bleibt", !c.isFading && c.state.monitor.volumeDB == -20)
        // setIDKey(.dim) -> 05 00 an 0x36/0x10
        c.setIDKey(.dim)
        spin(0.3)
        let key = t.sent.last { $0.control == ID14.Monitor.functionKeys }
        check("setIDKey(.dim) sendet 05 00 an 0x36/0x10", key?.data == [0x05, 0x00] && c.state.monitor.idKey == .dim, "\(String(describing: key))")
        hot.callback?(false)
        spin(0.1)
    }
    do {
        // Cap "Aus": Fade geht auf den gemerkten Wert (-12 dB), ohne Begrenzung
        let t = LoggingTransport()
        let (c, hot) = makeController(t) {
            $0.restore.monitorCapDB = 0; $0.monitor.volumeDB = -12; $0.restore.fadeSeconds = 0.3
        }
        hot.callback?(true)
        spin(3.0, until: { c.connection == .connected && !c.isFading && t.sent.count > 100 })
        spin(0.3)
        let mon = t.sent.filter { $0.control == ID14.Monitor.volume }.map { DB.decode($0.data) }
        check("Cap Aus: Fade endet auf gemerktem Wert -12 dB", abs((mon.last ?? 0) + 12) < 0.01, "\(mon.suffix(3))")
        check("Cap Aus: kein Schritt ueber dem gemerkten Wert", mon.allSatisfy { $0 <= -12 + 0.01 })
        hot.callback?(false)
        spin(0.1)
        // Gegenprobe: Cap -30 begrenzt
        let t2 = LoggingTransport()
        let (c2, hot2) = makeController(t2) { $0.restore.monitorCapDB = -30; $0.monitor.volumeDB = -12 }
        hot2.callback?(true)
        spin(3.0, until: { c2.connection == .connected && !c2.isFading && t2.sent.count > 100 })
        spin(0.3)
        let mon2 = t2.sent.filter { $0.control == ID14.Monitor.volume }.map { DB.decode($0.data) }
        check("Cap -30: Fade endet auf -30 dB", abs((mon2.last ?? 0) + 30) < 0.01, "\(mon2.suffix(3))")
        hot2.callback?(false)
        spin(0.1)
    }

    // 6c. Talkback (Nachtrag 6)
    do {
        let tb = MixerMath.sendDB(MixSend(volumeDB: 0, pan: 0.5), cut: false)   // Pan-Gesetz: Mitte ca. -6 dB je Seite
        let tbL = DB.encode(tb.left), tbR = DB.encode(tb.right)
        func sendsFor(_ cmds: ArraySlice<SetCommand>, input: Int, output: Int) -> [SetCommand] {
            cmds.filter { $0.control == ID14.mixerSend(input: input, output: output) }
        }
        let t = LoggingTransport()
        let (c, hot) = makeController(t) { s in
            s.inputs[0].mixes[1] = MixSend(volumeDB: -128, pan: 0.5)    // Cue gespeichert aus
            s.inputs[0].mixes[0] = MixSend(volumeDB: -9, pan: 0.5)      // Monitor-Mix
        }
        hot.callback?(true)
        spin(3.0, until: { c.connection == .connected && !c.isFading && t.sent.count > 100 })
        spin(0.2)
        let before = t.sent.count
        t.inner.markNow()
        t.triggerTalkback(true)
        spin(1.0, until: { c.state.monitor.talkback })
        spin(0.3)
        var tail = t.sent.suffix(from: before)
        check("Talkback an: Zustand merkt es", c.state.monitor.talkback)
        check("Talkback an (Mic 1): Kopfhoerer-Mix Ausgang 2/3 auf Talkback-Pegel (0 dB, Pan Mitte)",
              sendsFor(tail, input: 0, output: 2).last?.data == tbL && sendsFor(tail, input: 0, output: 3).last?.data == tbR)
        check("Talkback an: Monitor-Mix (Ausgang 0/1) unveraendert",
              sendsFor(tail, input: 0, output: 0).isEmpty && sendsFor(tail, input: 0, output: 1).isEmpty)
        check("Talkback an: gespeicherter Zustand unveraendert", c.state.inputs[0].mixes[1].volumeDB == -128)
        let beforeOff = t.sent.count
        t.triggerTalkback(false)
        spin(1.0, until: { !c.state.monitor.talkback })
        spin(0.3)
        tail = t.sent.suffix(from: beforeOff)
        check("Talkback aus: Kopfhoerer-Mix wieder -128 dB",
              sendsFor(tail, input: 0, output: 2).last?.data == [0x00, 0x80] && sendsFor(tail, input: 0, output: 3).last?.data == [0x00, 0x80])
        check("Talkback aus: Monitor-Mix weiter unberuehrt", sendsFor(tail, input: 0, output: 0).isEmpty)
        hot.callback?(false)
        spin(0.1)
    }
    do {
        // Mac-Quelle: Bruecke starten/stoppen, Eingang 15 im Kopfhoerer-Mix
        let t = LoggingTransport()
        let bridge = FakeBridge()
        let (c, hot) = makeController(t, bridge: bridge) { $0.monitor.talkbackSource = .mac }
        hot.callback?(true)
        spin(3.0, until: { c.connection == .connected && !c.isFading && t.sent.count > 100 })
        spin(0.2)
        let before = t.sent.count
        let startsBefore = bridge.starts
        t.triggerTalkback(true)
        spin(1.0, until: { bridge.starts > startsBefore })
        spin(0.3)
        let tail = t.sent.suffix(from: before)
        check("Talkback Mac an: Bruecke gestartet", bridge.starts == startsBefore + 1)
        check("Talkback Mac an: DAW 6 im Kopfhoerer-Mix auf Talkback-Pegel, im Monitor-Mix -128",
              tail.last { $0.control == ID14.mixerSend(input: 15, output: 2) }?.data == DB.encode(MixerMath.sendDB(MixSend(volumeDB: 0, pan: 0.5), cut: false).left)
              && tail.last { $0.control == ID14.mixerSend(input: 15, output: 0) }?.data == [0x00, 0x80])
        let stopsBefore = bridge.stops
        t.triggerTalkback(false)
        spin(1.0, until: { bridge.stops > stopsBefore })
        check("Talkback Mac aus: Bruecke gestoppt", bridge.stops > stopsBefore)
        // Abziehen waehrend Talkback stoppt die Bruecke ebenfalls
        t.triggerTalkback(true)
        spin(1.0, until: { bridge.starts == startsBefore + 2 })
        let stops2 = bridge.stops
        hot.callback?(false)
        spin(0.2)
        check("Talkback: Abziehen stoppt die Bruecke", bridge.stops > stops2 && !c.state.monitor.talkback)
    }

    // 6d. Tastenbelegung wechseln setzt Talkback/Dim/Mono/Alt zurueck, Cut bleibt
    do {
        let t = LoggingTransport()
        let bridge = FakeBridge()
        let (c, hot) = makeController(t, bridge: bridge) { $0.monitor.talkbackSource = .mac; $0.monitor.cut = true }
        hot.callback?(true)
        spin(3.0, until: { c.connection == .connected && !c.isFading && t.sent.count > 100 })
        spin(0.2)
        t.triggerTalkback(true)
        spin(1.0, until: { bridge.starts == 1 })
        c.setDim(true); c.setMono(true); c.setSpeakerAlt(true)
        spin(0.2)
        let before = t.sent.count
        let stops = bridge.stops
        c.setIDKey(.dim)
        spin(0.4)
        let tail = Array(t.sent.suffix(from: before))
        let ctl = tail.map { $0.control }
        func idx(_ c: ID14.Control) -> Int? { ctl.lastIndex(of: c) }
        let reset = [ID14.Monitor.talkback, ID14.Monitor.dim, ID14.Monitor.mono, ID14.Monitor.speakerSelect]
        check("Tastenwechsel: SETs Talkback/Dim/Mono/Speaker = 0",
              reset.allSatisfy { r in tail.last { $0.control == r }?.data == [0] }, "\(tail)")
        check("Tastenwechsel: functionKeys = 05 00 zuletzt",
              tail.last?.control == ID14.Monitor.functionKeys && tail.last?.data == [0x05, 0x00])
        check("Tastenwechsel: Reset vor der neuen Belegung",
              reset.allSatisfy { r in (idx(r) ?? Int.max) < (idx(ID14.Monitor.functionKeys) ?? -1) })
        check("Tastenwechsel: Zustand zurueckgesetzt, Cut unveraendert",
              !c.state.monitor.talkback && !c.state.monitor.dim && !c.state.monitor.mono
              && c.state.monitor.speakerSelect == 0 && c.state.monitor.cut && c.state.monitor.idKey == .dim)
        check("Tastenwechsel: Mac-Bruecke gestoppt", bridge.stops > stops)
        check("Tastenwechsel: kein Cut-SET", !tail.contains { $0.control == ID14.Monitor.cut })
        // gleicher Wert zaehlt ebenfalls
        c.setDim(true)
        spin(0.1)
        let n2 = t.sent.count
        c.setIDKey(.dim)
        spin(0.3)
        check("Tastenwechsel auf denselben Wert setzt ebenfalls zurueck", !c.state.monitor.dim && t.sent.count >= n2 + 5)
        hot.callback?(false)
        spin(0.1)
    }

    // 6e. Notify-Intervall (reine Funktion)
    do {
        func iv(_ tk: Bool, _ pv: Bool, _ f: Bool, _ b: Bool) -> Int {
            DeviceController.notifyInterval(talkbackKey: tk, panelVisible: pv, fading: f, burstActive: b)
        }
        check("Notify-Intervall: Leerlauf 5000 ms", iv(false, false, false, false) == 5000)
        check("Notify-Intervall: iD-Taste Talkback 100 ms (auch gegen alles andere)",
              [iv(true, false, false, false), iv(true, true, true, true), iv(true, false, true, true)].allSatisfy { $0 == 100 })
        check("Notify-Intervall: Panel sichtbar 100 ms", iv(false, true, false, false) == 100 && iv(false, true, true, true) == 100)
        check("Notify-Intervall: Fade 200 ms", iv(false, false, true, false) == 200)
        check("Notify-Intervall: Burst 200 ms", iv(false, false, false, true) == 200)
        check("Notify-Intervall: nach dem Burst wieder 5000 ms", iv(false, false, false, false) == 5000)
    }

    // 6f. iD-Taste "Stumm" mit Kopfhoerer-Beteiligung
    do {
        func phonesMutes(_ t: LoggingTransport) -> [SetCommand] { t.sent.filter { $0.control.unit == 0x0A && $0.control.cs == 0x01 } }
        check("needsFastNotify: Stumm/Monitor aus, Stumm/beide an, Talkback an",
              { var m = MonitorState(); m.idKey = .cut; let a = !m.needsFastNotify
                m.muteTarget = .both; let b = m.needsFastNotify
                m.idKey = .talkback; return a && b && m.needsFastNotify }())
        // beide: Taste stummt den Monitor, die App zieht die Kopfhoerer nach
        let t = LoggingTransport()
        let (c, hot) = makeController(t) { $0.monitor.idKey = .cut; $0.monitor.muteTarget = .both; $0.restore.rememberVolume = false }
        hot.callback?(true)
        spin(2.0, until: { c.connection == .connected })
        spin(0.8)
        let before = phonesMutes(t).count
        t.pressCut(true)
        spin(1.0, until: { c.state.monitor.phonesCut })
        check("Stumm/beide: Kopfhoerer werden mitgestummt", c.state.monitor.cut && c.state.monitor.phonesCut && phonesMutes(t).count > before)
        hot.callback?(false)
        spin(0.1)
        // nur Kopfhoerer: Monitor wird sofort wieder freigegeben, Kopfhoerer stumm
        let t2 = LoggingTransport()
        let (c2, hot2) = makeController(t2) { $0.monitor.idKey = .cut; $0.monitor.muteTarget = .headphones; $0.restore.rememberVolume = false }
        hot2.callback?(true)
        spin(2.0, until: { c2.connection == .connected })
        spin(0.8)
        t2.pressCut(true)
        spin(1.0, until: { c2.state.monitor.phonesCut })
        check("Stumm/Kopfhoerer: Kopfhoerer stumm, Monitor nicht stumm", c2.state.monitor.phonesCut && !c2.state.monitor.cut)
        check("Stumm/Kopfhoerer: Monitor-Cut wird auf 0 zurueckgesetzt", t2.sent.contains { $0.control == ID14.Monitor.cut && $0.data == [0] })
        hot2.callback?(false)
        spin(0.1)
        // nur Monitor: Kopfhoerer bleiben unberuehrt
        let t3 = LoggingTransport()
        let (c3, hot3) = makeController(t3) { $0.monitor.idKey = .cut; $0.restore.rememberVolume = false }
        hot3.callback?(true)
        spin(2.0, until: { c3.connection == .connected })
        spin(0.8)
        t3.pressCut(true)
        spin(0.6)
        check("Stumm/Monitor: Kopfhoerer bleiben unberuehrt", !c3.state.monitor.phonesCut)
        hot3.callback?(false)
        spin(0.1)
    }

    // 6f2. Frisches Einstecken: stumme Mixer-Sends entfallen (nur wenn das Geraet sie als -128 dB meldet)
    do {
        func mixerSends(_ t: LoggingTransport) -> [SetCommand] { t.sent.filter { $0.control.unit == ID14.mixerSend(input: 0, output: 0).unit } }
        var fresh = fastTiming; fresh.freshPlugMinSeconds = 0
        // a) Geraet leer + frisch: nur nicht stumme Sends, deutlich weniger Befehle
        let t = LoggingTransport(); t.mixerSendsSilent = true
        let (c, hot) = makeController(t, timing: fresh) {
            $0.restore.rememberVolume = false
            $0.inputs[10].mixes[0] = MixSend(volumeDB: 0, pan: 0.5)   // ein hoerbarer Send
        }
        spin(0.05)
        hot.callback?(true)
        spin(2.0, until: { c.connection == .connected })
        spin(0.8)
        let sends = mixerSends(t)
        check("Frisch: nur hoerbare Sends und die zwei Firmware-Standards werden gesendet", sends.count == 4 && sends.contains { $0.control == ID14.mixerSend(input: 0, output: 0) } && sends.contains { $0.control == ID14.mixerSend(input: 1, output: 1) }, "\(sends.count)")
        hot.callback?(false)
        spin(0.1)
        // b) Frisch, aber Geraet meldet etwas anderes als -128: alles senden
        let t2 = LoggingTransport()
        let (c2, hot2) = makeController(t2, timing: fresh) { $0.restore.rememberVolume = false }
        spin(0.05)
        hot2.callback?(true)
        spin(2.0, until: { c2.connection == .connected })
        spin(0.8)
        check("Frisch, Geraet nicht leer: alle 96 Mixer-Sends", mixerSends(t2).count == 96, "\(mixerSends(t2).count)")
        hot2.callback?(false)
        spin(0.1)
        // c) Nicht frisch (App-Start mit angestecktem Geraet): alles senden
        let t3 = LoggingTransport(); t3.mixerSendsSilent = true
        let (c3, hot3) = makeController(t3) { $0.restore.rememberVolume = false }
        hot3.callback?(true)
        spin(2.0, until: { c3.connection == .connected })
        spin(0.8)
        check("Nicht frisch: alle 96 Mixer-Sends", mixerSends(t3).count == 96, "\(mixerSends(t3).count)")
        hot3.callback?(false)
        spin(0.1)
        _ = (c, c2, c3)
    }

    // 6g. Aufwachen
    do {
        let t = LoggingTransport()
        let (c, hot) = makeController(t) { $0.restore.rememberVolume = false }
        hot.callback?(true)
        spin(3.0, until: { c.connection == .connected && t.sent.count > 100 })
        spin(0.3)
        let n1 = t.sent.count
        c.checkAfterWake()                   // Mixausgang normal -> nichts tun
        spin(0.5)
        check("Aufwachen: Geraet ok -> keine neue Anstecksequenz", t.sent.count == n1)
        t.mixOut3 = DB.encode(-128)          // Geraet nach dem Ruhezustand zurueckgesetzt
        let n2 = t.sent.count
        c.checkAfterWake()
        spin(3.0, until: { t.sent.count > n2 + 100 })
        check("Aufwachen: -128 dB auf Kanal 3 -> Wiederherstellung (neuer Push)", t.sent.count > n2 + 100, "\(t.sent.count - n2) SETs")
        hot.callback?(false)
        spin(0.1)
    }

    // 7. Fuzz: beschaedigte state.json
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("id14-fuzz-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let store = StateStore(url: url)
        let base = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(DeviceState()))
        var r = LCG(x: 42)
        var loaded = 0, bad = 0
        for i in 0..<200 {
            var data: Data
            switch i % 10 {
            case 7:  data = Data((0..<(1 + r.int(400))).map { _ in UInt8(truncatingIfNeeded: r.next()) })
            case 8:  let full = try! JSONSerialization.data(withJSONObject: base); data = full.prefix(r.int(full.count))
            case 9:  data = Data("{\"inputs\": NaN, \"mixOutputDB\": [NaN, Infinity]}".utf8)
            default: data = try! JSONSerialization.data(withJSONObject: mutateJSON(base, &r, i % 3 == 0 ? 0.01 : (i % 3 == 1 ? 0.05 : 1)) ?? [:])
            }
            try! data.write(to: url)
            guard let s = store.load() else { continue }
            loaded += 1
            let ok = s.inputs.count == 16 && s.inputs.allSatisfy { $0.mixes.count == 3 }
                && s.mixOutputDB.count == 6 && s.routeHost.count == 12 && s.routeOut.count == 6
                && s.opticalInputMode.count == 4 && s.monitor.functionKeyMode.count == 2
                && s.inputPolarity.count == 2
                && s.mixOutputDB.allSatisfy { $0.isFinite } && s.monitor.volumeDB.isFinite
            if !ok { bad += 1 }
            // und der Plan muss sich ohne Absturz bauen lassen
            _ = PushPlan.fullState(s, monitorVolumeDB: s.monitor.volumeDB, phonesLevelDB: nil, phonesVolumeDB: s.phonesVolumeDB)
        }
        check("Fuzz state.json: 200 Varianten ohne Absturz, Laengen korrekt", bad == 0, "\(bad) fehlerhaft von \(loaded) geladenen")
        check("Fuzz state.json: ein Teil der Varianten ist ladbar", loaded > 20, "geladen: \(loaded)")
    }

    // 8. Fuzz: beschaedigte iD-XML
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("id14-xml-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.xml")
        let baseXML = (try? String(contentsOf: testsDir.appendingPathComponent("state-referenz.xml"), encoding: .utf8)) ?? ""
        // Negative Ganzzahlen enthalten: IDStateImporter prueft jetzt id >= 0 (Fix von Opus).
        let junk = ["NaN", "1e999", "999999", "", "abc", "0.5.5", "\u{0}", "2147483648", "7", "1e-999", "-5", "-2147483649", "-1"]
        var r = LCG(x: 7)
        var parsed = 0
        for i in 0..<200 {
            var chars = Array(baseXML.unicodeScalars)
            switch i % 5 {
            case 0:   // Attributwerte ersetzen
                var text = baseXML
                for _ in 0..<(1 + r.int(30)) {
                    let parts = text.components(separatedBy: "=\"")
                    guard parts.count > 1 else { break }
                    let k = 1 + r.int(parts.count - 1)
                    var np = parts
                    if let q = np[k].firstIndex(of: "\"") { np[k] = junk[r.int(junk.count)] + np[k][q...] }
                    text = np.joined(separator: "=\"")
                }
                try? text.write(to: url, atomically: true, encoding: .utf8)
            case 1:   // abgeschnitten
                try? String(String.UnicodeScalarView(chars.prefix(r.int(chars.count)))).write(to: url, atomically: true, encoding: .utf8)
            case 2:   // Stuecke loeschen
                for _ in 0..<(1 + r.int(5)) where !chars.isEmpty {
                    let a = r.int(chars.count), b = min(chars.count, a + r.int(200))
                    chars.removeSubrange(a..<b)
                }
                try? String(String.UnicodeScalarView(chars)).write(to: url, atomically: true, encoding: .utf8)
            case 3:   // Zufallsbytes
                try? Data((0..<(1 + r.int(500))).map { _ in UInt8(truncatingIfNeeded: r.next()) }).write(to: url)
            default:  // Zeichen vertauschen
                for _ in 0..<(1 + r.int(40)) where !chars.isEmpty { chars[r.int(chars.count)] = Unicode.Scalar(UInt8(33 + r.int(90))) }
                try? String(String.UnicodeScalarView(chars)).write(to: url, atomically: true, encoding: .utf8)
            }
            if let s = try? IDStateImporter.load(from: url) {
                parsed += 1
                let c = s.sanitized()
                _ = PushPlan.fullState(c, monitorVolumeDB: nil)
            }
        }
        check("Fuzz iD-XML: 200 Varianten ohne Absturz", true, "geparst: \(parsed)")
    }
}
