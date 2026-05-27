#!/usr/bin/env python3
"""Normalize Codex CLI JSON logs into a line-oriented transcript.

The output is intentionally closer to the plain-text `ml_intern` trace style:
- wall-clock timestamps stay on every line
- tool calls become `▸ <tool> {...}`
- tool outputs are emitted as indented text blocks
- free-form agent updates stay as plain text instead of large JSON blobs
"""

from __future__ import annotations

import argparse
import json
import shlex
import shutil
import re
from pathlib import Path
from typing import Any

TIMESTAMP_PREFIX_RE = re.compile(r'^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\] ')
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
DETECT_LINES = 200
RESET = "\033[0m"
DIM = "\033[2m"
TOOL = "\033[38;2;255;200;80m"
WARN = "\033[33m"
ERROR = "\033[31m"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert Codex CLI JSONL logs into a human-readable transcript."
    )
    parser.add_argument("input", type=Path, help="Path to the input file produced by Codex CLI")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Destination text file. Defaults to <input>.parsed.txt in the same directory.",
    )
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="Print the parsed output to stdout instead of writing a file.",
    )
    return parser.parse_args()


def default_output_path(input_path: Path) -> Path:
    suffix = input_path.suffix or ""
    if suffix:
        return input_path.with_suffix(f"{suffix}.parsed.txt")
    return input_path.with_name(f"{input_path.name}.parsed.txt")


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def is_structured_json(input_path: Path) -> bool:
    with input_path.open("r", encoding="utf-8", errors="replace") as stream:
        seen = 0
        for raw_line in stream:
            stripped = raw_line.strip()
            if not stripped:
                continue
            ts_match = TIMESTAMP_PREFIX_RE.match(stripped)
            if ts_match:
                stripped = stripped[ts_match.end():]
            try:
                event = json.loads(stripped)
            except json.JSONDecodeError:
                seen += 1
                if seen >= DETECT_LINES:
                    break
                continue
            if isinstance(event, dict):
                return True
            seen += 1
            if seen >= DETECT_LINES:
                break
    return False


def copy_file(input_path: Path, args: argparse.Namespace) -> None:
    if args.stdout:
        print(input_path.read_text(encoding="utf-8"))
        return

    output_path = args.output or default_output_path(input_path)
    with input_path.open("rb") as src, output_path.open("wb") as dst:
        shutil.copyfileobj(src, dst)
    print(f"Wrote copied file to {output_path}")


def emit(
    lines: list[str],
    wall_ts: str | None,
    text: str,
    indent_level: int = 0,
    strip_colors: bool = True,
) -> None:
    prefix = f"[{wall_ts}] " if wall_ts else ""
    indent = "  " * indent_level
    normalized = (strip_ansi(text) if strip_colors else text).rstrip("\n")
    split_lines = normalized.splitlines() or [""]
    for line in split_lines:
        lines.append(f"{prefix}{indent}{line}".rstrip())


def compact_json(data: Any) -> str:
    return json.dumps(data, ensure_ascii=False, separators=(", ", ": "))


def format_command(command: list[str] | str | None) -> str:
    if command is None:
        return ""
    if isinstance(command, list):
        return " ".join(shlex.quote(str(token)) for token in command)
    return str(command)


def format_tool_call(
    lines: list[str],
    wall_ts: str | None,
    tool_name: str,
    payload: dict[str, Any] | None = None,
) -> None:
    if payload:
        emit(
            lines,
            wall_ts,
            f"{TOOL}▸ {tool_name}{RESET}  {DIM}{compact_json(payload)}{RESET}",
            1,
            strip_colors=False,
        )
    else:
        emit(lines, wall_ts, f"{TOOL}▸ {tool_name}{RESET}", 1, strip_colors=False)


def format_tool_output(lines: list[str], wall_ts: str | None, output: str | None) -> None:
    if output is None:
        return
    cleaned = strip_ansi(output).rstrip()
    if not cleaned:
        return
    emit(lines, wall_ts, cleaned, 2)


def format_exit_status(
    lines: list[str],
    wall_ts: str | None,
    exit_code: Any,
    status: str | None = None,
) -> None:
    if exit_code not in (None, 0):
        emit(lines, wall_ts, f"{ERROR}Exit code: {exit_code}{RESET}", 2, strip_colors=False)
    elif status and status not in {"completed", "success"}:
        emit(lines, wall_ts, f"{WARN}Status: {status}{RESET}", 2, strip_colors=False)


def format_message(lines: list[str], wall_ts: str | None, text: str | None) -> None:
    if text:
        emit(lines, wall_ts, text.rstrip())


def format_reasoning(lines: list[str], wall_ts: str | None, text: str | None) -> None:
    if not text:
        return
    emit(lines, wall_ts, "Reasoning:", 1)
    emit(lines, wall_ts, text.rstrip(), 2)


