ARG BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04
FROM ${BASE_IMAGE} AS base

ARG COMFYUI_VERSION=latest
ARG CUDA_VERSION_FOR_COMFY
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL
ARG MODEL_TYPE=base

# ── Build-time env ─────────────────────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PIP_NO_INPUT=1
ENV PYTHONUNBUFFERED=1
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# ── Runtime defaults — all overridable from RunPod endpoint env vars UI ─────────
ENV COMFY_DIR=/comfyui
ENV COMFY_HOST=127.0.0.1
ENV COMFY_PORT=8188
ENV MODEL_BASE_PATH=/runpod-volume/runpod-slim/ComfyUI/models
ENV CUSTOM_NODES_PATH=/runpod-volume/runpod-slim/ComfyUI/custom_nodes
ENV COMFY_LOG_LEVEL=INFO
ENV COMFY_READY_TIMEOUT=600
ENV COMFY_READY_INTERVAL=3
ENV REFRESH_WORKER=false
ENV NETWORK_VOLUME_DEBUG=true
ENV SERVE_API_LOCALLY=false

# ── System packages ────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
        python3.12 python3.12-venv git wget curl \
        libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
        ffmpeg openssh-server \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && apt-get autoremove -y && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

# ── uv (fast pip replacement) ──────────────────────────────────────────────────
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

ENV PATH="/opt/venv/bin:${PATH}"

# ── ComfyUI via comfy-cli ──────────────────────────────────────────────────────
RUN uv pip install --no-cache-dir comfy-cli pip setuptools wheel
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install \
          --version "${COMFYUI_VERSION}" \
          --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install \
          --version "${COMFYUI_VERSION}" --nvidia; \
    fi

# NEW: ensure ComfyUI core deps (alembic/sqlite stack) are installed
RUN uv pip install --no-cache-dir -r /comfyui/requirements.txt

# NEW: just bump torch stack, keep CUDA 12.1
RUN uv pip install --no-cache-dir --force-reinstall \
      torch==2.5.0+cu121 \
      torchvision==0.20.0+cu121 \
      torchaudio==2.5.0+cu121 \
      --index-url https://download.pytorch.org/whl/cu121

# ── RunPod handler deps ────────────────────────────────────────────────────────
RUN uv pip install --no-cache-dir runpod requests websocket-client

# ── ComfyUI extras ─────────────────────────────────────────────────────────────
RUN uv pip install --no-cache-dir einops scipy kornia

# ── Transformers / Qwen stack ──────────────────────────────────────────────────
RUN uv pip install --no-cache-dir "transformers>=4.49.0" accelerate
RUN uv pip install --no-cache-dir pillow huggingface-hub safetensors omegaconf
RUN uv pip install --no-cache-dir qwen-vl-utils \
    || echo "WARN: qwen-vl-utils unavailable – VL features limited"

# ── Handler + startup scripts ──────────────────────────────────────────────────
WORKDIR /
ADD src/start.sh src/network_volume.py handler.py test_input.json ./
RUN chmod +x /start.sh

COPY scripts/comfy-node-install.sh     /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

CMD ["bash", "/start.sh"]
