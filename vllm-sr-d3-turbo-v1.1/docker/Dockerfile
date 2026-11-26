# Image that runs d3_server.py bundled with d3-turbo. The server and model code are loaded from /models along with the weights.
# The model's requirements.txt uses version ranges, so the versions are pinned here:
#   - torch, transformers and flash-linear-attention: the set that pplx-decider-v1.3, another Qwen3.5-based model, pins for CUDA
#     (transformers 5.17.0 is also what d3-turbo's requirements.txt pins)
#   - everything else: the latest release as of the d3-turbo build date (2026-10-19)
FROM python:3.12-slim-bookworm
RUN pip install --no-cache-dir torch==2.14.0 torchvision==0.29.0
# Triton (used by flash-linear-attention) builds its launchers with a C compiler at run time
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir \
    transformers==5.17.0 \
    flash-linear-attention==0.5.2 \
    accelerate==1.15.0 \
    safetensors==0.8.0 \
    huggingface-hub==1.31.0 \
    einops==0.8.2 \
    pillow==12.3.0 \
    opencv-python-headless==4.14.0.94
