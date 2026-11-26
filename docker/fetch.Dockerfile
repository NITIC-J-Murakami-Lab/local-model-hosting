# Small image used only to fetch weights (it contains just the hf CLI).
# Kept separate from the engine images so that fetching weights does not pull a 10+ GB engine image.
FROM python:3.12-slim-bookworm
RUN pip install --no-cache-dir "huggingface_hub==2.4.0"
