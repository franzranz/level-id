Level iD 1.0 – slim menu bar app for the Audient iD14 MkII
====================================================================

Requirements
- Mac with Apple silicon (M1 or newer), macOS 14 Sonoma or newer
- Audient iD14 MkII (other Audient devices are not supported)

Installation
1. Drag "Level iD" into the "Applications" folder.
2. The app is not notarized by Apple. On first launch macOS therefore says that the
   developer cannot be verified. To open it anyway:
   - macOS 14: in Applications, right-click the app -> "Open" -> "Open".
   - macOS 15 and newer: launch the app once normally (dismiss the message), then
     System Settings -> Privacy & Security -> scroll down -> "Open Anyway".
   This is only needed the very first time.
3. The app appears as an icon in the menu bar. It can optionally be hidden while no
   ID14 is plugged in (Settings).

Good to know
- Please do not use Audient's original "iD" app at the same time. While iD is running,
  Level iD switches to read-only automatically.
- Keep doing firmware updates with the official iD app.
- Settings: launch at login (including automatic restart after a crash), remember
  volume, volume limit after plugging in, iD button assignment, talkback.
- For talkback via the Mac microphone, macOS asks for microphone access once.
- If the ID14 stops responding (notice in the panel), unplug it and plug it back in.
- Settings file: ~/Library/Application Support/ID14Control/
  Diagnostic log: ~/Library/Logs/ID14Control.log

Uninstall
Quit the app ("Quit" in the panel) and move it to the Trash. If "Launch at login" was
enabled, switch it off in Settings first.

Unofficial software, not affiliated with Audient. Use at your own risk.
