// DeviceController.swift – Steuerung (P4). Alle Transport-Aufrufe laufen auf der seriellen USB-Queue.
// Aufbau: Der @MainActor-Controller haelt UI-Zustand; USBWorker (nur Queue) macht Hotplug-Folgen,
// Polling, Fade und gedrosseltes Senden. Rueckmeldungen kommen als DeviceEvent per Main-Queue.
import AppKit
import Foundation
import os

// MARK: - Ereignisse Worker -> Controller

private enum MonitorField: Sendable {
    case talkback(Bool), phonesCut(Bool), volume(Double), dim(Bool), cut(Bool), mono(Bool), speaker(UInt8), polarity(Bool), dimAttenuation(Double)
}

private enum DeviceEvent: Sendable {
    case opened(passive: Bool, fading: Bool)
    case openFailed
    case unresponsive
    case monitor(MonitorField)
    case userOverrodeVolume(Double)
    case fadeFinished(monitor: Double?, phones: Double?)
    case meter([Double])
    case phonesChangedOnDevice
    case wakeReset
}

/// Zeitparameter. Standardwerte = echter Betrieb; Tests setzen kurze Werte.
struct DeviceTiming: Sendable {
    var attachDelay = 1.5                 // macOS richtet das Geraet noch ein (Test: 3,0 -> 2,0 -> 1,5)
    var openRetryMS = 500
    var readyIntervalMS = 100
    var readyTimeout = 10.0
    var pushPauseUS: UInt32 = 10_000      // Pause zwischen SETs
    var notifyFastMS = 100                // iD-Taste auf Talkback oder Panel sichtbar
    var notifyActiveMS = 200              // Fade, Burst nach Meldung, Bereitschaft fertig
    var notifyIdleMS = 5000               // Leerlauf
    var burstSeconds = 3.0                // Burst-Fenster nach der letzten Meldung
    var wakeDelay = 3.0                   // Pruefung nach dem Aufwachen
    var meterMS = 50    // 20 Hz bei offenem Panel
    /// Ein Anstecken frueher als so viele Sekunden nach dem App-Start gilt als "Geraet war schon da" (kein echtes Einstecken).
    var freshPlugMinSeconds = 2.0
    static let standard = DeviceTiming()
}

/// Thread-sichere Kopie des Zustands, damit der Worker den aktuellen Stand lesen kann.
private final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DeviceState
    init(_ v: DeviceState) { value = v }
    func get() -> DeviceState { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: DeviceState) { lock.lock(); value = v; lock.unlock() }
}

// MARK: - Worker (Queue-Seite)

private final class USBWorker: @unchecked Sendable {
    /// Zwischen Threads geteilte Flags (unter Lock).
    private struct Flags {
        var generation = 0
        var passive = false
        var monitorFadeActive = false
        var phonesFadeActive = false
        var metering = false
        var talkbackKey = false
        /// Echtes Einstecken: Das Geraet ist leer (alle Sends -128 dB), stumme Sends muessen nicht gesendet werden.
        var freshPlug = false
    }

    private struct FadeRun {
        var index = 0
        let steps: Int
        let monitorTarget: Double
        let phonesTarget: Double
        let monitorDirect: Bool
        let phonesDirect: Bool
        var monitorWritten: Double = DB.minimum
        var monitorDone = false
        var phonesDone = false
        var monitorOverridden = false
    }

    let queue = DispatchQueue(label: "app.levelid.usb", qos: .utility)   // Energiesparkerne
    private let transport: DeviceTransport
    private let stateBox: StateBox
    private let timing: DeviceTiming
    private let log = Logger(subsystem: "app.levelid", category: "device")
    private let lock = NSLock()
    private var flags = Flags()
    private var sink: (@Sendable (DeviceEvent) -> Void)?

    // Nur auf der Queue
    private var pending: [ID14.Control: SetCommand] = [:]
    private var pendingOrder: [ID14.Control] = []
    private var lastSent: [ID14.Control: DispatchTime] = [:]
    private var flushScheduled = false
    private var notifyTimer: DispatchSourceTimer?
    private var meterTimer: DispatchSourceTimer?
    private var fadeTimer: DispatchSourceTimer?
    private var fade: FadeRun?
    private var consecutiveErrors = 0
    private var notifyIntervalMS = 0
    private var burstUntil = DispatchTime.now()

    private static let minSendGapNS: UInt64 = 16_000_000      // ~60 Hz pro Control
    private static let echoSuppressNS: UInt64 = 300_000_000   // eigene Sets nicht zurueckspiegeln
    private static let readyNeeded = 5                       // GETs in Folge
    private static let pushCheckEvery = 16                   // Kontroll-GET nach n Befehlen
    private static let maxConsecutiveErrors = 3
    private static let fadeSteps = 30
    private static let fadeFloorDB = -60.0
    private static let userTurnThresholdDB = 0.05

    init(transport: DeviceTransport, stateBox: StateBox, timing: DeviceTiming) {
        self.transport = transport
        self.stateBox = stateBox
        self.timing = timing
    }

    func setSink(_ s: @escaping @Sendable (DeviceEvent) -> Void) { locked { _ in sink = s } }

    // MARK: Flags

    @discardableResult
    private func locked<T>(_ f: (inout Flags) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return f(&flags)
    }

    private func emit(_ e: DeviceEvent) {
        lock.lock(); let s = sink; lock.unlock()
        s?(e)
    }

    private var isPassive: Bool { locked { $0.passive } }
    private func isCurrent(_ gen: Int) -> Bool { locked { $0.generation == gen } }

    // MARK: Von beliebigen Threads aufrufbar

    /// Beim Beenden: laufende Fades/Pushes stoppen (Generation) und Timer abbauen.
    func stopForTermination() {
        locked { f in
            f.generation += 1
            f.monitorFadeActive = false
            f.phonesFadeActive = false
        }
        queue.async { [self] in stopTimers() }
    }

    func setPassiveFlag(_ p: Bool) { locked { $0.passive = p } }

    func setMetering(_ on: Bool) {
        locked { $0.metering = on }
        queue.async { [self] in updateMeterTimer(); reevaluateNotify() }
    }

    /// Nach dem Aufwachen: Kopfhoerer-Mixausgang (FU 0x0C Kanal 3) lesen. -128 dB trotz gespeichertem Pegel
    /// heisst: Geraet wurde zurueckgesetzt.
    func wakeCheck(expectSound: Bool) {
        queue.async { [self] in
            guard expectSound, transport.isOpen else { return }
            guard let b = cur(ID14.mixOutputVolume(channel: 3)), b.count >= 2 else { return }   // Fehler: Gesundheitsregel
            if DB.decode(b) <= DB.minimum + 0.01 {
                Diag.event("Aufwachen: Geraet zurueckgesetzt -> Wiederherstellung")
                emit(.wakeReset)
            } else {
                Diag.event("Aufwachen: Geraet ok")
            }
        }
    }

    /// Anstecksequenz neu durchlaufen: Generation erhoehen, Transport schliessen, attach().
    func reconnect() {
        detach()
        attach()
    }

