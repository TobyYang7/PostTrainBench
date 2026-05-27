#!/usr/bin/env python3
from __future__ import annotations

import argparse
import atexit
import concurrent.futures
import json
import math
import os
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import requests
from datasets import load_dataset
from inspect_ai.scorer._common import match_str
from inspect_evals.gsm8k.gsm8k import (
    MATH_PROMPT_TEMPLATE,
    record_to_sample,
    sample_to_fewshot,
)

VLLM_HEALTH_TIMEOUT = 600


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run sharded GSM8K evaluation against multiple single-GPU vLLM servers."
    )
    parser.add_argument(
        "--model-path",
        type=str,
        required=True,
        help="Path to the model directory to serve with vLLM.",
    )
    parser.add_argument(
        "--baseline-name",
        type=str,
        required=True,
        help="Baseline name used for final JSON output naming.",
    )
    parser.add_argument(
        "--output-file",
        type=str,
        required=True,
        help="Final merged JSON output path.",
    )
    parser.add_argument(
        "--work-dir",
        type=str,
        default=None,
        help="Directory for per-shard JSON files and vLLM logs.",
    )
    parser.add_argument(
        "--templates-dir",
        type=str,
        default="templates/",
        help="Directory containing chat templates.",
    )
    parser.add_argument(
        "--gpus",
        type=str,
        required=True,
        help="Comma-separated physical GPU ids, one per shard/server.",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=4000,
    )
    parser.add_argument(
        "--temperature",
        type=float,
        default=0.0,
    )
    parser.add_argument(
        "--top-p",
        type=float,
        default=1.0,
    )
    parser.add_argument(
        "--gpu-memory-utilization",
        type=float,
        default=0.7,
    )
    parser.add_argument(
        "--fewshot",
        type=int,
        default=10,
    )
    parser.add_argument(
        "--fewshot-seed",
        type=int,
        default=42,
    )
    parser.add_argument(
        "--shuffle-fewshot",
        action="store_true",
        default=True,
        help="Shuffle the train split before taking few-shot examples.",
    )
    parser.add_argument(
        "--no-shuffle-fewshot",
        action="store_false",
        dest="shuffle_fewshot",
    )
    parser.add_argument(
        "--request-timeout",
        type=int,
        default=600,
    )
    parser.add_argument(
        "--request-retries",
        type=int,
        default=5,
    )
    parser.add_argument(
        "--api-key",
        type=str,
        default=os.environ.get("VLLM_API_KEY", "inspectai"),
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=-1,
        help="Optional limit for smoke tests; use -1 for the full GSM8K test split.",
    )
    return parser.parse_args()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def model_type(model_path: str) -> str:
    lowered = model_path.lower()
    if "qwen" in lowered:
        return "qwen"
    if "llama" in lowered:
        return "llama"
    if "gemma" in lowered:
        return "gemma"
    if "smollm" in lowered:
        return "smollm"

    config_path = Path(model_path) / "config.json"
    with config_path.open("r", encoding="utf-8") as f:
        architecture = json.load(f)["architectures"][0].lower()
    if "qwen" in architecture:
        return "qwen"
    if "llama" in architecture:
        return "llama"
    if "gemma" in architecture:
        return "gemma"
    if "smollm" in architecture:
        return "smollm"
    raise ValueError(f"Unsupported architecture: {architecture}")


def chat_template_path(model_path: str, templates_dir: str) -> str:
    mapping = {
        "qwen": "qwen3.jinja",
        "llama": "llama3.jinja",
        "gemma": "gemma3.jinja",
        "smollm": "smollm.jinja",
    }
    return os.path.join(templates_dir, mapping[model_type(model_path)])


def find_available_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def wait_for_vllm_server(port: int, process: subprocess.Popen[bytes]) -> None:
    health_url = f"http://127.0.0.1:{port}/health"
    deadline = time.time() + VLLM_HEALTH_TIMEOUT

    while time.time() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"vLLM server on port {port} exited during startup.")
        try:
            response = requests.get(health_url, timeout=5)
            if response.status_code == 200:
                return
        except requests.RequestException:
            pass
        time.sleep(1)

    raise TimeoutError(f"Timed out waiting for vLLM server on port {port}.")


