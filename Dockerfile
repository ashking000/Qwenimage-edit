ARG BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04
FROM ${BASE_IMAGE} AS base

ARG COMFYUI_VERSION=latest
ARG CUDA_VERSION_FOR_COMFY
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL
ARG MODEL_TYPE=base

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PIP_NO_INPUT=1
ENV PYTHONUNBUFFERED=1
ENV CMAKE_BUILD_PARALLEL_LEVEL=8
ENV COMFY_DIR=/comfyui
ENV MODEL_BASE_PATH=/runpod-volume/runpod-slim/ComfyUI/models
ENV CUSTOM_NODES_PATH=/runpod-volume/runpod-slim/ComfyUI/custom_nodes
ENV COMFY_PORT=8188

RUN apt-get update && apt-get install -y         python3.12 python3.12-venv git wget curl         libgl1 libglib2.0-0 libsm6 libxext6 libxrender1         ffmpeg openssh-server     && ln -sf /usr/bin/python3.12 /usr/bin/python     && ln -sf /usr/bin/pip3 /usr/bin/pip     && apt-get autoremove -y && apt-get clean -y     && rm -rf /var/lib/apt/lists/*

RUN wget -qO- https://astral.sh/uv/install.sh | sh     && ln -s /root/.local/bin/uv /usr/local/bin/uv     && ln -s /root/.local/bin/uvx /usr/local/bin/uvx     && uv venv /opt/venv

ENV PATH="/opt/venv/bin:${PATH}"

RUN uv pip install --no-cache-dir comfy-cli pip setuptools wheel
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then       /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia;     else       /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia;     fi

RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ] && [ -n "$PYTORCH_INDEX_URL" ]; then       uv pip install --no-cache-dir --force-reinstall torch torchvision torchaudio --index-url ${PYTORCH_INDEX_URL};     fi

RUN uv pip install --no-cache-dir runpod requests websocket-client
RUN uv pip install --no-cache-dir einops scipy kornia
RUN uv pip install --no-cache-dir "transformers>=4.49.0" accelerate
RUN uv pip install --no-cache-dir pillow huggingface-hub safetensors omegaconf
RUN uv pip install --no-cache-dir qwen-vl-utils || echo "WARN: qwen-vl-utils unavailable – VL features limited"

WORKDIR /
ADD src/start.sh src/network_volume.py handler.py test_input.json ./
RUN chmod +x /start.sh

COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

CMD ["/start.sh"]
