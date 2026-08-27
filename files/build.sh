#!/usr/bin/env bash
# Spark recipe — build this kit's images from files/ (does not start containers).
# 1) kernel glm53-flash-sm121:v8 via Dockerfile + glm53-flash_SM121.py sm90
# 2) serving mia/glm53-flash-spark:mm-ray-v1 via Dockerfile.mm-ray
#    (Ray + MM + :8888). Context is always this directory so COPY works.
# Optionally docker-save | ssh-load onto the worker.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
KERNEL_IMAGE="${KERNEL_IMAGE:-glm53-flash-sm121:v8}"
IMAGE="${IMAGE:-mia/glm53-flash-spark:mm-ray-v1}"
WORKER_SSH="${WORKER_SSH:-zurih@10.0.0.2}"
HF_CACHE_DIR="${HF_HOME:-$HOME/.cache/huggingface}"
MODEL_CACHE_NAME="models--LibertAIDAI--GLM-5.3-Flash-NVFP4"

if ! docker image inspect "$KERNEL_IMAGE" >/dev/null 2>&1; then
    echo "[mia-build] kernel $KERNEL_IMAGE missing — docker build Dockerfile (context=$SCRIPT_DIR)"
    docker build --network=host -f "$SCRIPT_DIR/Dockerfile" \
        -t "$KERNEL_IMAGE" "$SCRIPT_DIR"
else
    echo "[mia-build] kernel $KERNEL_IMAGE already on this host — skip"
fi

JINJA_SRC=""
if [ -f "$HF_CACHE_DIR/hub/$MODEL_CACHE_NAME/refs/main" ]; then
    hash="$(<"$HF_CACHE_DIR/hub/$MODEL_CACHE_NAME/refs/main")"
    cand="$HF_CACHE_DIR/hub/$MODEL_CACHE_NAME/snapshots/$hash/chat_template.jinja"
    if [ -f "$cand" ]; then
        JINJA_SRC="$(readlink -f "$cand")"
    fi
fi
if [ -z "$JINJA_SRC" ]; then
    JINJA_SRC="$(find "$HF_CACHE_DIR/hub/$MODEL_CACHE_NAME/snapshots" -name chat_template.jinja 2>/dev/null | head -n 1 || true)"
fi
if [ -n "$JINJA_SRC" ] && [ -f "$JINJA_SRC" ]; then
    rm -f "$SCRIPT_DIR/chat_template.jinja"
    cat "$JINJA_SRC" > "$SCRIPT_DIR/chat_template.jinja"
    echo "[mia-build] chat_template.jinja from $JINJA_SRC"
else
    echo "[mia-build] ERROR: chat_template.jinja not under $HF_CACHE_DIR" >&2
    exit 1
fi

echo "[mia-build] serving tag $IMAGE from Dockerfile.mm-ray (context=$SCRIPT_DIR)"
docker build --network=host -f "$SCRIPT_DIR/Dockerfile.mm-ray" -t "$IMAGE" "$SCRIPT_DIR"
echo "[mia-build] built $IMAGE"

if [ "${SKIP_WORKER_LOAD:-0}" = "1" ]; then
    echo "[mia-build] SKIP_WORKER_LOAD=1 — not shipping to worker"
    exit 0
fi

echo "[mia-build] docker save | ssh $WORKER_SSH docker load ..."
docker save "$IMAGE" | ssh -o BatchMode=yes "$WORKER_SSH" docker load
echo "[mia-build] worker has $IMAGE"
