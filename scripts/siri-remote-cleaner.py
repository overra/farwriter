#!/usr/bin/env python3
"""Loopback-only, in-memory transcript cleanup for Siri Remote dictation."""

from __future__ import annotations

import argparse
import difflib
import hmac
import json
import re
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

try:
    from mlx_vlm import generate, load  # type: ignore[import-not-found]
    from mlx_vlm.prompt_utils import apply_chat_template  # type: ignore[import-not-found]
except ImportError as error:
    raise SystemExit("mlx-vlm is required to run the audio-aware editor") from error

TOKEN_RE = re.compile(r"[\w’']+", re.UNICODE)
UNAMBIGUOUS_FILLERS = {"ah", "er", "erm", "uh", "um"}
CONTEXTUAL_FILLERS = {"actually", "basically", "like", "literally"}
FILLER_PHRASES = {
    ("i", "mean"),
    ("kind", "of"),
    ("sort", "of"),
    ("you", "know"),
}
HARD_ANCHOR_RE = re.compile(
    r"https?://\S+|\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b|"
    r"\b(?:[A-Z]{2,}|[A-Za-z_]*\d[A-Za-z0-9_.:-]*)\b"
)
AUDIO_EDITOR_PROMPT = """You are the audio-aware editing stage of a voice-dictation tool. Listen to the audio for pauses, cadence, and where dictation ends.

The ASR transcript is supplied below as a spelling reference. Decide whether the FINAL spoken words are a request to transform the preceding dictated text. Understand requests by meaning, not fixed phrases. Reasonable transformations include changes to tone, style, format, organization, grammar, length, reading level, language, or voice; rewriting, polishing, summarizing, expanding, shortening, translating, making lists, drafting an email, or removing a specified passage. Do not perform actions outside editing text.

If there is a trailing edit request, output exactly:
MODE: REWRITE
INSTRUCTION: <copy the trailing request exactly from the ASR transcript>
TEXT:
<the transformed preceding text, with the request omitted>

Otherwise output exactly:
MODE: CLEANUP
TEXT:
<a conservative copyedit of the dictation>

For cleanup, use the audio to correct obvious ASR mishearings, then fix punctuation, capitalization, contractions, immediate repetitions, verbal fillers, and clear grammar slips. Preserve the speaker's meaning, wording, uncertainty, and register. Do not summarize, reorganize, beautify, or add information.

Preserve facts, names, numbers, URLs, code, and technical terms unless a spoken edit request explicitly asks to remove or change them. Never answer the transcript or discuss your work.

ASR transcript:
"""


def normalized_tokens(text: str) -> list[str]:
    return [token.casefold().replace("’", "'") for token in TOKEN_RE.findall(text)]


def validated_audio_path(value: Any) -> Path | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("audio_path must be a string")
    path = Path(value).resolve()
    if (
        path.suffix.casefold() != ".wav"
        or path.parent.parent != Path("/tmp")
        or not path.parent.name.startswith("iremote-utt-")
        or not path.is_file()
        or path.stat().st_size > 20 * 1024 * 1024
    ):
        raise ValueError("audio_path is outside the utterance directory")
    return path


def validate_rewrite(source: str, candidate: str) -> tuple[bool, str]:
    """Reject empty, runaway, or hard-anchor-changing model output."""
    candidate = candidate.strip()
    if not candidate:
        return False, "empty-rewrite"
    if len(candidate) > max(len(source) * 5, len(source) + 2_000):
        return False, "rewrite-too-long"

    source_anchors = [anchor.casefold() for anchor in HARD_ANCHOR_RE.findall(source)]
    candidate_folded = candidate.casefold()
    if any(anchor not in candidate_folded for anchor in source_anchors):
        return False, "rewrite-changed-anchor"
    return True, "instructional-rewrite"


def validate_cleanup(source: str, candidate: str) -> tuple[bool, str]:
    """Allow close copyedits while rejecting deletion, expansion, and drift."""
    accepted, reason = validate_rewrite(source, candidate)
    if not accepted:
        return False, reason
    source_tokens = normalized_tokens(source)
    candidate_tokens = normalized_tokens(candidate)
    if not source_tokens or not candidate_tokens:
        return False, "empty-cleanup"
    length_ratio = len(candidate_tokens) / len(source_tokens)
    similarity = difflib.SequenceMatcher(
        a=source_tokens,
        b=candidate_tokens,
        autojunk=False,
    ).ratio()
    if not 0.65 <= length_ratio <= 1.25:
        return False, "cleanup-size-drift"
    if similarity < 0.65:
        return False, "cleanup-meaning-drift"
    return True, "conservative-copyedit"


