// ProfileTests.swift – Geraeteprofile und harte Schreibsperre (readOnlyBeta), offline.
import Foundation

/// Meldet eine waehlbare PID und zaehlt ALLE Zugriffe, die den Transport erreichen (auch abgelehnte SETs).
final class PIDTransport: DeviceTransport, @unchecked Sendable {
    let inner = LoggingTransport()
    let pid: UInt16
    private let lock = NSLock()
    private var setAttemptCount = 0
    private var getCount = 0
    private var memGetCount = 0
    private var notifyGetCount = 0
    init(pid: UInt16) { self.pid = pid }
    var openedProductID: UInt16 { pid }
    var isOpen: Bool { inner.isOpen }
    var setAttempts: Int { lock.lock(); defer { lock.unlock() }; return setAttemptCount }
    var gets: Int { lock.lock(); defer { lock.unlock() }; return getCount }
    var memGets: Int { lock.lock(); defer { lock.unlock() }; return memGetCount }
    var notifyGets: Int { lock.lock(); defer { lock.unlock() }; return notifyGetCount }
    func open() -> Bool { inner.open() }
    func close() { inner.close() }
    func get(_ request: ID14.Request, unit: UInt8, wValue: UInt16, length: Int) -> [UInt8]? {
        lock.lock()
        getCount += 1
        if request == .mem { memGetCount += 1 }
        if unit == ID14.Unit.notify.rawValue { notifyGetCount += 1 }
        lock.unlock()
        return inner.get(request, unit: unit, wValue: wValue, length: length)
    }
    func set(_ command: SetCommand) -> Bool {
        lock.lock(); setAttemptCount += 1; lock.unlock()
        return inner.set(command)
    }
}

