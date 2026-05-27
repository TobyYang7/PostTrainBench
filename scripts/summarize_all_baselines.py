#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Optional

from summarize_result_root import FolderSummary, summarize_folder


TIME_FMT = "%Y-%m-%d %H:%M:%S CST"


def parse_end_time(value: str) -> Optional[datetime]:
    if value == "-":
        return None
    return datetime.strptime(value, TIME_FMT)


def safe_sort_key(value: str, fallback: str) -> tuple[int, datetime | None, str]:
    dt = parse_end_time(value)
    if dt is None:
        return (0, None, fallback)
    return (1, dt, fallback)


def parse_metric(value: str) -> Optional[float]:
    try:
        return float(value)
    except Exception:
        return None


def choose_run_for_baseline(baseline_dir: Path) -> tuple[FolderSummary, str]:
    runs: list[tuple[str, FolderSummary]] = []
    for run_dir in sorted([path for path in baseline_dir.iterdir() if path.is_dir()], key=lambda p: p.name):
        runs.append((run_dir.name, summarize_folder(run_dir)))

    if not runs:
        return (
            FolderSummary(
                folder="-",
                status="empty",
                loops="0",
                start_time="-",
                end_time="-",
                elapsed="-",
                wrapper_time="-",
                val_acc="-",
                test_acc="-",
                note="no run folders",
            ),
            "no_runs",
        )

    completed = [(name, item) for name, item in runs if item.status == "completed"]
    if completed:
        completed.sort(key=lambda pair: safe_sort_key(pair[1].end_time, pair[0]), reverse=True)
        return completed[0][1], "latest_completed"

    scored = []
    for name, item in runs:
        test_score = parse_metric(item.test_acc)
        val_score = parse_metric(item.val_acc)
        if test_score is not None or val_score is not None:
            score = test_score if test_score is not None else val_score
            basis = "best_incomplete_test" if test_score is not None else "best_incomplete_validation"
            scored.append((score, safe_sort_key(item.end_time, name), item, basis))
    if scored:
        scored.sort(key=lambda row: (row[0], row[1]), reverse=True)
        _, _, item, basis = scored[0]
        return item, basis

    latest = sorted(runs, key=lambda pair: safe_sort_key(pair[1].end_time, pair[0]), reverse=True)[0]
    return latest[1], "latest_no_metric"


def render_markdown(results_root: Path, rows: list[tuple[str, FolderSummary, str]]) -> str:
    generated_at = subprocess.check_output(["date", "+%Y-%m-%d %H:%M:%S CST"], text=True).strip()
    completed = sum(1 for _, _, basis in rows if basis == "latest_completed")
    best_incomplete = sum(1 for _, _, basis in rows if basis.startswith("best_incomplete"))
    no_metric = sum(1 for _, _, basis in rows if basis == "latest_no_metric")
    no_runs = sum(1 for _, _, basis in rows if basis == "no_runs")

    lines = [
        "# Baseline Audit",
        "",
        f"- Results root: `{results_root}`",
        f"- Generated at: `{generated_at}`",
        f"- Baseline count: `{len(rows)}`",
        f"- Selected by latest completed run: `{completed}`",
        f"- Selected by best incomplete result: `{best_incomplete}`",
        f"- Selected by latest run without metric: `{no_metric}`",
        f"- Baselines with no run folders: `{no_runs}`",
        "",
        "说明：",
        "- 每个 baseline 都保留一行。",
        "- 有已完成 run 时：取“最新完成”的 run。",
        "- 没有已完成但有分数时：取“最好分数”的不完整 run。",
        "- 连分数都没有时：取“最新尝试”的 run。",
        "- 如果 baseline 目录下没有任何 run 子目录，则记为 `no_runs`。",
        "- `Loop数` 按 `output.log` 中出现的 `Start Loop X` 去重计数；若没有该字段，则回退为日志中 `execution done ExecutionResult` 次数。",
        "- `总用时(日志)` 取 `output.log` 第一条和最后一条 UTC 时间戳的跨度。",
        "- `time_taken.txt` 是 wrapper 记录的时间；缺失时记为 `-`。",
        "- `Validation/Test` 优先取 benchmark 输出；没有 benchmark 时，回退取日志中的内部 `validation_exact_match`。",
        "",
        "| Baseline | Selected Run | 选择依据 | Status | Loop数 | 开始时间 | 结束/最后日志时间 | 总用时(日志) | time_taken.txt | Validation | Test | 备注 |",
        "| --- | --- | --- | --- | ---: | --- | --- | ---: | ---: | ---: | ---: | --- |",
    ]

    for baseline_name, item, basis in rows:
        lines.append(
            f"| `{baseline_name}` | `{item.folder}` | `{basis}` | `{item.status}` | `{item.loops}` | `{item.start_time}` | `{item.end_time}` | `{item.elapsed}` | `{item.wrapper_time}` | `{item.val_acc}` | `{item.test_acc}` | {item.note} |"
        )

    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("results_root", type=Path)
    parser.add_argument("output_md", type=Path)
    args = parser.parse_args()

    baseline_dirs = sorted([path for path in args.results_root.iterdir() if path.is_dir()], key=lambda p: p.name)
    rows: list[tuple[str, FolderSummary, str]] = []

    for baseline_dir in baseline_dirs:
        item, basis = choose_run_for_baseline(baseline_dir)
        rows.append((baseline_dir.name, item, basis))

    rows.sort(key=lambda row: safe_sort_key(row[1].end_time, row[0]), reverse=True)
    markdown = render_markdown(args.results_root, rows)
    args.output_md.write_text(markdown)
    print(args.output_md)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
