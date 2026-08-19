#!/usr/bin/env python3
"""Authenticated loopback bridge from iRemote to a resident, tool-limited pi session."""

from __future__ import annotations

import argparse
import hmac
import json
import queue
import subprocess
import sys
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, cast

MAX_REQUEST_BYTES = 32 * 1024
PROMPT_TIMEOUT_SECONDS = 90
SYSTEM_PROMPT = """You are a concise macOS voice assistant. The user speaks naturally.
You have exactly three actions. For requests to search, Google, look up, research,
or answer a factual question that may need current information, call search_web
immediately. Default to google; use perplexity only when the user asks for it.
Make the query concise and self-contained. The physical device in this context
is a silver Apple Siri Remote A2540 or A2854, so resolve phrases such as "this
remote" accordingly in a search query. For requests to open, launch, start, or
switch to an installed application, call open_macos_application immediately
with its concise display name (for example Slack, Safari, Messages, or Visual
Studio Code). For requests to open YouTube or YouTube Music and play music, call
play_youtube_music immediately. Preserve artist, song, album, genre, and mood
names in a concise search query. Default to youtube_music for music; use youtube
only when explicitly requested. Searches, app launching, and music playback do
not need confirmation. After a tool succeeds, answer in one short plain sentence
suitable for text-to-speech. Never claim an action you did not perform. For
unsupported requests, briefly say they are not enabled."""


def assistant_text(message: dict[str, Any]) -> str:
    if message.get("role") != "assistant":
        return ""
    content = message.get("content", [])
    if isinstance(content, str):
        return content.strip()
    parts = [
        item.get("text", "")
        for item in content
        if isinstance(item, dict) and item.get("type") == "text"
    ]
    return "".join(parts).strip()


class PiRPC:
    def __init__(self, pi_path: str, extension_path: str, model: str | None) -> None:
        command = [
            pi_path,
            "--mode", "rpc",
            "--no-session",
            "--no-builtin-tools",
            "--no-extensions",
            "--no-skills",
            "--no-prompt-templates",
            "--no-context-files",
            "--extension", extension_path,
            "--tools", "play_youtube_music,open_macos_application,search_web",
            "--thinking", "off",
            "--system-prompt", SYSTEM_PROMPT,
        ]
        if model:
            command.extend(["--model", model])
        # Start from the repo root so the extension can resolve local
        # @earendil-works packages instead of Homebrew absolute imports.
        repo_root = Path(extension_path).resolve().parent.parent
        self._process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=sys.stderr,
            bufsize=0,
            cwd=str(repo_root),
        )
        self._events: queue.Queue[dict[str, Any]] = queue.Queue()
        self._lock = threading.Lock()
        self._reader = threading.Thread(target=self._read_events, daemon=True)
        self._reader.start()

    @property
    def alive(self) -> bool:
        return self._process.poll() is None

    def close(self) -> None:
        if self.alive:
            self._process.terminate()

    def _read_events(self) -> None:
        assert self._process.stdout is not None
        for raw_line in self._process.stdout:
            line = raw_line.rstrip(b"\r\n")
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError as error:
                print(f"Ignoring malformed pi RPC output: {error}", file=sys.stderr)
                continue
            self._events.put(event)

    def _send(self, payload: dict[str, Any]) -> None:
        if not self.alive:
            raise RuntimeError("The pi assistant process is not running.")
        assert self._process.stdin is not None
        self._process.stdin.write(json.dumps(payload).encode("utf-8") + b"\n")
        self._process.stdin.flush()

    def prompt(self, transcript: str) -> str:
        with self._lock:
            while not self._events.empty():
                try:
                    self._events.get_nowait()
                except queue.Empty:
                    break

            request_id = "voice-prompt"
            self._send({"id": request_id, "type": "prompt", "message": transcript})
            accepted = False
            latest_text = ""

            while True:
                try:
                    event = self._events.get(timeout=PROMPT_TIMEOUT_SECONDS)
                except queue.Empty as error:
                    self._send({"type": "abort"})
                    raise TimeoutError("The voice assistant timed out.") from error

                if (
                    event.get("type") == "response"
                    and event.get("id") == request_id
                    and event.get("command") == "prompt"
                ):
                    if not event.get("success"):
                        raise RuntimeError(event.get("error", "pi rejected the prompt."))
                    accepted = True
                elif event.get("type") == "message_end":
                    text = assistant_text(event.get("message", {}))
                    if text:
                        latest_text = text
                elif event.get("type") == "agent_settled" and accepted:
                    return latest_text or "Done."


class AssistantServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], key: str, pi_rpc: PiRPC) -> None:
        super().__init__(address, AssistantHandler)
        self.key = key
        self.pi_rpc = pi_rpc


class AssistantHandler(BaseHTTPRequestHandler):
    @property
    def assistant_server(self) -> AssistantServer:
        return cast(AssistantServer, self.server)

    def log_message(self, format: str, *args: object) -> None:
        del format, args

    def authorized(self) -> bool:
        supplied = self.headers.get("Authorization", "")
        expected = f"Bearer {self.assistant_server.key}"
        return hmac.compare_digest(supplied, expected)

    def send_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path != "/health" or not self.authorized():
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        status = HTTPStatus.OK if self.assistant_server.pi_rpc.alive else HTTPStatus.SERVICE_UNAVAILABLE
        self.send_json(status, {"status": "ok" if status == HTTPStatus.OK else "pi unavailable"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/assist" or not self.authorized():
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self.send_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "invalid request size"})
            return

        try:
            payload = json.loads(self.rfile.read(length))
            transcript = str(payload.get("transcript", "")).strip()
            if not transcript:
                raise ValueError("transcript is required")
            response = self.assistant_server.pi_rpc.prompt(transcript)
        except (ValueError, RuntimeError, TimeoutError, json.JSONDecodeError) as error:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(error)})
            return
        self.send_json(HTTPStatus.OK, {"response": response})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18767)
    parser.add_argument("--key-file", required=True)
    parser.add_argument("--extension", required=True)
    parser.add_argument("--pi", default=None)
    parser.add_argument("--model")
    args = parser.parse_args()

    key = Path(args.key_file).read_text(encoding="utf-8").strip()
    if not key:
        raise SystemExit("assistant key file is empty")
    pi_path = args.pi or "pi"
    pi_rpc = PiRPC(pi_path, args.extension, args.model)
    server = AssistantServer(("127.0.0.1", args.port), key, pi_rpc)
    try:
        server.serve_forever()
    finally:
        pi_rpc.close()
        server.server_close()


if __name__ == "__main__":
    main()
