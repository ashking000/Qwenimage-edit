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
echo "[start.sh] SERVE_API_LOCALLY   = $SERVE_API_LOCALLY"
echo "[start.sh] COMFY_READY_INTERVAL= $COMFY_READY_INTERVAL"
echo "[start.sh] COMFY_READY_TIMEOUT = $COMFY_READY_TIMEOUT"
echo "[start.sh] COMFY_LOG_LEVEL     = $COMFY_LOG_LEVEL"
echo "[start.sh] CUSTOM_NODES_PATH   = $CUSTOM_NODES_PATH"
echo "[start.sh] MODEL_BASE_PATH     = $MODEL_BASE_PATH"
echo "[start.sh] COMFY_PORT          = $COMFY_PORT"
echo "[start.sh] COMFY_HOST          = $COMFY_HOST"
echo "[start.sh] COMFY_DIR           = $COMFY_DIR"
echo "[start.sh] ──────────────────────────────────────────────"

# ════════════════════════════════════════════════════════════════
# FILESYSTEM DISCOVERY — dirs only, no file spam
# ════════════════════════════════════════════════════════════════

echo ""
echo "[map] ══════════════ CONTAINER FILESYSTEM MAP ══════════════"

# 1. Disk mounts
echo "[map] ── Mounted filesystems (df -h):"
df -h --output=source,fstype,size,used,avail,target 2>/dev/null | grep -v tmpfs | grep -v overlay | grep -v udev || df -h

# 2. /proc/mounts — catch NFS / network volume
echo "[map] ── Network/NFS mounts in /proc/mounts:"
grep -E "nfs|runpod|volume|workspace|data|mnt" /proc/mounts 2>/dev/null || echo "[map]    (none found)"

# 3. Root-level dirs only
echo "[map] ── / (root) — top-level directories:"
ls -la / | grep '^d' | awk '{print "[map]   " $NF}'

# 4. Locate actual ComfyUI main.py
echo "[map] ── Searching for ComfyUI main.py (max depth 6):"
find / -maxdepth 6 -name "main.py" -path "*/comfyui*" 2>/dev/null \
  | grep -v __pycache__ | head -n 10 | sed 's/^/[map]   /' \
  || echo "[map]   (not found at depth 6)"

find / -maxdepth 6 -name "main.py" -path "*/ComfyUI*" 2>/dev/null \
  | grep -v __pycache__ | head -n 5 | sed 's/^/[map]   /' || true

# 5. Known candidate locations
echo "[map] ── Candidate ComfyUI locations:"
for p in /comfyui /ComfyUI /workspace/ComfyUI /workspace/comfyui \
          /root/ComfyUI /root/comfyui /opt/ComfyUI /opt/comfyui \
          /app/ComfyUI /app/comfyui /home/ComfyUI; do
  if [ -d "$p" ]; then
    echo "[map]   FOUND dir: $p"
    ls "$p" | tr '\n' '  ' | sed 's/^/[map]     contents: /'
    echo ""
  fi
done

# 6. $COMFY_DIR internal structure (dirs, depth 2)
echo "[map] ── $COMFY_DIR internal (dirs, depth 2):"
if [ -d "$COMFY_DIR" ]; then
  find "$COMFY_DIR" -maxdepth 2 -type d 2>/dev/null \
    | sed "s|$COMFY_DIR||" | grep -v "^$" | sort | sed 's/^/[map]   /'
else
  echo "[map]   !! $COMFY_DIR does NOT exist"
fi

# 7. /runpod-volume
echo "[map] ── /runpod-volume status:"
if [ -d "/runpod-volume" ]; then
  echo "[map]   EXISTS — top-level dirs:"
  find /runpod-volume -maxdepth 3 -type d 2>/dev/null | head -n 30 | sed 's/^/[map]   /'
else
  echo "[map]   !! /runpod-volume does NOT exist — network volume not mounted"
fi

# 8. Other common mount points
echo "[map] ── Other common mount candidates:"
for p in /workspace /data /mnt /vol /storage /network-volume; do
  if [ -d "$p" ]; then
    echo "[map]   FOUND: $p"
    ls "$p" 2>/dev/null | head -n 5 | sed 's/^/[map]     /'
  fi
done

