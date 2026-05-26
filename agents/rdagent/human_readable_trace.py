#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Normalize RD-Agent stdout into plain text.")
    parser.add_argument("input", type=Path, help="Raw solve_out.txt path")
    parser.add_argument("-o", "--output", type=Path, required=True, help="Destination parsed text path")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    text = args.input.read_text(encoding="utf-8", errors="replace")
    text = ANSI_RE.sub("", text)
    args.output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