    /// iD-Taste auf Talkback? (Notify-Intervall 100 ms)
    func setTalkbackKey(_ on: Bool) {
        locked { $0.talkbackKey = on }
        queue.async { [self] in reevaluateNotify() }
    }

    /// Fade-Besitz abgeben (Nutzer hat selbst gesetzt). Der naechste Fade-Schritt beendet den Fade.
    func cancelFades(monitor: Bool, phones: Bool) {
        locked {
            if monitor { $0.monitorFadeActive = false }
            if phones { $0.phonesFadeActive = false }
        }
    }

    /// Geraet wurde angesteckt: nach attachDelay oeffnen, Bereitschaft pruefen, gedrosselt pushen, einblenden.
    func attach(freshPlug: Bool = false) {
        Diag.event(freshPlug ? "attach (frisch)" : "attach")
        let gen = locked { f -> Int in
            f.generation += 1
            f.freshPlug = freshPlug
            f.monitorFadeActive = false
            f.phonesFadeActive = false
            return f.generation
        }
        queue.asyncAfter(deadline: .now() + timing.attachDelay, qos: .userInitiated) { [self] in openAttempt(gen: gen, tries: 5) }
    }

    /// Geraet abgezogen: Generation erhoehen (stoppt alte Fades sofort), Timer stoppen, schliessen.
    func detach() {
        Diag.event("detach")
        locked { f in
            f.generation += 1
            f.monitorFadeActive = false
            f.phonesFadeActive = false
        }
        queue.async { [self] in
            stopTimers()
            pending.removeAll(); pendingOrder.removeAll(); lastSent.removeAll()
            transport.close()
        }
    }

    /// Wechsel verbunden -> passiv: Fade und anstehende Sends verwerfen, Zustand lesen.
    func enterPassiveWork() {
        cancelFades(monitor: true, phones: true)
        queue.async { [self] in
            stopFadeTimer()
            pending.removeAll(); pendingOrder.removeAll()
            refreshMonitor()
        }
    }

    /// Wechsel passiv -> verbunden: aktuelle Lautstaerke lesen, vollen Zustand ohne Fade pushen.
    func leavePassiveWork() {
        queue.async(qos: .userInitiated) { [self] in pushFullFromDevice(gen: locked { $0.generation }) }
    }

    /// Voller Push (z. B. nach Import), ohne Fade.
    func pushFull() {
        cancelFades(monitor: true, phones: true)
        queue.async { [self] in
            stopFadeTimer()
            pushFullFromDevice(gen: locked { $0.generation })
        }
    }

    func enqueue(_ cmds: [SetCommand]) {
        queue.async(qos: .userInitiated) { [self] in
            for c in cmds {
                if pending[c.control] == nil { pendingOrder.append(c.control) }
                pending[c.control] = c
            }
            flush()
        }
    }

    // MARK: Nur Queue

    private func openAttempt(gen: Int, tries: Int) {
        guard isCurrent(gen) else { return }
        if transport.open() {
            log.info("Geraet geoeffnet, warte auf Bereitschaft")
            consecutiveErrors = 0
            let deadline = DispatchTime.now() + timing.readyTimeout
            readyStep(gen: gen, successes: 0, deadline: deadline)
        } else if tries > 1 {
            queue.asyncAfter(deadline: .now() + .milliseconds(timing.openRetryMS)) { [self] in
                openAttempt(gen: gen, tries: tries - 1)
            }
        } else {
            log.error("Geraet konnte nicht geoeffnet werden")
            emit(.openFailed)
        }
    }

    /// Bereitschaft: 5 erfolgreiche GETs in Folge (100 ms Abstand), hoechstens 10 s. Nichts wird gesendet.
    private func readyStep(gen: Int, successes: Int, deadline: DispatchTime) {
        guard isCurrent(gen), transport.isOpen else { return }
        let ok = transport.getCur(ID14.Monitor.volume) != nil
        let n = ok ? successes + 1 : 0
        if n >= Self.readyNeeded {
            afterReady(gen: gen)
        } else if DispatchTime.now() > deadline {
            log.error("Geraet wird nicht bereit, gebe auf")
            abortConnection()
        } else {
            queue.asyncAfter(deadline: .now() + .milliseconds(timing.readyIntervalMS)) { [self] in
                readyStep(gen: gen, successes: n, deadline: deadline)
            }
        }
    }

    private func afterReady(gen: Int) {
        Diag.event("bereit, Push startet (passiv=\(isPassive))")
        guard isCurrent(gen), transport.isOpen else { return }
        var passive = isPassive      // erst jetzt lesen: iD kann waehrend der Wartezeit gestartet sein
        var fading = false
        if !passive {
            let s = stateBox.get()
            var plan = PushPlan.fullState(s, monitorVolumeDB: DB.minimum, phonesLevelDB: nil,
                                          phonesVolumeDB: DB.minimum)
            if locked({ $0.freshPlug }) { plan = skippingSilentSends(plan) }
            switch push(plan, gen: gen) {
            case .ok: fading = beginFade(s)
            case .aborted: if !isCurrent(gen) { return }; passive = true
            case .failed: return
            }
        }
        emit(.opened(passive: passive, fading: fading))
        startBurst()   // Bereitschaft/Push fertig: erstmal 200 ms
        // Timer erst nach erfolgreichem Push bzw. nach der Bereitschaftspruefung (Passiv)
        startNotifyTimer()
        updateMeterTimer()
        if passive { refreshMonitor() }
    }

    /// Nach einem echten Einstecken steht jeder Mixer-Send auf -128 dB, ausser Mic 1 -> Ausgang 1 und Mic 2 -> Ausgang 2
    /// (Firmware-Standard 0 dB, am Geraet gemessen). Stumme Sends muessen dann nicht gesendet werden (spart rund 80
    /// von 135 Befehlen); die beiden Ausnahmen werden immer gesendet. Vorher werden sechs der uebersprungenen Sends
    /// gelesen; stimmt eines nicht, wird alles gesendet.
    private func skippingSilentSends(_ plan: [SetCommand]) -> [SetCommand] {
        let sendUnit = ID14.mixerSend(input: 0, output: 0).unit
        let deviceDefaultAudible = [ID14.mixerSend(input: 0, output: 0), ID14.mixerSend(input: 1, output: 1)]
        func isSkippable(_ c: SetCommand) -> Bool {
            c.control.unit == sendUnit && !deviceDefaultAudible.contains(c.control)
                && c.data.count >= 2 && DB.decode(c.data) <= DB.minimum + 0.01
        }
        let silent = plan.filter(isSkippable)
        guard silent.count >= 12 else { return plan }
        let n = silent.count
        for c in [silent[0], silent[n / 5], silent[2 * n / 5], silent[3 * n / 5], silent[4 * n / 5], silent[n - 1]] {
            guard let b = cur(c.control), b.count >= 2, DB.decode(b) <= DB.minimum + 0.01 else {
                Diag.event("Push: Sends nicht auf -128 dB, sende alles")
                return plan
            }
        }
        let kept = plan.filter { !isSkippable($0) }
        Diag.event("Push: \(plan.count - kept.count) stumme Sends uebersprungen")
        return kept
    }