@MainActor func runProfileTests() {
    print("\n-- Geraeteprofile --")
    check("Profil: iD14 MkII 0x0008", DeviceProfile.forProductID(0x0008) == .id14mk2 && DeviceProfile.id14mk2.allowsWrites)
    check("Profil: iD24 0x000D unverified (nur lesen), 2 Preamps, 1 Kopfhoerer",
          DeviceProfile.forProductID(0x000D) == .id24 && !DeviceProfile.id24.allowsWrites
          && DeviceProfile.id24.supportLevel == .unverified && DeviceProfile.id24.statusLabel == "unverified"
          && DeviceProfile.id24.preampCount == 2 && DeviceProfile.id24.headphoneCount == 1)
    check("Profil: Cue-Mix nur iD14/iD24, Label iD44 beta",
          DeviceProfile.id14mk2.showsCueMix && DeviceProfile.id24.showsCueMix && !DeviceProfile.id44.showsCueMix
          && !DeviceProfile.id44mk2.showsCueMix && DeviceProfile.id44.statusLabel == "beta" && DeviceProfile.id14mk2.statusLabel == nil)
    check("Profil: iD44 0x0005 4 Preamps, 2 Kopfhoerer, optisch 2",
          DeviceProfile.forProductID(0x0005) == .id44 && DeviceProfile.id44.preampCount == 4
          && DeviceProfile.id44.headphoneCount == 2 && DeviceProfile.id44.opticalInputs == 2 && !DeviceProfile.id44.allowsWrites)
    check("Profil: iD44 MkII 0x000B", DeviceProfile.forProductID(0x000B) == .id44mk2 && !DeviceProfile.id44mk2.allowsWrites)
    check("Profil: iD4 MkII (0x0009) nicht unterstuetzt", DeviceProfile.forProductID(0x0009) == nil)
    check("Profil: alle PIDs eindeutig, iD14 zuerst",
          Set(DeviceProfile.all.map(\.productID)).count == DeviceProfile.all.count && DeviceProfile.all.first == .id14mk2)

    // Funktionstasten je Geraet
    check("Tasten: iD14 1 Taste, Belegungen unveraendert",
          DeviceProfile.id14mk2.functionKeyCount == 1
          && DeviceProfile.id14mk2.functionKeyModes == [.none, .mono, .cut, .dim, .talkback, .altSpeaker]
          && !DeviceProfile.id14mk2.functionKeyModes.contains(.polarity))
    check("Tasten: iD24 3 Tasten F1-F3, ohne Cut/Dim",
          DeviceProfile.id24.functionKeyCount == 3 && DeviceProfile.id24.functionKeyNames == ["F1", "F2", "F3"]
          && DeviceProfile.id24.functionKeyModes == [.none, .mono, .polarity, .talkback, .altSpeaker])
    check("Tasten: iD44/iD44 MkII 3 Tasten, ohne Cut/Dim/Talkback",
          [DeviceProfile.id44, DeviceProfile.id44mk2].allSatisfy {
              $0.functionKeyCount == 3 && $0.functionKeyModes == [.none, .mono, .polarity, .altSpeaker] })
    check("Tasten: Polaritaet = 03 00, Rundlauf, Titel",
          IDKeyFunction.polarity.bytes == [0x03, 0x00] && IDKeyFunction(bytes: [0x03, 0x00]) == .polarity
          && IDKeyFunction.polarity.title == "Polarity")
    do {
        var s = DeviceState()
        s.monitor.setFunctionKey(1, .polarity)
        s.monitor.setFunctionKey(2, .altSpeaker)
        let r = s.sanitized().monitor
        check("Tasten: F1-F3 bleiben nach sanitized", r.functionKey(0) == .none && r.functionKey(1) == .polarity && r.functionKey(2) == .altSpeaker)
        var bad = DeviceState()
        bad.monitor.functionKeyModesStored = [99, 3]
        let rb = bad.sanitized().monitor
        check("Tasten: sanitized fixiert auf 3, unbekannt -> Aus",
              rb.functionKeyModesStored?.count == 3 && rb.functionKey(0) == .none && rb.functionKey(1) == .polarity && rb.functionKey(2) == .none)
        var pol = DeviceState()
        pol.monitor.idKey = .polarity
        check("Tasten: iD14-Einzeltaste bietet nie Polaritaet (sanitized -> Aus)", pol.sanitized().monitor.idKey == .none)
        check("Tasten: iD14 Auswahl im UI unveraendert", IDKeyChoice.selectable == [.none, .cut, .mono, .altSpeaker, .talkback])
        check("Tasten: Standard alle Aus", DeviceState().monitor.functionKey(0) == .none && DeviceState().monitor.functionKeyModesStored == nil)
    }

    // iD14: unveraendert, schreibt wie bisher
    do {
        let t = PIDTransport(pid: 0x0008)
        let (c, hot) = makeController(t)
        hot.callback?(true)
        spin(3.0, until: { c.connection == .connected && !t.inner.sent.isEmpty })
        spin(0.3)
        check("iD14: Profil iD14, nicht readOnlyBeta, verbunden", c.profile == .id14mk2 && !c.readOnlyBeta && c.connection == .connected)
        check("iD14: Push sendet SETs", !t.inner.sent.isEmpty && t.setAttempts > 0)
        let n = t.inner.sent.count
        c.setCut(true)
        spin(0.3)
        check("iD14: Setter sendet weiterhin", t.inner.sent.count > n && t.inner.sent.contains { $0.control == ID14.Monitor.cut })
        hot.callback?(false); spin(0.1)
    }

    // iD44 (readOnlyBeta): kein einziges SET, Lesen laeuft
    do {
        let t = PIDTransport(pid: 0x0005)
        let (c, hot) = makeController(t)
        c.meteringEnabled = true
        hot.callback?(true)
        spin(3.0, until: { c.connection == .connected })
        check("iD44: Profil erkannt, readOnlyBeta, Verbindung .connected (nicht passiv)",
              c.profile == .id44 && c.readOnlyBeta && c.connection == .connected)
        spin(0.6)
        check("iD44: Anstecken sendet ZERO SETs", t.setAttempts == 0 && t.inner.sent.isEmpty, "attempts=\(t.setAttempts)")
        check("iD44: Lesen laeuft (Bereitschaft, Notify, Meter)", t.gets >= 5 && t.notifyGets > 0 && t.memGets > 0,
              "gets=\(t.gets) notify=\(t.notifyGets) mem=\(t.memGets)")
        check("iD44: kein Fade", !c.isFading)
        check("iD44: Meter mit 4 Kanaelen", c.meters.mics.count == 4 && c.meters.channelCount == 4)
        let vol = c.state.monitor.volumeDB
        c.setMonitorVolume(-20); c.nudgeMonitorVolume(by: 1); c.setCut(true); c.setDim(true); c.setMono(true)
        c.setSpeakerAlt(true); c.setPhonesVolume(-10); c.setPhonesLevel(-5); c.setPhonesCut(true)
        c.setInputPolarity(mic: 1, true); c.setSendVolume(input: 0, mix: 0, db: -3); c.setSendPan(input: 0, mix: 0, pan: 0.2)
        c.setCueBlend(mix: 1, 0.5); c.setInputCut(input: 0, true); c.setIDKey(.mono); c.setIDKeyChoice(.talkback)
        c.setTalkbackSource(.mic2); c.volumeKey(up: true, fine: false); c.volumeKeyMute()
        spin(0.4)
        check("iD44: Setter sind No-Ops auf der Leitung", t.setAttempts == 0 && t.inner.sent.isEmpty, "attempts=\(t.setAttempts)")
        check("iD44: Setter aendern den Zustand nicht lokal", c.state.monitor.volumeDB == vol && !c.state.monitor.cut)
        let polls = t.notifyGets
        spin(0.3)
        check("iD44: Notify-Polling laeuft weiter", t.notifyGets > polls)

        // Zweiter Kopfhoerer: nur lokaler Zustand, nie ein SET
        c.setPhones2Volume(-12); c.setPhones2Cut(true)
        spin(0.2)
        check("iD44: phones2 nur lokal, kein SET", c.state.phones2VolumeDB == -12 && c.state.monitor.phones2Cut && t.setAttempts == 0)

        // Override an: Schreiben wieder erlaubt (voller Push + Setter)
        c.writeOverride = true
        spin(2.0, until: { !t.inner.sent.isEmpty })
        check("writeOverride: Push sendet jetzt SETs", !t.inner.sent.isEmpty && !c.readOnlyBeta)
        let n = t.inner.sent.count
        c.setMonitorVolume(-30)
        spin(0.3)
        check("writeOverride: Setter sendet", t.inner.sent.count > n && t.inner.sent.contains { $0.control == ID14.Monitor.volume })
        c.writeOverride = false
        spin(0.2)
        let m = t.setAttempts
        c.setMonitorVolume(-31); c.setCut(false)
        spin(0.3)
        check("writeOverride aus: wieder gesperrt", t.setAttempts == m)
        hot.callback?(false); spin(0.1)
    }

    // Override schon vor dem Anstecken: Push laeuft normal
    do {
        let t = PIDTransport(pid: 0x000D)
        let (c, hot) = makeController(t)
        c.writeOverride = true
        hot.callback?(true)
        spin(3.0, until: { c.connection == .connected })
        check("iD24 mit Override: Push sendet, Meter 2 Kanaele", c.profile == .id24 && !t.inner.sent.isEmpty && c.meters.mics.count == 2,
              "profile=\(c.profile.id) sent=\(t.inner.sent.count) mics=\(c.meters.mics.count) conn=\(c.connection)")
        hot.callback?(false); spin(0.1)
    }

    // iD24 ohne Override: ebenfalls null SETs
    do {
        let t = PIDTransport(pid: 0x000D)
        let (c, hot) = makeController(t)
        hot.callback?(true)
        spin(3.0, until: { c.connection == .connected })
        spin(0.4)
        check("iD24: ZERO SETs, readOnlyBeta", c.profile == .id24 && c.readOnlyBeta && t.setAttempts == 0)
        // Wechsel auf iD14: Sperre wieder weg, Profil aktualisiert
        hot.callback?(false); spin(0.1)
        check("iD24 abgezogen: Profil bleibt als letztes Geraet", c.connection == .disconnected && c.profile == .id24)
    }

    // Original-iD laeuft + Beta: passiv hat Vorrang, weiterhin kein SET
    do {
        let t = PIDTransport(pid: 0x0005)
        let (c, hot) = makeController(t, passive: true)
        hot.callback?(true)
        spin(3.0, until: { c.connection == .passive })
        spin(0.3)
        check("iD44 + Original-iD: .passive, readOnlyBeta, kein SET", c.connection == .passive && c.readOnlyBeta && t.setAttempts == 0)
        hot.callback?(false); spin(0.1)
    }

    // State: phones2 optional, Altdaten ohne Felder, sanitize
    do {
        var s = DeviceState()
        check("phones2: Standard -40 dB / nicht stumm, Felder nil", s.phones2VolumeDB == -40 && !s.monitor.phones2Cut
              && s.phones2VolumeStoredDB == nil && s.monitor.phones2CutStored == nil)
        s.phones2VolumeStoredDB = .nan
        check("phones2: sanitized NaN -> Standard", s.sanitized().phones2VolumeDB == -40)
        s.phones2VolumeStoredDB = 12
        check("phones2: sanitized auf 0 dB begrenzt", s.sanitized().phones2VolumeDB == 0)
        s.phones2VolumeStoredDB = -20
        let data = try? JSONEncoder().encode(s)
        let back = data.flatMap { try? JSONDecoder().decode(DeviceState.self, from: $0) }
        check("phones2: JSON-Roundtrip", back?.phones2VolumeDB == -20)
        let plain = (try? JSONEncoder().encode(DeviceState())).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("phones2: ungesetzt nicht im JSON (alte state.json kompatibel)", !plain.contains("phones2"))
    }

    // MeterModel mit 4 Kanaelen
    do {
        let m = MeterModel(rampSeconds: 0, channelCount: 4)
        check("Meter 4 Kanaele: Groesse", m.mics.count == 4 && m.channelCount == 4)
        m.peakHoldSeconds = 3
        let rest = [Double](repeating: -128, count: 12)
        m.update(inputs: [-6, -20, -30, -12] + rest, now: 10)
        check("Meter 4 Kanaele: alle Pegel", m.mics[0].levelDB == -6 && m.mics[1].levelDB == -20
              && m.mics[2].levelDB == -30 && m.mics[3].levelDB == -12)
        check("Meter 4 Kanaele: PPM steigt sofort", m.mics[2].ppmDB == -30 && m.mics[3].ppmDB == -12)
        m.update(inputs: [-40, -40, -40, -40] + rest, now: 12.9)
        check("Meter 4 Kanaele: Peak-Hold innerhalb der Haltezeit", m.mics[3].maxPeakDB == -12 && m.mics[2].maxPeakDB == -30)
        m.update(inputs: [-40, -40, -40, -40] + rest, now: 13.1)
        check("Meter 4 Kanaele: Peak-Hold nach Ablauf", m.mics[3].maxPeakDB == -40 && m.mics[0].maxPeakDB == -40)
        m.update(inputs: [-0.05, -40, -40, -0.05] + rest, now: 13.2)
        check("Meter 4 Kanaele: Clip auf Kanal 0 und 3", m.mics[0].lastClipAt == 13.2 && m.mics[3].lastClipAt == 13.2 && m.mics[2].lastClipAt == nil)
        m.resetPeak(mic: 3)
        check("Meter 4 Kanaele: resetPeak(mic: 3), Kanal 0 unberuehrt",
              m.mics[3].maxPeakDB == DB.minimum && m.mics[3].lastClipAt == nil && m.mics[0].lastClipAt == 13.2)
        m.resetPeak(mic: 4)
        check("Meter 4 Kanaele: resetPeak ausserhalb ignoriert", m.mics.count == 4)
        m.clearClip()
        check("Meter 4 Kanaele: clearClip alle", m.mics.allSatisfy { $0.lastClipAt == nil })
        m.reset()
        check("Meter 4 Kanaele: reset()", m.mics.count == 4 && m.mics.allSatisfy { $0.levelDB == DB.minimum && $0.maxPeakDB == DB.minimum } && !m.live)
        // Weniger Werte als Kanaele: Rest bleibt still
        m.update(inputs: [-10, -10], now: 20)
        check("Meter 4 Kanaele: fehlende Werte -> Kanal 2/3 still", m.mics[0].levelDB == -10 && m.mics[2].levelDB == DB.minimum && m.mics[3].levelDB == DB.minimum)
        m.configure(channelCount: 2)
        check("Meter configure(2): Groesse 2, still", m.mics.count == 2 && m.mics.allSatisfy { $0.levelDB == DB.minimum })
        m.configure(channelCount: 4)
        m.update(inputs: [-5, -5, -5, -5] + rest, now: 30)
        check("Meter configure(4): wieder 4 Kanaele", m.mics.count == 4 && m.mics[3].levelDB == -5)
    }
}
