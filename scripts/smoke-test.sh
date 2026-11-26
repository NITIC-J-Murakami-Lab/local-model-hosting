#!/usr/bin/env bash
# Connectivity check after startup. Sends one minimal request to each GPU slot, chosen by the model it runs, and prints the reply as is.
# Usage: smoke-test.sh [gpu0 gpu1 gpu2 gpu3 ...]   (without arguments: every slot that GPUn_MODEL in .env fills)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
set -a && . ./.env && set +a

host=${SMOKE_HOST:-127.0.0.1}

post() {
  echo "POST $1"
  curl -fsS --max-time 300 -H 'Content-Type: application/json' "$1" -d "$2"
  echo
}

# Each test_<model> takes the slot's base URL
test_qwen() {
  post "$1/v1/chat/completions" '{
    "model": "Qwen/Qwen3.8-27B",
    "messages": [{"role": "user", "content": "What is the capital of Japan? Answer in one word."}],
    "max_tokens": 64,
    "chat_template_kwargs": {"enable_thinking": false}}'
}

# System 1 (one-shot decision through the LoRA). The example comes from the model card
test_jev() {
  post "$1/v1/decide" '{
    "kind": "choice",
    "state": "Customer: my card was charged twice for one coffee.",
    "question": "Which team should handle this?",
    "options": ["billing", "shipping", "tech support"]}'
}

# The example comes from the Valen plugin README
test_valen() {
  post "$1/v1/decisions" '{
    "model": "Valen-Team/Valen-Decision-1.5-27B",
    "input": "A cat is on the sofa.",
    "questions": [{"name": "on_sofa", "type": "predicate", "instructions": "The cat is on the sofa."}]}'
}

# The example comes from the model card (cut down to 2 questions)
test_pplx() {
  post "$1/v1/decide" '{
    "state": "My integration keeps failing with a 401 since we rotated our API key. Please help.",
    "questions": {
      "team": {"type": "choice", "instructions": "Which team should handle this request?",
               "criteria": {"billing": "Charges and refunds", "support": "Technical integration errors",
                            "sales": "Questions about buying a product"}},
      "urgent": {"type": "noul", "instructions": "Is the customer blocked right now?"}}}'
}

# The example comes from the model card
test_d3() {
  post "$1/v1/systemone" '{
    "model": "vllm-sr/d3-turbo",
    "state": "Write a Python function that reverses a string.",
    "questions": {
      "kind": {"type": "choice", "instructions": "What kind of work is this?",
               "criteria": {"code": "Writing or fixing code", "math": "Mathematics", "chat": "Anything else"}},
      "reasoning": {"type": "noul", "instructions": "Does answering this need multi-step reasoning?"}}}'
}

# "Reasoning strength: <low|medium|high|xhigh>" in the system prompt sets how much the model thinks (per the model card)
test_glimmer() {
  post "$1/v1/chat/completions" '{
    "model": "meta-models/Muse-Glimmer-30B",
    "messages": [{"role": "system", "content": "Reasoning strength: low"},
                 {"role": "user", "content": "What is the capital of Japan? Answer in one word."}],
    "max_tokens": 512}'
}

# Thinking is on only when the system prompt contains <|think|> (off by default)
test_gemma() {
  post "$1/v1/chat/completions" '{
    "model": "google/gemma-4-31B-it",
    "messages": [{"role": "user", "content": "What is the capital of Japan? Answer in one word."}],
    "max_tokens": 64}'
}

if (($# == 0)); then
  mapfile -t all < <(docker compose config --services | grep '^gpu')
  for slot in "${all[@]}"; do
    var=${slot^^}_MODEL
    if [[ -n ${!var:-} ]]; then
      set -- "$@" "$slot"
    fi
  done
fi
for slot in "$@"; do
  var=${slot^^}_MODEL
  model=${!var:-}
  if [[ -z $model ]]; then
    echo "$slot is empty (set $var in .env)" >&2
    exit 1
  fi
  # The port Docker published for the slot, e.g. 0.0.0.0:8002
  addr=$(docker compose port "$slot" 8000)
  echo "== $slot ($model)"
  "test_$model" "http://$host:${addr##*:}"
done