    private enum PushResult { case ok, aborted, failed }

    /// Gedrosselter Push: 5 ms Pause je SET, alle 16 Befehle ein Kontroll-GET. Bei Fehler sofort Schluss.
    private func push(_ cmds: [SetCommand], gen: Int) -> PushResult {
        for (n, c) in cmds.enumerated() {
            guard isCurrent(gen), transport.isOpen else { return .aborted }
            if isPassive { return .aborted }
            if !sendNow(c) {
                guard transport.isOpen else { return .aborted }   // schon durch Gesundheitsregel geschlossen
                log.error("Push abgebrochen: SET fehlgeschlagen bei \(c.description, privacy: .public)")
                abortConnection()
                return .failed
            }
            if timing.pushPauseUS > 0 { usleep(timing.pushPauseUS) }
            if (n + 1) % Self.pushCheckEvery == 0 {
                guard isCurrent(gen), transport.isOpen else { return .aborted }
                if cur(ID14.Monitor.volume) == nil {
                    guard transport.isOpen else { return .aborted }
                    log.error("Push abgebrochen: Kontroll-GET fehlgeschlagen")
                    abortConnection()
                    return .failed
                }
            }
        }
        return .ok
    }

    /// Alles stoppen, Transport schliessen, Fehler melden. Danach keine Requests bis zum naechsten Attach.
    private func abortConnection() {
        Diag.event("abortConnection (Gesundheitsregel/Push-Fehler)")
        guard transport.isOpen else { return }
        stopTimers()
        pending.removeAll(); pendingOrder.removeAll()
        locked { $0.monitorFadeActive = false; $0.phonesFadeActive = false }
        transport.close()
        emit(.unresponsive)
    }

    /// Gesundheitsregel: 3 Fehler in Folge beenden die Verbindung.
    private func noteResult(_ ok: Bool) {
        if ok { consecutiveErrors = 0; return }
        consecutiveErrors += 1
        if consecutiveErrors >= Self.maxConsecutiveErrors {
            log.error("3 Fehler in Folge, Verbindung wird beendet")
            abortConnection()
        }
    }

    /// GET_CUR mit Gesundheitszaehler.
    private func cur(_ c: ID14.Control) -> [UInt8]? {
        guard transport.isOpen else { return nil }
        let r = transport.getCur(c)
        noteResult(r != nil)
        return r
    }

    private func pushFullFromDevice(gen: Int) {
        guard isCurrent(gen), transport.isOpen, !isPassive else { return }
        let s = stateBox.get()
        var vol: Double? = nil
        if let b = cur(ID14.Monitor.volume), b.count >= 2 {
            let v = DB.decode(b)
            vol = v
            emit(.monitor(.volume(v)))
        }
        guard transport.isOpen else { return }
        _ = push(PushPlan.fullState(s, monitorVolumeDB: vol, phonesLevelDB: nil, phonesVolumeDB: nil), gen: gen)
    }

    /// Einzelnes SET. Prueft Passiv-Flag und Transportzustand; Whitelist prueft der Transport.
    @discardableResult
    private func sendNow(_ cmd: SetCommand) -> Bool {
        guard !isPassive, transport.isOpen else { return false }
        let ok = transport.set(cmd)
        lastSent[cmd.control] = .now()
        if !ok { log.error("SET fehlgeschlagen: \(cmd.description, privacy: .public)") }
        noteResult(ok)
        return ok
    }

    /// Gedrosselt senden: je Control hoechstens alle ~16 ms, juengster Wert gewinnt.
    private func flush() {
        guard !pending.isEmpty else { return }
        if isPassive || !transport.isOpen {
            pending.removeAll(); pendingOrder.removeAll()
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        var remaining: [ID14.Control] = []
        for ctl in pendingOrder {
            guard let cmd = pending[ctl] else { continue }
            if let last = lastSent[ctl], now &- last.uptimeNanoseconds < Self.minSendGapNS {
                remaining.append(ctl)
                continue
            }
            pending[ctl] = nil
            sendNow(cmd)
        }
        pendingOrder = remaining
        if !remaining.isEmpty && !flushScheduled {
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + .milliseconds(17)) { [self] in
                flushScheduled = false
                flush()
            }
        }
    }

    // MARK: Timer

