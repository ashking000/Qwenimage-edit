#!/usr/bin/env bash
# worker-comfyui  —  start.sh  (Qwen Network-Volume Edition)
set -euo pipefail

# ── SSH (optional) ────────────────────────────────────────────
if [ -n "${PUBLIC_KEY:-}" ]; then
    mkdir -p ~/.ssh
    echo "$PUBLIC_KEY" > ~/.ssh/authorized_keys
    chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
    for key_type in rsa ecdsa ed25519; do
        key_file="/etc/ssh/ssh_host_${key_type}_key"
        [ ! -f "$key_file" ] && ssh-keygen -t "$key_type" -f "$key_file" -q -N ''
    done
    service ssh start && echo "[start.sh] SSH started" || echo "[start.sh] SSH failed" >&2
fi

# ── Memory allocator ──────────────────────────────────────────
TCMALLOC="$(ldconfig -p | grep -Po 'libtcmalloc\.so\.\d' | head -n 1)"
[ -n "$TCMALLOC" ] && export LD_PRELOAD="${TCMALLOC}"

# ── GPU check ─────────────────────────────────────────────────
echo "[start.sh] Checking GPU..."
GPU_CHECK=$(python3 -c "
import torch, sys
try:
    torch.cuda.init()
    print('OK:', torch.cuda.get_device_name(0))
except Exception as e:
    print('FAIL:', e, file=sys.stderr)
    sys.exit(1)
" 2>&1) || { echo "[start.sh] GPU unavailable — $GPU_CHECK"; exit 1; }
echo "[start.sh] $GPU_CHECK"

# ── Symlink custom nodes from network volume ───────────────────
if [ -d "/runpod-volume/custom_nodes" ]; then
    echo "[start.sh] Linking custom nodes from /runpod-volume/custom_nodes …"
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
    echo "[start.sh] Custom nodes ready."
else
    echo "[start.sh] WARNING — /runpod-volume/custom_nodes not found. No custom nodes linked." >&2
fi

# ── ComfyUI-Manager → offline mode ────────────────────────────
comfy-manager-set-mode offline \
    || echo "[start.sh] Could not set Manager offline mode" >&2

# ── Configurable tuning ───────────────────────────────────────
: "${COMFY_LOG_LEVEL:=INFO}"
: "${COMFY_READY_TIMEOUT:=120}"      # seconds to wait for HTTP 200
: "${COMFY_READY_INTERVAL:=2}"       # seconds between readiness probes
COMFY_HOST="127.0.0.1:8188"
COMFY_PID_FILE="/tmp/comfyui.pid"

# ── Start ComfyUI in background ───────────────────────────────
echo "[start.sh] Starting ComfyUI (logging at ${COMFY_LOG_LEVEL}) …"
COMFY_ARGS="--disable-auto-launch --disable-metadata --verbose ${COMFY_LOG_LEVEL} --log-stdout"
if [ "${SERVE_API_LOCALLY:-}" == "true" ]; then
    COMFY_ARGS="$COMFY_ARGS --listen"
fi

python -u /comfyui/main.py $COMFY_ARGS &
COMFY_PID=$!
echo $COMFY_PID > "$COMFY_PID_FILE"
echo "[start.sh] ComfyUI PID=$COMFY_PID"

# ── Wait until ComfyUI HTTP is actually ready ─────────────────
# Polls http://127.0.0.1:8188/ every COMFY_READY_INTERVAL seconds.
# Fails fast if the ComfyUI process has already died.
# Times out after COMFY_READY_TIMEOUT seconds with a clear error.
echo "[start.sh] Waiting for ComfyUI HTTP readiness (timeout=${COMFY_READY_TIMEOUT}s) …"
ELAPSED=0
READY=0
while [ "$ELAPSED" -lt "$COMFY_READY_TIMEOUT" ]; do
    # Fast-fail: ComfyUI process died unexpectedly
    if ! kill -0 "$COMFY_PID" 2>/dev/null; then
        echo "[start.sh] ERROR — ComfyUI process (PID=$COMFY_PID) exited before becoming ready." >&2
        echo "[start.sh] Check above for Python traceback / CUDA / model-loading errors." >&2
        exit 1
    fi

    # Readiness probe: HTTP 200 on /
    if curl -fsSo /dev/null --max-time 3 "http://${COMFY_HOST}/"; then
        READY=1
        break
    fi

    echo "[start.sh] … ComfyUI not ready yet (${ELAPSED}s elapsed), retrying in ${COMFY_READY_INTERVAL}s …"
    sleep "$COMFY_READY_INTERVAL"
    ELAPSED=$(( ELAPSED + COMFY_READY_INTERVAL ))
done

if [ "$READY" -ne 1 ]; then
    echo "[start.sh] ERROR — ComfyUI did not respond on http://${COMFY_HOST}/ within ${COMFY_READY_TIMEOUT}s." >&2
    echo "[start.sh] ComfyUI PID=$COMFY_PID still alive: $(kill -0 "$COMFY_PID" 2>/dev/null && echo yes || echo no)" >&2
    exit 1
fi

echo "[start.sh] ✅ ComfyUI is ready at http://${COMFY_HOST}/ (after ${ELAPSED}s)"

# ── Start RunPod handler (foreground) ─────────────────────────
# handler.py is exec'd (not backgrounded) so container exits when
# the handler terminates (normal RunPod lifecycle).
echo "[start.sh] Starting RunPod Handler …"
if [ "${SERVE_API_LOCALLY:-}" == "true" ]; then
    exec python -u /handler.py --rp_serve_api --rp_api_host=0.0.0.0
else
    exec python -u /handler.py
fi
