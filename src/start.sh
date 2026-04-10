#!/usr/bin/env bash
set -euo pipefail

# ── SSH (optional) ─────────────────────────────────────────────────────────────
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

# ── Memory allocator ───────────────────────────────────────────────────────────
TCMALLOC="$(ldconfig -p | grep -Po 'libtcmalloc\.so\.\d' | head -n 1 || true)"
[ -n "$TCMALLOC" ] && export LD_PRELOAD="${TCMALLOC}"

# ── Config — must match Dockerfile ENV defaults ────────────────────────────────
: "${COMFY_DIR:=/comfyui}"
: "${COMFY_HOST:=127.0.0.1}"
: "${COMFY_PORT:=8188}"
: "${MODEL_BASE_PATH:=/runpod-volume/runpod-slim/ComfyUI/models}"
: "${CUSTOM_NODES_PATH:=/runpod-volume/runpod-slim/ComfyUI/custom_nodes}"
: "${COMFY_LOG_LEVEL:=INFO}"
: "${COMFY_READY_TIMEOUT:=600}"
: "${COMFY_READY_INTERVAL:=3}"
: "${SERVE_API_LOCALLY:=false}"

COMFY_PID_FILE="/tmp/comfyui.pid"

echo "[start.sh] ──────────────────────────────────────────────"
echo "[start.sh] COMFY_DIR          = $COMFY_DIR"
echo "[start.sh] COMFY_HOST         = $COMFY_HOST"
echo "[start.sh] COMFY_PORT         = $COMFY_PORT"
echo "[start.sh] MODEL_BASE_PATH    = $MODEL_BASE_PATH"
echo "[start.sh] CUSTOM_NODES_PATH  = $CUSTOM_NODES_PATH"
echo "[start.sh] COMFY_LOG_LEVEL    = $COMFY_LOG_LEVEL"
echo "[start.sh] COMFY_READY_TIMEOUT= $COMFY_READY_TIMEOUT"
echo "[start.sh] COMFY_READY_INTERVAL= $COMFY_READY_INTERVAL"
echo "[start.sh] SERVE_API_LOCALLY  = $SERVE_API_LOCALLY"
echo "[start.sh] ──────────────────────────────────────────────"

# ── Sanity check ───────────────────────────────────────────────────────────────
if [ ! -d "$COMFY_DIR" ]; then
  echo "[start.sh] ERROR — COMFY_DIR not found: $COMFY_DIR" >&2
  exit 1
fi

mkdir -p "$COMFY_DIR/input" "$COMFY_DIR/output" "$COMFY_DIR/temp" "$COMFY_DIR/user"

# ── GPU check ──────────────────────────────────────────────────────────────────
echo "[start.sh] Checking GPU..."
GPU_CHECK=$(python3 -c "
import torch, sys
try:
    torch.cuda.init()
    print('OK:', torch.cuda.get_device_name(0))
except Exception as e:
    print('FAIL:', e, file=sys.stderr)
    sys.exit(1)
" 2>&1) || {
  echo "[start.sh] GPU unavailable — $GPU_CHECK" >&2
  exit 1
}
echo "[start.sh] GPU: $GPU_CHECK"

# ── Write extra_model_paths.yaml from MODEL_BASE_PATH ──────────────────────────
# This maps your network volume model tree into ComfyUI's model namespaces.
cat > "$COMFY_DIR/extra_model_paths.yaml" <<EOF
runpod_worker_comfy:
  base_path: "$MODEL_BASE_PATH"
  checkpoints: models/checkpoints
  clip: models/clip
  clip_vision: models/clip_vision
  configs: models/configs
  controlnet: models/controlnet
  embeddings: models/embeddings
  loras: models/loras
  upscale_models: models/upscale_models
  vae: models/vae
  diffusion_models:
    - models/diffusion_models
    - models/unet
EOF

# ── ComfyUI Manager offline mode ───────────────────────────────────────────────
comfy-manager-set-mode offline || echo "[start.sh] Could not set Manager offline mode" >&2

# ── Launch ComfyUI in background ───────────────────────────────────────────────
echo "[start.sh] Starting ComfyUI on $COMFY_HOST:$COMFY_PORT (log: $COMFY_LOG_LEVEL) ..."

COMFY_ARGS=(
  --disable-auto-launch
  --disable-metadata
  --verbose "$COMFY_LOG_LEVEL"
  --log-stdout
  --port "$COMFY_PORT"
)

# If SERVE_API_LOCALLY=true, bind to 0.0.0.0 so the port is reachable externally
if [ "$SERVE_API_LOCALLY" = "true" ]; then
  COMFY_ARGS+=(--listen 0.0.0.0)
fi

python -u "$COMFY_DIR/main.py" "${COMFY_ARGS[@]}" &
COMFY_PID=$!
echo "$COMFY_PID" > "$COMFY_PID_FILE"
echo "[start.sh] ComfyUI PID=$COMFY_PID"

# ── Readiness probe — always uses 127.0.0.1 explicitly ────────────────────────
# NOTE: We always probe 127.0.0.1 here regardless of COMFY_HOST, because
# ComfyUI may still be binding only to localhost even if COMFY_HOST=0.0.0.0.
# handler.py uses COMFY_HOST/COMFY_PORT independently for its own HTTP calls.
READINESS_URL="http://127.0.0.1:${COMFY_PORT}/"
echo "[start.sh] Readiness probe URL: $READINESS_URL (timeout=${COMFY_READY_TIMEOUT}s)"

ELAPSED=0
READY=0

while [ "$ELAPSED" -lt "$COMFY_READY_TIMEOUT" ]; do
  # Fast-fail if ComfyUI process died before becoming ready
  if ! kill -0 "$COMFY_PID" 2>/dev/null; then
    echo "[start.sh] ERROR — ComfyUI process (PID=$COMFY_PID) exited before becoming ready." >&2
    echo "[start.sh] Check above logs for Python traceback / CUDA / model-loading error." >&2
    exit 1
  fi

  if curl -fsSo /dev/null --max-time 3 "$READINESS_URL"; then
    READY=1
    break
  fi

  echo "[start.sh] ... not ready yet (${ELAPSED}s elapsed), retrying in ${COMFY_READY_INTERVAL}s ..."
  sleep "$COMFY_READY_INTERVAL"
  ELAPSED=$(( ELAPSED + COMFY_READY_INTERVAL ))
done

if [ "$READY" -ne 1 ]; then
  echo "[start.sh] ERROR — ComfyUI did not respond on $READINESS_URL within ${COMFY_READY_TIMEOUT}s." >&2
  exit 1
fi

echo "[start.sh] ✅ ComfyUI ready at $READINESS_URL (after ${ELAPSED}s)"

# ── Start RunPod handler (foreground) ──────────────────────────────────────────
echo "[start.sh] Starting RunPod Handler ..."
if [ "$SERVE_API_LOCALLY" = "true" ]; then
  exec python -u /handler.py --rp_serve_api --rp_api_host=0.0.0.0
else
  exec python -u /handler.py
fi