    private func makeTimer(first: DispatchTimeInterval, every: DispatchTimeInterval,
                           leeway: DispatchTimeInterval = .milliseconds(40),
                           qos: DispatchQoS = .unspecified,
                           _ handler: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + first, repeating: every, leeway: leeway)
        t.setEventHandler(qos: qos, handler: handler)
        t.resume()
        return t
    }

    private func startNotifyTimer() {
        Diag.event("Notify-Timer start")
        guard notifyTimer == nil, transport.isOpen else { return }
        let ms = desiredNotifyMS()
        notifyIntervalMS = ms
        notifyTimer = makeTimer(first: .milliseconds(ms), every: .milliseconds(ms), leeway: Self.notifyLeeway(ms)) { [weak self] in self?.pollNotify() }
        Diag.event("Notify-Intervall \(ms) ms")
    }

    private static func notifyLeeway(_ ms: Int) -> DispatchTimeInterval {
        .milliseconds(min(max(ms / 10, 5), 500))     // 10 %, min. 5 ms, max. 500 ms
    }

    private func desiredNotifyMS() -> Int {
        let (tk, metering) = locked { ($0.talkbackKey, $0.metering) }
        return DeviceController.notifyInterval(talkbackKey: tk, panelVisible: metering, fading: fade != nil,
                                               burstActive: DispatchTime.now() < burstUntil, timing: timing)
    }

    /// Notify-Timer nur umplanen, wenn sich das Soll-Intervall aendert.
    private func reevaluateNotify() {
        guard let t = notifyTimer else { return }
        let ms = desiredNotifyMS()
        guard ms != notifyIntervalMS else { return }
        notifyIntervalMS = ms
        t.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms), leeway: Self.notifyLeeway(ms))
        Diag.event("Notify-Intervall \(ms) ms")
    }

    private func startBurst() {
        burstUntil = DispatchTime.now() + .milliseconds(Int(timing.burstSeconds * 1000))
    }

    private func updateMeterTimer() {
        let want = locked { $0.metering } && transport.isOpen
        if want, meterTimer == nil {
            Diag.event("Meter-Timer start")
            meterTimer = makeTimer(first: .milliseconds(timing.meterMS), every: .milliseconds(timing.meterMS)) { [weak self] in self?.pollMeter() }
        } else if !want, let t = meterTimer {
            t.cancel(); meterTimer = nil
        }
    }

    private func stopFadeTimer() {
        fadeTimer?.cancel(); fadeTimer = nil
        fade = nil
        reevaluateNotify()
    }

    private func stopTimers() {
        notifyTimer?.cancel(); notifyTimer = nil
        notifyIntervalMS = 0
        meterTimer?.cancel(); meterTimer = nil
        stopFadeTimer()
    }

    // MARK: Meldungen lesen

    private func pollNotify() {
        guard transport.isOpen else { return }
        reevaluateNotify()    // u. a. Ende des Burst-Fensters
        // Jedes Lesen von 0x3E holt die naechste Meldung aus der Warteschlange des Geraets.
        // Fremde Meldungen (z. B. 0x0A vom Kopfhoerer-Regler) ueberspringen statt abbrechen,
        // sonst stauen sich Monitor-Meldungen dahinter (Opus-Review).
        for _ in 0..<8 {
            guard let bytes = cur(ID14.notify), let n = ChangeNotification(bytes: bytes) else { return }
            startBurst()
            reevaluateNotify()
            if n.unit == ID14.Unit.monitor.rawValue {
                readMonitorControl(cs: n.cs)
            } else if n.unit == ID14.Unit.phonesFU.rawValue,
                      ID14.phonesVolumeChannels.map({ $0 - 1 }).contains(n.channelZeroBased) {
                handlePhonesNotification(cs: n.cs)
            }   // alle anderen Meldungen ignorieren
        }
    }

    /// Meldung von FU 0x0A fuer Kanal 5/6 (Kanal-Byte 4/5).
    private func handlePhonesNotification(cs: UInt8) {
        switch cs {
        case ID14.phonesVolume(channel: 5).cs:
            // Echo eigener SETs (Fade/Schieber) ist kein Nutzer-Dreh (Opus-Fix nach Live-Test).
            if ID14.phonesVolumeChannels.contains(where: { recentlySent(ID14.phonesVolume(channel: $0)) }) { return }
            // Wert ist nicht lesbar: nur merken, dass der Regler bewegt wurde; Kopfhoerer-Fade endet.
            locked { $0.phonesFadeActive = false }
            emit(.phonesChangedOnDevice)
        case ID14.phonesMute(channel: 5).cs:
            let c = ID14.phonesMute(channel: 5)
            guard let b = cur(c), b.count >= c.length, !recentlySent(c) else { return }
            emit(.monitor(.phonesCut(b[0] != 0)))
        default: break
        }
    }

    private func recentlySent(_ c: ID14.Control) -> Bool {
        if pending[c] != nil { return true }
        guard let t = lastSent[c] else { return false }
        return DispatchTime.now().uptimeNanoseconds &- t.uptimeNanoseconds < Self.echoSuppressNS
    }

    private func readMonitorControl(cs: UInt8) {
        let control: ID14.Control
        switch cs {
        case ID14.Monitor.volume.cs: control = ID14.Monitor.volume
        case ID14.Monitor.dim.cs: control = ID14.Monitor.dim
        case ID14.Monitor.cut.cs: control = ID14.Monitor.cut
        case ID14.Monitor.mono.cs: control = ID14.Monitor.mono
        case ID14.Monitor.speakerSelect.cs: control = ID14.Monitor.speakerSelect
        case ID14.Monitor.polarity.cs: control = ID14.Monitor.polarity
        case ID14.Monitor.dimAttenuation.cs: control = ID14.Monitor.dimAttenuation
        case ID14.Monitor.talkback.cs: control = ID14.Monitor.talkback
        default: return   // unbekannt: ignorieren
        }
        // Waehrend des Monitor-Fades gehoert der Wert dem Fade (Abbruch-Erkennung im Schritt).
        if control == ID14.Monitor.volume, locked({ $0.monitorFadeActive }) { return }
        guard let b = cur(control), b.count >= control.length else { return }
        // Echo eigener Sets nicht zurueckspiegeln (Slider wuerde springen).
        if control != ID14.Monitor.talkback, recentlySent(control) { return }
        switch control {
        case ID14.Monitor.volume: emit(.monitor(.volume(DB.decode(b))))
        case ID14.Monitor.dim: emit(.monitor(.dim(b[0] != 0)))
        case ID14.Monitor.cut: emit(.monitor(.cut(b[0] != 0)))
        case ID14.Monitor.mono: emit(.monitor(.mono(b[0] != 0)))
        case ID14.Monitor.speakerSelect: emit(.monitor(.speaker(b[0])))
        case ID14.Monitor.polarity: emit(.monitor(.polarity(b[0] != 0)))
        case ID14.Monitor.dimAttenuation: emit(.monitor(.dimAttenuation(DB.decode(b))))
        case ID14.Monitor.talkback: emit(.monitor(.talkback(b[0] != 0)))
        default: break
        }
    }

    /// Alle Monitor-Werte einmal lesen (Passiv-Start).
    private func refreshMonitor() {
        guard transport.isOpen else { return }
        for cs in [ID14.Monitor.volume.cs, ID14.Monitor.dim.cs, ID14.Monitor.cut.cs, ID14.Monitor.mono.cs,
                   ID14.Monitor.speakerSelect.cs, ID14.Monitor.polarity.cs, ID14.Monitor.dimAttenuation.cs,
                   ID14.Monitor.talkback.cs] {
            readMonitorControl(cs: cs)
        }
    }

    private func pollMeter() {
        guard transport.isOpen, locked({ $0.metering }) else { return }
        // Opus: exakt iDs Muster – alle vier Meter-Bloecke nacheinander lesen (0: 32 B, 1: 12 B, 2: 16 B, 3: 6 B).
        // Nur Block 0 wiederholt zu lesen steht im Verdacht, die Firmware haengen zu lassen.
        let raw = transport.get(.mem, unit: ID14.Unit.mixer.rawValue,
                                wValue: ID14.meterInputsOffset, length: ID14.meterInputsLength)
        noteResult(raw != nil)
        guard let b = raw, b.count >= ID14.meterInputsLength else { return }
        for (block, len) in [(UInt16(1), 12), (2, 16), (3, 6)] {
            let r = transport.get(.mem, unit: ID14.Unit.mixer.rawValue, wValue: block, length: len)
            noteResult(r != nil)
            if r == nil { return }
        }
        let vals = (0..<ID14.mixerInputs).map { i in
            DB.meter(UInt16(b[2 * i]) | UInt16(b[2 * i + 1]) << 8)
        }
        emit(.meter(vals))
    }

    // MARK: Fade

    /// Startet den Fade-Timer. Rueckgabe true, wenn ein Fade laeuft.
    private func beginFade(_ s: DeviceState) -> Bool {
        // Ohne "Lautstaerke merken": kein Fade, Monitor und Kopfhoerer bleiben stumm (-128 aus dem Push).
        guard s.restore.rememberVolume else { return false }
        let cap = s.restore.monitorCapDB
        let capped = !s.restore.capIsOff        // Cap >= 0 heisst "Aus": keine Begrenzung
        let mTarget = min(max(capped ? min(s.monitor.volumeDB, cap) : s.monitor.volumeDB, DB.minimum), 0)
        let pRaw = (capped && s.restore.capPhonesToo) ? min(s.phonesVolumeDB, cap) : s.phonesVolumeDB
        let pTarget = min(max(pRaw, DB.minimum), 0)
        let mDirect = mTarget <= Self.fadeFloorDB
        let pDirect = pTarget <= Self.fadeFloorDB
        let seconds = s.restore.fadeSeconds
        let steps = (mDirect && pDirect) || seconds <= 0 ? 1 : Self.fadeSteps
        fade = FadeRun(steps: steps, monitorTarget: mTarget, phonesTarget: pTarget,
                       monitorDirect: mDirect || steps == 1, phonesDirect: pDirect || steps == 1)
        locked { $0.monitorFadeActive = true; $0.phonesFadeActive = true }
        let interval: DispatchTimeInterval = .microseconds(Int(max(0.001, seconds / Double(Self.fadeSteps)) * 1_000_000))
        reevaluateNotify()
        fadeTimer?.cancel()
        fadeTimer = makeTimer(first: .milliseconds(0), every: interval, leeway: .milliseconds(5), qos: .userInitiated) { [weak self] in self?.fadeStep() }
        return true
    }

    private func fadeValue(index i: Int, steps: Int, target: Double, direct: Bool) -> Double {
        if direct { return target }
        return Self.fadeFloorDB + (target - Self.fadeFloorDB) * Double(i) / Double(steps - 1)
    }

    private func fadeStep() {
        guard var f = fade else { stopFadeTimer(); return }
        let (passive, mActive, pActive) = locked { ($0.passive, $0.monitorFadeActive, $0.phonesFadeActive) }
        guard transport.isOpen, !passive else { stopFadeTimer(); return }
        defer { if !transport.isOpen { stopFadeTimer() } }

        var monitorStillOwned = mActive
        if mActive && !f.monitorDone {
            // Nutzer am Regler? Wert weicht vom zuletzt geschriebenen ab -> Monitor-Fade abbrechen.
            if let b = cur(ID14.Monitor.volume), b.count >= 2,
               abs(DB.decode(b) - f.monitorWritten) > Self.userTurnThresholdDB {
                let cur = DB.decode(b)
                locked { $0.monitorFadeActive = false }
                monitorStillOwned = false
                f.monitorOverridden = true
                f.monitorDone = true
                emit(.userOverrodeVolume(cur))
            } else if !f.monitorDirect || f.index == 0 {
                let v = fadeValue(index: f.index, steps: f.steps, target: f.monitorTarget, direct: f.monitorDirect)
                sendNow(SetCommand(control: ID14.Monitor.volume, data: DB.encode(v)))
                f.monitorWritten = v
                if f.monitorDirect || f.index == f.steps - 1 { f.monitorDone = true }
            }
        }
        if pActive && !f.phonesDone && (!f.phonesDirect || f.index == 0) {
            let v = fadeValue(index: f.index, steps: f.steps, target: f.phonesTarget, direct: f.phonesDirect)
            for ch in ID14.phonesVolumeChannels {
                sendNow(SetCommand(control: ID14.phonesVolume(channel: ch), data: DB.encode(v)))
            }
            if f.phonesDirect || f.index == f.steps - 1 { f.phonesDone = true }
        }
        f.index += 1
        fade = f

        let mFin = !monitorStillOwned || f.monitorDone
        let pFin = !pActive || f.phonesDone
        if (mFin && pFin) || f.index >= f.steps {
            let mResult: Double? = (monitorStillOwned && f.monitorDone && !f.monitorOverridden) ? f.monitorTarget : nil
            let pResult: Double? = (pActive && f.phonesDone) ? f.phonesTarget : nil
            locked { $0.monitorFadeActive = false; $0.phonesFadeActive = false }
            stopFadeTimer()
            emit(.fadeFinished(monitor: mResult, phones: pResult))
        }
    }
}