def simplify_changes(changes: list[dict[str, Any]] | None) -> list[dict[str, Any]]:
    if not changes:
        return []
    simplified: list[dict[str, Any]] = []
    for change in changes:
        simplified.append(
            {
                k: change[k]
                for k in ("path", "kind")
                if k in change
            }
        )
    return simplified


def format_legacy_item_started(lines: list[str], wall_ts: str | None, item: dict[str, Any]) -> None:
    item_type = item.get("type")
    if item_type == "command_execution":
        format_tool_call(lines, wall_ts, "bash", {"command": item.get("command", "")})
    elif item_type == "file_change":
        format_tool_call(lines, wall_ts, "edit", {"changes": simplify_changes(item.get("changes"))})


def format_legacy_item_completed(lines: list[str], wall_ts: str | None, item: dict[str, Any]) -> None:
    item_type = item.get("type")
    if item_type == "agent_message":
        format_message(lines, wall_ts, item.get("text"))
        return
    if item_type == "reasoning":
        format_reasoning(lines, wall_ts, item.get("text"))
        return
    if item_type == "command_execution":
        format_tool_output(lines, wall_ts, item.get("aggregated_output"))
        format_exit_status(lines, wall_ts, item.get("exit_code"), item.get("status"))
        return
    if item_type == "file_change" and item.get("changes"):
        emit(lines, wall_ts, f"Updated files: {compact_json(simplify_changes(item.get('changes')))}", 2)
        return

    payload = {k: v for k, v in item.items() if k != "type"}
    if payload:
        emit(lines, wall_ts, compact_json(payload), 1)


def format_legacy_event(lines: list[str], wall_ts: str | None, event: dict[str, Any]) -> None:
    event_type = event.get("type")
    if event_type == "thread.started":
        thread_id = event.get("thread_id")
        if thread_id:
            emit(lines, wall_ts, f"Session started: {thread_id}")
        return
    if event_type in {"turn.started", "turn.completed"}:
        return
    if event_type == "item.started":
        item = event.get("item")
        if isinstance(item, dict):
            format_legacy_item_started(lines, wall_ts, item)
        return
    if event_type == "item.completed":
        item = event.get("item")
        if isinstance(item, dict):
            format_legacy_item_completed(lines, wall_ts, item)
        return

    payload = {k: v for k, v in event.items() if k != "type"}
    if payload:
        emit(lines, wall_ts, compact_json(payload), 1)


def format_new_event(lines: list[str], wall_ts: str | None, msg: dict[str, Any]) -> None:
    event_type = msg.get("type")

    if event_type == "session_configured":
        details = {
            key: msg[key]
            for key in ("session_id", "model", "model_provider_id", "cwd", "approval_policy", "sandbox_policy")
            if key in msg
        }
        if details:
            emit(lines, wall_ts, f"Session configured: {compact_json(details)}")
        return

    if event_type in {"task_started", "turn_started", "task_complete", "turn_complete"}:
        last_message = msg.get("last_agent_message")
        if last_message:
            format_message(lines, wall_ts, last_message)
        return

    if event_type == "agent_message":
        format_message(lines, wall_ts, msg.get("message"))
        return

    if event_type in {"agent_reasoning", "agent_reasoning_raw_content"}:
        format_reasoning(lines, wall_ts, msg.get("text"))
        return

    if event_type == "user_message":
        format_message(lines, wall_ts, msg.get("message"))
        return

    if event_type == "exec_command_begin":
        payload = {"command": format_command(msg.get("command"))}
        if msg.get("cwd"):
            payload["cwd"] = msg["cwd"]
        format_tool_call(lines, wall_ts, "bash", payload)
        return

    if event_type == "exec_command_end":
        format_tool_output(lines, wall_ts, msg.get("stdout"))
        format_tool_output(lines, wall_ts, msg.get("stderr"))
        format_exit_status(lines, wall_ts, msg.get("exit_code"))
        return

    if event_type == "mcp_tool_call_begin":
        payload = {"tool": msg.get("tool_name")}
        if "arguments" in msg:
            payload["arguments"] = msg["arguments"]
        format_tool_call(lines, wall_ts, f"mcp:{msg.get('server_name', 'server')}", payload)
        return

    if event_type == "mcp_tool_call_end":
        result = msg.get("result")
        if result is not None:
            emit(lines, wall_ts, compact_json(result), 2)
        return

    if event_type == "patch_apply_begin":
        format_tool_call(lines, wall_ts, "apply_patch")
        patch = msg.get("patch")
        if patch:
            emit(lines, wall_ts, patch.rstrip(), 2)
        return

    if event_type == "patch_apply_end":
        status_bits = {}
        if "success" in msg:
            status_bits["success"] = msg["success"]
        if msg.get("error"):
            status_bits["error"] = msg["error"]
        if status_bits:
            emit(lines, wall_ts, compact_json(status_bits), 2)
        return

    if event_type == "token_count":
        session = msg.get("session")
        turn = msg.get("turn")
        if session:
            emit(lines, wall_ts, f"Session tokens: {compact_json(session)}", 1)
        if turn:
            emit(lines, wall_ts, f"Turn tokens: {compact_json(turn)}", 1)
        return

    if event_type == "warning":
        if msg.get("message"):
            emit(lines, wall_ts, f"{WARN}Warning: {msg['message']}{RESET}", strip_colors=False)
        return

    if event_type == "error":
        if msg.get("message"):
            emit(lines, wall_ts, f"{ERROR}Error: {msg['message']}{RESET}", strip_colors=False)
        else:
            emit(lines, wall_ts, f"{ERROR}Error{RESET}", strip_colors=False)
        if msg.get("code"):
            emit(lines, wall_ts, f"{ERROR}Code: {msg['code']}{RESET}", 1, strip_colors=False)
        return

    payload = {k: v for k, v in msg.items() if k != "type"}
    if payload:
        emit(lines, wall_ts, compact_json(payload), 1)


