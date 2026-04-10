# ============================================================
# worker-comfyui  —  Qwen Image 2512 (Network Volume Edition)
# Models + Custom Nodes live on /runpod-volume.
# Nothing baked in → fast build, small image.
# ============================================================

ARG BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04
FROM ${BASE_IMAGE}

ARG COMFYUI_VERSION=latest
ARG CUDA_VERSION_FOR_COMFY
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PYTHONUNBUFFERED=1
ENV CMAKE_BUILD_PARALLEL_LEVEL=8
ENV PIP_NO_INPUT=1

# ── System deps ───────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    python3.12 python3.12-venv git wget curl \
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
    ffmpeg openssh-server \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && apt-get autoremove -y && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

# ── uv fast-pip + virtualenv ──────────────────────────────────
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

ENV PATH="/opt/venv/bin:${PATH}"

# ── ComfyUI via comfy-cli ─────────────────────────────────────
RUN uv pip install comfy-cli pip setuptools wheel

RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install \
        --version "${COMFYUI_VERSION}" \
        --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install \
        --version "${COMFYUI_VERSION}" --nvidia; \
    fi

RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall torch torchvision torchaudio \
        --index-url ${PYTORCH_INDEX_URL}; \
    fi

# ── Python deps for custom nodes (code comes from network vol) ─
# RES4LYF  ────────────────────────────────────────────────────
RUN uv pip install einops scipy kornia open-clip-torch

# ComfyUI-QwenVL  ─────────────────────────────────────────────
RUN uv pip install \
    "transformers>=4.49.0" \
    accelerate \
    qwen-vl-utils \
    torchvision \
    pillow \
    huggingface-hub \
    safetensors \
    omegaconf

# RunPod serverless handler  ───────────────────────────────────
RUN uv pip install runpod requests websocket-client

# ── ComfyUI model-path config ─────────────────────────────────
WORKDIR /comfyui
ADD src/extra_model_paths.yaml ./

# ── Handler + boot scripts ────────────────────────────────────
WORKDIR /
ADD src/start.sh src/network_volume.py handler.py test_input.json ./
RUN chmod +x /start.sh

COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

CMD ["/start.sh"]
