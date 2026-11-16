// UpdateTests.swift – Offline-Tests fuer UpdateCheck (kein Netzwerk) und die neuen UI-Felder in DeviceState.
import Foundation

func runUpdateTests() {
    typealias U = UpdateCheck
    check("Version: 1.10.0 > 1.9.0", U.isNewer("1.10.0", than: "1.9.0"))
    check("Version: 1.9.0 nicht > 1.10.0", !U.isNewer("1.9.0", than: "1.10.0"))
    check("Version: 1.2.0 == v1.2.0", U.Version("1.2.0") == U.Version("v1.2.0") && !U.isNewer("v1.2.0", than: "1.2.0"))
    check("Version: 1.2 > 1.1.9", U.isNewer("1.2", than: "1.1.9"))
    check("Version: 1.2 == 1.2.0", U.Version("1.2") == U.Version("1.2.0"))
    check("Version: 1.2.1 > 1.2", U.isNewer("1.2.1", than: "1.2"))
    check("Version: 2.0.0 > 1.99.99", U.isNewer("2.0.0", than: "1.99.99"))
    for bad in ["", "v", "abc", "1..2", "1.2.x", "1.3.0-beta", "-1.0", "1.2.3.4.5.6.7", "99999999999.0"] {
        check("Version ungueltig: '\(bad)' -> kein Update", U.Version(bad) == nil && !U.isNewer(bad, than: "1.0.0"))
    }
    check("Version: ungueltige lokale Version -> kein Update", !U.isNewer("2.0.0", than: "dev"))

    func json(tag: String = "v1.3.0", draft: Bool = false, pre: Bool = false, assets: String? = nil) -> Data {
        let a = assets ?? """
        [{"name":"Level-iD.dmg","browser_download_url":"https://github.com/franzranz/level-id/releases/download/v1.3.0/Level-iD.dmg","size":1},
         {"name":"Level-iD.dmg.sha256","browser_download_url":"https://github.com/franzranz/level-id/releases/download/v1.3.0/Level-iD.dmg.sha256"}]
        """
        return Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/franzranz/level-id/releases/tag/\(tag)",
         "draft":\(draft),"prerelease":\(pre),"assets":\(a)}
        """.utf8)
    }

    if let r = U.parseRelease(json()) {
        check("Release: Tag/Version gelesen", r.tag == "v1.3.0" && r.version == U.Version("1.3.0"))
        check("Release: DMG und Pruefsumme gefunden", r.dmg?.url.lastPathComponent == "Level-iD.dmg"
              && r.checksum?.url.lastPathComponent == "Level-iD.dmg.sha256" && r.isInstallable)
        check("Release: Update gegenueber 1.2.9", U.update(r, current: "1.2.9") != nil)
        check("Release: kein Update gegenueber 1.3.0", U.update(r, current: "1.3.0") == nil)
        check("Release: kein Update gegenueber 1.10.0", U.update(r, current: "1.10.0") == nil)
    } else {
        check("Release: JSON parsebar", false)
    }
    if let r = U.parseRelease(json(assets: "[]")) {
        check("Release ohne Assets: nicht installierbar, aber Update", !r.isInstallable && r.dmg == nil && U.update(r, current: "1.0") != nil)
    } else { check("Release ohne Assets parsebar", false) }
    if let r = U.parseRelease(Data(#"{"tag_name":"v1.3.0","html_url":"https://github.com/x/y/releases/tag/v1.3.0"}"#.utf8)) {
        check("Release ohne assets-Schluessel: parsebar, nicht installierbar", !r.isInstallable)
    } else { check("Release ohne assets-Schluessel parsebar", false) }
    if let r = U.parseRelease(json(assets: #"[{"name":"Level-iD.dmg","browser_download_url":"http://evil.example/x.dmg"},{"name":"Level-iD.dmg.sha256","browser_download_url":"https://github.com/a"}]"#)) {
        check("Release: http-Asset wird abgelehnt", r.dmg == nil && !r.isInstallable)
    } else { check("Release mit http-Asset parsebar", false) }
    if let r = U.parseRelease(json(draft: true)) {
        check("Draft -> kein Update", U.update(r, current: "1.0.0") == nil)
    } else { check("Draft parsebar", false) }
    if let r = U.parseRelease(json(pre: true)) {
        check("Prerelease -> kein Update", U.update(r, current: "1.0.0") == nil)
    } else { check("Prerelease parsebar", false) }
    check("Release: ungueltiger Tag -> nil", U.parseRelease(json(tag: "nightly")) == nil)
    check("Release: kaputtes JSON -> nil", U.parseRelease(Data("{nope".utf8)) == nil && U.parseRelease(Data()) == nil)
    check("Release: ohne html_url -> nil", U.parseRelease(Data(#"{"tag_name":"v1.3.0"}"#.utf8)) == nil)

    // Pruefsummen
    let hash = String(repeating: "ab", count: 32)
    check("sha256-Datei: Standardformat", U.parseChecksumFile("\(hash)  Level-iD.dmg\n", fileName: "Level-iD.dmg") == hash)
    check("sha256-Datei: Grossbuchstaben -> klein", U.parseChecksumFile("\(hash.uppercased())  Level-iD.dmg", fileName: "Level-iD.dmg") == hash)
    check("sha256-Datei: Binary-Marker und Pfad", U.parseChecksumFile("\(hash) *./Level-iD.dmg", fileName: "Level-iD.dmg") == hash)
    check("sha256-Datei: nur Hash", U.parseChecksumFile(hash, fileName: "Level-iD.dmg") == hash)
    check("sha256-Datei: falscher Dateiname -> nil", U.parseChecksumFile("\(hash)  other.dmg", fileName: "Level-iD.dmg") == nil)
    check("sha256-Datei: zu kurz/kein Hex/leer -> nil",
          U.parseChecksumFile("abcd  Level-iD.dmg", fileName: "Level-iD.dmg") == nil
          && U.parseChecksumFile(String(repeating: "zz", count: 32) + "  Level-iD.dmg", fileName: "Level-iD.dmg") == nil
          && U.parseChecksumFile("", fileName: "Level-iD.dmg") == nil)
    check("sha256-Datei: richtige Zeile unter mehreren",
          U.parseChecksumFile("\(String(repeating: "11", count: 32))  a.txt\n\(hash)  Level-iD.dmg\n", fileName: "Level-iD.dmg") == hash)

    let payload = Data("hello".utf8)
    let known = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    check("sha256Hex(Data) bekannter Wert", U.sha256Hex(payload) == known)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("levelid-ut-\(UUID().uuidString)")
    try? payload.write(to: tmp)
    check("sha256Hex(Datei) == Data-Variante", (try? U.sha256Hex(ofFileAt: tmp)) == known)
    try? FileManager.default.removeItem(at: tmp)
    check("Hash passt", U.hashMatches(expectedHex: known, actualHex: U.sha256Hex(payload)))
    check("Hash passt (Grossschreibung)", U.hashMatches(expectedHex: known.uppercased(), actualHex: known))
    check("Falscher Hash wird abgelehnt", !U.hashMatches(expectedHex: hash, actualHex: U.sha256Hex(payload)))
    check("Manipulierte Daten werden abgelehnt", !U.hashMatches(expectedHex: known, actualHex: U.sha256Hex(Data("hellp".utf8))))
    check("Leerer/ungueltiger Hash wird abgelehnt", !U.hashMatches(expectedHex: "", actualHex: "") && !U.hashMatches(expectedHex: "abc", actualHex: "abc"))

    // DeviceState-Rueckwaertskompatibilitaet
    check("Update-Pruefung Standard an, nie geprueft", DeviceState().ui.autoUpdateCheck && DeviceState().ui.lastUpdateCheck == nil)
    if let enc = try? JSONEncoder().encode(DeviceState()),
       var obj = try? JSONSerialization.jsonObject(with: enc) as? [String: Any],
       var ui = obj["ui"] as? [String: Any] {
        ui.removeValue(forKey: "autoUpdateCheckStored")
        ui.removeValue(forKey: "lastUpdateCheck")
        obj["ui"] = ui
        if let old = try? JSONSerialization.data(withJSONObject: obj),
           let st = try? JSONDecoder().decode(DeviceState.self, from: old) {
            check("Alte state.json ohne Update-Felder: autoUpdateCheck an", st.ui.autoUpdateCheck && st.ui.lastUpdateCheck == nil)
        } else { check("Alte state.json dekodierbar", false) }
    } else { check("State kodierbar", false) }
    var up = DeviceState(); up.ui.autoUpdateCheck = true; up.ui.lastUpdateCheck = Date(timeIntervalSince1970: 1_700_000_000)
    if let enc = try? JSONEncoder().encode(up), let back = try? JSONDecoder().decode(DeviceState.self, from: enc) {
        check("Update-Felder: Rundreise", back.ui.autoUpdateCheck && back.ui.lastUpdateCheck == up.ui.lastUpdateCheck
              && back.sanitized().ui.autoUpdateCheck)
    } else { check("Update-Felder kodierbar", false) }
    var fut = DeviceState(); fut.ui.lastUpdateCheck = Date().addingTimeInterval(86_400 * 30)
    check("sanitized: Pruefzeitpunkt weit in der Zukunft -> nil", fut.sanitized().ui.lastUpdateCheck == nil)
    var past = DeviceState(); past.ui.lastUpdateCheck = Date().addingTimeInterval(-3600)
    check("sanitized: vergangener Pruefzeitpunkt bleibt", past.sanitized().ui.lastUpdateCheck != nil)
}
