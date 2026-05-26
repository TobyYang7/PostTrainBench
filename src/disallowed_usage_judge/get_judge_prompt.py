import os

import argparse


def resolve_prompt_path(prompt_name: str) -> str:
    if os.path.isabs(prompt_name) or os.path.sep in prompt_name:
        return prompt_name

    filename = prompt_name if prompt_name.endswith(".txt") else f"{prompt_name}.txt"
    return os.path.join("src", "disallowed_usage_judge", filename)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--benchmark", type=str, required=True)
    parser.add_argument("--model", type=str, required=True)
    parser.add_argument("--prompt", type=str, default=None)
    args = parser.parse_args()

    base_prompt = os.environ.get('POST_TRAIN_BENCH_PROMPT', 'prompt1')
    if "mock" in base_prompt:
        print("Just do nothing and return.")
        return

    prompt_name = args.prompt or os.environ.get("POST_TRAIN_BENCH_JUDGE_PROMPT", "prompt")
    prompt_path = resolve_prompt_path(prompt_name)
    with open(prompt_path, 'r') as f:
        prompt = f.read()

    prompt = prompt.replace("{model}", args.model)
    prompt = prompt.replace("{benchmark}", args.benchmark)

    other_allowed_data = ""
    if 'gsm8k' in args.benchmark.lower():
        other_allowed_data = "- Usage of the training subset of GSM8K for training.\n"

    prompt = prompt.replace("{other_allowed_data}", other_allowed_data)
    
    print(prompt)

if __name__ == "__main__":
    main()
