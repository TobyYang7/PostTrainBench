#!/usr/bin/env python3
import argparse
import re
from pathlib import Path

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_path")
    parser.add_argument("-o", "--output", required=True)
    args = parser.parse_args()

    content = Path(args.input_path).read_text(encoding="utf-8", errors="replace")
    content = ANSI_RE.sub("", content)
    Path(args.output).write_text(content, encoding="utf-8")


if __name__ == "__main__":
    main()
