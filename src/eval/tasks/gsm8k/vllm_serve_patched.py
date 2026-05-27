#!/usr/bin/env python3
from __future__ import annotations

from transformers.tokenization_utils_base import PreTrainedTokenizerBase


if not hasattr(PreTrainedTokenizerBase, "all_special_tokens_extended"):
    PreTrainedTokenizerBase.all_special_tokens_extended = property(  # type: ignore[attr-defined]
        lambda self: list(self.all_special_tokens)
    )


def main() -> int:
    from vllm.entrypoints.cli.main import main as vllm_main

    return int(vllm_main() or 0)


if __name__ == "__main__":
    raise SystemExit(main())
