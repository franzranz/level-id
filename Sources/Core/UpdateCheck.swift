// UpdateCheck.swift – reine Logik der Update-Pruefung (kein AppKit, kein Netzwerk): Versionsvergleich,
// Release-JSON (GitHub "releases/latest"), Asset-Auswahl, Pruefsummen. Netzwerk/Installation: Sources/UI/Updater.swift.
import Foundation
import CryptoKit

enum UpdateCheck {
    static let dmgName = "Level-iD.dmg"
    static let checksumName = "Level-iD.dmg.sha256"

    /// Numerische Version ("1.10.0", "v1.2"). Nachgestellte Nullen zaehlen nicht (1.2 == 1.2.0).
    struct Version: Equatable, Comparable, CustomStringConvertible {
        let parts: [Int]

        init?(_ text: String) {
            var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
            let pieces = t.split(separator: ".", omittingEmptySubsequences: false)
            guard !pieces.isEmpty, pieces.count <= 6 else { return nil }
            var nums: [Int] = []
            for p in pieces {
                guard !p.isEmpty, p.count <= 9, p.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let n = Int(p) else { return nil }
                nums.append(n)
            }
            while nums.count > 1, nums.last == 0 { nums.removeLast() }
            parts = nums
        }

        static func < (a: Version, b: Version) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
        var description: String { parts.map(String.init).joined(separator: ".") }
    }

    /// true nur, wenn beide Versionen gueltig sind und `remote` echt neuer ist. Ungueltig -> false.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        guard let r = Version(remote), let l = Version(local) else { return false }
        return r > l
    }

    struct Asset: Equatable {
        let name: String
        let url: URL
    }

    struct Release: Equatable {
        let tag: String
        let version: Version
        let htmlURL: URL
        let isDraft: Bool
        let isPrerelease: Bool
        let assets: [Asset]

        var dmg: Asset? { assets.first { $0.name == UpdateCheck.dmgName } }
        var checksum: Asset? { assets.first { $0.name == UpdateCheck.checksumName } }
        /// Beide Assets vorhanden (Voraussetzung fuer die Ein-Klick-Installation)
        var isInstallable: Bool { dmg != nil && checksum != nil }
    }

    /// Release-JSON parsen. nil bei ungueltigem JSON, fehlendem/ungueltigem tag_name oder html_url.
    /// Assets mit unerlaubtem URL-Schema oder ohne Namen werden uebersprungen.
    static func parseRelease(_ data: Data, allowedSchemes: Set<String> = ["https"]) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, let version = Version(tag),
              let page = obj["html_url"] as? String, let htmlURL = URL(string: page),
              let scheme = htmlURL.scheme?.lowercased(), allowedSchemes.contains(scheme)
        else { return nil }
        var assets: [Asset] = []
        for a in (obj["assets"] as? [[String: Any]]) ?? [] {
            guard let name = a["name"] as? String, !name.isEmpty,
                  let s = a["browser_download_url"] as? String, let u = URL(string: s),
                  let sc = u.scheme?.lowercased(), allowedSchemes.contains(sc) else { continue }
            assets.append(Asset(name: name, url: u))
        }
        return Release(tag: tag, version: version, htmlURL: htmlURL,
                       isDraft: obj["draft"] as? Bool ?? false,
                       isPrerelease: obj["prerelease"] as? Bool ?? false,
                       assets: assets)
    }

    /// Das Release, falls es ein Update gegenueber `current` ist (kein Entwurf, kein Pre-Release, echt neuer).
    static func update(_ release: Release, current: String) -> Release? {
        guard !release.isDraft, !release.isPrerelease, let cur = Version(current), release.version > cur else { return nil }
        return release
    }

    /// Inhalt einer .sha256-Datei (`shasum -a 256`: "<hex>  <Dateiname>") -> Hash in Kleinbuchstaben.
    /// Mit Dateiname: die Zeile muss zu `fileName` passen. Eine Zeile nur mit Hash wird auch akzeptiert.
    static func parseChecksumFile(_ text: String, fileName: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = fields.first, isHex64(String(first)) else { continue }
            let hash = String(first).lowercased()
            if fields.count == 1 { return hash }
            var name = fields.dropFirst().joined(separator: " ")
            if name.hasPrefix("*") { name.removeFirst() }
            if name == fileName || (name as NSString).lastPathComponent == fileName { return hash }
        }
        return nil
    }

    private static func isHex64(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 einer Datei, gestreamt (DMG ist gross).
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk = try fh.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Hash-Vergleich (Hex, Gross-/Kleinschreibung egal). Leer/ungueltig -> false.
    static func hashMatches(expectedHex: String, actualHex: String) -> Bool {
        isHex64(expectedHex) && isHex64(actualHex) && expectedHex.lowercased() == actualHex.lowercased()
    }
}
