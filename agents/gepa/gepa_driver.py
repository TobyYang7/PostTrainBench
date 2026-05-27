#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import subprocess
import textwrap
import time
from pathlib import Path
from queue import Empty, Queue
from threading import Thread
from typing import Any

import gepa.optimize_anything as oa
from gepa.optimize_anything import EngineConfig, GEPAConfig, ReflectionConfig, optimize_anything


TASK_ROOT = Path("/home/ben/task").resolve()
WORK_ROOT = TASK_ROOT / "gepa_runs"
SNAPSHOT_ROOT = WORK_ROOT / "seed_snapshot"
RESULTS_ROOT = WORK_ROOT / "evaluations"
FINAL_RUN_DIR = WORK_ROOT / "final_run"
CODEX_HOME_SEED = WORK_ROOT / "codex_home_seed"

PROMPT = os.environ["PROMPT"]
TASK_NAME = os.environ.get("EVALUATION_TASK", "unknown")
MODEL_TO_TRAIN = os.environ.get("MODEL_TO_TRAIN", "unknown")
EXEC_MODEL = os.environ.get("GEPA_EXEC_MODEL", os.environ.get("AGENT_CONFIG", "gpt-5.5"))
REFLECTION_MODEL = os.environ.get("GEPA_REFLECTION_MODEL", EXEC_MODEL)
MAX_METRIC_CALLS = int(os.environ.get("GEPA_MAX_METRIC_CALLS", "8"))
EVAL_LIMIT = int(os.environ.get("GEPA_EVAL_LIMIT", "32"))
CANDIDATE_TIMEOUT_SECS = int(os.environ.get("GEPA_CANDIDATE_TIMEOUT_SECS", "1500"))
FINAL_TIMEOUT_SECS = int(os.environ.get("GEPA_FINAL_TIMEOUT_SECS", str(CANDIDATE_TIMEOUT_SECS * 2)))

def get_optional_env(name: str, default: str = "") -> str:
    value = os.environ.get(name, default)
    if value is None:
        return default
    value = value.strip()
    if not value or value.upper() == "UNDEFINED":
        return default
    return value


METRIC_KEY = get_optional_env("GEPA_METRIC_KEY")


def ignore_snapshot_dir(_: str, names: list[str]) -> list[str]:
    ignored = {"gepa_runs"}
    if "final_model" in names:
        ignored.add("final_model")
    return sorted(ignored.intersection(names))


def ensure_snapshot() -> None:
    WORK_ROOT.mkdir(parents=True, exist_ok=True)
    RESULTS_ROOT.mkdir(parents=True, exist_ok=True)
    if SNAPSHOT_ROOT.exists():
        if CODEX_HOME_SEED.exists():
            return
    else:
        log(f"[GEPA] Creating task snapshot at {SNAPSHOT_ROOT}")
        shutil.copytree(TASK_ROOT, SNAPSHOT_ROOT, ignore=ignore_snapshot_dir)

    if not CODEX_HOME_SEED.exists():
        source_codex_home = Path.home() / ".codex"
        if not source_codex_home.is_dir():
            raise FileNotFoundError(f"Expected Codex auth directory at {source_codex_home}")
        log(f"[GEPA] Snapshotting Codex auth into {CODEX_HOME_SEED}")
        shutil.copytree(source_codex_home, CODEX_HOME_SEED)
        force_chatgpt_login(CODEX_HOME_SEED)


