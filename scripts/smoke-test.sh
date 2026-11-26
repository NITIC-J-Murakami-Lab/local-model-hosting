#!/usr/bin/env bash
# Connectivity check after startup. Sends one minimal request to each service and prints the reply as is.
# Usage: smoke-test.sh [qwen|jev|valen|pplx|d3|glimmer|gemma ...]   (without arguments: the models chosen in COMPOSE_PROFILES)
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

test_qwen() {
  post "http://$host:${QWEN_PORT:-8000}/v1/chat/completions" '{
    "model": "Qwen/Qwen3.8-27B",
    "messages": [{"role": "user", "content": "What is the capital of Japan? Answer in one word."}],
    "max_tokens": 64,
    "chat_template_kwargs": {"enable_thinking": false}}'
}

# System 1 (one-shot decision through the LoRA). The example comes from the model card
test_jev() {
  post "http://$host:${JEV_PORT:-8001}/v1/decide" '{
    "kind": "choice",
    "state": "Customer: my card was charged twice for one coffee.",
    "question": "Which team should handle this?",
    "options": ["billing", "shipping", "tech support"]}'
}

# The example comes from the Valen plugin README
test_valen() {
  post "http://$host:${VALEN_PORT:-8002}/v1/decisions" '{
    "model": "Valen-Team/Valen-Decision-1.5-27B",
    "input": "A cat is on the sofa.",
    "questions": [{"name": "on_sofa", "type": "predicate", "instructions": "The cat is on the sofa."}]}'
}

# The example comes from the model card (cut down to 2 questions)
test_pplx() {
  post "http://$host:${PPLX_PORT:-8003}/v1/decide" '{
    "state": "My integration keeps failing with a 401 since we rotated our API key. Please help.",
    "questions": {
      "team": {"type": "choice", "instructions": "Which team should handle this request?",
               "criteria": {"billing": "Charges and refunds", "support": "Technical integration errors",
                            "sales": "Questions about buying a product"}},
      "urgent": {"type": "noul", "instructions": "Is the customer blocked right now?"}}}'
}

# The example comes from the model card
test_d3() {
  post "http://$host:${D3_PORT:-8004}/v1/systemone" '{
    "model": "vllm-sr/d3-turbo",
    "state": "Write a Python function that reverses a string.",
    "questions": {
      "kind": {"type": "choice", "instructions": "What kind of work is this?",
               "criteria": {"code": "Writing or fixing code", "math": "Mathematics", "chat": "Anything else"}},
      "reasoning": {"type": "noul", "instructions": "Does answering this need multi-step reasoning?"}}}'
}

# "Reasoning strength: <low|medium|high|xhigh>" in the system prompt sets how much the model thinks (per the model card)
test_glimmer() {
  post "http://$host:${GLIMMER_PORT:-8005}/v1/chat/completions" '{
    "model": "meta-models/Muse-Glimmer-30B",
    "messages": [{"role": "system", "content": "Reasoning strength: low"},
                 {"role": "user", "content": "What is the capital of Japan? Answer in one word."}],
    "max_tokens": 512}'
}

# Thinking is on only when the system prompt contains <|think|> (off by default)
test_gemma() {
  post "http://$host:${GEMMA_PORT:-8006}/v1/chat/completions" '{
    "model": "google/gemma-4-31B-it",
    "messages": [{"role": "user", "content": "What is the capital of Japan? Answer in one word."}],
    "max_tokens": 64}'
}

if (($# == 0)); then
  mapfile -t services < <(docker compose config --services | grep -v '^fetch-')
  set -- "${services[@]}"
fi
for svc in "$@"; do
  echo "== $svc"
  "test_$svc"
done
