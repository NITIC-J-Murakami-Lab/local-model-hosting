# local-model-hosting

Docker Compose setup for serving local models as HTTP APIs (OpenAI-compatible and others) on a DGX A100 (80GB).
Each model takes one GPU to itself. There are 7 models but only 4 GPUs, so you choose which models to start in `.env`.

| service | Model | Engine | GPU (default) | Port | Main endpoints |
| --- | --- | --- | --- | --- | --- |
| `qwen` | [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) | SGLang v0.5.23 | `QWEN_GPU` (0) | 8000 | `/v1/chat/completions` |
| `jev` | [autotrust/JEV-27B-VL](https://huggingface.co/autotrust/AutoTrust-Decider-Pro-Vision-27B) | vLLM v0.33.0 | `JEV_GPU` (1) | 8001 | `/v1/decide`, `/v1/chat/completions` |
| `valen` | [Valen-Team/Valen-Decision-1.5-27B](https://huggingface.co/Valen-Team/Valen-Decision-1.5-27B) | SGLang v0.5.23 + Valen plugin | `VALEN_GPU` (2) | 8002 | `/v1/decisions`, `/v1/systemone` |
| `pplx` | [perplexity-ai/pplx-decider-v1.3](https://huggingface.co/perplexity-ai/pplx-decider-v1.3) | bundled pplx_decider library + `serve.py` | `PPLX_GPU` (3) | 8003 | `/v1/decide` |
| `d3` | [vllm-sr/d3-turbo](https://huggingface.co/vllm-sr/d3-turbo) v1.1 | bundled `d3_server.py` | `D3_GPU` (3) | 8004 | `/v1/systemone` |
| `glimmer` | [meta-models/Muse-Glimmer-30B](https://huggingface.co/meta-models/Muse-Glimmer-30B) | SGLang v0.5.23 | `GLIMMER_GPU` (3) | 8005 | `/v1/chat/completions` |
| `gemma` | [google/gemma-4-31B-it](https://huggingface.co/google/gemma-4-31B-it) | SGLang v0.5.23 | `GEMMA_GPU` (3) | 8006 | `/v1/chat/completions` |

By default, `qwen`, `jev` and `valen` start. The other 4 models all default to the free GPU 3.

## Directory layout

```text
.
├── compose.yaml              # entry point that bundles every model with include
├── .env.example              # weights location (must be set), models to start, GPU assignment, ports
├── docker/
│   ├── common.yaml           # shared settings that each model uses through extends (templates for servers and weight fetching)
│   └── fetch.Dockerfile      # small image used only to fetch weights (just the hf CLI)
├── scripts/
│   ├── fetch-model.sh        # fetches weights at a pinned revision; skips them if already fetched
│   ├── preflight.sh          # checks before starting (read only)
│   └── smoke-test.sh         # connectivity check after starting
├── qwen3.8/docker/compose.yaml
├── autotrust-jev-vl/docker/compose.yaml
├── valen-decision-1.5/
│   ├── Valen/                # submodule: github.com/Valen-Team/Valen (pinned to f6df4fd)
│   └── docker/compose.yaml   # the image is built from Valen/serving/sglang/docker/Dockerfile
├── pplx-decider-v1.3/docker/
│   ├── compose.yaml
│   ├── Dockerfile            # installs torch and the rest at the versions in the model's requirements.txt
│   └── serve.py              # minimal server that exposes the bundled library over HTTP (standard library only)
├── vllm-sr-d3-turbo-v1.1/docker/
│   ├── compose.yaml          # the server is d3_server.py, fetched along with the weights
│   └── Dockerfile
├── muse-glimmer-30b/docker/compose.yaml
└── gemma-4-31b/docker/compose.yaml
```

Model-specific details (the revision to fetch, engine, launch flags, GPU and port) live in each `<model>/docker/compose.yaml`.
Every model belongs to a Compose profile named after its service.

## Requirements

- One 80GB A100 per model you start. BF16 weights take 52-63GB per model, so they do not fit on a 40GB card.
- NVIDIA driver 580 or later. Every image runs on CUDA 13.0 (vLLM v0.33.0, SGLang v0.5.23, torch 2.14.0).
- Docker, Docker Compose v2.20 or later (for `include`), and the NVIDIA Container Toolkit.
- python3, which `scripts/preflight.sh` uses to read the Compose configuration.
- Space for the weights: 52-63GB per model you start, about 390GB for all 7. On a DGX, the data RAID at `/raid` is recommended.
- Access to Hugging Face, Docker Hub and PyPI on the first run.

## Getting started

```bash
git submodule update --init
cp .env.example .env
mkdir -p /raid/models
scripts/preflight.sh
docker compose up -d
docker compose ps
scripts/smoke-test.sh
```

After `cp .env.example .env`, edit `.env` and replace `MODELS_DIR` with the real path. Until you do, every compose command stops with the `set volume path` message.
Set the models to start (`COMPOSE_PROFILES`), HOST_UID/GID and the GPU numbers there as well. Pass the same path as `MODELS_DIR` to `mkdir -p`.

`docker compose up -d` first runs the `fetch-*` services, which fetch any missing weights of the chosen models. Each server starts as soon as its weights are ready.
The first run takes a while, because it downloads the weights and builds the `valen`, `pplx` and `d3` images.
A model is ready to use once `docker compose ps` shows it as `healthy`.

## Choosing the models to start

List the service names of the models to start in `COMPOSE_PROFILES` in `.env`, separated by commas.

```bash
COMPOSE_PROFILES=qwen,jev,valen,gemma
```

Set the matching `*_GPU` values so that the chosen models do not share a GPU. `scripts/preflight.sh` checks this (it looks only at the models chosen in `COMPOSE_PROFILES`).

To switch models, stop everything, edit `.env`, then start again.

```bash
docker compose --profile '*' down
docker compose up -d
```

Without `--profile '*'`, the containers of models that are not in `COMPOSE_PROFILES` keep running and keep holding their GPUs, so always pass it when switching.

To add or stop a single model, name its service. A named model starts even if it is not in `COMPOSE_PROFILES`, and its weights are fetched as needed.

```bash
docker compose up -d gemma
docker compose stop gemma
```

## Weights and volumes

| What | Where | Lifetime |
| --- | --- | --- |
| Model weights | `MODELS_DIR` on the host (bind mount, read-only for the servers) | Stay until deleted on the host. `docker compose down -v` and image updates do not remove them |
| Engine caches (JIT kernels, torch.compile, etc.) | Docker volume `<service>-cache` | Removed by `down -v`. Losing them only makes the next start slower |

```text
$MODELS_DIR/
├── Qwen3.8-27B/             # 55.6GB
├── JEV-27B-VL/              # 56.0GB (the Qwen3.8-27B weights + a LoRA; not shared, so that each model stays independent)
├── Valen-Decision-1.5-27B/  # 52.2GB
├── pplx-decider-v1.3/       # 54.1GB (includes the decision library in source/)
├── d3-turbo-v1.1/           # 52.2GB (includes the server d3_server.py and the model code)
├── Muse-Glimmer-30B/        # 59.6GB
└── gemma-4-31B-it/          # 62.6GB
```

- Only the weights of the models you start are fetched.
- Revisions are pinned to commits. A finished directory gets a `.download-complete` file, and later runs skip it without touching the network.
- An interrupted download resumes when you run it again.
- If `MODELS_DIR` does not exist, Docker stops with an error instead of creating it (`create_host_path: false`). This keeps a mistyped path from sending the weights somewhere unintended.

## How the engines were chosen

Engines are tried in the order SGLang → vLLM → llama.cpp, and each model uses the first one that supports it. Models that none of them support run on their authors' official code.

- **qwen → SGLang**: there is an official cookbook, but its verified GPUs do not include A100 (only H200, RTX PRO 6000, RTX 5090 and DGX Spark). The FP8 KV cache that every cookbook recipe sets is not used, because it has not been confirmed to work on A100.
- **jev → vLLM**: `serve_decide.py`, which provides the decision API (`/v1/decide`), ships with the model and depends on vLLM internals. The model card does not mention SGLang either.
- **valen → SGLang**: uses the official plugin. The plugin's official Dockerfile hardcodes `--attention-backend fa3`. FA3 has kernels for SM80 (A100), and SGLang v0.5.23 does not reject SM80, but it has not been confirmed to run on A100. If it does not work, switch to the vLLM version of the plugin in the same submodule (`Valen/serving/vllm`).
- **pplx → bundled library**: its `decision_config.json` is format_version 2. SGLang (`/v1/systemone`) and vLLM (Decision 3.0 support) read only format_version 1 and fail at startup, and their unreleased main branches do the same. So `serve.py` exposes the bundled `pplx_decider` over HTTP. Decisions run on the reference path (`fast=False`) that the model card used for its evaluation.
- **d3 → bundled server**: its `decision_config.json` sets `attention_mode` to `prefix_bidir`. SGLang and vLLM read only `causal` and `noncausal_full_attention` and fail at startup. vLLM's d3 support targets the non-turbo d3. So the official server bundled with the model, `d3_server.py`, is used.
- **glimmer → SGLang**: the v0.5.23 cookbook says support is not in a release yet, but that text is outdated. The model implementation and the `muse` parsers have been in SGLang since September 2026 and ship in v0.5.23. As in the cookbook default, `--language-model-only` makes it text only.
- **gemma → SGLang**: there is an official cookbook, and the `gemma4` parsers are used. On A100, SGLang picks the triton attention backend automatically.

## Cautions

- **There is no authentication.** Every server is published on `0.0.0.0`, so anyone on a network that reaches the DGX can use every model. Ports that Docker publishes bypass host firewalls such as ufw. To restrict access, set `BIND_ADDRESS=127.0.0.1` and use an SSH tunnel, or put an authenticating reverse proxy in front.
- **Do not remove the `jev` flags.** `--max-num-seqs 8` and `--trust-request-chat-template` are required. The model card says that batching more than 8 sequences corrupts the probabilities on the LoRA path.
- **`jev` runs with `--trust-request-chat-template`.** Clients can send any chat template.
- **No model has been confirmed to run on A100.** A100 is not among the GPUs that the engine cookbooks or model cards list as verified (some models list no GPU at all). In particular, the `d3` authors validated it on ROCm (MI325X) only. On CUDA it runs on the transformers path instead of the ROCm-only fast path.
- **`serve_decide.py` has not been confirmed to work.** The JEV authors validated it on a September 2026 development build of vLLM. The modules and attributes it needs were confirmed to exist in v0.33.0 by reading the source.
- **`pplx` and `d3` handle one request at a time.** Both run decisions serially behind a lock. They accept images only as base64 data URLs, so that clients cannot make the server read files.
- **`glimmer` does not accept images.** A bug in the image embedding order was fixed after the v0.5.23 release (sgl-project/sglang#50855). To keep images off on this version, it starts in text-only mode.
- **Context length:** whatever the weights leave free on one 80GB GPU becomes the KV cache. `qwen`, `jev` and `glimmer` use 131072 tokens. `gemma` uses 65536, because its weights take 62.6GB and leave roughly 10GB for KV. Tune it from `max_total_num_tokens` in the startup log.
- **Model code runs.** `serve_decide.py` for `jev`, `pplx_decider` for `pplx` and `d3_server.py` for `d3` ship with the models, and `valen` runs its plugin. All of them are pinned to commits.

## Adding a model

1. Create `<model>/docker/compose.yaml`. Extend `fetch` and `server` from `../../docker/common.yaml`, and set the revision to fetch, the engine, the GPU and the port. The server must listen on port 8000 inside the container and answer `GET /health`.
2. Give both services (`fetch-<service>` and `<service>`) `profiles: [<service>]`.
3. Add the file to `include` in the root `compose.yaml`.
4. Add GPU and port variables to `.env.example`, and a `test_<service>` for the model to `scripts/smoke-test.sh`. `scripts/preflight.sh` reads the Compose configuration, so it needs no changes.