// MARK: - Controller (Main)

@MainActor
final class DeviceController: ObservableObject {
    enum Connection: Equatable { case disconnected, connected, passive /* Original-iD laeuft */, unresponsive /* Geraet haengt */ }

    @Published private(set) var connection: Connection = .disconnected
    @Published private(set) var state: DeviceState {
        didSet { stateBox.set(state) }
    }
    /// Meter werden nur ueber dieses Objekt veroeffentlicht (nicht ueber den Controller).
    let meters = MeterModel()
    @Published private(set) var isFading = false
    /// Kopfhoerer-Regler am Geraet bewegt (Wert nicht lesbar) – App-Wert evtl. veraltet
    @Published private(set) var phonesChangedOnDevice = false

    var meteringEnabled: Bool = false {
        didSet {
            guard oldValue != meteringEnabled else { return }
            worker.setMetering(meteringEnabled)
            if !meteringEnabled { meters.reset() }
        }
    }

    private let store: StateStore
    private let watch: (@escaping (Bool) -> Void) -> Void
    private var startedAt: TimeInterval = 0
    private let originalAppProbe: () -> Bool
    private let timing: DeviceTiming
    private let bridge: TalkbackBridge
    /// Quelle, fuer die das Talkback-Overlay gerade auf dem Geraet liegt (nil = keins)
    private var appliedTalkback: TalkbackSource?
    private let stateBox: StateBox
    private let worker: USBWorker
    private let log = Logger(subsystem: "app.levelid", category: "device")

    private var started = false
    private var loadedFromStore: Bool
    private var deviceAttached = false
    private var originalAppRunning = false

