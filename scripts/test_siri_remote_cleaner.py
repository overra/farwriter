#!/usr/bin/env python3
"""Safety tests for transcript cleanup projection."""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType


def load_cleaner() -> ModuleType:
    path = Path(__file__).with_name("siri-remote-cleaner.py")
    spec = importlib.util.spec_from_file_location("siri_remote_cleaner", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load cleaner module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> None:
    cleaner = load_cleaner()
    cases = [
        (
            "Um I think like this works, you know. Um anyway.",
            "I think this works. anyway.",
            "I think this works. Anyway.",
        ),
        (
            "Things like Super Whisper work.",
            "Super Whisper is useful.",
            "Things like Super Whisper work.",
        ),
        (
            "Uh uh please test this.",
            "Please test this.",
            "Please test this.",
        ),
        (
            "I think this works.",
            "This definitely works.",
            "I think this works.",
        ),
    ]
    for source, candidate, expected in cases:
        actual, _changed, _reason = cleaner.project_safe_deletions(source, candidate)
        if actual != expected:
            raise AssertionError((source, candidate, expected, actual))

    routed_cases = [
        (
            "apples are red oranges are orange turn that into a bulleted list",
            "MODE: REWRITE\nINSTRUCTION: turn that into a bulleted list\nTEXT:\n- Apples are red.\n- Oranges are orange.",
            "instructional-rewrite",
            "- Apples are red.\n- Oranges are orange.",
        ),
        (
            "This is too wordy say the same thing like a pirate.",
            "MODE: REWRITE\nINSTRUCTION: say the same thing like a pirate\nTEXT:\nArrr, this be too wordy!",
            "instructional-rewrite",
            "Arrr, this be too wordy!",
        ),
        (
            "Um keep this text unchanged.",
            "MODE: CLEANUP\nTEXT:\nKeep this text unchanged.",
            "conservative-copyedit",
            "Keep this text unchanged.",
        ),
        (
            "It doesnt really claim up anything.",
            "MODE: CLEANUP\nTEXT:\nIt doesn't really clean up anything.",
            "conservative-copyedit",
            "It doesn't really clean up anything.",
        ),
        (
            "all right this doesnt have punctuation",
            "MODE: CLEANUP\nTEXT: All right, this doesn't have punctuation.",
            "conservative-copyedit",
            "All right, this doesn't have punctuation.",
        ),
        (
            "Uh okay. Um this uh this works.",
            "MODE: CLEANUP\nTEXT: Uh, okay. Um, this uh this works.",
            "conservative-copyedit",
            "Okay. This works.",
        ),
        (
            "Deploy A2854 tomorrow. Turn that into 3 bullet points.",
            "MODE: REWRITE\nINSTRUCTION: Turn that into 3 bullet points.\nTEXT:\n- Deploy A2854 tomorrow.",
            "instructional-rewrite",
            "- Deploy A2854 tomorrow.",
        ),
    ]
    for source, candidate, expected_mode, expected_text in routed_cases:
        actual = cleaner.apply_editor_candidate(source, candidate)
        if actual["mode"] != expected_mode or actual["text"] != expected_text:
            raise AssertionError((source, expected_mode, expected_text, actual))

    validation_cases = [
        (
            "Deploy Qwen3.5 to A2854 at 3:30.",
            "Please deploy Qwen3.5 to A2854 at 3:30.",
            True,
        ),
        (
            "Deploy Qwen3.5 to A2854 at 3:30.",
            "Please deploy Qwen3.5 to A2540 at 3:30.",
            False,
        ),
        (
            "This is a detailed explanation of the current implementation.",
            "Implementation.",
            True,
        ),
        (
            "Keep this short.",
            "word " * 1_000,
            False,
        ),
    ]
    for source, candidate, expected in validation_cases:
        actual, _reason = cleaner.validate_rewrite(source, candidate)
        if actual != expected:
            raise AssertionError((source, candidate, expected, actual))

    total = len(cases) + len(routed_cases) + len(validation_cases)
    print(f"transcript cleanup: {total} cases passed")


if __name__ == "__main__":
    main()
