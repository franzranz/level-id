# Changelog

## Unreleased

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
