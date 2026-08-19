#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

APP="$GENERATED/iRemote-derived/Build/Products/Release/iRemote.app"
APP_BINARY="$APP/Contents/MacOS/iRemote"
FLUID_CLI="$FLUID/.build/release/fluidaudiocli"
PARAKEET_DIR="$GENERATED/parakeet-v3-coreml"
STREAMING_MODEL_DIR="$GENERATED/parakeet-eou-streaming/160ms"
CLEANER_SCRIPT="$SCRIPTS/siri-remote-cleaner.py"
CLEANER_PORT=18766
CLEANER_URL="http://127.0.0.1:$CLEANER_PORT"
ASSISTANT_SCRIPT="$SCRIPTS/siri-remote-assistant.py"
ASSISTANT_EXTENSION="$SCRIPTS/siri-remote-assistant-extension.ts"
ASSISTANT_PORT=18767
ASSISTANT_URL="http://127.0.0.1:$ASSISTANT_PORT"
TTS_SCRIPT="$SCRIPTS/siri-remote-tts.py"
TTS_PORT=18768
TTS_URL="http://127.0.0.1:$TTS_PORT"
ENABLE_TTS=${IREMOTE_ENABLE_TTS:-0}
TTS_VOICE=${IREMOTE_TTS_VOICE:-am_michael}
TTS_COMMAND=${IREMOTE_TTS_COMMAND:-}
KEY_FILE="$GENERATED/farwriter-cleaner.key"
CLEANER_PID_FILE="$GENERATED/farwriter-cleaner.pid"
ASSISTANT_PID_FILE="$GENERATED/farwriter-assistant.pid"
TTS_PID_FILE="$GENERATED/farwriter-tts.pid"
APP_PID_FILE="$GENERATED/farwriter-app.pid"
RUNTIME_TMP="$GENERATED/farwriter-runtime-tmp"
PACKETLOGGER_CAPTURE_PATTERN="/Applications/PacketLogger.app/Contents/Resources/packetlogger convert -b -o /tmp/iremote-window-live/remote.pklg"
CAPTURE_HELPER=/usr/local/bin/iremote-capture-helper
ROLLING_WORK_DIR=/tmp/iremote-window-live

stop_pid_file() {
  local file=$1
  if [[ -s "$file" ]]; then
    local pid
    pid=$(cat "$file")
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    kill -KILL "$pid" 2>/dev/null || true
    rm -f "$file"
  fi
}

stop_stack() {
  # Stop services before the app so the app-lifetime watcher cannot race us by
  # removing their PID files while their ports are still winding down.
  stop_pid_file "$ASSISTANT_PID_FILE"
  stop_pid_file "$TTS_PID_FILE"
  stop_pid_file "$CLEANER_PID_FILE"
  # PacketLogger runs as root and is reparented to launchd. Ask the already
  # allowlisted capture helper to stop the PID recorded for this app instance.
  if [[ -x "$CAPTURE_HELPER" ]]; then
    /usr/bin/sudo -n "$CAPTURE_HELPER" stop "$ROLLING_WORK_DIR" \
      >/dev/null 2>&1 || true
  fi
  stop_pid_file "$APP_PID_FILE"
  # Stop both release and any developer/debug build of this generated app.
  pkill -f "$GENERATED/iRemote-derived/Build/Products/.*/iRemote.app/Contents/MacOS/iRemote" \
    2>/dev/null || true
  # The privileged helper reparents PacketLogger to launchd, so it is not in
  # iRemote's process tree and otherwise survives app restarts.
  pkill -f "$PACKETLOGGER_CAPTURE_PATTERN" 2>/dev/null || true
}

if [[ ${1:-} == --stop ]]; then
  stop_stack
  echo "Farwriter stopped."
  exit 0
fi

for path in \
  "$APP_BINARY" \
  "$FLUID_CLI" \
  "$PARAKEET_DIR" \
  "$STREAMING_MODEL_DIR" \
  "$VENV/bin/python" \
  "$CLEANER_SCRIPT"; do
  if [[ ! -e "$path" ]]; then
    echo "Missing build artifact: $path" >&2
    echo "Run $SCRIPTS/setup.sh, then $SCRIPTS/build.sh." >&2
    exit 1
  fi
done

enable_assistant=0
if command -v pi >/dev/null \
  && [[ -e "$ASSISTANT_SCRIPT" ]] \
  && [[ -e "$ASSISTANT_EXTENSION" ]] \
  && [[ -d "$ROOT/node_modules/@earendil-works/pi-coding-agent" ]]; then
  enable_assistant=1
else
  echo "Assistant is off. Dictation will still run."
  echo "To enable it, install pi and bun, then re-run setup.sh."
fi

