#!/usr/bin/env bash
# Checks to run on the DGX before starting. Read only: it changes nothing.
# Covers the models chosen in COMPOSE_PROFILES in .env. Exits with status 1 if any check is NG.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
if [[ ! -f .env ]]; then
  echo "NG   .env is missing (run cp .env.example .env and edit it)"
  exit 1
fi
# Stops here with the "set volume path" message if MODELS_DIR has not been edited
# shellcheck source=/dev/null
set -a && . ./.env && set +a

status=0
ok() { echo "OK   $*"; }
warn() { echo "WARN $*"; }
ng() {
  echo "NG   $*"
  status=1
}

# Upper bound of one model's weights (the largest, gemma, is 62.6GB)
WEIGHTS_GB_PER_MODEL=65

# --- Docker
if ! docker compose version >/dev/null 2>&1; then
  ng "docker compose is not available"
  exit 1
fi
ok "$(docker compose version)"
if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia || command -v nvidia-ctk >/dev/null; then
  ok "NVIDIA Container Toolkit"
else
  ng "NVIDIA Container Toolkit not found"
fi

# --- Models to start. Extract these lines from the compose configuration:
#   gpu <service> <GPU>              one line per service that uses a GPU
#   weights <dir> <repo>@<revision>  where the weights go (relative to MODELS_DIR) and the value their completion marker holds
#   build <Dockerfile>               the Dockerfile of an image to build
if ! command -v python3 >/dev/null; then
  ng "python3 not found (it reads the compose configuration)"
  exit 1
fi
if ! plan=$(docker compose config --format json | python3 -I -c '
import json, os, sys
lines = set()
for name, svc in (json.load(sys.stdin).get("services") or {}).items():
    for dev in svc.get("deploy", {}).get("resources", {}).get("reservations", {}).get("devices", []):
        for gpu in dev.get("device_ids", []):
            lines.add(f"gpu {name} {gpu}")
    if "/scripts/fetch-model.sh" in (svc.get("entrypoint") or []):
        d, repo, rev = svc["command"][:3]
        lines.add(f"weights {d} {repo}@{rev}")
    build = svc.get("build")
    if build:
        lines.add("build " + os.path.join(build["context"], build.get("dockerfile", "Dockerfile")))
print("\n".join(sorted(lines)))
'); then
  ng "docker compose config failed"
  exit 1
fi
mapfile -t gpus < <(sed -n 's/^gpu //p' <<<"$plan")
mapfile -t weights < <(sed -n 's/^weights //p' <<<"$plan")
mapfile -t dockerfiles < <(sed -n 's/^build //p' <<<"$plan")
if ((${#gpus[@]} == 0)); then
  ng "no model is chosen in COMPOSE_PROFILES in .env"
  exit 1
fi
ok "models to start: ${COMPOSE_PROFILES:-}"

# --- GPUs and driver
if ! command -v nvidia-smi >/dev/null; then
  ng "nvidia-smi not found"
  exit 1
fi
driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
if ((${driver%%.*} >= 580)); then
  ok "NVIDIA driver $driver"
else
  ng "NVIDIA driver $driver < 580: every image runs on CUDA 13.0 (vLLM v0.33.0, SGLang v0.5.23, torch 2.14.0)"
fi

declare -A seen=()
for entry in "${gpus[@]}"; do
  read -r svc id <<<"$entry"
  if [[ -n ${seen[$id]:-} ]]; then
    ng "GPU $id is assigned to both ${seen[$id]} and $svc (change the GPU numbers in .env)"
  fi
  seen[$id]=$svc
  if ! info=$(nvidia-smi -i "$id" --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null); then
    ng "$svc: GPU $id does not exist"
    continue
  fi
  name=${info%,*} mem=${info##*, }
  if ((mem < 70000)); then
    ng "$svc: GPU $id ($name, ${mem}MiB) cannot hold the BF16 weights (52-63GB); an 80GB GPU is required"
  else
    ok "$svc: GPU $id ($name, ${mem}MiB)"
  fi
  procs=$(nvidia-smi -i "$id" --query-compute-apps=pid,process_name,used_memory --format=csv,noheader)
  if [[ -n $procs ]]; then
    warn "$svc: other processes are running on GPU $id: $procs"
  fi
done

# --- Sources of the images to build (valen builds from a submodule)
for dockerfile in "${dockerfiles[@]}"; do
  if [[ -f $dockerfile ]]; then
    ok "Dockerfile ${dockerfile#"$PWD/"}"
  else
    ng "${dockerfile#"$PWD/"} is missing (for a submodule, run git submodule update --init)"
  fi
done

# --- Weights directory
if [[ ! -d $MODELS_DIR ]]; then
  ng "MODELS_DIR ($MODELS_DIR) does not exist (create it with mkdir -p)"
else
  owner=$(stat -c %u "$MODELS_DIR")
  if [[ $owner != "${HOST_UID:-0}" && ${HOST_UID:-0} != 0 ]]; then
    warn "MODELS_DIR is owned by uid $owner, not HOST_UID (${HOST_UID}); fetching weights may fail to write there"
  fi
  # Weights count as fetched only when their .download-complete marker names the pinned revision (the same test as fetch-model.sh)
  missing=()
  for entry in "${weights[@]}"; do
    read -r d want <<<"$entry"
    marker=$MODELS_DIR/$d/.download-complete
    [[ -f $marker && $(<"$marker") == "$want" ]] || missing+=("$d")
  done
  need=$((${#missing[@]} * WEIGHTS_GB_PER_MODEL))
  avail=$(df -BG --output=avail "$MODELS_DIR" | tail -1 | tr -dc 0-9)
  if ((${#missing[@]} == 0)); then
    ok "all weights are fetched ($MODELS_DIR)"
  elif ((avail < need)); then
    ng "only ${avail}GB free in $MODELS_DIR (not fetched yet: ${missing[*]}; up to ${need}GB needed)"
  else
    ok "${avail}GB free in $MODELS_DIR (not fetched yet: ${missing[*]}; up to ${need}GB needed)"
  fi
fi

exit $status