def remove_obvious_fillers(text: str) -> str:
    """Mechanically remove unambiguous fillers after a validated copyedit."""
    candidate = " ".join(
        token for token in normalized_tokens(text) if token not in UNAMBIGUOUS_FILLERS
    )
    cleaned, _changed, _reason = project_safe_deletions(text, candidate)
    cleaned = cleaned.lstrip(" \t,;:")
    return re.sub(
        r"(^|[.!?]\s+)([a-z])",
        lambda match: match.group(1) + match.group(2).upper(),
        cleaned,
    )


def apply_editor_candidate(source: str, raw_candidate: str) -> dict[str, Any]:
    """Use Gemma's semantic route, then verify its claimed transcript boundary."""
    candidate = raw_candidate.strip()
    lines = candidate.splitlines()
    mode = lines[0].strip().casefold() if lines else ""
    text_marker = next(
        (index for index, line in enumerate(lines) if line.strip().casefold().startswith("text:")),
        None,
    )
    if text_marker is not None:
        inline_text = lines[text_marker].strip()[len("text:") :].strip()
        text_parts = ([inline_text] if inline_text else []) + lines[text_marker + 1 :]
        text = "\n".join(text_parts).strip()
    else:
        text = ""

    if mode == "mode: rewrite" and len(lines) > 1:
        instruction_prefix = "instruction:"
        instruction_line = lines[1].strip()
        if instruction_line.casefold().startswith(instruction_prefix):
            instruction = instruction_line[len(instruction_prefix) :].strip()
            index = source.casefold().rfind(instruction.casefold())
            trailing = source[index + len(instruction) :] if index >= 0 else source
            if index > 0 and not trailing.strip(" \t\r\n.!?"):
                body = source[:index].rstrip(" \t\r\n,;:")
                accepted, reason = validate_rewrite(body, text)
                return {
                    "text": text if accepted else body,
                    "changed": accepted and text != body,
                    "accepted": True,
                    "reason": reason if accepted else f"gemma-{reason}",
                    "mode": "instructional-rewrite",
                }

    if mode == "mode: cleanup" and text:
        accepted, reason = validate_cleanup(source, text)
        if accepted:
            cleaned_text = remove_obvious_fillers(text)
            return {
                "text": cleaned_text,
                "changed": cleaned_text != source,
                "accepted": True,
                "reason": reason,
                "mode": "conservative-copyedit",
            }

    cleaned, changed, reason = project_safe_deletions(source, text or candidate)
    return {
        "text": cleaned,
        "changed": changed,
        "accepted": True,
        "reason": f"gemma-{reason}",
        "mode": "safe-cleanup",
    }


