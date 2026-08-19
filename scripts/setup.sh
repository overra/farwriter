#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need() {
  command -v "$1" >/dev/null || {
    echo "Missing required command: $1" >&2
    echo "$2" >&2
    exit 1
  }
}

if [[ $(uname -s) != Darwin ]]; then
  echo "This stack only runs on macOS." >&2
  exit 1
fi
if [[ $(uname -m) != arm64 ]]; then
  echo "This stack needs Apple Silicon. The ASR and editor models are Core ML / MLX." >&2
  exit 1
fi

need git "Install Xcode command-line tools: xcode-select --install"
need swift "Install Xcode command-line tools: xcode-select --install"
need xcodebuild "Install Xcode command-line tools: xcode-select --install"

if ! command -v brew >/dev/null; then
  echo "Homebrew is required." >&2
  echo 'Install it from https://brew.sh then re-run this script.' >&2
  exit 1
fi

brew list opus >/dev/null 2>&1 || brew install opus
brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
brew list python@3.12 >/dev/null 2>&1 || brew install python@3.12

if [[ ! -x /opt/homebrew/bin/python3.12 ]]; then
  echo "Python 3.12 did not land at /opt/homebrew/bin/python3.12." >&2
  exit 1
fi
if [[ ! -f /opt/homebrew/lib/libopus.a ]]; then
  echo "Homebrew opus did not provide /opt/homebrew/lib/libopus.a." >&2
  exit 1
fi

if ! command -v bun >/dev/null; then
  echo "Installing bun via Homebrew..."
  brew install oven-sh/bun/bun
fi
need bun "Install bun: brew install oven-sh/bun/bun"

if ! command -v pi >/dev/null; then
  echo "pi is not on PATH. Dictation will still build; assistant mode will not."
  echo "Install @earendil-works/pi-coding-agent, put pi on PATH, and configure"
  echo "a model provider before using the orange assistant."
fi

(
  cd "$ROOT"
  bun install --frozen-lockfile 2>/dev/null || bun install
)

cat <<EOF

Local tools are ready.

Apple still has to be installed by hand, once per machine:

1. Download Additional Tools for Xcode from
   https://developer.apple.com/download/all/?q=Additional%20Tools
   and put PacketLogger.app in /Applications.
2. Install Apple's Bluetooth Logging for macOS profile
   (com.apple.bluetooth.1) from those same additional tools.
3. Pair a silver Siri Remote A2540 or A2854.

Then:

  $SCRIPTS/build.sh
  $SCRIPTS/run.sh

The first launch of iRemote will ask for administrator approval to
install its PacketLogger helper. That is expected.

First build downloads a few gigabytes of models. Later builds reuse
generated/.
EOF
