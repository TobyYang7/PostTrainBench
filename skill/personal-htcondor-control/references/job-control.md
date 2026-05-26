# Job Control

## Install and start Personal HTCondor

Use this path when the user wants local HTCondor on a single GPU node instead of a site-wide pool.

From the repo root:

```bash
bash scripts/setup_personal_htcondor.sh
bash scripts/start_personal_htcondor.sh
```

What the setup script does:

- Downloads the HTCondor tarball into `.htcondor-local/src/` if missing.
- Expands it into `.htcondor-local/condor/`.
- Runs `make-personal-from-tarball`.
- Writes the local GPU-oriented config in `.htcondor-local/condor/local/config.d/10-posttrainbench-local-gpu.conf`.

What the start script does:

- Auto-runs setup if `condor.sh` is missing.
- Sources `.htcondor-local/condor/condor.sh`.
- Starts `condor_master` if the pool is not already running.
- Waits for `condor_status -compact` to succeed.

To stop the local pool:

```bash
bash scripts/stop_personal_htcondor.sh
```

## Inspect jobs

Use the repo wrapper first:

```bash
bash scripts/htcondor/check_htcondor_jobs.sh
bash scripts/htcondor/check_htcondor_jobs.sh <cluster_id>
bash scripts/htcondor/check_htcondor_jobs.sh --status
bash scripts/htcondor/check_htcondor_jobs.sh --history <cluster_id>
bash scripts/htcondor/check_htcondor_jobs.sh --watch 5 <cluster_id>
```

What it covers:

- `condor_status -compact`
- `condor_q -nobatch`
- `condor_history`
- A simple refresh loop for watch mode

If the wrapper is not enough, inspect these directly:

```bash
source .htcondor-local/condor/condor.sh
condor_q <cluster_id> -nobatch
condor_q <cluster_id> -af ClusterId ProcId JobStatus RemoveReason LastRemoteHost
condor_history <cluster_id> -limit 5
```

## Monitor a running job

Use this when the user wants queue state plus task logs together:

```bash
bash scripts/htcondor/monitor_ptb_cluster.sh <cluster_id> <result_dir> [interval_seconds]
```

This prints:

- `condor_q`
- `condor_history`
- tails of `output.log`, `error.log`, `solve_out.txt`, and `proj/workspace/system_monitor.log`

## Cancel a job

Prefer the repo wrapper over raw `condor_rm`:

```bash
bash scripts/htcondor/kill_htcondor_job.sh <cluster_id>
bash scripts/htcondor/kill_htcondor_job.sh <cluster_id_1> <cluster_id_2>
bash scripts/htcondor/kill_htcondor_job.sh --all
bash scripts/htcondor/kill_htcondor_job.sh --grace-only <cluster_id>
```

Behavior of `kill_htcondor_job.sh`:

1. Tries `condor_rm`.
2. Waits for the job to become removed or leave the queue.
3. If wrappers are still alive, sends signals to the matching `run_task.sh`, `condor_starter`, and `condor_shadow` processes.

Use `--grace-only` only when the user explicitly wants no host-side cleanup.

## When a removed job still occupies a GPU

This repo can end up in a state where:

- `condor_q` shows `JobStatus=3` or the job has already left the queue
- but `nvidia-smi` still shows a Python process on the assigned GPU

In that case:

1. Run `bash scripts/htcondor/kill_htcondor_job.sh <cluster_id>`.
2. Re-check:

```bash
nvidia-smi -i <gpu_idx>
ps -fp <pid>
```

The usual culprit is a lingering child under:

- `condor_starter`
- `/bin/bash src/run_task.sh ...`
- `timeout ... llamafactory-cli train ...`
- a Python child that still owns a CUDA context

## Submission context

For local submits, the main entrypoint is:

```bash
bash scripts/submit_codex_personal_htcondor.sh
```

Useful repo paths:

- Local HTCondor state: `.htcondor-local/`
- Condor event and stdout/stderr logs: `.htcondor-local/logs/`
- Benchmark outputs: `results/`

## Shared-cluster note

If the host does not have HTCondor client tools but the user already has access to a shared external HTCondor pool, the README's Docker submit environment is the right path:

- `docker/htcondor-submit/`
- `bash scripts/submit_codex_htcondor_docker.sh`

That is submit-side setup only; it is not the local Personal HTCondor single-node flow.
