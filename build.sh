#!/bin/bash
# build.sh – baut Level iD nur mit den Xcode Command Line Tools (swiftc + clang), ohne Xcode-Projekt/SwiftPM.
#   ./build.sh test   -> baut und startet die Offline-Tests (kein Geraetezugriff)
#   ./build.sh app    -> baut ".build/Level iD.app" (signiert mit "Level iD Release", sonst ad hoc)
#   ./build.sh probe  -> baut das Diagnose-CLI .build/id14ctl (nur lesend)
#   ./build.sh dist   -> baut .build/Level-iD-<Version>.dmg zum Weitergeben (+ Level-iD.dmg und Level-iD.dmg.sha256)
#   ./build.sh install -> baut und installiert nach /Applications (fuer Login-Start/Absturz-Neustart)
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD
OUT=$ROOT/.build
mkdir -p "$OUT"

# Optional: lokale Overrides in .buildenv (nicht im Repo), z.B. VFS-Overlay fuer defekte Command Line Tools:
#   OVERLAY=/pfad/overlay.yaml   SDK=/pfad/MacOSX.sdk   export CPLUS_INCLUDE_PATH=...
[ -f "$ROOT/.buildenv" ] && source "$ROOT/.buildenv"
SDK=${SDK:-$(xcrun --sdk macosx --show-sdk-path)}
SWIFTFLAGS=(-O -swift-version 5 -target arm64-apple-macos14.0 -sdk "$SDK")
if [ -n "${OVERLAY:-}" ]; then
  SWIFTFLAGS+=(-vfsoverlay "$OVERLAY" -Xcc -ivfsoverlay -Xcc "$OVERLAY")
fi

# Dateien, die OHNE USB/UI kompilieren muessen (Offline-Tests)
CORE_PURE=(Sources/Core/Protocol.swift Sources/Core/DeviceState.swift Sources/Core/MixerMath.swift
           Sources/Core/PushPlan.swift Sources/Core/IDStateImporter.swift Sources/Core/StateStore.swift
           Sources/Core/RecordingTransport.swift Sources/Core/VolumeStep.swift
           Sources/Core/DeviceProfile.swift Sources/Core/DeviceReport.swift Sources/Core/UpdateCheck.swift)

# Test-Build: zusaetzlich Controller + MeterModel (ohne USBTransport/cusb; Diag liefert Tests/FaultTransport.swift)
CORE_TEST=("${CORE_PURE[@]}" Sources/Core/MeterModel.swift Sources/Core/MeterScale.swift Sources/Core/TalkbackBridge.swift
           Sources/Core/DeviceController.swift)

# Nur fuer lokale Updater-Tests: LEVELID_UPDATE_TEST=1 ./build.sh app  (erlaubt LEVELID_UPDATE_URL/_TARGET).
# Nie fuer install/dist.
TESTFLAGS=()
if [ -n "${LEVELID_UPDATE_TEST:-}" ]; then
  TESTFLAGS=(-D LEVELID_UPDATE_TEST)
  case "${1:-app}" in
    install|dist) echo "FEHLER: LEVELID_UPDATE_TEST ist nur fuer 'app' erlaubt" >&2; exit 2 ;;
  esac
  echo "HINWEIS: Test-Build mit LEVELID_UPDATE_TEST (Update-URL ueberschreibbar) - nicht weitergeben" >&2
fi

build_cusb() {
  clang -c -O2 -Wall -Wextra -target arm64-apple-macos14.0 -isysroot "$SDK" \
        Sources/CUSB/cusb.c -o "$OUT/cusb.o"
}

# Signieren: mit dem Zertifikat "Level iD Release" (feste Identitaet, siehe Tools/make-signing-cert.sh),
# sonst ad hoc. Nur mit fester Identitaet behaelt macOS die Bedienungshilfen-Berechtigung ueber Updates.
sign_app() {
  local app=$1 ids
  # In Variable einlesen statt Pipe: vermeidet SIGPIPE-Fehler unter pipefail
  ids=$(security find-identity -p codesigning 2>/dev/null || true)
  if grep -q "Level iD Release" <<<"$ids"; then
    codesign --force --options runtime --timestamp=none \
      --entitlements "$ROOT/Resources/LevelID.entitlements" \
      --sign "Level iD Release" "$app"
  else
    echo "WARNUNG: ad hoc signiert: Bedienungshilfen-Recht geht bei jedem Update verloren – einmalig Tools/make-signing-cert.sh ausführen" >&2
    codesign --force -s - "$app"
  fi
}

