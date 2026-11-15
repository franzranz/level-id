// DeviceReport.swift – Reiner Text-Bericht fuer "Help verify this device" (ohne UI, ohne Geraetezugriff).
// Enthaelt bewusst KEINE Seriennummer, keinen Benutzernamen und keine Pfade.
import Foundation

enum DeviceReport {
    /// Baut den Klartext-Bericht. `steps` = (Beschriftung, erledigt).
    static func make(profileName: String, productID: UInt16, appVersion: String, macOSVersion: String,
                     steps: [(String, Bool)], monitorVolumeDB: Double, meterPeaks: [Double]) -> String {
        var lines: [String] = []
        lines.append("Level iD device report")
        lines.append("Model: \(profileName) (PID 0x\(String(format: "%04X", productID)))")
        lines.append("App: \(appVersion)")
        lines.append("macOS: \(macOSVersion)")
        lines.append("")
        lines.append("Checklist:")
        for (label, done) in steps {
            lines.append("[\(done ? "x" : " ")] \(label)")
        }
        lines.append("")
        lines.append("Monitor volume: \(dbText(monitorVolumeDB))")
        if meterPeaks.isEmpty {
            lines.append("Input peaks: none")
        } else {
            let peaks = meterPeaks.enumerated().map { "Input \($0.offset + 1) \(dbText($0.element))" }
            lines.append("Input peaks: " + peaks.joined(separator: ", "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Adresse des GitHub-Issue-Formulars. Der Bericht selbst steht NICHT in der URL (nur der Titel).
    static func issueURL(profileName: String) -> URL? {
        let title = "Device report: \(profileName)"
        // Strenge Kodierung: nur unreservierte Zeichen bleiben stehen
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://github.com/franzranz/level-id/issues/new?template=device-report.md&title=" + encoded)
    }

    /// "-12.3 dB" bzw. "-" fuer nicht gemessene Werte (-128 dB)
    private static func dbText(_ db: Double) -> String {
        guard db.isFinite, db > DB.minimum + 0.01 else { return "-" }
        return String(format: "%.1f dB", db)
    }
}
