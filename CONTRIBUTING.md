# Contributing to Level iD

Thanks for your interest. This is a small hobby project, so any help is welcome, from a short bug report to a pull request.

## What I would like most

1. **Feedback.** Tell me what works, what does not, and what confuses you. Please open an issue.
2. **Testing on other Audient interfaces** (iD4, iD22, iD24, iD44). Support is limited to the iD14 MkII today because that is the only device I can test. If you want to help extend it:
   - Build the read-only probe: `./build.sh probe`, then run `.build/id14ctl status` and `.build/id14ctl sends`. These only read from the device.
   - Compare the output with [docs/PROTOCOL.md](docs/PROTOCOL.md). Unit IDs, channel counts and the USB product ID will differ per model.
   - Share what you find in an issue before sending any write commands to the device. Please only send commands that Audient's own iD app also sends.
3. **Other help I could use:**
   - Testing on other Macs and macOS versions, light mode, and sleep/wake.
   - Open protocol questions: is the +10 dB input boost controllable over USB, which routing codes switch loopback on or off, and how newer firmware behaves.
   - Code signing and notarization, a Homebrew cask, and translations.

## Reporting a bug

Please include:
- macOS version and Mac model (Apple silicon or Intel).
- iD14 MkII firmware version, if you know it.
- What you did, what you expected, and what happened.
- The diagnostic log, if it is relevant: `~/Library/Logs/ID14Control.log`. Check it for anything you do not want to share first.

## Building and testing

You need the Xcode Command Line Tools.

```bash
./build.sh test   # offline tests, no device access
./build.sh app    # builds the app
```

The offline tests do not touch hardware. Please run them before sending a pull request and add a test for new behavior where you can. The app is built with strict concurrency checking and warnings as errors.

## Safety rules for device access

- Never send firmware or DFU commands.
- Only send control commands that Audient's own iD app sends. The allowed list is `ID14.isWritable` in `Sources/Core/Protocol.swift`.
- Keep the startup push slow and checked. Flooding the device right after plug-in can make it stop responding until it is replugged.

## Code style

Keep changes small and focused. Match the style of the surrounding code. Code comments are partly in German, you may write new ones in English.
