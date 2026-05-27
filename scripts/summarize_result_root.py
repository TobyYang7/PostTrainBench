#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable
from zoneinfo import ZoneInfo


UTC_TS_RE = re.compile(r"^\[(?P<utc>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\]")
LOOP_RE = re.compile(r"Start Loop (\d+)")
ACCURACY_RE = re.compile(r"\|\s*gsm8k\s*\|\s*[^|]+\|\s*accuracy\s*\|\s*gen\s*\|\s*([0-9]+(?:\.[0-9]+)?)\s*\|")
FINAL_MODEL_RE = re.compile(r"Selected .* final_model")
DONE_RE = re.compile(r"(^|\n).*\bdone=1\b")
FINAL_MODEL_DIR_RE = re.compile(r"(^|\n).*final_model_(?:load_ok|tokenizer_load_ok|dir)=")
VALIDATION_EXACT_RE = re.compile(r"validation_exact_match(?:=[^\d]*|=)([0-9]+(?:\.[0-9]+)?)")
EXEC_DONE_RE = re.compile(r"execution done ExecutionResult")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


@dataclass
class FolderSummary:
    folder: str
    status: str
    loops: str
    start_time: str
    end_time: str
    elapsed: str
    wrapper_time: str
    val_acc: str
    test_acc: str
    note: str


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def parse_utc_timestamps(lines: Iterable[str]) -> list[datetime]:
    timestamps: list[datetime] = []
    for line in lines:
        match = UTC_TS_RE.match(line)
        if not match:
            continue
        timestamps.append(datetime.fromisoformat(match.group("utc").replace("Z", "+00:00")))
    return timestamps


def format_dt(dt: datetime | None) -> str:
    if dt is None:
        return "-"
    local = dt.astimezone(ZoneInfo("Asia/Shanghai"))
    return local.strftime("%Y-%m-%d %H:%M:%S CST")


def format_delta(delta: timedelta | None) -> str:
    if delta is None:
        return "-"
    total_seconds = int(delta.total_seconds())
    if total_seconds < 0:
        total_seconds = 0
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def tail_note(output_text: str, error_text: str, status: str) -> str:
    if status == "completed":
        cleaned = [strip_ansi(line).strip() for line in output_text.splitlines()]
        cleaned = [line for line in cleaned if line]
        final_model_lines = [line for line in cleaned if "Selected " in line and "final_model" in line]
        if final_model_lines:
            line = final_model_lines[-1]
        else:
            final_dir_lines = [line for line in cleaned if "final_model_dir=" in line or "final_model_load_ok=1" in line]
            line = final_dir_lines[-1] if final_dir_lines else (cleaned[-1] if cleaned else "-")
    elif error_text.strip():
        line = error_text.strip().splitlines()[-1]
    else:
        cleaned = [strip_ansi(line).strip() for line in output_text.splitlines()]
        cleaned = [line for line in cleaned if line]
        line = cleaned[-1] if cleaned else "-"
    if len(line) > 120:
        line = line[:117] + "..."
    return line


def summarize_folder(folder: Path) -> FolderSummary:
    output_path = folder / "output.log"
    error_path = folder / "error.log"
    time_path = folder / "time_taken.txt"

    output_text = output_path.read_text(errors="replace") if output_path.exists() else ""
    error_text = error_path.read_text(errors="replace") if error_path.exists() else ""

    timestamps = parse_utc_timestamps(output_text.splitlines())
    start_dt = timestamps[0] if timestamps else None
    end_dt = timestamps[-1] if timestamps else None
    elapsed = (end_dt - start_dt) if start_dt and end_dt else None

    loop_ids = sorted({int(match.group(1)) for match in LOOP_RE.finditer(output_text)})
    if loop_ids:
        loop_count = str(len(loop_ids))
    else:
        exec_done_count = len(EXEC_DONE_RE.findall(output_text))
        loop_count = str(exec_done_count) if exec_done_count else "0"

    scores = [match.group(1) for match in ACCURACY_RE.finditer(output_text)]
    val_acc = scores[0] if len(scores) >= 1 else "-"
    test_acc = scores[1] if len(scores) >= 2 else "-"
    if val_acc == "-":
        internal_validation_scores = VALIDATION_EXACT_RE.findall(output_text)
        if internal_validation_scores:
            val_acc = internal_validation_scores[-1]

    has_final_model = bool(FINAL_MODEL_RE.search(output_text) or (DONE_RE.search(output_text) and FINAL_MODEL_DIR_RE.search(output_text)))
    if has_final_model:
        status = "completed"
    elif error_text.strip():
        status = "failed"
    elif "ERROR:" in output_text:
        status = "failed"
    elif output_text.strip():
        status = "incomplete"
    else:
        status = "empty"

    wrapper_time = time_path.read_text(errors="replace").strip() if time_path.exists() else "-"
    note = tail_note(output_text, error_text, status)

    return FolderSummary(
        folder=folder.name,
        status=status,
        loops=loop_count,
        start_time=format_dt(start_dt),
        end_time=format_dt(end_dt),
        elapsed=format_delta(elapsed),
        wrapper_time=wrapper_time or "-",
        val_acc=val_acc,
        test_acc=test_acc,
        note=note,
    )


def render_markdown(result_root: Path, summaries: list[FolderSummary]) -> str:
    generated_at = subprocess.check_output(["date", "+%Y-%m-%d %H:%M:%S CST"], text=True).strip()
    completed = sum(1 for item in summaries if item.status == "completed")
    failed = sum(1 for item in summaries if item.status == "failed")
    incomplete = sum(1 for item in summaries if item.status == "incomplete")
    empty = sum(1 for item in summaries if item.status == "empty")

    lines = [
        f"# Result Audit",
        "",
        f"- Result root: `{result_root}`",
        f"- Generated at: `{generated_at}`",
        f"- Folder count: `{len(summaries)}`",
        f"- Completed: `{completed}`",
        f"- Failed: `{failed}`",
        f"- Incomplete: `{incomplete}`",
        f"- Empty: `{empty}`",
        "",
        "说明：",
        "- `Loop数` 按 `output.log` 中出现的 `Start Loop X` 去重计数。",
        "- `总用时(日志)` 取 `output.log` 第一条和最后一条 UTC 时间戳的跨度。",
        "- `time_taken.txt` 是 wrapper 记录的时间；缺失时记为 `-`。",
        "- `Validation/Test` 准确率按 `output.log` 中出现的 `gsm8k accuracy` 表格行提取；没有则记为 `-`。",
        "",
        "| Folder | Status | Loop数 | 开始时间 | 结束/最后日志时间 | 总用时(日志) | time_taken.txt | Validation | Test | 备注 |",
        "| --- | --- | ---: | --- | --- | ---: | ---: | ---: | ---: | --- |",
    ]

    for item in summaries:
        lines.append(
            f"| `{item.folder}` | `{item.status}` | `{item.loops}` | `{item.start_time}` | `{item.end_time}` | `{item.elapsed}` | `{item.wrapper_time}` | `{item.val_acc}` | `{item.test_acc}` | {item.note} |"
        )

    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("result_root", type=Path)
    parser.add_argument("output_md", type=Path)
    args = parser.parse_args()

    folders = sorted([path for path in args.result_root.iterdir() if path.is_dir()], key=lambda p: p.name)
    summaries = [summarize_folder(folder) for folder in folders]
    markdown = render_markdown(args.result_root, summaries)
    args.output_md.write_text(markdown)
    print(args.output_md)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
