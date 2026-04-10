#!/usr/bin/env bash
# worker-comfyui  –  start.sh  (Qwen Network-Volume Edition)

# ── SSH (optional) ────────────────────────────────────────────
if [ -n "$PUBLIC_KEY" ]; then
    mkdir -p ~/.ssh
    echo "$PUBLIC_KEY" > ~/.ssh/authorized_keys
    chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
    for key_type in rsa ecdsa ed25519; do
        key_file="/etc/ssh/ssh_host_${key_type}_key"
        [ ! -f "$key_file" ] && ssh-keygen -t "$key_type" -f "$key_file" -q -N ''
    done
    service ssh start && echo "worker-comfyui: SSH started" || echo "worker-comfyui: SSH failed" >&2
fi

# ── Memory allocator ─────────────────────────────────────────
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
[ -n "$TCMALLOC" ] && export LD_PRELOAD="${TCMALLOC}"

# ── GPU check ────────────────────────────────────────────────
echo "worker-comfyui: Checking GPU..."
if ! GPU_CHECK=$(python3 -c "
import torch
try:
    torch.cuda.init()
    print(f'OK: {torch.cuda.get_device_name(0)}')
except Exception as e:
    print(f'FAIL: {e}')
    exit(1)
" 2>&1); then
    echo "worker-comfyui: GPU unavailable – $GPU_CHECK"
    exit 1
fi
echo "worker-comfyui: $GPU_CHECK"

# ── Symlink custom nodes from network volume ─────────────────
# Your network volume already has all custom nodes at
#   /runpod-volume/custom_nodes/<node-name>/
# We symlink them into the ComfyUI workspace at startup.
# This avoids re-downloading them on every image rebuild.
if [ -d "/runpod-volume/custom_nodes" ]; then
    echo "worker-comfyui: Linking custom nodes from /runpod-volume/custom_nodes ..."
    mkdir -p /comfyui/custom_nodes
    for node_dir in /runpod-volume/custom_nodes/*/; do
        node_name=$(basename "$node_dir")
        target="/comfyui/custom_nodes/$node_name"
        if [ -e "$target" ] || [ -L "$target" ]; then
            echo "  [skip]   $node_name"
        else
            ln -s "$node_dir" "$target"
            echo "  [linked] $node_name"
        fi
    done
    echo "worker-comfyui: Custom nodes ready."
else
    echo "worker-comfyui: WARNING – /runpod-volume/custom_nodes not found. No custom nodes linked."
fi

# ── ComfyUI-Manager → offline mode ───────────────────────────
comfy-manager-set-mode offline \
    || echo "worker-comfyui: Could not set Manager offline mode" >&2

# ── Start ComfyUI ─────────────────────────────────────────────
echo "worker-comfyui: Starting ComfyUI"
: "${COMFY_LOG_LEVEL:=DEBUG}"
COMFY_PID_FILE="/tmp/comfyui.pid"

if [ "$SERVE_API_LOCALLY" == "true" ]; then
    python -u /comfyui/main.py \
        --disable-auto-launch --disable-metadata \
        --listen --verbose "${COMFY_LOG_LEVEL}" --log-stdout &
    echo $! > "$COMFY_PID_FILE"
    echo "worker-comfyui: Starting RunPod Handler (local API mode)"
    python -u /handler.py --rp_serve_api --rp_api_host=0.0.0.0
else
    python -u /comfyui/main.py \
        --disable-auto-launch --disable-metadata \
        --verbose "${COMFY_LOG_LEVEL}" --log-stdout &
    echo $! > "$COMFY_PID_FILE"
    echo "worker-comfyui: Starting RunPod Handler"
    python -u /handler.py
fi
