// DeviceReportTests.swift – Bericht fuer "Help verify this device" (rein offline).
import Foundation

func runDeviceReportTests() {
    let steps: [(String, Bool)] = [("Turn the volume knob", true), ("Turn the headphone knob", false),
                                   ("Press the iD button", true), ("Speak into each input", true),
                                   ("Unplug and plug in again", false)]
    let report = DeviceReport.make(profileName: "iD44 MkII", productID: 0x000B, appVersion: "1.1.0",
                                   macOSVersion: "14.6.1", steps: steps, monitorVolumeDB: -18.5,
                                   meterPeaks: [-12.34, -128, -3.0, -40.0])
    check("Bericht: Modell und PID-Hex", report.contains("Model: iD44 MkII (PID 0x000B)"), report)
    check("Bericht: App- und macOS-Version", report.contains("App: 1.1.0") && report.contains("macOS: 14.6.1"))
    check("Bericht: Haekchen [x] und offen [ ]",
          report.contains("[x] Turn the volume knob") && report.contains("[ ] Turn the headphone knob")
              && report.contains("[x] Press the iD button") && report.contains("[ ] Unplug and plug in again"))
    check("Bericht: Monitor-Lautstaerke", report.contains("Monitor volume: -18.5 dB"))
    check("Bericht: Eingangsspitzen, nicht gemessen als \"-\"",
          report.contains("Input 1 -12.3 dB") && report.contains("Input 2 -") && report.contains("Input 4 -40.0 dB"), report)
    check("Bericht: keine Benutzerpfade", !report.contains("/Users"))
    check("Bericht: keine Seriennummer-Angabe", !report.lowercased().contains("serial"))
    let empty = DeviceReport.make(profileName: "iD24", productID: 0x000D, appVersion: "1.1.0", macOSVersion: "15.0",
                                  steps: [], monitorVolumeDB: DB.minimum, meterPeaks: [])
    check("Bericht ohne Schritte/Meter ist gueltig", empty.contains("Model: iD24 (PID 0x000D)") && empty.contains("Input peaks: none"))
    let url = DeviceReport.issueURL(profileName: "iD44 MkII")?.absoluteString ?? ""
    check("Issue-URL: Template und kodierter Titel",
          url.hasPrefix("https://github.com/franzranz/level-id/issues/new?template=device-report.md&title=")
              && url.hasSuffix("Device%20report%3A%20iD44%20MkII"), url)
    check("Issue-URL: Bericht nicht in der URL", !url.contains("Model") && !url.contains("PID"))
}
