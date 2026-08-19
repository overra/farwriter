# Shared paths for the Siri Remote voice stack.
# shellcheck shell=bash

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS="$ROOT/scripts"
PATCHES="$ROOT/patches"
GENERATED="$ROOT/generated"
IREMOTE="$GENERATED/iRemote-upstream"
FLUID="$GENERATED/FluidAudio-upstream"
VENV="$GENERATED/siri-remote-voice-venv"
KOKORO_VENV="$GENERATED/siri-remote-kokoro-venv"
HF_HOME_DIR="$GENERATED/huggingface"
PATCH="$PATCHES/iremote-silver-remotes.patch"

IREMOTE_REPO=https://github.com/jono-shaw/iRemote.git
IREMOTE_COMMIT=e2d5efa1c486882ea39f9efb74a968a901dbc928
FLUID_REPO=https://github.com/FluidInference/FluidAudio.git
FLUID_COMMIT=7f3f96ed88f927f5ae5a63461a27bdce63e213e7
PARAKEET_MODEL=FluidInference/parakeet-tdt-0.6b-v3-coreml
STREAMING_MODEL=FluidInference/parakeet-realtime-eou-120m-coreml
CLEANER_MODEL=unsloth/gemma-4-E4B-it-UD-MLX-4bit
