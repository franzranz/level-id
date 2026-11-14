// RecordingTransport.swift – Offline-Transport fuer Tests. Sendet nie an ein Geraet.
import Foundation

final class RecordingTransport: DeviceTransport {
    private(set) var isOpen = false
    /// Alle akzeptierten SET-Befehle in Sendereihenfolge
    var sent: [SetCommand] = []
    /// Antworten fuer GET. Schluessel: "\(unit)-\(wValue)-\(request.rawValue)"
    var getResponses: [String: [UInt8]] = [:]

    func open() -> Bool {
        isOpen = true
        return true
    }

    func close() {
        isOpen = false
    }

    func get(_ request: ID14.Request, unit: UInt8, wValue: UInt16, length: Int) -> [UInt8]? {
        getResponses["\(unit)-\(wValue)-\(request.rawValue)"]
    }

    /// Prueft wie der echte Transport Whitelist und Laenge, bevor der Befehl "gesendet" wird.
    func set(_ command: SetCommand) -> Bool {
        guard ID14.isWritable(command.control), command.data.count == command.control.length else { return false }
        sent.append(command)
        return true
    }
}
