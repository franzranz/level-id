# Changelog

## 1.3.0

- Built-in updates: Level iD checks GitHub for a new version at most once a week (Settings → Updates → "Check automatically", on by default). "Install" downloads the update, verifies its checksum and code signature, replaces the app and restarts. Nothing is installed without your click.
- Safer start after plugging in: two device settings that can make the iD14 firmware stop responding when read are no longer read, they are always sent instead.
- Stable code signature: macOS now keeps the Accessibility permission for the volume keys across updates. After installing 1.3.0, allow it one last time (System Settings → Privacy & Security → Accessibility).
- Settings: compact Updates row and the version number at the bottom.

## 1.2.0

- iD24 and iD44 / iD44 MkII are detected automatically and run read-only for now: meters and volume display work, but the app sends nothing to these devices until an owner confirms the protocol. iD24 is marked "unverified", iD44 "beta" (four input meters, no cue mix yet). The iD4 cannot be supported (no software volume control).
- Settings → "Help verify this device…" walks owners of these models through five checks and prepares a report for a GitHub issue. Nothing is sent automatically.
- Faster start after plugging in: only settings that differ from the device are sent, so the volume comes back after about 3 s instead of 4 s.
- Click the RMS value under the meters to switch to PPM (peak programme meter, useful for podcasts). The choice is remembered, and the target zone and marker follow the mode.
- Clearer target zone on the meters.
- Tooltips appear after 2 s instead of 1.5 s.

## 1.1.0

- Optional Mac volume keys (off by default): while the iD14 is the Mac's sound output, the volume and mute keys control the monitor or headphone volume, with a small on-screen display. Needs the Accessibility permission.
- Volume keys unmute the selected output, like macOS does.
- Input meters ramp up over 0.5 s after opening the panel or plugging in, so startup glitches no longer show up as a false peak or clip.

## 1.0.0

First public release.

- Menu bar app for the Audient iD14 MkII: monitor and headphone volume, input level meters, cue mix.
- Remembers the volume across unplugging, with a fade-in and a configurable "Safe start level".
- iD button assignment: Off, Mute (monitor, headphones, or both), Mono, Alt speakers, Talkback.
- Talkback via mic 1, mic 2, both, or the Mac microphone, routed to the headphones only.
- Monitor speaker pair switch (Output 1/2 or 3/4).
- Pro-style input meters with RMS, peak hold, and a clip indicator.
- Uses about 0 % CPU while the panel is closed.
