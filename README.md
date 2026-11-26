# local-model-hosting

Docker Compose setup for serving local models as HTTP APIs (OpenAI-compatible and others) on a DGX A100 (80GB).
Each of the 4 GPUs is a slot that runs one model. You assign a model to each GPU in `.env`, and the same model can run on several GPUs at once.

| name | Model | Engine | Main endpoints |
| --- | --- | --- | --- |
| `qwen` | [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) | SGLang v0.5.23 | `/v1/chat/completions` |
| `jev` | [autotrust/JEV-27B-VL](https://huggingface.co/autotrust/AutoTrust-Decider-Pro-Vision-27B) | vLLM v0.33.0 | `/v1/decide`, `/v1/chat/completions` |
| `valen` | [Valen-Team/Valen-Decision-1.5-27B](https://huggingface.co/Valen-Team/Valen-Decision-1.5-27B) | SGLang v0.5.23 + Valen plugin | `/v1/decisions`, `/v1/systemone` |
| `pplx` | [perplexity-ai/pplx-decider-v1.3](https://huggingface.co/perplexity-ai/pplx-decider-v1.3) | bundled pplx_decider library + `serve.py` | `/v1/decide` |
| `d3` | [vllm-sr/d3-turbo](https://huggingface.co/vllm-sr/d3-turbo) v1.1 | bundled `d3_server.py` | `/v1/systemone` |
| `glimmer` | [meta-models/Muse-Glimmer-30B](https://huggingface.co/meta-models/Muse-Glimmer-30B) | SGLang v0.5.23 | `/v1/chat/completions` |
| `gemma` | [google/gemma-4-31B-it](https://huggingface.co/google/gemma-4-31B-it) | SGLang v0.5.23 | `/v1/chat/completions` |

By default, GPU 0 runs `qwen` (port 8000), GPU 1 runs `jev` (8001), GPU 2 runs `valen` (8002), and GPU 3 is free.

## Directory layout

```text
.
├── compose.yaml              # entry point: the GPU slots gpu0..gpu3, each running the model chosen in .env
├── models.yaml               # catalog of the models a slot can run (names for GPU0_MODEL..GPU3_MODEL)
├── .env.example              # weights location (must be set), model per GPU, ports
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

Model-specific details (the revision to fetch, engine and launch flags) live in each `<model>/docker/compose.yaml` as two templates,
`fetch-<name>` and `<name>`. A slot in `compose.yaml` takes both through `models.yaml` and adds the GPU, the port, and the wait for the weights.

## Requirements

- One 80GB A100 per model you start. BF16 weights take 52-63GB per model, so they do not fit on a 40GB card.
- NVIDIA driver R570 or later. The SGLang v0.5.23 and vLLM v0.33.0 images are built on CUDA 13.0, which needs R580; on older drivers they run through the CUDA forward-compatibility libraries in the image, which data center GPUs such as A100 support (confirmed with SGLang on R570). The `pplx` and `d3` images use the CUDA 12.6 build of torch 2.14.0, which runs from R560 on.
- Docker, Docker Compose v2 or later, and the NVIDIA Container Toolkit.
- python3, which `scripts/preflight.sh` uses to read the Compose configuration.
- Space for the weights: 52-63GB per model you assign (once, however many GPUs run it), about 390GB for all 7. On a DGX, the data RAID at `/raid` is recommended.
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
Set the model for each GPU (`GPU0_MODEL`..`GPU3_MODEL`) and HOST_UID/GID there as well. Pass the same path as `MODELS_DIR` to `mkdir -p`.

`docker compose up -d` first runs the `fetch-gpu*` services, which fetch any missing weights of the assigned models. Each server starts as soon as its weights are ready.
The first run takes a while, because it downloads the weights and builds the images of `valen`, `pplx` and `d3` (whichever are assigned).
A slot is ready to use once `docker compose ps` shows it as `healthy`.

## Assigning models to GPUs

Each GPU is a slot: `gpuN` runs the model in `GPUN_MODEL` on GPU N and publishes it on `GPUN_PORT` (8000 + N by default).
Use the names from the table above, and leave a slot blank to keep its GPU free.

```bash
GPU0_MODEL=qwen
GPU1_MODEL=jev
GPU2_MODEL=valen
GPU3_MODEL=valen
```

With this, `gpu2` and `gpu3` are two independent Valen servers, on ports 8002 and 8003.
They read the same copy of the weights and share one engine cache. Nothing balances requests between them; clients choose a port.

The port belongs to the GPU, not the model, so moving a model to another GPU changes its URL. `GET /v1/models` on a port tells which model runs there.

To change the assignment, edit `.env` and run `docker compose up -d` again. Compose recreates the slots whose model changed,
stops the slots you left blank, and leaves the others running.

To work on a single slot, name it:

```bash
docker compose up -d gpu3
docker compose logs -f gpu3
docker compose stop gpu3
docker compose down        # stop every slot
```

## Weights and volumes

| What | Where | Lifetime |
| --- | --- | --- |
| Model weights | `MODELS_DIR` on the host (bind mount, read-only for the servers) | Stay until deleted on the host. `docker compose down -v` and image updates do not remove them |
| Engine caches (JIT kernels, torch.compile, etc.) | Docker volume `<name>-cache`, shared by every slot that runs the model | Removed by `down -v`. Losing them only makes the next start slower |

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

- Only the weights of the models you assign are fetched, one copy per model. When several slots run the same model, the first one downloads it while the others wait for it.
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

1. Create `<model>/docker/compose.yaml` with two templates: `fetch-<name>`, which extends `fetch` from `../../docker/common.yaml` and sets the revision to fetch, and `<name>`, which extends `server` and sets the engine, its flags and the `<name>-cache` volume at `/root/.cache`. The server must listen on port 8000 inside the container and answer `GET /health`. Leave out the GPU and the port; the slot adds them.
2. Add both templates to `models.yaml`.
3. Declare `<name>-cache` under `volumes` in the root `compose.yaml`.
4. Add the name to the choices in `.env.example`, and a `test_<name>` for the model to `scripts/smoke-test.sh`. `scripts/preflight.sh` reads the Compose configuration, so it needs no changes.
