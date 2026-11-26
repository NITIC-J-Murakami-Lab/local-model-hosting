# Image that serves pplx-decider-v1.3 over HTTP. The decision library (pplx_decider) is loaded from /models along with the weights.
# Dependency versions match the model's requirements.txt (revision 9c2ebb2).
FROM python:3.12-slim-bookworm
RUN pip install --no-cache-dir torch==2.14.0 torchvision==0.29.0
RUN pip install --no-cache-dir \
    transformers==5.17.0 \
    safetensors==0.8.0 \
    pillow==12.3.0 \
    huggingface-hub==1.31.0
COPY serve.py /app/serve.py
ENTRYPOINT ["python3", "/app/serve.py"]