@dataclass
class Example:
    index: int
    sample_id: str
    question: str
    target: str
    messages: list[dict[str, str]]


class VLLMServer:
    def __init__(
        self,
        *,
        args: argparse.Namespace,
        gpu_id: int,
        shard_id: int,
        template_path: str,
        work_dir: Path,
    ) -> None:
        self.args = args
        self.gpu_id = gpu_id
        self.shard_id = shard_id
        self.template_path = template_path
        self.work_dir = work_dir
        self.port: int | None = None
        self.process: subprocess.Popen[bytes] | None = None
        self.served_model_name = f"{args.baseline_name}-shard-{shard_id}"
        self.log_path = work_dir / f"vllm_shard_{shard_id}.log"
        self.log_file: Any | None = None

    def start(self) -> None:
        if self.process is not None:
            raise RuntimeError(f"vLLM shard {self.shard_id} already started.")

        self.port = find_available_port()
        env = os.environ.copy()
        env["CUDA_VISIBLE_DEVICES"] = str(self.gpu_id)
        env["VLLM_API_KEY"] = self.args.api_key
        env["PYTHONUNBUFFERED"] = "1"

        command = [
            sys.executable,
            str(Path(__file__).with_name("vllm_serve_patched.py")),
            "serve",
            self.args.model_path,
            "--host",
            "127.0.0.1",
            "--port",
            str(self.port),
            "--served-model-name",
            self.served_model_name,
            "--gpu-memory-utilization",
            str(self.args.gpu_memory_utilization),
            "--trust-remote-code",
            "--api-key",
            self.args.api_key,
            "--chat-template",
            self.template_path,
        ]

        self.log_file = self.log_path.open("w", encoding="utf-8")
        self.process = subprocess.Popen(
            command,
            env=env,
            stdout=self.log_file,
            stderr=subprocess.STDOUT,
        )
        try:
            wait_for_vllm_server(self.port, self.process)
        except Exception:
            self.stop(force=True)
            raise

        atexit.register(self.stop)

    def stop(self, force: bool = False) -> None:
        if self.process is None:
            return
        if self.process.poll() is None:
            if force:
                self.process.kill()
            else:
                self.process.terminate()
                try:
                    self.process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    self.process.kill()
        self.process = None
        if self.log_file is not None:
            self.log_file.close()
            self.log_file = None

    @property
    def endpoint(self) -> str:
        if self.port is None:
            raise RuntimeError("vLLM server not started.")
        return f"http://127.0.0.1:{self.port}/v1/chat/completions"


def sample_stderr(values: list[int]) -> float:
    n = len(values)
    if n < 2:
        return 0.0
    mean = sum(values) / n
    variance = sum((value - mean) ** 2 for value in values) / (n - 1)
    return math.sqrt(variance) / math.sqrt(n)


def build_examples(args: argparse.Namespace) -> list[Example]:
    train_split = load_dataset("openai/gsm8k", "main", split="train")
    if args.shuffle_fewshot:
        train_split = train_split.shuffle(seed=args.fewshot_seed)
    fewshot_records = train_split.select(range(args.fewshot))
    fewshot_text = "\n\n".join(
        sample_to_fewshot(record_to_sample(record)) for record in fewshot_records
    )

    test_split = load_dataset("openai/gsm8k", "main", split="test")
    if args.limit is not None and args.limit >= 0:
        test_split = test_split.select(range(min(args.limit, len(test_split))))
    examples: list[Example] = []
    for index, record in enumerate(test_split):
        sample = record_to_sample(record)
        messages: list[dict[str, str]] = []
        if fewshot_text:
            messages.append({"role": "system", "content": fewshot_text})
        messages.append(
            {
                "role": "user",
                "content": MATH_PROMPT_TEMPLATE.format(prompt=sample.input),
            }
        )
        examples.append(
            Example(
                index=index,
                sample_id=str(sample.id),
                question=str(sample.input),
                target=str(sample.target),
                messages=messages,
            )
        )
    return examples