# 9. Model file count by location (no individual listing)
echo "[map] ── .safetensors / .gguf file counts by dir:"
find / -maxdepth 7 \( -name "*.safetensors" -o -name "*.gguf" -o -name "*.ckpt" \) \
  2>/dev/null \
  | grep -v proc | grep -v sys \
  | sed 's|/[^/]*$||' \
  | sort | uniq -c | sort -rn \
  | head -n 20 | sed 's/^/[map]   /'

# 10. Existing extra_model_paths.yaml
echo "[map] ── Existing extra_model_paths.yaml files:"
find / -maxdepth 7 -name "extra_model_paths.yaml" 2>/dev/null \
  | head -n 5 | sed 's/^/[map]   /' || echo "[map]   (none found)"

# 11. custom_nodes dir + count
echo "[map] ── Custom nodes dirs found:"
find / -maxdepth 6 -type d -name "custom_nodes" 2>/dev/null \
  | head -n 5 \
  | while read -r d; do
      cnt=$(find "$d" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
      echo "[map]   $d  ($cnt nodes)"
    done

# 12. Python package check
echo "[map] ── Key Python packages:"
python3 -c "
import importlib, sys
pkgs = ['torch','torchvision','safetensors','transformers','diffusers','comfy']
for p in pkgs:
    try:
        m = importlib.import_module(p)
        ver = getattr(m, '__version__', 'no-version')
        print(f'[map]   OK  {p} == {ver}')
    except ImportError as e:
        print(f'[map]   MISS {p}: {e}')
" 2>&1

echo "[map] ══════════════ END FILESYSTEM MAP ══════════════"
echo ""

# ════════════════════════════════════════════════════════════════
# END DISCOVERY
# ════════════════════════════════════════════════════════════════

# ── Sanity check ───────────────────────────────────────────────────────────────
if [ ! -d "$COMFY_DIR" ]; then
  echo "[start.sh] ERROR — COMFY_DIR not found: $COMFY_DIR" >&2
  echo "[start.sh] Check [map] output above for where ComfyUI actually lives." >&2
  exit 1
fi

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

# ── Write extra_model_paths.yaml ───────────────────────────────────────────────
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
  text_encoders: text_encoders
EOF

echo "[start.sh] Wrote extra_model_paths.yaml pointing at: $MODEL_BASE_PATH"
cat "$COMFY_DIR/extra_model_paths.yaml" | sed 's/^/[start.sh]   /'

# ── Optionally disable broken custom nodes ────────────────────────────────────
if [ -d "$CUSTOM_NODES_PATH" ]; then
  for d in "$CUSTOM_NODES_PATH"/*; do
    [ -d "$d" ] || continue
    if grep -R "comfy_aimdo" -q "$d" 2>/dev/null; then
      echo "[start.sh] Disabling custom node using comfy_aimdo: $d"
      mv "$d" "${d}.disabled" 2>/dev/null || true
    fi
  done
fi

# ── Launch ComfyUI in background ──────────────────────────────────────────────
echo "[start.sh] Starting ComfyUI on $COMFY_HOST:$COMFY_PORT (log: $COMFY_LOG_LEVEL) ..."

COMFY_ARGS=(
  --disable-auto-launch
  --disable-metadata
  --verbose "$COMFY_LOG_LEVEL"
  --log-stdout
  --port "$COMFY_PORT"
  --extra-model-paths-config "$COMFY_DIR/extra_model_paths.yaml"
)

if [ "$SERVE_API_LOCALLY" = "true" ]; then
  COMFY_ARGS+=(--listen 0.0.0.0)
else
  COMFY_ARGS+=(--listen 127.0.0.1)
fi

python -u "$COMFY_DIR/main.py" "${COMFY_ARGS[@]}" &
COMFY_PID=$!
echo "$COMFY_PID" > "$COMFY_PID_FILE"
echo "[start.sh] ComfyUI PID=$COMFY_PID"

# ── Readiness probe ────────────────────────────────────────────────────────────
READINESS_URL="http://127.0.0.1:${COMFY_PORT}/"
echo "[start.sh] Readiness probe URL: $READINESS_URL (timeout=${COMFY_READY_TIMEOUT}s)"

ELAPSED=0
READY=0

while [ "$ELAPSED" -lt "$COMFY_READY_TIMEOUT" ]; do
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

# ── Start RunPod handler (foreground) ─────────────────────────────────────────
echo "[start.sh] Starting RunPod Handler ..."
if [ "$SERVE_API_LOCALLY" = "true" ]; then
  exec python -u /handler.py --rp_serve_api --rp_api_host=0.0.0.0
else
  exec python -u /handler.py
fi
