// IDStateImporter.swift – Liest iDs state.xml in ein DeviceState (P3). Reine Datei-Verarbeitung.
import Foundation

enum IDStateImporter {
    enum ImportError: Error { case invalidFormat }

    /// Vermuteter Speicherort der iD-Datei (nicht verifiziert, siehe Bericht).
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Audient/iD/state.xml")

    static func load(from url: URL) throws -> DeviceState {
        let doc = try XMLDocument(contentsOf: url, options: [])
        guard doc.rootElement()?.name == "presets" else { throw ImportError.invalidFormat }
        var s = DeviceState()

        // Eingaenge und Sends
        for node in try doc.nodes(forXPath: "//input") {
            guard let e = node as? XMLElement, let ch = int(e, "channel"), s.inputs.indices.contains(ch) else { continue }
            if let name = attr(e, "name") { s.inputs[ch].name = name }
            if let mode = int(e, "mode") { s.inputs[ch].mode = mode }
            if let cut = flag(e, "cut") { s.inputs[ch].cut = cut }
            if s.inputPolarity.indices.contains(ch), let pol = flag(e, "polarity") { s.inputPolarity[ch] = pol }

            for mixNode in e.elements(forName: "mix") {
                guard let idx = int(mixNode, "index"), s.inputs[ch].mixes.indices.contains(idx),
                      let vol = double(mixNode, "volume"), let pan = double(mixNode, "pan") else { continue }
                s.inputs[ch].mixes[idx] = MixSend(volumeDB: vol, pan: pan)
            }
        }

        // Ausgangspegel (nur wenn vorhanden)
        for node in try doc.nodes(forXPath: "//output") {
            guard let e = node as? XMLElement, let ch = int(e, "channel"), s.mixOutputDB.indices.contains(ch),
                  let vol = double(e, "volume") else { continue }
            s.mixOutputDB[ch] = vol
        }

        // Monitor-Controller
        if let mc = try doc.nodes(forXPath: "//monitor-controller").first as? XMLElement {
            if let v = flag(mc, "cut") { s.monitor.cut = v }
            if let v = flag(mc, "dim") { s.monitor.dim = v }
            if let v = double(mc, "dim-attenuation") { s.monitor.dimAttenuationDB = v }
            if let v = int(mc, "active-monitor-output") { s.monitor.speakerSelect = UInt8(clamping: v) }
            if let v = double(mc, "alt-monitor-trim") { s.monitor.altMonTrimDB = v }
            if let v = flag(mc, "mono-mode") { s.monitor.mono = v }
            if let v = flag(mc, "headphone-cut") { s.monitor.phonesCut = v }
            // talkback-input wird bewusst ignoriert (Default bleibt)
        }
        if let fk = try doc.nodes(forXPath: "//monitor-controller/function-key").first as? XMLElement,
           int(fk, "mode") == -1 {
            s.monitor.functionKeyMode = [0xFF, 0xFF]
        }

        // System: optischer Eingangsmodus und Routing
        if let sys = try doc.nodes(forXPath: "//system").first as? XMLElement,
           attr(sys, "optical-input-mode") == "adat" {
            s.opticalInputMode = [0, 0, 0, 0]
        }
        for node in try doc.nodes(forXPath: "//system/routing") {
            // id >= 0: negative IDs aus kaputter Datei wuerden sonst abstuerzen (Fund: Sonnet-Fuzz-Test)
            guard let e = node as? XMLElement, let id = int(e, "id"), id >= 0, id + 1 < s.routeOut.count else { continue }
            switch attr(e, "source") {
            case "main-speakers": s.routeOut[id] = 0x1B; s.routeOut[id + 1] = 0x1C
            case "alt-speakers":  s.routeOut[id] = 0x1D; s.routeOut[id + 1] = 0x1E
            case "cuea":          s.routeOut[id] = 0x14; s.routeOut[id + 1] = 0x15
            default: break
            }
        }
        return s
    }

    // MARK: XML-Helfer
    private static func attr(_ e: XMLElement, _ name: String) -> String? {
        e.attribute(forName: name)?.stringValue
    }
    private static func double(_ e: XMLElement, _ name: String) -> Double? {
        attr(e, name).flatMap { Double($0) }
    }
    private static func int(_ e: XMLElement, _ name: String) -> Int? {
        attr(e, name).flatMap { Int($0) }
    }
    private static func flag(_ e: XMLElement, _ name: String) -> Bool? {
        attr(e, name).map { $0 == "1" || $0 == "true" }
    }
}
