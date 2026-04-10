#!/usr/bin/env bash
set -euo pipefail

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

TCMALLOC="$(ldconfig -p | grep -Po 'libtcmalloc\.so\.\d' | head -n 1 || true)"
[ -n "$TCMALLOC" ] && export LD_PRELOAD="${TCMALLOC}"

: "${COMFY_DIR:=/comfyui}"
: "${MODEL_BASE_PATH:=/runpod-volume/runpod-slim/ComfyUI/models}"
: "${CUSTOM_NODES_PATH:=/runpod-volume/runpod-slim/ComfyUI/custom_nodes}"
: "${COMFY_LOG_LEVEL:=INFO}"
: "${COMFY_READY_TIMEOUT:=180}"
: "${COMFY_READY_INTERVAL:=2}"
: "${COMFY_PORT:=8188}"
COMFY_HOST="127.0.0.1:${COMFY_PORT}"
COMFY_PID_FILE="/tmp/comfyui.pid"

[ -d "$COMFY_DIR" ] || { echo "[start.sh] ERROR — COMFY_DIR not found: $COMFY_DIR" >&2; exit 1; }

mkdir -p "$COMFY_DIR/input" "$COMFY_DIR/output" "$COMFY_DIR/temp" "$COMFY_DIR/user"

echo "[start.sh] COMFY_DIR=$COMFY_DIR"
echo "[start.sh] MODEL_BASE_PATH=$MODEL_BASE_PATH"
echo "[start.sh] CUSTOM_NODES_PATH=$CUSTOM_NODES_PATH"

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

cat > "$COMFY_DIR/extra_model_paths.yaml" <<EOF
runpod_worker_comfy:
  base_path: ${MODEL_BASE_PATH}
  checkpoints: checkpoints/
  clip: clip/
  clip_vision: clip_vision/
  configs: configs/
  controlnet: controlnet/
  embeddings: embeddings/
  loras: loras/
  upscale_models: upscale_models/
  vae: vae/
  unet: unet/
  diffusion_models: diffusion_models/
  text_encoders: text_encoders/
  LLM: LLM/
  model_patches: model_patches/
  ipadapter: ipadapter/
  insightface: insightface/
EOF
echo "[start.sh] Wrote $COMFY_DIR/extra_model_paths.yaml"

if [ -d "$CUSTOM_NODES_PATH" ]; then
  echo "[start.sh] Linking custom nodes from $CUSTOM_NODES_PATH …"
  mkdir -p "$COMFY_DIR/custom_nodes"
  shopt -s nullglob
  for node_dir in "$CUSTOM_NODES_PATH"/*/; do
    node_name=$(basename "$node_dir")
    target="$COMFY_DIR/custom_nodes/$node_name"
    if [ -e "$target" ] || [ -L "$target" ]; then
      echo " [skip] $node_name"
    else
      ln -s "$node_dir" "$target"
      echo " [linked] $node_name"
    fi
  done
  shopt -u nullglob
  echo "[start.sh] Custom nodes ready."
else
  echo "[start.sh] WARNING — $CUSTOM_NODES_PATH not found. No custom nodes linked." >&2
fi

comfy-manager-set-mode offline || echo "[start.sh] Could not set Manager offline mode" >&2

echo "[start.sh] Starting ComfyUI (logging at ${COMFY_LOG_LEVEL}) …"
COMFY_ARGS=(--disable-auto-launch --disable-metadata --verbose "$COMFY_LOG_LEVEL" --log-stdout --port "$COMFY_PORT")
if [ "${SERVE_API_LOCALLY:-}" = "true" ]; then
  COMFY_ARGS+=(--listen 0.0.0.0)
fi

python -u "$COMFY_DIR/main.py" "${COMFY_ARGS[@]}" &
COMFY_PID=$!
echo $COMFY_PID > "$COMFY_PID_FILE"
echo "[start.sh] ComfyUI PID=$COMFY_PID"

echo "[start.sh] Waiting for ComfyUI HTTP readiness (timeout=${COMFY_READY_TIMEOUT}s) …"
ELAPSED=0
READY=0
while [ "$ELAPSED" -lt "$COMFY_READY_TIMEOUT" ]; do
  if ! kill -0 "$COMFY_PID" 2>/dev/null; then
    echo "[start.sh] ERROR — ComfyUI process (PID=$COMFY_PID) exited before becoming ready." >&2
    exit 1
  fi
  if curl -fsSo /dev/null --max-time 3 "http://${COMFY_HOST}/"; then
    READY=1
    break
  fi
  sleep "$COMFY_READY_INTERVAL"
  ELAPSED=$(( ELAPSED + COMFY_READY_INTERVAL ))
done

if [ "$READY" -ne 1 ]; then
  echo "[start.sh] ERROR — ComfyUI did not respond on http://${COMFY_HOST}/ within ${COMFY_READY_TIMEOUT}s." >&2
  exit 1
fi

echo "[start.sh] ComfyUI is ready at http://${COMFY_HOST}/"
echo "[start.sh] Starting RunPod Handler …"
if [ "${SERVE_API_LOCALLY:-}" = "true" ]; then
  exec python -u /handler.py --rp_serve_api --rp_api_host=0.0.0.0
else
  exec python -u /handler.py
fi
