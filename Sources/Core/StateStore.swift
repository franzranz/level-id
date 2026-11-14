// StateStore.swift – Persistenz des DeviceState als JSON (P3, Zuverlaessigkeit: Opus).
import Foundation

/// Thread-sicher: veraenderlicher Zustand (`pending`, `lastScheduled`) wird nur auf `queue` angefasst.
final class StateStore: @unchecked Sendable {
    static let `default` = StateStore(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ID14Control/state.json"))

    let url: URL
    /// Serielle Queue fuer Debounce und Speichern
    private let queue = DispatchQueue(label: "app.levelid.store")
    private var pending: DispatchWorkItem?
    private var lastScheduled: DeviceState?

    init(url: URL) {
        self.url = url
    }

    /// Laedt und validiert den Zustand. Eine vorhandene, aber unlesbare Datei wird als
    /// `state.json.defekt-<Zeitstempel>` beiseitegelegt (nie geloescht), Rueckgabe dann nil.
    func load() -> DeviceState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let s = try? JSONDecoder().decode(DeviceState.self, from: data) {
            return s.sanitized()
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = url.deletingLastPathComponent().appendingPathComponent("state.json.defekt-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: aside)
        return nil
    }

    /// Atomar schreiben. Gibt false zurueck, wenn das Schreiben fehlschlug.
    @discardableResult
    func save(_ s: DeviceState) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(s.sanitized()) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Debounce: nach 2,0 s wird die zuletzt uebergebene Version gespeichert.
    func scheduleSave(_ s: DeviceState) {
        queue.async { [self] in
            pending?.cancel()
            lastScheduled = s
            let item = DispatchWorkItem { [self] in
                save(s)
                lastScheduled = nil
            }
            pending = item
            queue.asyncAfter(deadline: .now() + 2.0, execute: item)
        }
    }

    /// Sofort speichern, falls noch etwas ansteht (z. B. beim Beenden der App). Blockiert kurz.
    func flush() {
        queue.sync { [self] in
            pending?.cancel(); pending = nil
            if let s = lastScheduled { save(s); lastScheduled = nil }
        }
    }
}
