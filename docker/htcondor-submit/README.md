# PostTrainBench HTCondor Submit Container

This image provides a Dockerized HTCondor submit environment for PostTrainBench.
It is based on the official `htcondor/submit` access-point image.

The container only submits jobs. The benchmark jobs still run on the existing
HTCondor execute nodes, and `src/run_task.sh` still uses the repository's
Apptainer image on those execute nodes.

## Requirements

- Docker access on the submit host.
- Network access from the container to the HTCondor central manager.
- `CONDOR_HOST` or `CONDOR_SERVICE_HOST` for the existing HTCondor pool.
- Token or pool-password credentials accepted by that pool.
- The PostTrainBench repo mounted at the same absolute path visible to execute
  nodes, for example `/mnt/cpfs-01cde2b08bc90ffb/yzyang/PostTrainBench`.

The official HTCondor Docker docs say `htcondor/submit` connects to an existing
pool and requires `CONDOR_HOST`/`CONDOR_SERVICE_HOST` plus token or pool-password
security. `htcondor/mini` is an all-in-one test pool and is not appropriate for
submitting to your real GPU execute nodes.

If the system Docker daemon is not available to your user, rootless Docker can
also work as long as `dockerd-rootless-setuptool.sh check --skip-iptables`
passes. After starting a rootless daemon, export:

```bash
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
```

On shared filesystems, rootless Docker may fail to unpack image layers with a
`failed to register layer` or symlink permission error. Put the rootless Docker
data root on a local filesystem, for example:

```ini
# ~/.config/systemd/user/docker.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd-rootless.sh --iptables=false --data-root=/tmp/%u-rootless-docker
```

Then run:

```bash
systemctl --user daemon-reload
systemctl --user restart docker.service
```

## Build

```bash
cd /mnt/cpfs-01cde2b08bc90ffb/yzyang/PostTrainBench
docker build -t posttrainbench-htcondor-submit docker/htcondor-submit
```

The Dockerfile defaults to `htcondor/submit:lts`. Override it if your pool needs
a different HTCondor version:

```bash
docker build \
  --build-arg HTCONDOR_SUBMIT_IMAGE=htcondor/submit:latest \
  -t posttrainbench-htcondor-submit \
  docker/htcondor-submit
```

## Configure Credentials

Create local state directories:

```bash
mkdir -p .htcondor-submit/tokens .htcondor-submit/passwords .htcondor-submit/config
cp docker/htcondor-submit/env.example .htcondor-submit/env
```

Then use one of:

- Token auth: put token files in `.htcondor-submit/tokens/`.
- Pool password auth: put password files in `.htcondor-submit/passwords/` and
  set `USE_POOL_PASSWORD=yes`.

If your site requires extra HTCondor config, put `*.conf` files in
`.htcondor-submit/config/`.

Load your local environment before using the helper script:

```bash
set -a
source .htcondor-submit/env
set +a
```

## Submit With The Helper Script

The repository helper builds the image if needed, starts the submit container,
mounts this repo at the same absolute path, prepares shared log/results/home
directories, and runs `src/commit_utils/commit_codex.sh` as the HTCondor
`submituser`.

```bash
bash scripts/submit_codex_htcondor_docker.sh
```

By default, the helper uses:

```text
results/
.htcondor-submit/logs/
.htcondor-submit/home/
```

The default `HF_HOME` is `.htcondor-submit/home/.cache/huggingface`, unless you
export `HF_HOME` yourself.

## Start The Submit Container Manually

```bash
export CONDOR_HOST=<central-manager-hostname>

REPO=/mnt/cpfs-01cde2b08bc90ffb/yzyang/PostTrainBench

docker run -d --name ptb-htcondor-submit \
  --network host \
  -e CONDOR_HOST="$CONDOR_HOST" \
  -e USE_POOL_PASSWORD="${USE_POOL_PASSWORD:-no}" \
  -v "$REPO:$REPO" \
  -v "$REPO/.htcondor-submit/tokens:/etc/condor/tokens-orig.d:ro" \
  -v "$REPO/.htcondor-submit/passwords:/etc/condor/passwords-orig.d:ro" \
  -v "$REPO/.htcondor-submit/config:/root/config:ro" \
  posttrainbench-htcondor-submit
```

Verify the pool is reachable:

```bash
docker exec -it -u submituser ptb-htcondor-submit condor_status
```

If your execute nodes run jobs under a different OS user, `results/`,
`.htcondor-submit/logs/`, and `.htcondor-submit/home/` must be writable by that
job user.

## Submit Codex Benchmark On GPU 7

```bash
REPO=/mnt/cpfs-01cde2b08bc90ffb/yzyang/PostTrainBench

docker exec -it \
  -u submituser \
  -w "$REPO" \
  -e OPENAI_API_KEY="$OPENAI_API_KEY" \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  -e GEMINI_API_KEY="$GEMINI_API_KEY" \
  -e CUDA_DEVICE_IDX=7 \
  -e POST_TRAIN_BENCH_EXPERIMENT_NAME=_gpu7 \
  -e POST_TRAIN_BENCH_RESULTS_DIR="$REPO/results" \
  -e CONDOR_LOG_DIR="$REPO/.htcondor-submit/logs" \
  -e HOME="$REPO/.htcondor-submit/home" \
  -e HF_HOME="$REPO/.htcondor-submit/home/.cache/huggingface" \
  ptb-htcondor-submit \
  bash src/commit_utils/commit_codex.sh
```

Default output folder:

```text
results/codex_non_api_high_gpt-5.5_10h_gpu7/
```

If `POST_TRAIN_BENCH_RESULTS_DIR` is set, the same run folder is created under
that directory instead of `results/`.