def seed_candidate() -> str:
    return textwrap.dedent(
        """
        You are optimizing the strategy prompt for an autonomous coding agent working inside PostTrainBench.

        Operating principles:
        1. Inspect evaluate.py, timer.sh, and gepa_timeout.sh first so you understand the metric plus both the benchmark-level and inner-executor time budgets.
        2. Prefer fast iteration loops before committing to long training runs.
        3. Start with lightweight methods such as LoRA / parameter-efficient fine-tuning unless the task clearly benefits from something else.
        4. Use the benchmark's training split, synthetic data, or self-generated supervision, but never train on benchmark test answers.
        5. Keep all artifacts loadable in the starting environment without requiring new global packages.
        6. Always leave the best model in ./final_model before exiting.
        7. When something fails, diagnose it from logs and try the smallest targeted fix instead of restarting from scratch.
        8. Respect the execution mode injected by the outer GEPA runner:
           - In `candidate_evaluation`, optimize for a quick, valid `./final_model` that finishes comfortably within the provided timeout. Prefer smoke tests plus one short training run over a full multi-epoch training job.
           - In `final_replay`, reuse the best validated recipe and spend the fuller timeout budget to maximize final quality.
        9. In `candidate_evaluation`, keep at least 20%% of the timeout in reserve for merge/save and follow-up checks. Base this on `bash gepa_timeout.sh`, not `bash timer.sh`, because `timer.sh` only reports the outer benchmark deadline.
        10. Do not start a training run that is likely to overrun the remaining time shown by `bash gepa_timeout.sh`.
        """
    ).strip()


def objective() -> str:
    return (
        f"Optimize a strategy prompt for an autonomous Codex executor so that it post-trains "
        f"{MODEL_TO_TRAIN} for {TASK_NAME} inside PostTrainBench and leaves the best model in final_model."
    )


def background() -> str:
    return textwrap.dedent(
        f"""
        The strategy prompt is not the benchmark task prompt itself. It is guidance for an inner Codex executor.

        Benchmark task prompt:
        {PROMPT}

        Hard constraints:
        - The executor must obey all PostTrainBench rules in the benchmark task prompt.
        - The evaluator scores candidates by running the inner Codex executor in a fresh workspace copy, then running evaluate.py.
        - Higher evaluation scores are better.
        - The inner executor runs in a bounded timeout, so strategies should emphasize fast useful progress.
        """
    ).strip()


