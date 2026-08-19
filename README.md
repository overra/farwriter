# Farwriter

Hold a clicker, speak, and the words land in the focused app.

Farwriter is local voice input for the silver Apple TV remotes (A2540
Lightning and A2854 USB-C) on Apple Silicon Macs. It uses the remote's
microphone, not the Mac's. Ordinary dictation never leaves the machine.

This is an independent project and is not affiliated with, endorsed by,
or associated with Apple Inc.

## What you get

- Hold the microphone button to dictate. Live captions appear; the
  focused app only receives the cleaned final text.
- Double-tap that button to send Return.
- Tap Back to delete one character; hold Back and it repeats like a
  phone keyboard.
- Optional: tap, then hold within 1.4 seconds for a one-shot assistant
  that can open a search, launch an installed app, or play YouTube /
  YouTube Music.

Play/Pause, volume, and mute stay with the system.

## Why this is a workshop, not a welcome mat

Apple's public HID APIs expose the remote's buttons. They do not expose
the microphone. The system Bluetooth stack consumes that audio before
userspace can hear it.

Farwriter does not guess packets. It already knows the Opus frames and
the ATT handles. What it cannot do, without help, is *see* them.

The free latch is Apple's own diagnostic tap: PacketLogger, from
Additional Tools for Xcode, plus the Bluetooth Logging for macOS
profile. This repository does not bundle, download, or redistribute
either one. You fetch them from Apple, then Farwriter tails the capture
PacketLogger writes.

That is a diagnostic key, not a supported input API. Future macOS
releases can close it. Engineers should treat this as a locksmith's
latch, not a doorbell.

## On another Mac

You need Apple Silicon, macOS 14 or newer, and a paired silver remote.

```bash
git clone git@github.com:overra/farwriter.git
cd farwriter
./scripts/setup.sh
./scripts/build.sh
./scripts/run.sh
```

`setup.sh` installs Homebrew packages (`opus`, `xcodegen`, `python@3.12`,
`bun` if missing) and the local TypeScript packages used by the optional
assistant. It will not download Apple's tools.

Apple steps, once per machine:

1. Download **Additional Tools for Xcode** from
   [developer.apple.com](https://developer.apple.com/download/all/?q=Additional%20Tools).
2. Put `PacketLogger.app` in `/Applications`.
3. Install the **Bluetooth Logging for macOS** profile
   (`com.apple.bluetooth.1`) from those same additional tools. Sign in
   with an Apple ID; approve the profile in System Settings. Do not
   redistribute the profile.
4. Pair the remote.

The first run of the app asks for administrator approval to install a
narrow PacketLogger helper. That is expected.

Stop everything with:

```bash
./scripts/run.sh --stop
```

Spoken receipts are off by default. To keep the completed Kokoro
integration resident:

```bash
IREMOTE_ENABLE_TTS=1 ./scripts/build.sh
IREMOTE_ENABLE_TTS=1 ./scripts/run.sh
```

That costs about 2 GiB of memory for little payoff beside the captions.

## Assistant

The assistant is optional. Dictation works without it.

To enable the orange one-shot mode, install and configure
[`pi`](https://github.com/earendil-works/pi) so the `pi` binary is on
`PATH`. The runner then starts a tool-limited session with no shell,
filesystem, browser, or AppleScript tool. It can only:

- open an encoded Google or Perplexity search (Google unless you name
  Perplexity)
- launch an installed app with `/usr/bin/open -a`
- open an allowlisted YouTube or YouTube Music URL

Audio never leaves the machine. Only the finalized command text reaches
pi's configured model.

Examples:

- `Google how much this remote cost when it was new`
- `ask Perplexity what the weather will be tomorrow`
- `open Slack`
- `play Miles Davis on YouTube`

## Spoken editing

Pause after dictating, then end with any reasonable request to change
the preceding text. There is no fixed phrase.

- `turn that into a bulleted list`
- `make it half as long`
- `write that as an email`

Without a trailing request, cleanup is a conservative copyedit.

## Layout

```
scripts/          setup, build, run, workers, tests
patches/          reproducible iRemote patch
generated/        clones, models, venvs, logs, keys (gitignored)
```

Pinned upstream:

- iRemote `e2d5efa1c486882ea39f9efb74a968a901dbc928` (MIT)
- FluidAudio `7f3f96ed88f927f5ae5a63461a27bdce63e213e7` (Apache-2.0)
- Parakeet Core ML weights (CC-BY-4.0)
- Gemma 4 E4B (Apache-2.0)

## Privacy

Ordinary dictation and cleanup are local. The cleaner and assistant bind
only to `127.0.0.1` and share a mode-`0600` bearer key under `generated/`.
Utterance audio is deleted after editing. PacketLogger's rolling capture
is removed when the listener stops. The Apple Bluetooth logging profile
stays installed until you remove it in System Settings.

## License

MIT. See [LICENSE](LICENSE).

Farwriter is not affiliated with Apple. PacketLogger and the Bluetooth
Logging profile are Apple's, fetched by you, never shipped here.

This started as a household experiment in
[clanklin](https://github.com/overra/clanklin.com) and now lives on its
own so other engineers can pick it up.