case "${1:-app}" in
  test)
    swiftc "${SWIFTFLAGS[@]}" "${CORE_TEST[@]}" Tests/*.swift -o "$OUT/offline-tests"
    "$OUT/offline-tests" "$ROOT/Tests"
    ;;
  probe)
    build_cusb
    swiftc "${SWIFTFLAGS[@]}" -import-objc-header Sources/CUSB/cusb.h \
      "${CORE_PURE[@]}" Sources/Core/USBTransport.swift Tools/id14ctl.swift \
      "$OUT/cusb.o" -framework IOKit -framework CoreFoundation -o "$OUT/id14ctl"
    ;;
  app)
    build_cusb
    APP="$OUT/Level iD.app"
    rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    # Zuverlaessigkeit: strikte Concurrency-Pruefung, jede Warnung bricht den Build ab
    swiftc "${SWIFTFLAGS[@]}" -strict-concurrency=complete -warnings-as-errors \
      ${TESTFLAGS[@]+"${TESTFLAGS[@]}"} -parse-as-library -import-objc-header Sources/CUSB/cusb.h \
      Sources/Core/*.swift Sources/UI/*.swift "$OUT/cusb.o" \
      -framework IOKit -framework CoreFoundation -framework ServiceManagement \
      -o "$APP/Contents/MacOS/ID14Control"
    cp Resources/Info.plist "$APP/Contents/Info.plist"
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    # Login-Start/Absturz-Neustart: klassischer LaunchAgent in ~/Library/LaunchAgents,
    # wird von der App selbst geschrieben (SingleInstance.swift). Kein SMAppService (Signaturbindung).
    sign_app "$APP"
    codesign --verify "$APP"
    echo "Gebaut: $APP"
    ;;
  install)
    # Baut und installiert nach /Applications (fester Pfad fuer den LaunchAgent).
    "$0" app
    DEST="/Applications/Level iD.app"
    OLD="/Applications/ID14 Control.app"     # frueherer Name
    OLD2="/Applications/Minimal iD Control.app"   # frueherer Name
    AGENT="$HOME/Library/LaunchAgents/app.levelid.mac.plist"
    # SIGTERM -> App speichert und endet mit Exit 0 -> launchd startet sie NICHT neu
    pkill -TERM -x ID14Control 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -x ID14Control >/dev/null || break; sleep 0.25; done
    rm -rf "$DEST" "$OLD" "$OLD2"
    ditto "$OUT/Level iD.app" "$DEST"
    codesign --verify "$DEST"
    touch "$DEST"   # Finder/Dock-Icon-Cache aktualisieren
    if [ -f "$AGENT" ]; then
      # Agent auf den (ggf. neuen) Programmpfad zeigen lassen
      plutil -replace ProgramArguments -json "[\"$DEST/Contents/MacOS/ID14Control\"]" "$AGENT"
      launchctl bootout "gui/$(id -u)/app.levelid.mac" 2>/dev/null || true
      sleep 1
      # Login-Start aktiv: verwaltete Instanz mit der neuen Version starten
      launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || true
      launchctl kickstart "gui/$(id -u)/app.levelid.mac" || open "$DEST"
    else
      open "$DEST"
    fi
    echo "Installiert: $DEST"
    ;;
  dist)
    # Weitergabe-Paket: DMG mit App, Verknuepfung zu /Applications und README
    "$0" app
    VER=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
    STAGE="$OUT/dmg"; DMG="$OUT/Level-iD-$VER.dmg"
    rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
    ditto "$OUT/Level iD.app" "$STAGE/Level iD.app"
    ln -s /Applications "$STAGE/Applications"
    cp Resources/dist/README.txt "$STAGE/README.txt"
    hdiutil create -volname "Level iD $VER" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    # Release-Assets mit festen Namen fuer die In-App-Aktualisierung (Updater sucht genau diese Namen)
    cp "$DMG" "$OUT/Level-iD.dmg"
    (cd "$OUT" && shasum -a 256 Level-iD.dmg > Level-iD.dmg.sha256)
    echo "Paket: $DMG"
    echo "Release-Assets: $OUT/Level-iD.dmg und $OUT/Level-iD.dmg.sha256"
    ;;
  *) echo "Aufruf: $0 [test|app|probe|install|dist]"; exit 2 ;;
esac
