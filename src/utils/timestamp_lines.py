#!/usr/bin/env python3
"""Prepend UTC timestamps to each line of stdin, flushing immediately.

Output format: [2026-04-03T14:05:32Z] <original line>

Designed to sit between an agent process and its log file so that
scaffolds which don't emit their own timestamps (Claude Code, Codex CLI)
still get wall-clock times in the raw trace.
"""

import codecs
import os
import sys
from datetime import datetime, timezone


def emit(line: str) -> None:
    if not line:
        return
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    sys.stdout.write(f"[{ts}] {line}\n")
    sys.stdout.flush()


decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
buffer = ""

while True:
    chunk = os.read(sys.stdin.fileno(), 4096)
    if not chunk:
        break

    buffer += decoder.decode(chunk)
    start = 0
    for idx, ch in enumerate(buffer):
        if ch in "\r\n":
            emit(buffer[start:idx])
            start = idx + 1
    buffer = buffer[start:]

buffer += decoder.decode(b"", final=True)
if buffer:
    emit(buffer)
