// MemoryRelief.swift – gibt freien Heap-Speicher ans System zurueck (einzige Stelle fuer den Aufruf).
import Darwin
import Dispatch

enum MemoryRelief {
    /// Gibt freie Heap-Seiten aller malloc-Zonen an das System zurueck.
    static func relieve() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    /// Wie `relieve()`, aber nach `seconds` (z. B. bis eine Schliessen-Animation fertig ist).
    @MainActor
    static func relieve(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { relieve() }
    }
}