    init(transport: DeviceTransport, store: StateStore = .default,
         watch: @escaping (@escaping (Bool) -> Void) -> Void, timing: DeviceTiming = .standard,
         originalAppProbe: @escaping () -> Bool = DeviceController.originalAppIsRunning,
         talkbackBridge: TalkbackBridge = NoOpTalkbackBridge()) {
        self.originalAppProbe = originalAppProbe
        self.timing = timing
        self.bridge = talkbackBridge
        self.store = store
        self.watch = watch
        let loaded = store.load()
        loadedFromStore = loaded != nil
        var initial = loaded ?? DeviceState()
        initial.monitor.talkback = false   // Laufzeitwert, nach Neustart immer aus
        state = initial
        stateBox = StateBox(initial)
        worker = USBWorker(transport: transport, stateBox: stateBox, timing: timing)
        worker.setTalkbackKey(initial.monitor.needsFastNotify)
        worker.setSink { event in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
    }

    /// Notify-Intervall in ms; die strengste aktive Regel gewinnt.
    nonisolated static func notifyInterval(talkbackKey: Bool, panelVisible: Bool, fading: Bool, burstActive: Bool,
                                           timing: DeviceTiming = .standard) -> Int {
        if talkbackKey || panelVisible { return timing.notifyFastMS }
        if fading || burstActive { return timing.notifyActiveMS }
        return timing.notifyIdleMS
    }

    /// Laeuft die Original-App? (Standard-Probe, fuer Tests ersetzbar)
    nonisolated static func originalAppIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: ID14.originalAppBundleID).isEmpty
    }

    func start() {
        guard !started else { return }
        started = true
        if !loadedFromStore {
            if let imported = try? IDStateImporter.load(from: IDStateImporter.defaultURL) {
                state = imported
                log.info("Zustand aus iD importiert")
            }
            store.save(state)
        }
        startedAt = ProcessInfo.processInfo.systemUptime
        originalAppRunning = originalAppProbe()
        worker.setPassiveFlag(originalAppRunning)
        observeOriginalApp()
        observeWake()
        // Hotplug nur einmal registrieren; Rueckmeldung kommt auf dem Main-Run-Loop.
        watch { attached in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.handleHotplug(attached) }
            }
        }
    }

    // MARK: Hotplug & Passiv

    private func observeOriginalApp() {
        let nc = NSWorkspace.shared.notificationCenter
        let key = NSWorkspace.applicationUserInfoKey
        let id = ID14.originalAppBundleID
        for (name, running) in [(NSWorkspace.didLaunchApplicationNotification, true),
                                (NSWorkspace.didTerminateApplicationNotification, false)] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let bundle = (note.userInfo?[key] as? NSRunningApplication)?.bundleIdentifier
                guard bundle == id else { return }
                MainActor.assumeIsolated { self?.originalAppChanged(running: running) }
            }
        }
    }

    // MARK: Aufwachen

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleWakeCheck() }
        }
    }

    private func scheduleWakeCheck() {
        let delay = timing.wakeDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.checkAfterWake() }
        }
    }

    /// Pruefung nach dem Aufwachen. Verbunden: Gerät zurueckgesetzt? Dann Wiederherstellung. Unresponsive: einmal neu versuchen.
    func checkAfterWake() {
        guard deviceAttached else { return }
        switch connection {
        case .connected:
            worker.wakeCheck(expectSound: state.mixOutputDB[2] > DB.minimum)
        case .unresponsive:
            Diag.event("Aufwachen: Geraet reagierte nicht -> neuer Versuch")
            resetTalkbackRuntime()
            worker.reconnect()
        default:
            break
        }
    }

    private func originalAppChanged(running: Bool) {
        guard running != originalAppRunning else { return }
        originalAppRunning = running
        worker.setPassiveFlag(running)   // sofort, bevor weitere Sends laufen
        log.info("Original-iD \(running ? "gestartet" : "beendet", privacy: .public)")
        switch connection {
        case .connected where running:
            connection = .passive
            isFading = false
            resetTalkbackRuntime()
            worker.enterPassiveWork()
        case .passive where !running:
            connection = .connected
            resetTalkbackRuntime()   // Push sendet Talkback aus
            worker.leavePassiveWork()
        default: break
        }
    }

    private func handleHotplug(_ attached: Bool) {
        if attached {
            guard !deviceAttached else { return }
            deviceAttached = true
            worker.setPassiveFlag(originalAppRunning)
            // Frisch eingesteckt (nicht schon beim App-Start da): Geraet ist leer, stumme Sends koennen entfallen
            let fresh = ProcessInfo.processInfo.systemUptime - startedAt > timing.freshPlugMinSeconds
            worker.attach(freshPlug: fresh)
        } else {
            guard deviceAttached else { return }
            deviceAttached = false
            connection = .disconnected
            isFading = false
            resetTalkbackRuntime()
            worker.detach()
        }
    }

    // MARK: Ereignisse vom Worker

    private func handle(_ event: DeviceEvent) {
        guard deviceAttached else { return }
        switch event {
        case let .opened(passive, fading):
            connection = passive ? .passive : .connected
            isFading = fading && !passive
            if !passive { resetTalkbackRuntime() }   // Push sendet Talkback aus
            // Passiv-Zustand hat sich waehrend des Oeffnens geaendert: angleichen.
            if passive != originalAppRunning {
                if originalAppRunning { connection = .passive; isFading = false; resetTalkbackRuntime(); worker.enterPassiveWork() }
                else { connection = .connected; resetTalkbackRuntime(); worker.leavePassiveWork() }
            }
        case .openFailed:
            // Oeffnen/Push gescheitert oder Gesundheitsregel: Ruhe bis zum naechsten Attach
            connection = .disconnected
            isFading = false
            resetTalkbackRuntime()
        case .unresponsive:
            // Geraet antwortet nicht mehr: Ruhe bis zum naechsten Attach, Setter nur lokal
            connection = .unresponsive
            isFading = false
            resetTalkbackRuntime()
        case let .monitor(field):
            apply(field)
        case let .userOverrodeVolume(v):
            if state.monitor.volumeDB != v { state.monitor.volumeDB = v }
            store.scheduleSave(state)
        case let .fadeFinished(m, p):
            if let m { state.monitor.volumeDB = m }
            _ = p   // phonesVolumeDB aendert sich nie durch den Fade
            isFading = false
            store.save(state)
        case let .meter(values):
            applyMeter(values)
        case .phonesChangedOnDevice:
            phonesChangedOnDevice = true
        case .wakeReset:
            resetTalkbackRuntime()
            worker.reconnect()
        }
    }

    private func apply(_ field: MonitorField) {
        var m = state.monitor
        switch field {
        case let .volume(v): m.volumeDB = v
        case let .dim(b): m.dim = b
        case let .cut(b): m.cut = b
        case let .mono(b): m.mono = b
        case let .speaker(s): m.speakerSelect = s
        case let .polarity(b): m.polarity = b
        case let .dimAttenuation(d): m.dimAttenuationDB = d
        case let .phonesCut(b): m.phonesCut = b
        case let .talkback(b): m.talkback = b
        }
        guard m != state.monitor else { return }
        let talkbackChanged = m.talkback != state.monitor.talkback
        let cutChanged = m.cut != state.monitor.cut
        state.monitor = m
        if talkbackChanged { applyTalkback(on: m.talkback) }
        if cutChanged { mirrorMuteKey(cut: m.cut) }
        store.scheduleSave(state)
    }

    /// iD-Taste "Stumm" mit Kopfhoerer-Beteiligung: Die Firmware stummt immer nur den Monitor; die App zieht den
    /// Kopfhoerer-Mute nach (beide) bzw. gibt den Monitor sofort wieder frei und schaltet nur die Kopfhoerer um.
    private func mirrorMuteKey(cut: Bool) {
        guard state.monitor.idKey == .cut else { return }
        switch state.monitor.muteTarget {
        case .monitor:
            break
        case .both:
            if state.monitor.phonesCut != cut { setPhonesCut(cut) }
        case .headphones:
            guard cut else { return }
            let next = !state.monitor.phonesCut
            setCut(false)
            setPhonesCut(next)
        }
    }

    private func applyMeter(_ values: [Double]) {
        guard meteringEnabled, values.count == ID14.mixerInputs else { return }
        meters.update(inputs: values)
    }

    func clearClip() { meters.clearClip() }

    /// Beim Beenden der App: ausstehende Speicherung sofort ausfuehren, Timer stoppen.
    func prepareForTermination() {
        bridge.stop()
        store.flush()
        worker.stopForTermination()
    }

    // MARK: Setter

    /// Im Passiv-Modus wird nichts geaendert und nichts gesendet.
    private var writable: Bool { connection != .passive }
    private var live: Bool { connection == .connected }

    private func clampVolume(_ db: Double) -> Double { min(max(db, DB.minimum), 0) }

    private func commit(_ cmds: [SetCommand]) {
        if live, !cmds.isEmpty { worker.enqueue(overlaid(cmds)) }
        store.scheduleSave(state)
    }

    func setMonitorVolume(_ db: Double) {
        guard writable else { return }
        let v = clampVolume(db)
        state.monitor.volumeDB = v
        if live { worker.cancelFades(monitor: true, phones: false) }
        commit([SetCommand(control: ID14.Monitor.volume, data: DB.encode(v))])
    }

    func nudgeMonitorVolume(by deltaDB: Double) { setMonitorVolume(state.monitor.volumeDB + deltaDB) }

    func setPhonesLevel(_ db: Double) {
        guard writable else { return }
        let v = clampVolume(db)
        state.phonesLevelDB = v
        if live { worker.cancelFades(monitor: false, phones: true) }
        commit(ID14.phonesLevelChannels.map {
            SetCommand(control: ID14.mixOutputVolume(channel: $0), data: DB.encode(v))
        })
    }

    func setPhonesVolume(_ db: Double) {
        guard writable else { return }
        let v = clampVolume(db)
        state.phonesVolumeDB = v
        phonesChangedOnDevice = false
        if live { worker.cancelFades(monitor: false, phones: true) }
        commit(ID14.phonesVolumeChannels.map {
            SetCommand(control: ID14.phonesVolume(channel: $0), data: DB.encode(v))
        })
    }

    func nudgePhonesVolume(by deltaDB: Double) { setPhonesVolume(state.phonesVolumeDB + deltaDB) }

    func nudgePhonesLevel(by deltaDB: Double) { setPhonesLevel(state.phonesLevelDB + deltaDB) }

    func setDim(_ on: Bool) {
        guard writable else { return }
        state.monitor.dim = on
        commit([SetCommand(control: ID14.Monitor.dim, data: [on ? 1 : 0])])
    }

    func setCut(_ on: Bool) {
        guard writable else { return }
        state.monitor.cut = on
        commit([SetCommand(control: ID14.Monitor.cut, data: [on ? 1 : 0])])
    }

    func setMono(_ on: Bool) {
        guard writable else { return }
        state.monitor.mono = on
        commit([SetCommand(control: ID14.Monitor.mono, data: [on ? 1 : 0])])
    }

    func setSpeakerAlt(_ on: Bool) {
        guard writable else { return }
        state.monitor.speakerSelect = on ? 1 : 0
        commit([SetCommand(control: ID14.Monitor.speakerSelect, data: [on ? 1 : 0])])
    }

    func setPhonesCut(_ on: Bool) {
        guard writable else { return }
        state.monitor.phonesCut = on
        commit(ID14.phonesMuteChannels.map {
            SetCommand(control: ID14.phonesMute(channel: $0), data: [on ? 1 : 0])
        })
    }

    func setInputPolarity(mic: Int, _ on: Bool) {
        guard writable, (1...2).contains(mic), state.inputPolarity.indices.contains(mic - 1) else { return }
        state.inputPolarity[mic - 1] = on
        commit([SetCommand(control: ID14.inputPolarity(mic: mic), data: [on ? 1 : 0])])
    }

    /// Eingaenge, die eine Aenderung betrifft: bei Stereo-Paar (mode 1) auch i+1.
    private func affectedInputs(_ i: Int) -> [Int] {
        if state.inputs[i].mode == 1, i + 1 < state.inputs.count { return [i, i + 1] }
        return [i]
    }

    /// Nur die zwei Sends eines Mixes (Ausgang 2m, 2m+1) aus dem Plan des Eingangs.
    private func sendCommands(inputs: [Int], mix: Int?) -> [SetCommand] {
        var out: [SetCommand] = []
        for i in inputs {
            for c in PushPlan.sends(forInput: i, in: state) {
                if let m = mix {
                    let output = Int(c.control.ch) % ID14.mixerOutputs
                    guard output == 2 * m || output == 2 * m + 1 else { continue }
                }
                out.append(c)
            }
        }
        return out
    }

    private func validSend(input: Int, mix: Int) -> Bool {
        state.inputs.indices.contains(input) && (0..<ID14.mixCount).contains(mix)
            && mix < state.inputs[input].mixes.count
    }

    func setSendVolume(input: Int, mix: Int, db: Double) {
        guard writable, validSend(input: input, mix: mix) else { return }
        let v = min(max(db, DB.minimum), 6.0)
        let targets = affectedInputs(input)
        for i in targets where mix < state.inputs[i].mixes.count { state.inputs[i].mixes[mix].volumeDB = v }
        commit(sendCommands(inputs: targets, mix: mix))
    }

    func setSendPan(input: Int, mix: Int, pan: Double) {
        guard writable, validSend(input: input, mix: mix) else { return }
        state.inputs[input].mixes[mix].pan = min(max(pan, 0), 1)   // Pan bleibt pro Kanal
        commit(sendCommands(inputs: [input], mix: mix))
    }

    /// Cue-Blend Mikrofon/PC fuer Mix 0 (Monitore) oder 1 (Kopfhoerer). Wirkt nur auf Nutzeraktion.
    func setCueBlend(mix: Int, _ value: Double) {
        guard writable, (0...1).contains(mix) else { return }
        state.setCueBlend(mix: mix, value)
        let (mic, pc) = MixerMath.blendDB(state.cueBlend(mix: mix))
        let targets = [ID14.Input.mic1, ID14.Input.mic2, ID14.Input.daw1, ID14.Input.daw2]
        for i in targets where state.inputs.indices.contains(i) && mix < state.inputs[i].mixes.count {
            switch i {
            case ID14.Input.mic1, ID14.Input.mic2:
                state.inputs[i].mixes[mix] = MixSend(volumeDB: mic, pan: 0.5)
            case ID14.Input.daw1:
                state.inputs[i].mixes[mix] = MixSend(volumeDB: pc, pan: 0.0)
            default:
                state.inputs[i].mixes[mix] = MixSend(volumeDB: pc, pan: 1.0)
            }
            state.inputs[i].cut = false
        }
        commit(sendCommands(inputs: targets, mix: mix))
    }

    func setInputCut(input: Int, _ on: Bool) {
        guard writable, state.inputs.indices.contains(input) else { return }
        let targets = affectedInputs(input)
        for i in targets { state.inputs[i].cut = on }
        commit(sendCommands(inputs: targets, mix: nil))
    }

    // MARK: Talkback

    /// Ein Mix-Send (links/rechts) fuer einen Eingang und Mix.
    private func mixSendCommands(input i: Int, mix: Int, send: MixSend, cut: Bool) -> [SetCommand] {
        let (l, r) = MixerMath.sendDB(send, cut: cut)
        return [SetCommand(control: ID14.mixerSend(input: i, output: 2 * mix), data: DB.encode(l)),
                SetCommand(control: ID14.mixerSend(input: i, output: 2 * mix + 1), data: DB.encode(r))]
    }

    /// Temporaeres Overlay nur im Kopfhoerer-Mix (Mix 1): an = 0 dB, aus = gespeicherte Werte.
    /// Der gespeicherte Zustand bleibt unveraendert. Mac-Quelle: Monitor-Mix des Eingangs immer -128.
    private func talkbackCommands(on: Bool, source: TalkbackSource) -> [SetCommand] {
        var out: [SetCommand] = []
        for i in source.mixerInputs where state.inputs.indices.contains(i) && state.inputs[i].mixes.count > 1 {
            if on {
                out += mixSendCommands(input: i, mix: 1, send: MixSend(volumeDB: 0, pan: 0.5), cut: false)
            } else {
                out += mixSendCommands(input: i, mix: 1, send: state.inputs[i].mixes[1], cut: state.inputs[i].cut)
            }
            if source == .mac, on {
                out += mixSendCommands(input: i, mix: 0, send: MixSend(volumeDB: DB.minimum, pan: 0.5), cut: true)
            }
        }
        return out
    }

    /// Waehrend aktivem Overlay behalten die Talkback-Eingaenge im Kopfhoerer-Mix ihre 0 dB,
    /// auch wenn der Nutzer dort am Fader dreht (der Wert landet nur im Zustand).
    private func overlaid(_ cmds: [SetCommand]) -> [SetCommand] {
        guard let src = appliedTalkback else { return cmds }
        let ins = src.mixerInputs
        let on = MixerMath.sendDB(MixSend(volumeDB: 0, pan: 0.5), cut: false)
        return cmds.map { c in
            guard c.control.unit == ID14.Unit.mixer.rawValue else { return c }
            let i = Int(c.control.ch) / ID14.mixerOutputs, o = Int(c.control.ch) % ID14.mixerOutputs
            guard ins.contains(i), o == 2 || o == 3 else { return c }
            return SetCommand(control: c.control, data: DB.encode(o == 2 ? on.left : on.right))
        }
    }

    /// Talkback hat gewechselt (Meldung 0x36 CS 0x07). Nur bei .connected wird gesendet.
    private func applyTalkback(on: Bool) {
        if on, live {
            let src = state.monitor.talkbackSource
            appliedTalkback = src
            worker.enqueue(talkbackCommands(on: true, source: src))
            if src == .mac { bridge.start() }
        } else {
            if let src = appliedTalkback, live { worker.enqueue(talkbackCommands(on: false, source: src)) }
            appliedTalkback = nil
            bridge.stop()
        }
    }

    /// Verbindung weg, Passiv, unresponsive oder neuer Push: Bruecke stoppen, Overlay vergessen, kein USB.
    private func resetTalkbackRuntime() {
        appliedTalkback = nil
        bridge.stop()
        if state.monitor.talkback { state.monitor.talkback = false }
    }

    func setTalkbackSource(_ s: TalkbackSource) {
        state.monitor.talkbackSource = s
        if live, let applied = appliedTalkback, applied != s {
            worker.enqueue(talkbackCommands(on: false, source: applied) + talkbackCommands(on: true, source: s))
            appliedTalkback = s
            if applied == .mac && s != .mac { bridge.stop() }
            if s == .mac && applied != .mac { bridge.start() }
        }
        store.scheduleSave(state)
    }

    // MARK: App-Einstellungen (kein USB, auch im Passiv-Modus erlaubt)

    func setRestoreCap(_ db: Double) {
        state.restore.monitorCapDB = min(max(db, RestorePreferences.capRange.lowerBound),
                                         RestorePreferences.capRange.upperBound)
        state.restore.capPhonesToo = true
        store.scheduleSave(state)
    }

    func setHideIconWhenDisconnected(_ on: Bool) {
        state.ui.hideIconWhenDisconnected = on
        store.scheduleSave(state)
    }

    /// Ziel der iD-Taste in der Belegung "Stumm" (App-Einstellung, kein USB).
    func setMuteTarget(_ t: MuteTarget) {
        state.monitor.muteTarget = t
        worker.setTalkbackKey(state.monitor.needsFastNotify)
        store.scheduleSave(state)
    }

    func setRememberVolume(_ on: Bool) {
        state.restore.rememberVolume = on
        store.scheduleSave(state)
    }

    /// Belegung der iD-Taste (0x36 CS 0x10). Nicht im Passiv-Modus, USB nur bei .connected.
    func setIDKey(_ f: IDKeyFunction) {
        guard writable else { return }
        applyIDKey(f)
    }

    /// iD-Taste aus Sicht des UI (inkl. Mix-Regler, der geraeteseitig auf Mono liegt).
    func setIDKeyChoice(_ c: IDKeyChoice) {
        guard writable else { return }
        applyIDKey(c.deviceFunction)
    }

    private func applyIDKey(_ f: IDKeyFunction) {
        // Jeder Wechsel (auch auf denselben Wert) setzt alles zurueck, was die iD-Taste schalten kann
        // und was es in der App nicht als Bedienelement gibt. Cut/Kopfhoerer-Cut bleiben unberuehrt.
        applyTalkback(on: false)   // Overlay zurueck, Bruecke stoppen (keine Aenderung ohne .connected auf USB)
        state.monitor.talkback = false
        state.monitor.dim = false
        state.monitor.mono = false
        state.monitor.speakerSelect = 0
        state.monitor.idKey = f
        worker.setTalkbackKey(state.monitor.needsFastNotify)
        commit([SetCommand(control: ID14.Monitor.talkback, data: [0]),
                SetCommand(control: ID14.Monitor.dim, data: [0]),
                SetCommand(control: ID14.Monitor.mono, data: [0]),
                SetCommand(control: ID14.Monitor.speakerSelect, data: [0]),
                SetCommand(control: ID14.Monitor.functionKeys, data: f.bytes)])
    }

    func setFadeSeconds(_ s: Double) {
        state.restore.fadeSeconds = min(max(s, 0), 3)
        store.scheduleSave(state)
    }

    func setVolumeStep(_ db: Double) {
        let v = min(max(db, 0.1), 6)
        state.ui.volumeStepDB = v
        state.ui.fineStepDB = v / 5
        store.scheduleSave(state)
    }

    // MARK: Import

    func importFromID() -> Bool {
        do {
            var imported = try IDStateImporter.load(from: IDStateImporter.defaultURL)
            imported.monitor.volumeDB = state.monitor.volumeDB
            imported.restore = state.restore
            imported.ui = state.ui
            imported.monitor.talkbackSourceStored = state.monitor.talkbackSourceStored
            imported.monitor.muteTargetStored = state.monitor.muteTargetStored
            state = imported
            worker.setTalkbackKey(state.monitor.needsFastNotify)
            store.save(state)
            if live {
                worker.pushFull()   // Worker liest die Geraete-Lautstaerke, kein Fade
                if let src = appliedTalkback { worker.enqueue(talkbackCommands(on: true, source: src)) }
            }
            return true
        } catch {
            log.error("Import aus iD fehlgeschlagen: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
