// PushPlan.swift – Erzeugt die SET-Befehle in iD-Reihenfolge (P3). Keine Geraetezugriffe.
import Foundation

enum PushPlan {
    /// Kompletter Zustand in iD-Reihenfolge (Schritte 1-7, siehe ARCHITECTURE.md).
    static func fullState(_ raw: DeviceState, monitorVolumeDB: Double? = nil, phonesLevelDB: Double? = nil,
                          phonesVolumeDB: Double? = nil) -> [SetCommand] {
        let s = raw.sanitized()   // garantiert alle Laengen (Opus, Zuverlaessigkeit)
        var cmds: [SetCommand] = []

        // 1. Routing USB-Eingaenge zum Mac (Kanal 0-11)
        for (ch, src) in s.routeHost.enumerated() {
            cmds.append(SetCommand(control: ID14.routeHost(channel: UInt8(ch)), data: [src]))
        }
        // 2. Routing physische Ausgaenge (Kanal 0-5)
        for (ch, src) in s.routeOut.enumerated() {
            cmds.append(SetCommand(control: ID14.routeOut(channel: UInt8(ch)), data: [src]))
        }
        // 3. Optischer Eingangsmodus (4 Bytes)
        cmds.append(SetCommand(control: ID14.opticalInputMode, data: s.opticalInputMode))
        // 4. Funktionstasten (2 Bytes)
        cmds.append(SetCommand(control: ID14.Monitor.functionKeys, data: s.monitor.functionKeyMode))

        // 5. Mixer-Ausgangspegel, FU-Kanal 3-6 (Index 2...5). Kopfhoerer-Pegel ersetzt Kanal 3/4.
        var levels = Array(s.mixOutputDB[2...5])
        if let phones = phonesLevelDB {
            levels[0] = phones
            levels[1] = phones
        }
        for (idx, ch) in [UInt8(3), 4, 5, 6].enumerated() {
            cmds.append(SetCommand(control: ID14.mixOutputVolume(channel: ch), data: DB.encode(levels[idx])))
        }

        // 6. Monitor-Controller ohne Lautstaerke
        let m = s.monitor
        cmds.append(SetCommand(control: ID14.Monitor.cut, data: [m.cut ? 1 : 0]))
        cmds.append(SetCommand(control: ID14.Monitor.dim, data: [m.dim ? 1 : 0]))
        cmds.append(SetCommand(control: ID14.Monitor.dimAttenuation, data: DB.encode(m.dimAttenuationDB)))
        cmds.append(SetCommand(control: ID14.Monitor.speakerSelect, data: [m.speakerSelect]))
        cmds.append(SetCommand(control: ID14.Monitor.talkbackInput, data: [m.talkbackInput]))
        // Opus: Talkback beim (Neu-)Anstecken immer aus (sonst bleiben Monitore gedimmt und Mic offen)
        cmds.append(SetCommand(control: ID14.Monitor.talkback, data: [0]))
        cmds.append(SetCommand(control: ID14.Monitor.altMonTrim, data: DB.encode(m.altMonTrimDB)))
        // 6b. Ergaenzung (Opus): Zustaende, die iD beim Start nicht sendet, das Geraet aber nach
        // dem Abstecken vergisst. Sonst gingen Mono/Polaritaet/Kopfhoerer-Cut beim Einstecken verloren.
        cmds.append(SetCommand(control: ID14.Monitor.mono, data: [m.mono ? 1 : 0]))
        cmds.append(SetCommand(control: ID14.Monitor.polarity, data: [m.polarity ? 1 : 0]))
        for ch in ID14.phonesMuteChannels {
            cmds.append(SetCommand(control: ID14.phonesMute(channel: ch), data: [m.phonesCut ? 1 : 0]))
        }
        for (i, on) in s.inputPolarity.enumerated() {
            cmds.append(SetCommand(control: ID14.inputPolarity(mic: i + 1), data: [on ? 1 : 0]))
        }

        // 7. Alle Mixer-Sends (Eingang 0-15, je 6 Ausgaenge)
        for i in s.inputs.indices {
            cmds.append(contentsOf: sends(forInput: i, in: s))
        }

        // Optional: Monitor-Lautstaerke zuletzt
        if let vol = monitorVolumeDB {
            cmds.append(SetCommand(control: ID14.Monitor.volume, data: DB.encode(vol)))
        }
        // Optional (Opus): echte Kopfhoerer-Lautstaerke FU 0x0A Kanal 5/6
        if let pv = phonesVolumeDB {
            for ch in ID14.phonesVolumeChannels {
                cmds.append(SetCommand(control: ID14.phonesVolume(channel: ch), data: DB.encode(pv)))
            }
        }
        return cmds
    }

    /// Diff gegen den Geraetezustand: behaelt Befehle, deren Controlwert nicht gelesen werden konnte (nil), vom Plan
    /// abweicht oder deren Control mehrfach im Plan steht (dann gehen alle Vorkommen in Originalreihenfolge raus).
    /// Jedes Control wird hoechstens einmal gelesen. Controls mit !ID14.isSafeToRead werden NIE gelesen (die Firmware
    /// haengt dann); ihr Befehl geht immer raus, wie bei "nicht lesbar".
    static func differing(_ plan: [SetCommand], read: (ID14.Control) -> [UInt8]?)
        -> (send: [SetCommand], unchanged: Int) {
        var count: [ID14.Control: Int] = [:]
        for c in plan { count[c.control, default: 0] += 1 }
        var cache: [ID14.Control: [UInt8]?] = [:]
        var send: [SetCommand] = []
        var unchanged = 0
        for c in plan {
            let dup = (count[c.control] ?? 0) > 1
            guard ID14.isSafeToRead(c.control) else { send.append(c); continue }
            var curValue: [UInt8]?
            if let known = cache[c.control] { curValue = known } else {
                curValue = read(c.control)
                cache[c.control] = .some(curValue)
            }
            if dup || curValue == nil || !equivalent(c, curValue!) { send.append(c) } else { unchanged += 1 }
        }
        return (send, unchanged)
    }

    /// Gleich im Sinne des Diff-Push: exakt dieselben Bytes, oder bei Mixer-Sends beide stumm (<= -128 dB).
    /// Die Firmware meldet stumme Sends nach dem Einstecken mit anderen Bytes als 0x8000; beides ist Stille
    /// (frueher bereits per Stichprobe als -128 dB erkannt und uebersprungen, ohne Probleme).
    static func equivalent(_ c: SetCommand, _ device: [UInt8]) -> Bool {
        if device == c.data { return true }
        guard c.control.unit == ID14.mixerSend(input: 0, output: 0).unit,
              c.data.count == 2, device.count == 2 else { return false }
        return DB.decode(c.data) <= DB.minimum + 0.01 && DB.decode(device) <= DB.minimum + 0.01
    }

    /// Die Sends eines Eingangs (6 Befehle: Mix m links = Ausgang 2m, rechts = 2m+1).
    static func sends(forInput i: Int, in s: DeviceState) -> [SetCommand] {
        guard s.inputs.indices.contains(i) else { return [] }   // Zuverlaessigkeit: nie ausserhalb lesen
        let input = s.inputs[i]
        var cmds: [SetCommand] = []
        for m in 0..<ID14.mixCount where m < input.mixes.count {
            let (left, right) = MixerMath.sendDB(input.mixes[m], cut: input.cut)
            cmds.append(SetCommand(control: ID14.mixerSend(input: i, output: 2 * m), data: DB.encode(left)))
            cmds.append(SetCommand(control: ID14.mixerSend(input: i, output: 2 * m + 1), data: DB.encode(right)))
        }
        return cmds
    }
}
