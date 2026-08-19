#!/usr/bin/env python3
"""Authenticated loopback Kokoro TTS worker for the Siri Remote assistant."""

from __future__ import annotations

import argparse
import hmac
import importlib
import json
import os
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any, cast

MAX_REQUEST_BYTES = 8 * 1024
MAX_TEXT_CHARACTERS = 600


class ReusableHTTPServer(HTTPServer):
    allow_reuse_address = True


class KokoroSynthesizer:
    def __init__(self, voice: str) -> None:
        import warnings

        warnings.filterwarnings("ignore")
        os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

        np = importlib.import_module("numpy")
        sf = importlib.import_module("soundfile")
        kokoro = importlib.import_module("kokoro")

        language = voice[0] if voice and voice[0] in "abefhijpz" else "a"
        self._np = np
        self._sf = sf
        self._pipeline = kokoro.KPipeline(
            lang_code=language,
            repo_id="hexgrad/Kokoro-82M",
            device="mps",
        )
        self.voice = voice
        # Compile the MPS path before the health endpoint reports ready. This
        # costs about a second at startup and removes it from the first reply.
        list(self._pipeline("Ready.", voice=self.voice))

    def write(self, text: str, destination: Path) -> None:
        chunks = [audio for _, _, audio in self._pipeline(text, voice=self.voice)]
        if not chunks:
            raise RuntimeError("Kokoro produced no audio")
        audio = chunks[0] if len(chunks) == 1 else self._np.concatenate(chunks)
        self._sf.write(destination, audio, 24_000)


class TTSHandler(BaseHTTPRequestHandler):
    @property
    def tts_server(self) -> "TTSServer":
        return cast("TTSServer", self.server)

    def log_message(self, format: str, *args: Any) -> None:
        del format, args

    def _authorized(self) -> bool:
        scheme, separator, credential = self.headers.get("Authorization", "").partition(" ")
        return (
            separator == " "
            and scheme == "Bearer"
            and hmac.compare_digest(credential, self.tts_server.bearer_key)
        )

    def _reply(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if not self._authorized():
            self._reply(401, {"error": "unauthorized"})
            return
        if self.path != "/health":
            self._reply(404, {"error": "not found"})
            return
        self._reply(200, {"status": "ok", "voice": self.tts_server.synthesizer.voice})

    def do_POST(self) -> None:
        if not self._authorized():
            self._reply(401, {"error": "unauthorized"})
            return
        if self.path != "/speak":
            self._reply(404, {"error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._reply(400, {"error": "invalid content length"})
            return
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self._reply(413, {"error": "request too large"})
            return

        try:
            payload = json.loads(self.rfile.read(length))
            text = payload.get("text", "") if isinstance(payload, dict) else ""
            if not isinstance(text, str):
                raise ValueError("text must be a string")
            text = text.strip()
            if not text:
                raise ValueError("text is empty")
            if len(text) > MAX_TEXT_CHARACTERS:
                text = text[:MAX_TEXT_CHARACTERS]

            descriptor, raw_path = tempfile.mkstemp(
                prefix="assistant-tts-",
                suffix=".wav",
                dir=self.tts_server.runtime_dir,
            )
            os.close(descriptor)
            audio_path = Path(raw_path)
            audio_path.chmod(0o600)
            try:
                self.tts_server.synthesizer.write(text, audio_path)
                subprocess.run(
                    ["/usr/bin/afplay", str(audio_path)],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=90,
                )
            finally:
                audio_path.unlink(missing_ok=True)
        except (ValueError, json.JSONDecodeError) as error:
            self._reply(400, {"error": str(error)})
            return
        except Exception:
            self._reply(500, {"error": "speech synthesis failed"})
            return

        self._reply(200, {"spoken": True})


class TTSServer(ReusableHTTPServer):
    def __init__(
        self,
        address: tuple[str, int],
        bearer_key: str,
        runtime_dir: Path,
        synthesizer: KokoroSynthesizer,
    ) -> None:
        self.bearer_key = bearer_key
        self.runtime_dir = runtime_dir
        self.synthesizer = synthesizer
        super().__init__(address, TTSHandler)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=18_768)
    parser.add_argument("--key-file", required=True)
    parser.add_argument("--runtime-dir", required=True)
    parser.add_argument("--voice", default="am_michael")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    key_path = Path(args.key_file)
    bearer_key = key_path.read_text(encoding="utf-8").strip()
    if not bearer_key:
        raise SystemExit("TTS bearer key is empty")

    runtime_dir = Path(args.runtime_dir).resolve()
    runtime_dir.mkdir(parents=True, exist_ok=True)
    runtime_dir.chmod(0o700)

    synthesizer = KokoroSynthesizer(args.voice)
    server = TTSServer(("127.0.0.1", args.port), bearer_key, runtime_dir, synthesizer)
    server.serve_forever()


if __name__ == "__main__":
    main()
