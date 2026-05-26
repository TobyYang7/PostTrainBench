---
name: personal-htcondor-control
description: Use when the user wants to install Personal HTCondor for this PostTrainBench repo, start or stop the local pool, inspect local HTCondor jobs, monitor a specific cluster, cancel jobs, or clean up lingering local wrapper/GPU processes after condor_rm.
---

# Personal HTCondor Control

This skill is for the repo-local Personal HTCondor workflow in `PostTrainBench`. Use it when the user asks to set up local HTCondor on a GPU node, submit or inspect local jobs, monitor a specific cluster, cancel jobs, or debug cleanup after a job is already marked removed.

## Quick start

Assume commands are run from the repository root.

- Install the local Personal HTCondor tarball and config:
  `bash scripts/setup_personal_htcondor.sh`
- Start the local `collector` / `schedd` / `startd` stack:
  `bash scripts/start_personal_htcondor.sh`
- Stop the local pool:
  `bash scripts/stop_personal_htcondor.sh`
- Inspect jobs and status:
  `bash scripts/htcondor/check_htcondor_jobs.sh`
- Cancel one or more jobs:
  `bash scripts/htcondor/kill_htcondor_job.sh <cluster_id>`

For the detailed workflow and command choices, read [references/job-control.md](references/job-control.md).

## Workflow

1. If the user needs HTCondor installed locally, use the install steps in [references/job-control.md](references/job-control.md#install-and-start-personal-htcondor). Prefer the repo scripts over manual tarball handling.
2. If the user asks whether a job is running, queued, removed, or finished, start with `bash scripts/htcondor/check_htcondor_jobs.sh [cluster_id]`.
3. If the user asks to watch a specific run end to end, use `bash scripts/htcondor/monitor_ptb_cluster.sh <cluster_id> <result_dir> [interval_seconds]`.
4. If the user asks to cancel a job, prefer `bash scripts/htcondor/kill_htcondor_job.sh <cluster_id>` instead of raw `condor_rm`. This script does `condor_rm`, waits briefly, and then kills lingering `run_task.sh`, `condor_starter`, and `condor_shadow` wrappers if needed.
5. If the pool is not running, `kill_htcondor_job.sh` can still do host-side cleanup for matching wrapper processes. Use that when `condor_status` or `condor_q` is unavailable but stale local processes remain.

## Boundaries

- This skill is for the repo's local Personal HTCondor setup under `.htcondor-local/`.
- For a shared external HTCondor cluster where the host lacks client tools, the README's Docker submit workflow is the right reference, not this skill's primary path.
- When cleaning up a job, avoid killing `condor_startd`, `condor_schedd`, or `condor_master` unless the user explicitly asks to stop the whole local pool. Prefer the repo cleanup script first.
