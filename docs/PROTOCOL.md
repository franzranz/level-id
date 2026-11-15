# Audient iD14 MkII – USB control protocol

Notes written for interoperability, from observing the behavior of the device over USB. Verified on one iD14 MkII, firmware bcdDevice 1.12. Not an official specification. Everything here is also encoded in `Sources/Core/Protocol.swift`.

## Basics
- Device: **VID 0x2708 / PID 0x0008**, USB 2.0 High Speed.
- All commands are **UAC2 class requests to interface 0** on endpoint 0:
  - GET_CUR: `bmRequestType 0xA1, bRequest 0x01`
  - SET_CUR: `bmRequestType 0x21, bRequest 0x01`
  - GET_RANGE: `0xA1 / 0x02`
  - GET_MEM: `0xA1 / 0x03` (meters only)
  - `wValue = (ControlSelector << 8) | channel`, `wIndex = (UnitID << 8) | 0`
- dB values: **int16 little-endian in 1/256 dB**, minimum `0x8000` = −128 dB (silent), maximum 0 dB. GET_RANGE of the feature units reports −127…0 dB in 1 dB steps, but finer values are accepted.
- On macOS the device can be addressed through `IOUSBDeviceInterface` with `DeviceRequest` and **without** `USBDeviceOpen`, so it works alongside the Apple USB audio driver.

## Important behavior
- **The device stores no state.** After every unplug and plug-in, monitor, mixer and output levels are at −128 dB. The host must resend the full state (about 250 SETs). Do not send them all at once: pace them (about 10 ms apart) and wait a few seconds after attach first. Flooding the device right after attach can make it stop responding until it is replugged.
- After plugging in, the monitor volume is −128 dB, so fading in produces no jump.
- Reading only meter block 0 repeatedly can make the firmware stop responding. Read all four blocks in sequence.

## Change notifications (Unit 0x3E, CS 0x06)
- GET_CUR `0x3E / CS 0x06 / ch 0`, 4 bytes: `[CS, channel, 00, unit]`. `ff xx 00 ff` means "nothing changed" (xx = counter).
- A notification stays pending until the reported control has been read (true for unit 0x36). For unit 0x0A it stays pending even after reading.
- The channel byte in notifications is 0-based.
- Examples: `12 00 00 36` = monitor volume changed (hardware knob). `02 04 00 0a` = knob moved in headphone mode (FU 0x0A, channel 5). `ff 01..09 00 ff` = sequence after plug-in.
- 5–10 Hz polling is enough for an app. 100 ms keeps button presses responsive.

## Monitor controller – extension unit 0x36
| CS | Length | Function | Values |
|---|---|---|---|
| 0x00 | 1 | Mono | 0/1 |
| 0x03 | 1 | Monitor polarity | 0/1 |
| 0x04 | 1 | Cut (mute) | 0/1 |
| 0x05 | 1 | Dim | 0/1 |
| 0x06 | 2 | Dim attenuation | dB |
| 0x07 | 1 | Talkback | 0/1 |
| 0x08 | 1 | Talkback input | index |
| 0x0C | 1 | Speaker select Main/Alt | 0 = Main, 1 = Alt |
| 0x10 | 2 (ch = key) | Function key mode | `ff ff` = none |
| 0x12 | 2 | **Monitor volume** | dB; the hardware knob changes this value and reports it via 0x3E |
| 0x15 | 1 | Cue solo | 0/1 |
| 0x17 | 2 (ch 1) | Alt monitor trim | dB |

Function key mode values equal the CS number of the function: `0x00` Mono, `0x04` Cut, `0x05` Dim, `0x07` Talkback, `0x0C` Alt speakers, `-1` none. Talkback (CS 0x07) automatically also enables Dim in the firmware.

