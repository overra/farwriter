# Siri Remote voice

Local voice input for the aluminum Apple Siri Remote on macOS. It uses the
remote's microphone, not the Mac's. Dictation stays on the machine. The
optional assistant can open a search, launch an installed app, or play
YouTube / YouTube Music.

This was lifted out of [clanklin.com](https://github.com/overra/clanklin.com)
so another household Mac can clone it without taking the whole house.

## What you get

- Hold **Siri** to dictate. Live captions appear; the focused app only
  receives the cleaned final text.
- Double-tap **Siri** to send Return.
- Tap **Back** to delete one character; hold Back and it repeats like a
  phone keyboard.
- Tap Siri, then hold within 1.4 seconds for a one-shot orange assistant.

Play/Pause, volume, and mute stay with the system.

## On another Mac

You need Apple Silicon, macOS 14 or newer, and a silver Remote (A2540
Lightning or A2854 USB-C).

```bash
git clone git@github.com:overra/siri-remote-voice.git
cd siri-remote-voice
./scripts/setup.sh
./scripts/build.sh
./scripts/run.sh
```

`setup.sh` installs Homebrew packages (`opus`, `xcodegen`, `python@3.12`,
`bun` if missing) and the local pi TypeScript packages. It will not
download Apple's PacketLogger for you.

Apple steps, once per machine:

1. Download **Additional Tools for Xcode** from
   [developer.apple.com](https://developer.apple.com/download/all/?q=Additional%20Tools).
2. Put `PacketLogger.app` in `/Applications`.
3. Install the **Bluetooth Logging for macOS** profile
   (`com.apple.bluetooth.1`).
4. Pair the Remote.

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

Pi must already be installed and configured. The runner starts a
tool-limited session with no shell, filesystem, browser, or AppleScript
tool. It can only:

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