if [[ "$ENABLE_TTS" != 0 && "$ENABLE_TTS" != 1 ]]; then
  echo "IREMOTE_ENABLE_TTS must be 0 or 1." >&2
  exit 1
fi
if [[ "$ENABLE_TTS" == 1 ]]; then
  for path in "$KOKORO_VENV/bin/python" "$TTS_SCRIPT"; do
    if [[ ! -e "$path" ]]; then
      echo "Missing optional TTS artifact: $path" >&2
      echo "Build once with IREMOTE_ENABLE_TTS=1." >&2
      exit 1
    fi
  done
fi

if [[ ! -x /Applications/PacketLogger.app/Contents/Resources/packetlogger ]]; then
  echo "PacketLogger.app is missing from /Applications." >&2
  echo "Install Apple's Additional Tools for Xcode, then copy PacketLogger.app." >&2
  exit 1
fi

stop_stack

if [[ ! -s "$KEY_FILE" ]]; then
  umask 077
  openssl rand -hex 24 >"$KEY_FILE"
fi
chmod 600 "$KEY_FILE"
key=$(cat "$KEY_FILE")

# Long-lived processes must not inherit an ephemeral TMPDIR from an invoking
# terminal, agent harness, or launch wrapper. Final Parakeet transcription uses
# tmpfile(3), which fails once such a directory is cleaned up.
mkdir -p "$RUNTIME_TMP"
chmod 700 "$RUNTIME_TMP"
export TMPDIR="$RUNTIME_TMP"

assistant_pid=""
assistant_endpoint=""
if [[ "$enable_assistant" == 1 ]]; then
  # The assistant extension resolves @earendil-works/* from this repo, not from
  # whichever directory pi happens to start in.
  export NODE_PATH="$ROOT/node_modules${NODE_PATH:+:$NODE_PATH}"

  if [[ -n ${IREMOTE_ASSISTANT_MODEL:-} ]]; then
    nohup "$VENV/bin/python" "$ASSISTANT_SCRIPT" \
      --port "$ASSISTANT_PORT" \
      --key-file "$KEY_FILE" \
      --extension "$ASSISTANT_EXTENSION" \
      --model "$IREMOTE_ASSISTANT_MODEL" \
      >"$GENERATED/siri-remote-assistant.log" 2>&1 &
  else
    nohup "$VENV/bin/python" "$ASSISTANT_SCRIPT" \
      --port "$ASSISTANT_PORT" \
      --key-file "$KEY_FILE" \
      --extension "$ASSISTANT_EXTENSION" \
      >"$GENERATED/siri-remote-assistant.log" 2>&1 &
  fi
  assistant_pid=$!
  echo "$assistant_pid" >"$ASSISTANT_PID_FILE"

  assistant_ready=false
  for _ in $(seq 1 120); do
    if curl --fail --silent \
      --header "Authorization: Bearer $key" \
      "$ASSISTANT_URL/health" >/dev/null; then
      assistant_ready=true
      break
    fi
    if ! kill -0 "$assistant_pid" 2>/dev/null; then
      break
    fi
    sleep 0.25
  done
  if [[ $assistant_ready != true ]]; then
    stop_pid_file "$ASSISTANT_PID_FILE"
    echo "Voice assistant failed to start; see $GENERATED/siri-remote-assistant.log" >&2
    exit 1
  fi
  assistant_endpoint="$ASSISTANT_URL/assist"
fi

export HF_HOME="$HF_HOME_DIR"
export HF_HUB_CACHE="$HF_HOME/hub"
tts_pid=""
tts_endpoint=""
if [[ "$ENABLE_TTS" == 1 ]]; then
  nohup "$KOKORO_VENV/bin/python" "$TTS_SCRIPT" \
    --port "$TTS_PORT" \
    --key-file "$KEY_FILE" \
    --runtime-dir "$RUNTIME_TMP" \
    --voice "$TTS_VOICE" \
    >"$GENERATED/siri-remote-tts.log" 2>&1 &
  tts_pid=$!
  echo "$tts_pid" >"$TTS_PID_FILE"

  tts_ready=false
  for _ in $(seq 1 120); do
    if curl --fail --silent \
      --header "Authorization: Bearer $key" \
      "$TTS_URL/health" >/dev/null; then
      tts_ready=true
      break
    fi
    if ! kill -0 "$tts_pid" 2>/dev/null; then
      break
    fi
    sleep 0.25
  done
  if [[ $tts_ready != true ]]; then
    stop_pid_file "$TTS_PID_FILE"
    stop_pid_file "$ASSISTANT_PID_FILE"
    echo "Kokoro TTS failed to start; see $GENERATED/siri-remote-tts.log" >&2
    exit 1
  fi
  tts_endpoint="$TTS_URL/speak"
fi