## Headphones
- Notification channels for unit 0x0A are 0-based: a notification with channel 4/5 refers to **FU 0x0A, channels 5/6**.
- Headphone mute: SET_CUR FU 0x0A, CS 0x01, channels 5 and 6, 1 byte 0/1.
- Headphone knob level: FU 0x0A, CS 0x02, channels 5/6. **Not readable**: it always reads −128 dB even while the knob is audibly active. Setting it works.
- **Host controlled and required for sound:** mixer output **FU 0x0C, CS 0x02, channels 3/4**. After plug-in it is −128 dB, so the headphones are silent until the host raises it.

## Mixer – mixer unit 0x3C (16 inputs × 6 outputs)
- SET_CUR `CS 0x01`, **channel = input × 6 + output** (0x00…0x5F), value in dB. A pan is two sends (L/R).
- Pan law (p = 0…1, k = 0.004748821258544922): `gL = (1−p)·((1−p)·(−k) + 1 + k)`, `gR = p·(p·(−k) + 1 + k)`. Send dB = fader dB + 20·log10(g).
- Inputs: 0 Mic 1 · 1 Mic 2 · 2–9 Digital 1–8 (ADAT) · 10/11 DAW 1/2 · 12/13 DAW 3/4 · 14/15 DAW 5/6.
- Outputs: 0/1 Mix 1 (monitor) · 2/3 Mix 2 · 4/5 Mix 3. Mix 2 is the headphone mix.
- Mix output levels: feature unit 0x0C, CS 0x02, channels 1–6.
- Meters: GET_MEM `wIndex 0x3C00`, `wValue 0x0000` (32 B, inputs), `0x0001` (12 B, outputs), `0x0002` (16 B), `0x0003` (6 B). Encoding: uint16 LE per channel, **dB = 20·log10(v/65535)**, floored at −128 dB.

## Inputs – feature unit 0x0B
- Polarity: CS 0x0D, channel 1 = Mic 1, channel 2 = Mic 2, 1 byte 0/1.
- Input cut, solo and stereo link are pure host logic: they are implemented by setting mixer sends (0x3C) to −128 dB or changing pans.
- Gain and 48 V are analog and not controllable. No digital indication of the Hi-Z instrument input was found.

## Routing – extension units 0x33 (outputs) and 0x34 (USB inputs to the computer)
- SET_CUR `CS 0x06`, channel = destination, 1 byte = source.
- 0x34 (inputs to the computer, channels 0–11): at startup ch0…9 = 06…0F, ch10 = 12 / 00, ch11 = 13 / 01.
- Loopback: computer inputs 11/12 are 0x34 channels 10/11. Observed source codes are 0x12/0x13 and 0x00/0x01. Which code means on or off is not confirmed.

## Clock / system
- Clock source 0x29 (internal), 0x2C (optical), selector 0x28. Sample rate via GET 0x29 CS 1.
- 0x0100 CS 0: optical input mode (4 bytes, 0 = ADAT).

## Not available over USB
- LED meter source and knob step size.
- Gain, 48 V, Hi-Z state.

## Other iD models (derived from the iD app, not verified on hardware)

| Model | USB PID | Preamps | Headphone outputs | Optical in/out |
|---|---|---|---|---|
| iD24 | 0x000D | 2 | 1 (two jacks, same mix) | 1/1 |
| iD44 | 0x0005 | 4 | 2 independent | 2/2 |
| iD44 MkII | 0x000B | 4 | 2 independent | 2/2 |
| iD4 MkII | 0x0009 | 2 | 1 | – |

- In the iD app, iD24/iD44/iD44 MkII have a monitor section and default monitor and headphone volume to −128 dB after plug-in, like the iD14 MkII, so the host must restore the volume.
- The iD4 MkII has no monitor section in the iD app (its monitor-section builder returns null) and no function-key definition; Level iD does not support it.
- Unit IDs are discovered by the iD app at runtime from the USB descriptor, so they are not in the product definitions. Level iD assumes the iD14 MkII units until owner reports confirm them; until then these models are read-only.
- How the iD44's second headphone output is controlled is not known yet.