def parse_delta_text(event: dict[str, Any]) -> tuple[str | None, str | None]:
    msg = event.get("msg", event)
    event_type = msg.get("type")
    if event_type not in {
        "agent_message_delta",
        "agent_reasoning_delta",
        "agent_reasoning_raw_content_delta",
    }:
        return None, None
    text = msg.get("delta") or msg.get("text")
    if not text:
        return None, None
    return event_type, str(text)


def flush_delta_buffer(
    lines: list[str],
    wall_ts: str | None,
    delta_type: str | None,
    delta_parts: list[str],
) -> None:
    if not delta_type or not delta_parts:
        return
    text = "".join(delta_parts).rstrip()
    if not text:
        return
    if delta_type == "agent_message_delta":
        format_message(lines, wall_ts, text)
    else:
        format_reasoning(lines, wall_ts, text)


def main() -> None:
    args = parse_args()
    input_path = args.input
    if not input_path.exists():
        raise SystemExit(f"Input file not found: {input_path}")

    if not is_structured_json(input_path):
        copy_file(input_path, args)
        return

    output_path = args.output or default_output_path(input_path)
    lines: list[str] = []
    delta_type: str | None = None
    delta_parts: list[str] = []
    delta_wall_ts: str | None = None

    with input_path.open("r", encoding="utf-8", errors="replace") as stream:
        for raw_line in stream:
            stripped = raw_line.strip()
            if not stripped:
                continue

            wall_ts = None
            ts_match = TIMESTAMP_PREFIX_RE.match(stripped)
            if ts_match:
                wall_ts = ts_match.group(1)
                stripped = stripped[ts_match.end():]

            try:
                event = json.loads(stripped)
            except json.JSONDecodeError:
                flush_delta_buffer(lines, delta_wall_ts, delta_type, delta_parts)
                delta_type = None
                delta_parts = []
                delta_wall_ts = None
                emit(lines, wall_ts, stripped)
                continue

            if not isinstance(event, dict):
                flush_delta_buffer(lines, delta_wall_ts, delta_type, delta_parts)
                delta_type = None
                delta_parts = []
                delta_wall_ts = None
                emit(lines, wall_ts, stripped)
                continue

            maybe_delta_type, maybe_delta_text = parse_delta_text(event)
            if maybe_delta_type and maybe_delta_text is not None:
                if delta_type is not None and maybe_delta_type != delta_type:
                    flush_delta_buffer(lines, delta_wall_ts, delta_type, delta_parts)
                    delta_parts = []
                delta_type = maybe_delta_type
                delta_wall_ts = delta_wall_ts or wall_ts
                delta_parts.append(maybe_delta_text)
                continue

            flush_delta_buffer(lines, delta_wall_ts, delta_type, delta_parts)
            delta_type = None
            delta_parts = []
            delta_wall_ts = None

            if "msg" in event and isinstance(event["msg"], dict):
                format_new_event(lines, wall_ts, event["msg"])
            else:
                format_legacy_event(lines, wall_ts, event)

    flush_delta_buffer(lines, delta_wall_ts, delta_type, delta_parts)

    output_text = "\n".join(line for line in lines if line is not None).rstrip() + "\n"

    if args.stdout:
        print(output_text, end="")
    else:
        output_path.write_text(output_text, encoding="utf-8")
        print(f"Wrote parsed report to {output_path}")


if __name__ == "__main__":
    main()