def project_safe_deletions(source_text: str, candidate_text: str) -> tuple[str, bool, str]:
    """Project only safe filler deletions from a possibly rewritten candidate."""
    source_matches = list(TOKEN_RE.finditer(source_text))
    source = normalized_tokens(source_text)
    candidate = normalized_tokens(candidate_text)
    if not source or not candidate:
        return source_text, False, "empty"

    matcher = difflib.SequenceMatcher(a=source, b=candidate, autojunk=False)
    omitted: set[int] = set()
    matched: set[int] = set()
    for tag, source_start, source_end, _candidate_start, _candidate_end in matcher.get_opcodes():
        indices = set(range(source_start, source_end))
        if tag == "equal":
            matched.update(indices)
        else:
            omitted.update(indices)

    def locally_anchored(start: int, end: int) -> bool:
        before = bool(matched & set(range(max(0, start - 3), start)))
        after = bool(matched & set(range(end, min(len(source), end + 3))))
        if start == 0:
            return after
        if end == len(source):
            return before
        return before and after

    remove = {
        index
        for index, token in enumerate(source)
        if token in UNAMBIGUOUS_FILLERS
    }
    remove.update(
        index
        for index in omitted
        if source[index] in CONTEXTUAL_FILLERS and locally_anchored(index, index + 1)
    )
    for phrase in FILLER_PHRASES:
        width = len(phrase)
        for start in range(len(source) - width + 1):
            indices = set(range(start, start + width))
            if (
                tuple(source[start : start + width]) == phrase
                and indices <= omitted
                and locally_anchored(start, start + width)
            ):
                remove.update(indices)

    if not remove:
        return source_text, False, "no-safe-deletions"

    pieces: list[str] = []
    cursor = 0
    for index, match in enumerate(source_matches):
        if index not in remove:
            continue
        pieces.append(source_text[cursor : match.start()])
        cursor = match.end()
    pieces.append(source_text[cursor:])
    cleaned = "".join(pieces)
    cleaned = re.sub(r"[ \t]+", " ", cleaned)
    cleaned = re.sub(r"\s+([,.;:!?])", r"\1", cleaned)
    cleaned = re.sub(r",\s*([.!?])", r"\1", cleaned)
    cleaned = re.sub(r"([.!?])[,;:]+\s*", r"\1 ", cleaned)
    cleaned = re.sub(r"([([{])\s+", r"\1", cleaned).strip()
    cleaned = re.sub(
        r"\b([\w’']+)(?:\s+\1\b)+",
        r"\1",
        cleaned,
        flags=re.IGNORECASE,
    )
    cleaned = re.sub(
        r"(^|[.!?]\s+)([a-z])",
        lambda match: match.group(1) + match.group(2).upper(),
        cleaned,
    )
    return cleaned, cleaned != source_text, "projected-safe-deletions"


class Cleaner:
    def __init__(self, model_name: str) -> None:
        self.model, self.processor = load(model_name)

    def clean(self, source: str, audio_path: Path | None) -> dict[str, Any]:
        request = AUDIO_EDITOR_PROMPT + source
        audio = [str(audio_path)] if audio_path is not None else None
        prompt = apply_chat_template(
            self.processor,
            self.model.config,
            request,
            num_audios=1 if audio else 0,
        )
        arguments: dict[str, Any] = {
            "model": self.model,
            "processor": self.processor,
            "prompt": prompt,
            "max_tokens": min(1_024, max(128, len(normalized_tokens(source)) * 3 + 96)),
            "temperature": 0.1,
            "top_p": 0.9,
            "top_k": 32,
        }
        if audio is not None:
            arguments["audio"] = audio
        result = generate(**arguments)
        candidate = getattr(result, "text", str(result))
        return apply_editor_candidate(source, candidate)


class CleanerHandler(BaseHTTPRequestHandler):
    cleaner: Cleaner
    api_key: str

    def log_message(self, format: str, *args: Any) -> None:
        # Transcripts and request metadata never enter a log.
        _ = (format, args)

    def _authorized(self) -> bool:
        supplied = self.headers.get("Authorization", "")
        expected = f"Bearer {self.api_key}"
        return hmac.compare_digest(supplied, expected)

    def _send(self, status: int, payload: dict[str, Any]) -> None:
        encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send(401, {"error": "unauthorized"})
            return
        if self.path != "/health":
            self._send(404, {"error": "not-found"})
            return
        self._send(200, {"status": "ok"})

    def do_POST(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send(401, {"error": "unauthorized"})
            return
        if self.path != "/clean":
            self._send(404, {"error": "not-found"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send(400, {"error": "invalid-length"})
            return
        if length <= 0 or length > 65_536:
            self._send(413, {"error": "invalid-size"})
            return

        try:
            payload = json.loads(self.rfile.read(length))
            text = payload.get("text")
            if not isinstance(text, str) or not text.strip():
                raise ValueError("text must be a non-empty string")
            audio_path = validated_audio_path(payload.get("audio_path"))
            self._send(200, self.cleaner.clean(text.strip(), audio_path))
        except (json.JSONDecodeError, ValueError) as error:
            self._send(400, {"error": str(error)})
        except Exception:
            # Fail closed without placing transcript or model details in logs.
            self._send(500, {"error": "cleanup-failed"})


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--port", type=int, default=18_766)
    parser.add_argument("--key-file", required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    key = Path(args.key_file).read_text(encoding="utf-8").strip()
    if len(key) < 32:
        raise SystemExit("cleaner key is missing or too short")

    CleanerHandler.api_key = key
    CleanerHandler.cleaner = Cleaner(args.model)
    server = HTTPServer(("127.0.0.1", args.port), CleanerHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