def summarize_text(text: str, limit: int = 8000) -> str:
    if len(text) <= limit:
        return text
    head = text[: limit // 2]
    tail = text[-(limit // 2) :]
    return f"{head}\n\n... [truncated] ...\n\n{tail}"


def log(msg: str) -> None:
    print(msg, flush=True)


def force_chatgpt_login(codex_home: Path) -> None:
    config_path = codex_home / "config.toml"
    config_path.parent.mkdir(parents=True, exist_ok=True)
    current = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    if 'forced_login_method = "chatgpt"' not in current:
        suffix = "" if not current or current.endswith("\n") else "\n"
        config_path.write_text(f'{current}{suffix}forced_login_method = "chatgpt"\n', encoding="utf-8")


def prepare_codex_home(run_root: Path) -> Path:
    run_home = run_root / "runner_home"
    codex_home = run_home / ".codex"
    if run_home.exists():
        shutil.rmtree(run_home)
    run_home.mkdir(parents=True, exist_ok=True)
    shutil.copytree(CODEX_HOME_SEED, codex_home)
    force_chatgpt_login(codex_home)
    return run_home


def _pump_stream(pipe, queue: Queue, stream_name: str) -> None:
    try:
        for line in iter(pipe.readline, ""):
            queue.put((stream_name, line))
    finally:
        pipe.close()


def run_streaming_subprocess(
    cmd: list[str],
    cwd: Path,
    timeout_secs: int,
    output_path: Path,
    env: dict[str, str] | None = None,
    prefix: str = "",
) -> tuple[int, str, str]:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as out_f:
        proc = subprocess.Popen(
            cmd,
            cwd=cwd,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=1,
        )

        queue: Queue = Queue()
        threads = [
            Thread(target=_pump_stream, args=(proc.stdout, queue, "stdout"), daemon=True),
            Thread(target=_pump_stream, args=(proc.stderr, queue, "stderr"), daemon=True),
        ]
        for thread in threads:
            thread.start()

        stdout_chunks: list[str] = []
        stderr_chunks: list[str] = []
        timed_out = False
        deadline = time.time() + timeout_secs

        while True:
            try:
                stream_name, line = queue.get(timeout=0.2)
                out_f.write(line)
                out_f.flush()
                rendered = f"{prefix}{line.rstrip()}" if prefix else line.rstrip()
                if rendered:
                    log(rendered)
                if stream_name == "stdout":
                    stdout_chunks.append(line)
                else:
                    stderr_chunks.append(line)
            except Empty:
                pass

            if proc.poll() is not None:
                break
            if time.time() > deadline:
                timed_out = True
                proc.kill()
                break

        for thread in threads:
            thread.join(timeout=1)

        while True:
            try:
                stream_name, line = queue.get_nowait()
            except Empty:
                break
            out_f.write(line)
            out_f.flush()
            rendered = f"{prefix}{line.rstrip()}" if prefix else line.rstrip()
            if rendered:
                log(rendered)
            if stream_name == "stdout":
                stdout_chunks.append(line)
            else:
                stderr_chunks.append(line)

        return (124 if timed_out else proc.returncode), "".join(stdout_chunks), "".join(stderr_chunks)


def build_executor_prompt(strategy_prompt: str, mode: str, timeout_secs: int) -> str:
    return textwrap.dedent(
        f"""
        You are an autonomous coding agent inside PostTrainBench.

        Execution mode: {mode}
        Available inner-executor timeout budget at launch: {timeout_secs} seconds
        Use `bash gepa_timeout.sh` to check the remaining inner-executor time budget.
        Use `bash timer.sh` only to check the benchmark's overall time budget.

        Strategy instructions:
        {strategy_prompt}

        Benchmark task:
        {PROMPT}
        """
    ).strip()


def write_inner_timeout_script(task_dir: Path, timeout_secs: int) -> Path:
    deadline_epoch = int(time.time() + timeout_secs)
    script_path = task_dir / "gepa_timeout.sh"
    script_body = textwrap.dedent(
        f"""\
        #!/bin/bash
        set -euo pipefail

        DEADLINE_EPOCH={deadline_epoch}
        NOW=$(date +%s)
        REMAINING=$((DEADLINE_EPOCH - NOW))

        if [ "$REMAINING" -le 0 ]; then
            echo "GEPA inner timeout expired!"
        else
            echo "Remaining inner-executor time (hours:minutes:seconds):"
            HOURS=$((REMAINING / 3600))
            MINUTES=$(((REMAINING % 3600) / 60))
            SECONDS=$((REMAINING % 60))
            printf "%d:%02d:%02d\\n" "$HOURS" "$MINUTES" "$SECONDS"
        fi
        """
    )
    script_path.write_text(script_body, encoding="utf-8")
    script_path.chmod(0o755)
    return script_path


def copy_snapshot_to(run_dir: Path) -> Path:
    task_dir = run_dir / "task"
    if task_dir.exists():
        shutil.rmtree(task_dir)
    shutil.copytree(SNAPSHOT_ROOT, task_dir)
    log(f"[GEPA] Prepared workspace {task_dir}")
    return task_dir


def run_codex_executor(task_dir: Path, prompt: str, timeout_secs: int, output_path: Path) -> tuple[int, str, str]:
    run_home = prepare_codex_home(output_path.parent)
    cmd = [
        "codex",
        "--search",
        "exec",
        "--json",
        "-c",
        "model_reasoning_summary=detailed",
        "--skip-git-repo-check",
        "--yolo",
        "--model",
        EXEC_MODEL,
        prompt,
    ]
    env = os.environ.copy()
    # The GEPA reflection LM uses the API key in the parent process, but the inner
    # Codex executor should use the copied ChatGPT auth under ~/.codex instead of
    # inheriting the benchmark API key, which triggers 401s with the Codex CLI.
    env["OPENAI_API_KEY"] = ""
    env["CODEX_API_KEY"] = ""
    env["OPENAI_BASE_URL"] = ""
    env["OPENAI_API_BASE"] = ""
    env["HOME"] = str(run_home)
    env["CODEX_HOME"] = str(run_home / ".codex")
    log(f"[GEPA] Launching inner Codex executor at {task_dir} with timeout={timeout_secs}s")
    return run_streaming_subprocess(
        cmd=cmd,
        cwd=task_dir,
        env=env,
        timeout_secs=timeout_secs,
        output_path=output_path,
        prefix="[inner-codex] ",
    )


def has_final_model(task_dir: Path) -> bool:
    final_model_dir = task_dir / "final_model"
    return final_model_dir.is_dir() and any(final_model_dir.iterdir())


def run_eval(task_dir: Path, result_dir: Path) -> tuple[float, dict[str, Any], str, str]:
    metrics_path = result_dir / "metrics.json"
    eval_log_path = result_dir / "evaluate_output.txt"
    cmd = [
        "python",
        "evaluate.py",
        "--model-path",
        "final_model",
        "--templates-dir",
        "templates",
        "--limit",
        str(EVAL_LIMIT),
        "--json-output-file",
        str(metrics_path),
    ]
    log(f"[GEPA] Launching evaluator in {task_dir}")
    returncode, stdout, stderr = run_streaming_subprocess(
        cmd=cmd,
        cwd=task_dir,
        timeout_secs=max(600, CANDIDATE_TIMEOUT_SECS),
        output_path=eval_log_path,
        prefix="[evaluate] ",
    )
    if returncode != 0 or not metrics_path.exists():
        return 0.0, {}, stdout, stderr

    with metrics_path.open("r", encoding="utf-8") as f:
        metrics = json.load(f)

    score = choose_score(metrics)
    return score, metrics, stdout, stderr


def choose_score(metrics: dict[str, Any]) -> float:
    if METRIC_KEY:
        value = metrics.get(METRIC_KEY)
        if isinstance(value, (int, float)):
            return float(value)
        raise ValueError(f"Configured GEPA_METRIC_KEY={METRIC_KEY!r} not found in metrics: {sorted(metrics)}")

    priority_keys = [
        "accuracy",
        "pass_at_1",
        "exact_match",
        "score",
        "primary_score",
        "overall",
    ]
    for key in priority_keys:
        value = metrics.get(key)
        if isinstance(value, (int, float)):
            return float(value)

    numeric_items = [(k, float(v)) for k, v in metrics.items() if isinstance(v, (int, float))]
    if not numeric_items:
        raise ValueError(f"No numeric metrics found in {metrics}")
    numeric_items.sort(key=lambda item: item[0])
    return numeric_items[0][1]


class Evaluator:
    def __init__(self) -> None:
        self.eval_counter = 0

    def __call__(self, candidate: str) -> tuple[float, dict[str, Any]]:
        self.eval_counter += 1
        log(f"[GEPA] ===== Candidate {self.eval_counter} / max_metric_calls={MAX_METRIC_CALLS} =====")
        run_dir = RESULTS_ROOT / f"eval_{self.eval_counter:03d}"
        if run_dir.exists():
            shutil.rmtree(run_dir)
        run_dir.mkdir(parents=True, exist_ok=True)
        task_dir = copy_snapshot_to(run_dir)

        strategy_path = run_dir / "strategy.txt"
        strategy_path.write_text(candidate, encoding="utf-8")
        log(f"[GEPA] Candidate {self.eval_counter} strategy saved to {strategy_path}")
        write_inner_timeout_script(task_dir, CANDIDATE_TIMEOUT_SECS)

        executor_prompt = build_executor_prompt(
            candidate,
            mode="candidate_evaluation",
            timeout_secs=CANDIDATE_TIMEOUT_SECS,
        )
        codex_output_path = run_dir / "codex_output.jsonl"
        codex_exit, codex_stdout, codex_stderr = run_codex_executor(
            task_dir=task_dir,
            prompt=executor_prompt,
            timeout_secs=CANDIDATE_TIMEOUT_SECS,
            output_path=codex_output_path,
        )

        oa.log(f"Candidate strategy:\n{candidate}")
        oa.log(f"Codex exit code: {codex_exit}")
        log(f"[GEPA] Candidate {self.eval_counter} inner Codex exit code: {codex_exit}")
        if codex_stdout:
            oa.log(f"Codex stdout:\n{summarize_text(codex_stdout)}")
        if codex_stderr:
            oa.log(f"Codex stderr:\n{summarize_text(codex_stderr)}")

        side_info: dict[str, Any] = {
            "candidate_index": self.eval_counter,
            "codex_exit_code": codex_exit,
            "run_dir": str(run_dir),
        }

        if not has_final_model(task_dir):
            side_info["final_model_present"] = False
            log(f"[GEPA] Candidate {self.eval_counter} did not produce final_model")
            return 0.0, side_info

        score, metrics, eval_stdout, eval_stderr = run_eval(task_dir, run_dir)
        side_info["final_model_present"] = True
        side_info["metrics"] = metrics
        side_info["score"] = score
        log(f"[GEPA] Candidate {self.eval_counter} score={score}")

        if eval_stdout:
            oa.log(f"Evaluation stdout:\n{summarize_text(eval_stdout)}")
        if eval_stderr:
            oa.log(f"Evaluation stderr:\n{summarize_text(eval_stderr)}")
        if metrics:
            oa.log(f"Metrics: {json.dumps(metrics, indent=2, sort_keys=True)}")
            log(f"[GEPA] Candidate {self.eval_counter} metrics keys={sorted(metrics)}")

        return score, side_info


def reset_final_model(root: Path) -> None:
    final_model_dir = root / "final_model"
    if final_model_dir.exists():
        shutil.rmtree(final_model_dir)


def run_final_candidate(best_candidate: str) -> None:
    if FINAL_RUN_DIR.exists():
        shutil.rmtree(FINAL_RUN_DIR)
    FINAL_RUN_DIR.mkdir(parents=True, exist_ok=True)

    reset_final_model(TASK_ROOT)
    write_inner_timeout_script(TASK_ROOT, FINAL_TIMEOUT_SECS)
    log("[GEPA] Replaying best candidate into /home/ben/task/final_model")
    final_prompt = build_executor_prompt(
        best_candidate,
        mode="final_replay",
        timeout_secs=FINAL_TIMEOUT_SECS,
    )
    output_path = FINAL_RUN_DIR / "codex_output.jsonl"
    exit_code, stdout, stderr = run_codex_executor(
        task_dir=TASK_ROOT,
        prompt=final_prompt,
        timeout_secs=FINAL_TIMEOUT_SECS,
        output_path=output_path,
    )

    (FINAL_RUN_DIR / "strategy.txt").write_text(best_candidate, encoding="utf-8")
    (FINAL_RUN_DIR / "codex_stdout.txt").write_text(stdout, encoding="utf-8")
    (FINAL_RUN_DIR / "codex_stderr.txt").write_text(stderr, encoding="utf-8")

    if exit_code != 0:
        raise RuntimeError(f"Final GEPA candidate run failed with codex exit code {exit_code}")
    if not has_final_model(TASK_ROOT):
        raise RuntimeError("Final GEPA candidate run did not produce ./final_model")


def main() -> None:
    ensure_snapshot()
    log(
        f"[GEPA] task={TASK_NAME} model={MODEL_TO_TRAIN} exec_model={EXEC_MODEL} "
        f"reflection_model={REFLECTION_MODEL}"
    )
    log(f"[GEPA] work_root={WORK_ROOT}")

    config = GEPAConfig(
        engine=EngineConfig(
            run_dir=str(WORK_ROOT / "engine"),
            max_metric_calls=MAX_METRIC_CALLS,
            display_progress_bar=False,
            parallel=False,
            max_workers=1,
            num_parallel_proposals=1,
            capture_stdio=False,
        ),
        reflection=ReflectionConfig(
            reflection_lm=REFLECTION_MODEL,
        ),
    )

    evaluator = Evaluator()
    log("[GEPA] Invoking optimize_anything")
    result = optimize_anything(
        seed_candidate=seed_candidate(),
        evaluator=evaluator,
        objective=objective(),
        background=background(),
        config=config,
    )

    best_candidate = result.best_candidate
    if not isinstance(best_candidate, str):
        raise TypeError(f"Expected string best_candidate for GEPA strategy prompt, got {type(best_candidate)!r}")

    best_path = WORK_ROOT / "best_strategy.txt"
    best_path.write_text(best_candidate, encoding="utf-8")
    log(f"[GEPA] Best strategy saved to {best_path}")

    run_final_candidate(best_candidate)


if __name__ == "__main__":
    main()
