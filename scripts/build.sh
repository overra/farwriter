#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ENABLE_TTS=${IREMOTE_ENABLE_TTS:-0}
if [[ "$ENABLE_TTS" != 0 && "$ENABLE_TTS" != 1 ]]; then
  echo "IREMOTE_ENABLE_TTS must be 0 or 1." >&2
  exit 1
fi

for command in git xcodegen xcodebuild swift bun; do
  command -v "$command" >/dev/null || {
    echo "Missing required command: $command" >&2
    echo "Run $SCRIPTS/setup.sh first." >&2
    exit 1
  }
done

PYTHON=${PYTHON:-/opt/homebrew/bin/python3.12}
if [[ ! -x "$PYTHON" ]]; then
  echo "Python 3.12 is required at $PYTHON (override with PYTHON=/path/to/python3.12)." >&2
  exit 1
fi

"$PYTHON" - <<PY
import ast
from pathlib import Path
for script in ("siri-remote-assistant.py", "siri-remote-tts.py"):
    ast.parse(Path("$SCRIPTS", script).read_text(encoding="utf-8"))
PY

mkdir -p "$GENERATED"

for path in /opt/homebrew/include/opus/opus.h /opt/homebrew/lib/libopus.a; do
  if [[ ! -f "$path" ]]; then
    echo "Missing static Opus dependency: $path" >&2
    echo "Install it with: brew install opus" >&2
    exit 1
  fi
done

if [[ ! -d "$ROOT/node_modules/@earendil-works/pi-coding-agent" ]]; then
  echo "Missing local pi packages. Run $SCRIPTS/setup.sh first." >&2
  exit 1
fi

if [[ ! -d "$FLUID/.git" ]]; then
  git clone "$FLUID_REPO" "$FLUID"
fi
git -C "$FLUID" fetch --quiet origin "$FLUID_COMMIT"
git -C "$FLUID" reset --hard "$FLUID_COMMIT"
git -C "$FLUID" clean -fd
swift build --package-path "$FLUID" -c release --product fluidaudiocli

if [[ ! -d "$IREMOTE/.git" ]]; then
  git clone "$IREMOTE_REPO" "$IREMOTE"
fi
git -C "$IREMOTE" fetch --quiet origin "$IREMOTE_COMMIT"
git -C "$IREMOTE" reset --hard "$IREMOTE_COMMIT"
git -C "$IREMOTE" clean -fd

git -C "$IREMOTE" apply --check "$PATCH"
git -C "$IREMOTE" apply "$PATCH"

(
  cd "$IREMOTE"
  xcodegen generate >/dev/null
  xcodebuild \
    -project iRemote.xcodeproj \
    -scheme iRemote \
    -configuration Release \
    -derivedDataPath "$GENERATED/iRemote-derived" \
    CODE_SIGN_IDENTITY=- \
    build
)

rm -rf "$VENV"
"$PYTHON" -m venv "$VENV"
PIP_CACHE_DIR="$GENERATED/.pip-cache" \
  "$VENV/bin/pip" install --quiet 'mlx-vlm==0.6.15' 'huggingface-hub>=0.34,<2'

if [[ "$ENABLE_TTS" == 1 ]]; then
  rm -rf "$KOKORO_VENV"
  "$PYTHON" -m venv "$KOKORO_VENV"
  PIP_CACHE_DIR="$GENERATED/.pip-cache" \
    "$KOKORO_VENV/bin/pip" install --quiet 'kokoro==0.9.4' 'soundfile==0.13.1'
fi

export HF_HOME="$HF_HOME_DIR"
export HF_HUB_CACHE="$HF_HOME/hub"
export GENERATED PARAKEET_MODEL STREAMING_MODEL CLEANER_MODEL
"$VENV/bin/python" <<'PY'
import os
from huggingface_hub import snapshot_download
from mlx_vlm import load

snapshot_download(
    os.environ["PARAKEET_MODEL"],
    local_dir=os.path.join(os.environ["GENERATED"], "parakeet-v3-coreml"),
)
snapshot_download(
    os.environ["STREAMING_MODEL"],
    allow_patterns=["160ms/*"],
    local_dir=os.path.join(os.environ["GENERATED"], "parakeet-eou-streaming"),
)
load(os.environ["CLEANER_MODEL"])
PY

if [[ "$ENABLE_TTS" == 1 ]]; then
  # Download and exercise the default Kokoro voice during the build so startup
  # never reaches the network and a missing MPS/phonemizer dependency fails here.
  "$KOKORO_VENV/bin/python" <<'PY'
import os
import warnings

warnings.filterwarnings("ignore")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
from kokoro import KPipeline

pipeline = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M", device="mps")
list(pipeline("Resident voice ready.", voice="am_michael"))
PY
fi

cat <<EOF

Siri Remote voice stack built successfully.
Run:
  $SCRIPTS/run.sh
EOF