def shard_examples(examples: list[Example], num_shards: int) -> list[list[Example]]:
    return [examples[shard_id::num_shards] for shard_id in range(num_shards)]


def request_completion(
    *,
    session: requests.Session,
    endpoint: str,
    api_key: str,
    model_name: str,
    messages: list[dict[str, str]],
    max_tokens: int,
    temperature: float,
    top_p: float,
    timeout: int,
    retries: int,
) -> tuple[str, dict[str, Any]]:
    session.headers["Authorization"] = f"Bearer {api_key}"

    payload: dict[str, Any] = {
        "model": model_name,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "top_p": top_p,
    }

    last_error: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            response = session.post(endpoint, json=payload, timeout=timeout)
            response.raise_for_status()
            data = response.json()
            return data["choices"][0]["message"]["content"], data.get("usage", {})
        except Exception as err:  # noqa: BLE001
            last_error = err
            if attempt == retries:
                break
            sleep_seconds = min(30, attempt * 2)
            print(
                f"[retry] endpoint={endpoint} attempt={attempt}/{retries} error={err}; "
                f"sleep={sleep_seconds}s",
                flush=True,
            )
            time.sleep(sleep_seconds)

    raise RuntimeError(f"Request to {endpoint} failed after {retries} attempts: {last_error}")