nohup "$VENV/bin/python" "$CLEANER_SCRIPT" \
  --model "$CLEANER_MODEL" \
  --port "$CLEANER_PORT" \
  --key-file "$KEY_FILE" \
  >"$GENERATED/siri-remote-cleaner.log" 2>&1 &
cleaner_pid=$!
echo "$cleaner_pid" >"$CLEANER_PID_FILE"

cleaner_ready=false
for _ in $(seq 1 240); do
  if curl --fail --silent \
    --header "Authorization: Bearer $key" \
    "$CLEANER_URL/health" >/dev/null; then
    cleaner_ready=true
    break
  fi
  if ! kill -0 "$cleaner_pid" 2>/dev/null; then
    break
  fi
  sleep 0.25
done
if [[ $cleaner_ready != true ]]; then
  stop_pid_file "$CLEANER_PID_FILE"
  stop_pid_file "$TTS_PID_FILE"
  stop_pid_file "$ASSISTANT_PID_FILE"
  echo "Transcript cleaner failed to start; see $GENERATED/siri-remote-cleaner.log" >&2
  exit 1
fi

IREMOTE_PARAKEET_CLI="$FLUID_CLI" \
  IREMOTE_PARAKEET_MODEL_DIR="$PARAKEET_DIR" \
  IREMOTE_STREAMING_MODEL_DIR="$STREAMING_MODEL_DIR" \
  IREMOTE_CLEANER_URL="$CLEANER_URL/clean" \
  IREMOTE_CLEANER_KEY_FILE="$KEY_FILE" \
  IREMOTE_ASSISTANT_URL="$assistant_endpoint" \
  IREMOTE_TTS_URL="$tts_endpoint" \
  IREMOTE_TTS_COMMAND="$TTS_COMMAND" \
  nohup "$APP_BINARY" >"$GENERATED/iremote-app.stdout.log" 2>&1 &
app_pid=$!
echo "$app_pid" >"$APP_PID_FILE"

# Keep the resident cleaner, assistant, and optional TTS worker only while
# the menu-bar app is alive.
nohup bash -c "
  app_pid=\$1
  cleaner_pid=\$2
  assistant_pid=\$3
  app_pid_file=\$4
  cleaner_pid_file=\$5
  assistant_pid_file=\$6
  packetlogger_capture_pattern=\$7
  capture_helper=\$8
  rolling_work_dir=\$9
  tts_pid=\${10}
  tts_pid_file=\${11}
  while kill -0 \"\$app_pid\" 2>/dev/null; do sleep 2; done
  kill \"\$cleaner_pid\" 2>/dev/null || true
  if [[ -n \"\$tts_pid\" ]]; then kill \"\$tts_pid\" 2>/dev/null || true; fi
  pkill -TERM -P \"\$assistant_pid\" 2>/dev/null || true
  kill \"\$assistant_pid\" 2>/dev/null || true
  if [[ -x \"\$capture_helper\" ]]; then
    /usr/bin/sudo -n \"\$capture_helper\" stop \"\$rolling_work_dir\" >/dev/null 2>&1 || true
  fi
  pkill -f \"\$packetlogger_capture_pattern\" 2>/dev/null || true
  if [[ -s \"\$app_pid_file\" ]] && [[ \"\$(cat \"\$app_pid_file\")\" == \"\$app_pid\" ]]; then
    rm -f \"\$app_pid_file\"
  fi
  if [[ -s \"\$cleaner_pid_file\" ]] && [[ \"\$(cat \"\$cleaner_pid_file\")\" == \"\$cleaner_pid\" ]]; then
    rm -f \"\$cleaner_pid_file\"
  fi
  if [[ -s \"\$assistant_pid_file\" ]] && [[ \"\$(cat \"\$assistant_pid_file\")\" == \"\$assistant_pid\" ]]; then
    rm -f \"\$assistant_pid_file\"
  fi
  if [[ -s \"\$tts_pid_file\" ]] && [[ \"\$(cat \"\$tts_pid_file\")\" == \"\$tts_pid\" ]]; then
    rm -f \"\$tts_pid_file\"
  fi
" _ "$app_pid" "$cleaner_pid" "$assistant_pid" "$APP_PID_FILE" "$CLEANER_PID_FILE" "$ASSISTANT_PID_FILE" "$PACKETLOGGER_CAPTURE_PATTERN" "$CAPTURE_HELPER" "$ROLLING_WORK_DIR" "$tts_pid" "$TTS_PID_FILE" \
  >/dev/null 2>&1 &

echo "Farwriter is running (app PID $app_pid)."
echo "Hold the microphone button, speak, then release."
echo "Double-tap that button for Enter. Tap Back to delete; hold Back to keep deleting."
if [[ "$enable_assistant" == 1 ]]; then
  echo "Tap, then hold the microphone button within 1.4 seconds for assistant."
else
  echo "Assistant is off."
fi
