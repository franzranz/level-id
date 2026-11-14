// SingleInstance.swift – Einzelinstanz-Sperre und Uebergabe an launchd (Login-Start).
// Regel: Es darf nie zwei Instanzen am Geraet geben. Ist Login-Start an, laeuft immer die
// von launchd verwaltete Instanz (Neustart nach Absturz, Exit 0 bleibt beendet).
//
// Opus (Umbau nach Live-Test): KEIN SMAppService mehr. SMAppService bindet den Agent an die
// Code-Signatur; bei ad-hoc-signierten Updates verweigert launchd dann den Start
// ("needs LWCR update", EX_CONFIG) und es laeuft gar keine Instanz. Stattdessen ein klassischer
// LaunchAgent in ~/Library/LaunchAgents mit absolutem Programmpfad (keine Signaturbindung).
import Foundation
import ServiceManagement
import os

enum SingleInstance {
    static let agentLabel = "app.levelid.mac"
    /// Argument fuer eine bewusst nicht verwaltete Instanz (kein kickstart, nur Sperre)
    static let noKickstartArg = "--no-kickstart"

    private static let log = Logger(subsystem: "app.levelid", category: "instance")
    // Nur beim Start (Main) bzw. fuer die Prozesslaufzeit gesetzt
    nonisolated(unsafe) private static var lockFD: Int32 = -1
    nonisolated(unsafe) private static var termSource: DispatchSourceSignal?

    /// Verwaltete Instanz erkennen: launchd setzt XPC_SERVICE_NAME = Label, zusaetzlich ID14_LAUNCHD.
    static var isLaunchdInstance: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["ID14_LAUNCHD"] == "1" || env["XPC_SERVICE_NAME"] == agentLabel
    }

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }
    static var loginEnabled: Bool { FileManager.default.fileExists(atPath: agentURL.path) }
    private static var domain: String { "gui/\(getuid())" }

    // MARK: Start

    /// Ganz am Anfang aufrufen, BEVOR DeviceController oder USB angefasst werden. Kehrt nur zurueck,
    /// wenn diese Instanz laufen darf; sonst exit(0) (Exit 0 = fuer launchd "erfolgreich", kein Neustart).
    static func guardStart() {
        migrateFromSMAppService()
        // Manuell geoeffnet, aber Login-Start aktiv: verwaltete Instanz anstossen und beenden.
        // Nur beenden, wenn das Anstossen nachweislich klappt; sonst selbst weiterlaufen (nie "keine Instanz").
        if !isLaunchdInstance, !CommandLine.arguments.contains(noKickstartArg), loginEnabled {
            if launchctl(["kickstart", "\(domain)/\(agentLabel)"]) == 0
                || (launchctl(["bootstrap", domain, agentURL.path]) == 0
                    && launchctl(["kickstart", "\(domain)/\(agentLabel)"]) == 0) {
                exit(0)
            }
            log.error("Agent nicht startbar, laufe als normale Instanz weiter")
        }
        if !acquireLock(timeout: 5.0) {
            log.info("Sperre nicht erhalten, beende mich")
            exit(0)
        }
    }

    /// Alte SMAppService-Anmeldung (fruehere Version) einmalig entfernen und ggf. in den klassischen
    /// Agent uebernehmen.
    private static func migrateFromSMAppService() {
        let old = SMAppService.agent(plistName: "\(agentLabel).plist")
        guard old.status != .notRegistered, old.status != .notFound else { return }
        let wasOn = old.status == .enabled || old.status == .requiresApproval
        try? old.unregister()
        if wasOn, !loginEnabled { _ = writeAgentPlist() }
    }

    private static func lockURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ID14Control/instance.lock")
    }

    /// flock(LOCK_EX | LOCK_NB), alle 200 ms erneut bis zum Timeout. FD bleibt offen (Prozesslaufzeit).
    private static func acquireLock(timeout: Double) -> Bool {
        let url = lockURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            log.error("Sperrdatei nicht oeffenbar")
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                lockFD = fd
                return true
            }
            if Date() >= deadline { close(fd); return false }
            usleep(200_000)
        }
    }

    /// launchctl mit Zeitlimit 3 s ausfuehren. Rueckgabe: Exit-Code (-1 bei Fehler/Timeout).
    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        let end = Date().addingTimeInterval(3.0)
        while p.isRunning, Date() < end { usleep(20_000) }
        if p.isRunning { p.terminate(); return -1 }
        return p.terminationStatus
    }

    /// Klassischer LaunchAgent: absoluter Programmpfad, Neustart nur nach Absturz, Login-Start.
    private static func writeAgentPlist() -> Bool {
        guard let exe = Bundle.main.executablePath else { return false }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "EnvironmentVariables": ["ID14_LAUNCHD": "1"],
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: agentURL, options: .atomic)
            return true
        } catch {
            log.error("Agent-Plist nicht schreibbar")
            return false
        }
    }

    // MARK: SIGTERM

    /// SIGTERM sauber behandeln: speichern, Timer stoppen, exit(0).
    @MainActor static func installTermHandler(controller: DeviceController) {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler {
            MainActor.assumeIsolated { controller.prepareForTermination() }
            exit(0)
        }
        src.resume()
        termSource = src
    }

    // MARK: Login-Start umschalten (Fehler still, Zustand danach aus loginEnabled lesen)

    @MainActor static func setLoginItem(_ on: Bool, controller: DeviceController) {
        if on {
            guard writeAgentPlist() else { return }
            if isLaunchdInstance { return }
            // Uebergabe: launchd startet die verwaltete Instanz (RunAtLoad), sie wartet bis zu 5 s auf die Sperre.
            controller.prepareForTermination()
            if launchctl(["bootstrap", domain, agentURL.path]) == 0 {
                exit(0)
            }
            // Bootstrap fehlgeschlagen: Datei wieder weg, selbst weiterlaufen.
            try? FileManager.default.removeItem(at: agentURL)
            log.error("bootstrap fehlgeschlagen")
        } else {
            if isLaunchdInstance {
                // Erst nicht verwaltete Instanz starten (wartet auf die Sperre), dann selbst abgeben.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-n", Bundle.main.bundlePath, "--args", noKickstartArg]
                do { try p.run() } catch { log.error("Neustart ohne launchd fehlgeschlagen"); return }
                controller.prepareForTermination()
            }
            try? FileManager.default.removeItem(at: agentURL)
            launchctl(["bootout", "\(domain)/\(agentLabel)"])   // beendet die verwaltete Instanz (SIGTERM)
        }
    }
}