def evaluate_shard(
    *,
    args: argparse.Namespace,
    server: VLLMServer,
    examples: list[Example],
    shard_path: Path,
) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    correct_flags: list[int] = []
    session = requests.Session()

    for position, example in enumerate(examples, start=1):
        completion, usage = request_completion(
            session=session,
            endpoint=server.endpoint,
            api_key=args.api_key,
            model_name=server.served_model_name,
            messages=example.messages,
            max_tokens=args.max_tokens,
            temperature=args.temperature,
            top_p=args.top_p,
            timeout=args.request_timeout,
            retries=args.request_retries,
        )
        parsed_answer, matched = match_str(
            value=completion,
            target=example.target,
            location="end",
            ignore_case=True,
            numeric=True,
        )
        correct = 1 if matched else 0
        correct_flags.append(correct)
        results.append(
            {
                "index": example.index,
                "sample_id": example.sample_id,
                "question": example.question,
                "target": example.target,
                "parsed_answer": parsed_answer,
                "correct": bool(correct),
                "completion": completion,
                "usage": usage,
            }
        )
        if position % 10 == 0 or position == len(examples):
            print(
                f"[shard {server.shard_id}] {position}/{len(examples)} complete "
                f"(gpu={server.gpu_id}, accuracy={sum(correct_flags)/len(correct_flags):.4f})",
                flush=True,
            )

    shard_payload = {
        "baseline_name": args.baseline_name,
        "shard_id": server.shard_id,
        "gpu_id": server.gpu_id,
        "port": server.port,
        "model_path": args.model_path,
        "served_model_name": server.served_model_name,
        "accuracy": sum(correct_flags) / len(correct_flags),
        "stderr": sample_stderr(correct_flags),
        "sample_count": len(correct_flags),
        "correct_count": sum(correct_flags),
        "server_log": str(server.log_path),
        "started_at": utc_now(),
        "samples": results,
    }
    shard_path.write_text(json.dumps(shard_payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return shard_payload


def merge_results(
    *,
    args: argparse.Namespace,
    shards: list[dict[str, Any]],
    final_path: Path,
    gpus: list[int],
    started_at: str,
    completed_at: str,
) -> None:
    merged_samples: list[dict[str, Any]] = []
    correct_flags: list[int] = []
    shard_summaries: list[dict[str, Any]] = []

    for shard in shards:
        shard_summaries.append(
            {
                "shard_id": shard["shard_id"],
                "gpu_id": shard["gpu_id"],
                "port": shard["port"],
                "accuracy": shard["accuracy"],
                "stderr": shard["stderr"],
                "sample_count": shard["sample_count"],
                "correct_count": shard["correct_count"],
                "server_log": shard["server_log"],
            }
        )
        for sample in shard["samples"]:
            merged_samples.append(sample)
            correct_flags.append(1 if sample["correct"] else 0)

    merged_samples.sort(key=lambda sample: sample["index"])
    sample_count = len(merged_samples)
    correct_count = sum(correct_flags)
    accuracy = correct_count / sample_count if sample_count else 0.0
    stderr = sample_stderr(correct_flags)

    payload = {
        "accuracy": accuracy,
        "stderr": stderr,
        "sample_count": sample_count,
        "correct_count": correct_count,
        "baseline_name": args.baseline_name,
        "task": "inspect_evals/gsm8k",
        "dataset": {
            "name": "openai/gsm8k",
            "config": "main",
            "split": "test",
            "samples": sample_count,
        },
        "model": {
            "path": args.model_path,
            "gpus": gpus,
            "gpu_memory_utilization": args.gpu_memory_utilization,
            "chat_template": chat_template_path(args.model_path, args.templates_dir),
        },
        "generation": {
            "max_tokens": args.max_tokens,
            "temperature": args.temperature,
            "top_p": args.top_p,
        },
        "fewshot": {
            "count": args.fewshot,
            "seed": args.fewshot_seed,
            "shuffle": args.shuffle_fewshot,
        },
        "timing": {
            "started_at": started_at,
            "completed_at": completed_at,
        },
        "shards": shard_summaries,
        "samples": merged_samples,
    }
    final_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> int:
    args = parse_args()
    gpus = [int(gpu.strip()) for gpu in args.gpus.split(",") if gpu.strip()]
    if not gpus:
        raise ValueError("At least one GPU id is required.")

    output_path = Path(args.output_file).resolve()
    work_dir = (
        Path(args.work_dir).resolve()
        if args.work_dir is not None
        else output_path.with_suffix(output_path.suffix + ".d")
    )
    work_dir.mkdir(parents=True, exist_ok=True)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    template_path = chat_template_path(args.model_path, args.templates_dir)
    examples = build_examples(args)
    shard_inputs = shard_examples(examples, len(gpus))
    servers = [
        VLLMServer(
            args=args,
            gpu_id=gpu_id,
            shard_id=shard_id,
            template_path=template_path,
            work_dir=work_dir,
        )
        for shard_id, gpu_id in enumerate(gpus)
    ]

    started_at = utc_now()
    shard_outputs: list[dict[str, Any]] = []
    try:
        for server in servers:
            print(f"[startup] starting shard {server.shard_id} on gpu {server.gpu_id}", flush=True)
            server.start()
            print(
                f"[startup] shard {server.shard_id} ready on gpu {server.gpu_id} "
                f"port {server.port}",
                flush=True,
            )

        with concurrent.futures.ThreadPoolExecutor(max_workers=len(servers)) as executor:
            futures = {}
            for server, shard_examples_list in zip(servers, shard_inputs, strict=True):
                shard_path = work_dir / f"shard_{server.shard_id}.json"
                print(
                    f"[eval] shard {server.shard_id} starting with {len(shard_examples_list)} samples",
                    flush=True,
                )
                future = executor.submit(
                    evaluate_shard,
                    args=args,
                    server=server,
                    examples=shard_examples_list,
                    shard_path=shard_path,
                )
                futures[future] = server.shard_id

            for future in concurrent.futures.as_completed(futures):
                shard_id = futures[future]
                result = future.result()
                print(f"[eval] shard {shard_id} finished", flush=True)
                shard_outputs.append(result)

        completed_at = utc_now()
        merge_results(
            args=args,
            shards=shard_outputs,
            final_path=output_path,
            gpus=gpus,
            started_at=started_at,
            completed_at=completed_at,
        )
        print(f"[done] wrote merged output to {output_path}", flush=True)
        return 0
    finally:
        for server in servers:
            server.stop()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        raise
