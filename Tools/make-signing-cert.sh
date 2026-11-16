#!/bin/bash
# make-signing-cert.sh – legt einmalig ein selbstsigniertes Codesigning-Zertifikat
# "Level iD Release" im Anmeldeschluesselbund an.
# Damit signiert build.sh mit einer festen Identitaet, sodass macOS die
# Bedienungshilfen-Berechtigung ueber Updates hinweg behaelt.
set -euo pipefail

IDENT="Level iD Release"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Schon vorhanden und vertrauenswuerdig? Dann ist nichts zu tun.
VALID=$(security find-identity -v -p codesigning 2>/dev/null || true)
if grep -q "$IDENT" <<<"$VALID"; then
  echo "Signierzertifikat \"$IDENT\" ist bereits vorhanden – nichts zu tun."
  exit 0
fi

# Vorhanden, aber nicht als vertrauenswuerdig gelistet? Dann nicht erneut importieren
# (sonst entstehen doppelte Eintraege).
ALL=$(security find-identity -p codesigning 2>/dev/null || true)
if grep -q "$IDENT" <<<"$ALL"; then
  echo "Identitaet \"$IDENT\" ist vorhanden, wird aber nicht als vertrauenswuerdig gelistet."
  echo "codesign kann trotzdem damit signieren (ueblich bei selbstsignierten Zertifikaten)."
  exit 0
fi

# /usr/bin/openssl (LibreSSL auf macOS) statt Homebrew-OpenSSL: erzeugt .p12-Dateien,
# die der macOS-Schluesselbund zuverlaessig importiert.
OSSL=/usr/bin/openssl
echo "Verwende: $("$OSSL" version)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/levelid-cert.XXXXXX")
# Temporaere Dateien (Schluessel, Zertifikat, Passwort) beim Beenden wieder loeschen
trap 'rm -rf "$TMP"' EXIT

# Zertifikatsprofil fuer Codesigning
cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no

[dn]
CN = Level iD Release

[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# Selbstsigniertes Zertifikat (RSA 2048, 10 Jahre) erzeugen
"$OSSL" req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.cnf"

# Einmal-Passwort fuer das .p12 (wird nur per Umgebungsvariable uebergeben, nicht in der Prozessliste)
LEVELID_P12_PW=$("$OSSL" rand -hex 16)
export LEVELID_P12_PW

# Legacy-Verschluesselung (3DES/SHA1), die macOS beim Import akzeptiert.
# OpenSSL 3 braucht dafuer -legacy; LibreSSL kennt die Option nicht.
LEGACY=()
if "$OSSL" version | grep -q '^OpenSSL'; then
  LEGACY=(-legacy)
fi

"$OSSL" pkcs12 ${LEGACY[@]+"${LEGACY[@]}"} -export \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$IDENT" \
  -out "$TMP/identity.p12" \
  -passout env:LEVELID_P12_PW \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

# In den Anmeldeschluesselbund importieren; codesign darf den Schluessel nutzen
security import "$TMP/identity.p12" -k "$KEYCHAIN" \
  -P "$LEVELID_P12_PW" -T /usr/bin/codesign

# Pruefen, ob die Identitaet jetzt gelistet wird
VALID=$(security find-identity -v -p codesigning 2>/dev/null || true)
if grep -q "$IDENT" <<<"$VALID"; then
  echo "Zertifikat \"$IDENT\" wurde importiert und ist vertrauenswuerdig."
else
  ALL=$(security find-identity -p codesigning 2>/dev/null || true)
  if grep -q "$IDENT" <<<"$ALL"; then
    echo "Zertifikat \"$IDENT\" wurde importiert. Es wird ohne -v gelistet (nicht als vertrauenswuerdig markiert)."
    echo "codesign kann trotzdem damit signieren."
  else
    echo "FEHLER: Zertifikat \"$IDENT\" wurde nach dem Import nicht gefunden." >&2
    exit 1
  fi
fi

echo ""
echo "Hinweis: Beim ersten Signieren fragt macOS nach dem Schluesselzugriff."
echo "Dort einmalig \"Immer erlauben\" waehlen, sonst muss jedes Mal bestaetigt werden."
