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
echo "[start.sh] COMFY_DIR           = $COMFY_DIR"
echo "[start.sh] COMFY_HOST          = $COMFY_HOST"
echo "[start.sh] COMFY_PORT          = $COMFY_PORT"
echo "[start.sh] MODEL_BASE_PATH     = $MODEL_BASE_PATH"
echo "[start.sh] CUSTOM_NODES_PATH   = $CUSTOM_NODES_PATH"
echo "[start.sh] COMFY_LOG_LEVEL     = $COMFY_LOG_LEVEL"
echo "[start.sh] COMFY_READY_TIMEOUT = $COMFY_READY_TIMEOUT"
echo "[start.sh] COMFY_READY_INTERVAL= $COMFY_READY_INTERVAL"
echo "[start.sh] SERVE_API_LOCALLY   = $SERVE_API_LOCALLY"
echo "[start.sh] ──────────────────────────────────────────────"

# ── Sanity check ───────────────────────────────────────────────────────────────
if [ ! -d "$COMFY_DIR" ]; then
  echo "[start.sh] ERROR — COMFY_DIR not found: $COMFY_DIR" >&2
  exit 1
fi

echo "[start.sh] Debug: listing model dirs on /runpod-volume"
ls -lah /runpod-volume/runpod-slim/ComfyUI/models/vae || true
ls -lah /runpod-volume/runpod-slim/ComfyUI/models/unet | head || true
ls -lah /runpod-volume/runpod-slim/ComfyUI/models/text_encoders | head || true

echo "[start.sh] Debug: /runpod-volume root listing"
ls -lah /runpod-volume || true
echo "[start.sh] Debug: find ComfyUI/models under /runpod-volume (top 50)"
find /runpod-volume -maxdepth 4 -type d -name models -o -name ComfyUI | head -n 50 || true


mkdir -p "$COMFY_DIR/input" "$COMFY_DIR/output" "$COMFY_DIR/temp" "$COMFY_DIR/user"

# ── GPU check (non-fatal) ──────────────────────────────────────────────────────
echo "[start.sh] Checking GPU..."
python3 - <<'PY' || echo "[start.sh] WARN: GPU check failed (continuing anyway)." >&2
import torch, sys
try:
    print("[start.sh] torch version:", torch.__version__)
    print("[start.sh] cuda available:", torch.cuda.is_available())
    if torch.cuda.is_available():
        print("[start.sh] gpu:", torch.cuda.get_device_name(0))
except Exception as e:
    print("[start.sh] GPU probe failed:", e, file=sys.stderr)
    sys.exit(1)
PY

# ── Write extra_model_paths.yaml from MODEL_BASE_PATH ──────────────────────────
# MODEL_BASE_PATH is the "models" root. Subfolders are relative to that root.
cat > "$COMFY_DIR/extra_model_paths.yaml" <<EOF
runpod_worker_comfy:
  base_path: ${MODEL_BASE_PATH}
  checkpoints: checkpoints
  clip: clip
  clip_vision: clip_vision
  configs: configs
  controlnet: controlnet
  embeddings: embeddings
  loras: loras
  upscale_models: upscale_models
  vae: vae
  diffusion_models: |
    diffusion_models
    unet
EOF

# ── Optionally disable comfy_aimdo custom node to avoid import errors ──────────
if [ -d "$CUSTOM_NODES_PATH" ]; then
  for d in "$CUSTOM_NODES_PATH"/*; do
    [ -d "$d" ] || continue
    if grep -R "comfy_aimdo" -q "$d" 2>/dev/null; then
      echo "[start.sh] Disabling custom node using comfy_aimdo: $d"
      mv "$d" "${d}.disabled" 2>/dev/null || true
    fi
  done
fi

# ── Launch ComfyUI in background ───────────────────────────────────────────────
echo "[start.sh] Starting ComfyUI on $COMFY_HOST:$COMFY_PORT (log: $COMFY_LOG_LEVEL) ..."

COMFY_ARGS=(
  --disable-auto-launch
  --disable-metadata
  --verbose "$COMFY_LOG_LEVEL"
  --log-stdout
  --port "$COMFY_PORT"
  COMFY_ARGS+=(--extra-model-paths-config "$COMFY_DIR/extra_model_paths.yaml")
)

# Explicit listen behaviour
if [ "$SERVE_API_LOCALLY" = "true" ]; then
  # For local dev / exposing API
  COMFY_ARGS+=(--listen 0.0.0.0)
else
  # Serverless worker: bind only to localhost
  COMFY_ARGS+=(--listen 127.0.0.1)
fi

python -u "$COMFY_DIR/main.py" "${COMFY_ARGS[@]}" &
COMFY_PID=$!
echo "$COMFY_PID" > "$COMFY_PID_FILE"
echo "[start.sh] ComfyUI PID=$COMFY_PID"

# ── Readiness probe — always uses 127.0.0.1 explicitly ────────────────────────
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
