// Updater.swift – optionale Update-Pruefung und Ein-Klick-Installation (GitHub Releases).
// Pruefung nur auf Wunsch (Einstellung, hoechstens 1x pro Woche) oder per "Check now". Gesendet wird nur die
// Anfrage an GitHub (User-Agent "LevelID/<Version>"), keine persoenlichen Daten.
// Installation: Download -> SHA-256 -> DMG mounten -> Signatur der neuen App gegen die Designated Requirement
// der LAUFENDEN App -> Kopie neben die alte App -> Austausch (alte in den Papierkorb) -> Neustart.
// Ad hoc signierte oder nicht in /Applications liegende Apps installieren nicht selbst (nur Release-Seite).
// Alle externen Programme laufen als Process mit Argument-Arrays (kein Shell-String).
import AppKit
import Foundation
import Security
import os

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Status: Equatable {
        case idle, checking, upToDate
        case available(version: String, url: URL)
        case downloading, installing
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// Release-Seite des gefundenen Updates (auch nach einem Fehler fuer "Open release page")
    @Published private(set) var releaseURL: URL?
    /// Gesetzt = keine Ein-Klick-Installation moeglich (Grund); dann nur Release-Seite anbieten
    @Published private(set) var installNote: String?

    private var release: UpdateCheck.Release?
    private weak var controller: DeviceController?
    private var busy: Bool {
        switch status {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }
    private nonisolated static let log = Logger(subsystem: "app.levelid", category: "update")
    private static let interval: TimeInterval = 7 * 24 * 3600   // einmal pro Woche

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var isBusy: Bool { busy }

    // MARK: Konfiguration (Test-Overrides nur mit -D LEVELID_UPDATE_TEST)

    private static var endpoint: URL {
        #if LEVELID_UPDATE_TEST
        if let s = ProcessInfo.processInfo.environment["LEVELID_UPDATE_URL"], let u = URL(string: s) { return u }
        #endif
        return URL(string: "https://api.github.com/repos/franzranz/level-id/releases/latest")!
    }

    private static var allowedSchemes: Set<String> {
        #if LEVELID_UPDATE_TEST
        return ["https", "http", "file"]
        #else
        return ["https"]
        #endif
    }

    /// Zu ersetzende App (Standard: laufende App). Test-Override: LEVELID_UPDATE_TARGET.
    private static var targetURL: URL {
        #if LEVELID_UPDATE_TEST
        if let p = ProcessInfo.processInfo.environment["LEVELID_UPDATE_TARGET"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        #endif
        return URL(fileURLWithPath: Bundle.main.bundlePath)
    }

    private static var targetIsOverridden: Bool {
        #if LEVELID_UPDATE_TEST
        return ProcessInfo.processInfo.environment["LEVELID_UPDATE_TARGET"].map { !$0.isEmpty } ?? false
        #else
        return false
        #endif
    }

    // MARK: Automatische Pruefung

    func attach(controller: DeviceController) { self.controller = controller }

    /// Einmaliger Start-Check (kein Dauer-Polling); weitere Pruefungen beim Oeffnen des Panels (checkIfDue).
    func scheduleStartupCheck() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self?.checkIfDue()
        }
    }

    /// Prueft nur, wenn der Nutzer es eingeschaltet hat und die letzte Pruefung > 7 Tage her ist.
    func checkIfDue() {
        guard let controller, controller.state.ui.autoUpdateCheck, !busy else { return }
        if case .available = status { return }
        if let last = controller.state.ui.lastUpdateCheck, Date().timeIntervalSince(last) < Self.interval,
           Date() >= last { return }
        check()
    }

    // MARK: Pruefen

    func check() {
        guard !busy else { return }
        status = .checking
        releaseURL = nil
        installNote = nil
        release = nil
        controller?.setLastUpdateCheck(Date())
        Task { await runCheck() }
    }

    private func runCheck() async {
        do {
            let data = try await Self.fetch(Self.endpoint, maxBytes: 2_000_000)
            guard let rel = UpdateCheck.parseRelease(data, allowedSchemes: Self.allowedSchemes) else {
                status = .failed("Unexpected response from GitHub.")
                return
            }
            guard let newer = UpdateCheck.update(rel, current: Self.currentVersion) else {
                status = .upToDate
                return
            }
            release = newer
            releaseURL = newer.htmlURL
            installNote = Self.installBlocker(for: newer)
            status = .available(version: newer.version.description, url: newer.htmlURL)
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    /// Grund, warum nicht selbst installiert werden kann (nil = Ein-Klick-Installation moeglich)
    private static func installBlocker(for r: UpdateCheck.Release) -> String? {
        if !r.isInstallable { return "This release has no installer for in-app updates." }
        if !targetIsOverridden, targetURL.path != "/Applications/Level iD.app" {
            return "Level iD isn't in the Applications folder, so it can't update itself."
        }
        if !FileManager.default.isWritableFile(atPath: targetURL.deletingLastPathComponent().path) {
            return "No permission to write to the Applications folder."
        }
        if runningSignature() != .certificate {
            return "This copy has no fixed signature, so it can't verify an update. Please download the new version from the release page."
        }
        return nil
    }

    // MARK: Installieren

    func install() {
        guard case .available = status, installNote == nil, let rel = release,
              let dmg = rel.dmg, let sum = rel.checksum else { return }
        status = .downloading
        Task { await runInstall(version: rel.version, dmg: dmg.url, checksum: sum.url) }
    }

    func openReleasePage() {
        if let url = releaseURL { NSWorkspace.shared.open(url) }
    }

    private func runInstall(version: UpdateCheck.Version, dmg: URL, checksum: URL) async {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("LevelID-Update-\(UUID().uuidString)")
        let target = Self.targetURL
        var staged: URL?
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            // 1. Download + Pruefsumme
            let sumData = try await Self.fetch(checksum, maxBytes: 4096)
            guard let expected = UpdateCheck.parseChecksumFile(String(decoding: sumData, as: UTF8.self),
                                                               fileName: UpdateCheck.dmgName) else {
                throw UpdateError("The checksum file is invalid.")
            }
            let dmgFile = work.appendingPathComponent(UpdateCheck.dmgName)
            try await Self.download(dmg, to: dmgFile)
            let actual = try UpdateCheck.sha256Hex(ofFileAt: dmgFile)
            guard UpdateCheck.hashMatches(expectedHex: expected, actualHex: actual) else {
                throw UpdateError("The download is corrupt (checksum mismatch).")
            }
            // 2. DMG mounten, Signatur pruefen, Kopie neben die alte App, DMG wieder auswerfen
            status = .installing
            let newURL = target.appendingPathExtension("new")
            staged = newURL
            try await Self.runDetached { try Self.stage(dmg: dmgFile, work: work, newApp: newURL, minVersion: version) }
            // 3. Gerät beruhigen: nicht mitten im Fade ersetzen
            var waited = 0.0
            while let c = controller, c.isFading, waited < 10 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                waited += 0.25
            }
            if controller?.isFading == true { throw UpdateError("The device is busy. Please try again in a moment.") }
            // 4. Austausch (alte App in den Papierkorb), bei Fehler Rollback
            try await Self.runDetached { try Self.swap(target: target, newApp: newURL) }
            staged = nil
            try? fm.removeItem(at: work)
            Self.log.info("Update auf \(version.description, privacy: .public) installiert, starte neu")
            // 5. Zustand sichern, neu starten, beenden
            controller?.prepareForTermination()
            Self.relaunch(target: target)
            NSApp.terminate(nil)
        } catch {
            if let s = staged { try? fm.removeItem(at: s) }
            try? fm.removeItem(at: work)
            Self.log.error("Update fehlgeschlagen: \(Self.describe(error), privacy: .public)")
            status = .failed(Self.describe(error))
        }
    }

    // MARK: Netzwerk

    private struct UpdateError: Error { let message: String; init(_ m: String) { message = m } }

    private nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? UpdateError { return e.message }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "No internet connection."
            case .timedOut: return "The server did not respond in time."
            default: break
            }
        }
        return "Something went wrong (\((error as NSError).localizedDescription))."
    }

    private nonisolated static func request(_ url: URL, api: Bool) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: api ? 15 : 60)
        r.setValue("LevelID/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if api { r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        return r
    }

    private nonisolated static func checkHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }   // file:// im Test-Build
        switch http.statusCode {
        case 200..<300: return
        case 404: throw UpdateError("No release found.")
        case 403, 429: throw UpdateError("GitHub is limiting requests right now. Try again later.")
        default: throw UpdateError("GitHub answered with status \(http.statusCode).")
        }
    }

    private nonisolated static func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request(url, api: maxBytes > 4096))
        try checkHTTP(response)
        guard data.count <= maxBytes else { throw UpdateError("The response is too large.") }
        return data
    }

    private nonisolated static func download(_ url: URL, to dest: URL) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (tmp, response) = try await session.download(for: request(url, api: false))
        try checkHTTP(response)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    // MARK: Signatur

    enum SignatureKind { case certificate, adHoc, unsigned }

    /// Laufende App: Zertifikatssignatur (feste Identitaet) oder ad hoc/unsigniert.
    nonisolated static func runningSignature() -> SignatureKind {
        var me: SecCode?
        var staticMe: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe else { return .unsigned }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticMe, [], &req) == errSecSuccess, let req else { return .unsigned }
        var text: CFString?
        if SecRequirementCopyString(req, [], &text) == errSecSuccess, let s = text as String?, s.contains("cdhash") {
            return .adHoc
        }
        var info: CFDictionary?
        if SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let d = info as? [String: Any] {
            let flags = (d[kSecCodeInfoFlags as String] as? UInt32) ?? 0
            if flags & 0x2 != 0 { return .adHoc }            // kSecCodeSignatureAdhoc
            if ((d[kSecCodeInfoCertificates as String] as? [Any]) ?? []).isEmpty { return .adHoc }
        } else {
            return .unsigned
        }
        return .certificate
    }

    /// Neue App muss gueltig signiert sein UND die Designated Requirement der laufenden App erfuellen.
    private nonisolated static func verifySignature(of app: URL) throws {
        guard runningSignature() == .certificate else {
            throw UpdateError("This copy of Level iD has no fixed signature, so the update can't be verified.")
        }
        var me: SecCode?
        var staticMe: SecStaticCode?
        var req: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe, [], &req) == errSecSuccess, let req else {
            throw UpdateError("Could not read the signature of the running app.")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("Could not read the downloaded app.")
        }
        let st = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), req)
        guard st == errSecSuccess else {
            throw UpdateError("The downloaded app is not signed by the same developer identity (status \(st)). Nothing was installed.")
        }
    }

    // MARK: Dateien und Prozesse (blockierend, nur ausserhalb des Main-Threads aufrufen)

    private nonisolated static func runDetached(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try work(); c.resume() } catch { c.resume(throwing: error) }
            }
        }
    }

    @discardableResult
    private nonisolated static func run(_ exe: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// DMG mounten, neue App pruefen und nach `newApp` kopieren. Mount wird immer wieder ausgeworfen.
    private nonisolated static func stage(dmg: URL, work: URL, newApp: URL, minVersion: UpdateCheck.Version) throws {
        let fm = FileManager.default
        let mount = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        let attach = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                 "-mountpoint", mount.path, dmg.path])
        guard attach.status == 0 else { throw UpdateError("The disk image could not be opened.") }
        defer {
            if let r = try? run("/usr/bin/hdiutil", ["detach", mount.path]), r.status != 0 {
                _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
            }
        }
        let src = mount.appendingPathComponent("Level iD.app")
        guard fm.fileExists(atPath: src.path) else { throw UpdateError("The disk image does not contain Level iD.") }
        try verifySignature(of: src)
        // Version und Bundle-ID der neuen App muessen zum Release passen
        let plist = NSDictionary(contentsOf: src.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard let v = (plist?["CFBundleShortVersionString"] as? String).flatMap(UpdateCheck.Version.init), v >= minVersion,
              plist?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError("The downloaded app does not match the release.")
        }
        try? fm.removeItem(at: newApp)
        let cp = try run("/usr/bin/ditto", [src.path, newApp.path])
        guard cp.status == 0 else {
            try? fm.removeItem(at: newApp)
            throw UpdateError("Copying the new version failed.")
        }
        do { try verifySignature(of: newApp) } catch {
            try? fm.removeItem(at: newApp)
            throw error
        }
    }

    /// Alte App in den Papierkorb, neue umbenennen. Scheitert das Umbenennen, kommt die alte App zurueck.
    private nonisolated static func swap(target: URL, newApp: URL) throws {
        let fm = FileManager.default
        var trashed: NSURL?
        do { try fm.trashItem(at: target, resultingItemURL: &trashed) } catch {
            throw UpdateError("The old version could not be moved to the Trash.")
        }
        do {
            try fm.moveItem(at: newApp, to: target)
        } catch {
            if let t = trashed as URL?, (try? fm.moveItem(at: t, to: target)) != nil {
                try? fm.removeItem(at: newApp)
                throw UpdateError("The new version could not be put in place. The old version was restored.")
            }
            throw UpdateError("The new version could not be put in place. The old version is in the Trash.")
        }
    }

    /// Neustart: LaunchAgent (Login-Start) per kickstart -k, sonst frische Instanz per open -n.
    private static func relaunch(target: URL) {
        if !targetIsOverridden, SingleInstance.loginEnabled,
           SingleInstance.launchctl(["kickstart", "-k", "\(SingleInstance.domain)/\(SingleInstance.agentLabel)"]) == 0 {
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", target.path]
        do { try p.run() } catch { log.error("Neustart fehlgeschlagen") }
    }
}
