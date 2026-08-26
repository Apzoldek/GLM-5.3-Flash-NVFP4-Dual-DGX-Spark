#!/usr/bin/env bash
# ============================================================================
# download.sh — download GLM-5.3-Flash-NVFP4 weights and sync to the worker
# ============================================================================
# Does exactly two things (starts no containers):
#   1. download  LibertAIDAI/GLM-5.3-Flash-NVFP4 (~181 GiB, 120 shards) into
#                the local HF cache via `hf download` (resumable, effectively
#                a no-op when already complete)
#   2. rsync     the cache copy to zurih@10.0.0.2 so both TP=2 ranks load
#                from local disk, then verify the shard counts match
#
# Env overrides:
#   HF_HOME=...            HF cache root (default ~/.cache/huggingface)
#   WORKER_SSH=...         default zurih@10.0.0.2
#   WORKER_HOME=...        default /home/zurih
#   EXPECTED_SHARDS=...    default: live count from the HF API (fallback 120)
#   REFRESH_WEIGHTS=1      re-run hf download to update / re-verify
#   SKIP_SYNC=1            download locally only, don't touch the worker
#   HF_TOKEN=...           (or legacy HUGGINGFACE_HUB_TOKEN) — picked up from
#                          the shell env and used for both `hf download` and
#                          the HF API query. Optional (model is public/MIT),
#                          but avoids anonymous rate limits.
#
# Config mirrors start.sh — keep the two in sync if you change the model.
# ============================================================================
set -euo pipefail

MODEL="LibertAIDAI/GLM-5.3-Flash-NVFP4"
MODEL_CACHE_NAME="models--LibertAIDAI--GLM-5.3-Flash-NVFP4"
WORKER_SSH="${WORKER_SSH:-zurih@10.0.0.2}"
WORKER_HOME="${WORKER_HOME:-/home/zurih}"

HF_CACHE_DIR="${HF_HOME:-$HOME/.cache/huggingface}"
MODEL_PATH="$HF_CACHE_DIR/hub/$MODEL_CACHE_NAME"
WORKER_CACHE_DIR="$WORKER_HOME/.cache/huggingface"
WORKER_MODEL_PATH="$WORKER_CACHE_DIR/hub/$MODEL_CACHE_NAME"
DEFAULT_EXPECTED_SHARDS=120

log()  { printf '\033[1;36m[glm53]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[glm53]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[glm53]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }

worker_ssh() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$WORKER_SSH" "$@"; }

# count *.safetensors in the snapshots dir — NO '-type f': HF cache snapshot
# entries are symlinks into blobs/, which '-type f' would miss entirely.
# '|| true': find exits 1 when the dir doesn't exist yet (pipefail-safe).
count_shards() { find "$1/snapshots" -name '*.safetensors' 2>/dev/null | wc -l | tr -d '[:space:]' || true; }

# ---------------------------------------------------------------------------
# resolve the HF CLI
# ---------------------------------------------------------------------------
HF_CLI="$(command -v hf || command -v huggingface-cli || true)"
[ -n "$HF_CLI" ] || die "neither 'hf' nor 'huggingface-cli' found — pip install --user -U 'huggingface_hub[cli]'"

# ---------------------------------------------------------------------------
# HF token from the shell env (optional — the model is public/MIT, but a
# token avoids anonymous rate limits). hf/huggingface-cli read these env
# vars natively, so `hf download` below is already authenticated; we also
# forward the token to the direct HF API query.
# ---------------------------------------------------------------------------
HF_TOKEN_VAL="${HF_TOKEN:-${HUGGINGFACE_HUB_TOKEN:-}}"
API_AUTH=()
if [ -n "$HF_TOKEN_VAL" ]; then
    if [ -n "${HF_TOKEN:-}" ]; then
        log "HF token detected (\$HF_TOKEN) — using it for the download and API queries"
    else
        log "HF token detected (\$HUGGINGFACE_HUB_TOKEN) — using it for the download and API queries"
    fi
    API_AUTH=(-H "Authorization: Bearer ${HF_TOKEN_VAL}")
fi

# ---------------------------------------------------------------------------
# expected shard count: live from the HF API when possible, else the default
# ---------------------------------------------------------------------------
expected="${EXPECTED_SHARDS:-}"
if [ -z "$expected" ]; then
    expected="$(curl -fsS -m 15 "${API_AUTH[@]}" "https://huggingface.co/api/models/${MODEL}" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(sum(1 for f in d.get("siblings", []) if f["rfilename"].endswith(".safetensors")))
except Exception:
    pass' 2>/dev/null || true)"
    [ -n "$expected" ] || expected="$DEFAULT_EXPECTED_SHARDS"
fi
[[ "$expected" =~ ^[0-9]+$ ]] || expected="$DEFAULT_EXPECTED_SHARDS"

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
command -v rsync >/dev/null 2>&1 || die "rsync not found"
command -v curl   >/dev/null 2>&1 || die "curl not found"

if [ "${SKIP_SYNC:-0}" != "1" ]; then
    log "checking worker ${WORKER_SSH} ..."
    worker_ssh true 2>/dev/null || die "cannot ssh (key-based) to ${WORKER_SSH}"
fi

# disk space: model is ~181 GiB
need_kb=$((190 * 1024 * 1024))
avail="$(df -Pk "$HF_CACHE_DIR" 2>/dev/null | awk 'NR==2{print $4}' || true)"
[ "${avail:-0}" -ge "$need_kb" ] || warn "only $((avail / 1024 / 1024)) GiB free on head for a ~181 GiB model"
if [ "${SKIP_SYNC:-0}" != "1" ]; then
    avail="$(worker_ssh "df -Pk '$WORKER_HOME' 2>/dev/null" | awk 'NR==2{print $4}' || true)"
    [ "${avail:-0}" -ge "$need_kb" ] || warn "only $((avail / 1024 / 1024)) GiB free on worker for a ~181 GiB model"
fi

# ---------------------------------------------------------------------------
# download (or resume) locally
# ---------------------------------------------------------------------------
local_n="$(count_shards "$MODEL_PATH")"
need=0
if [ ! -d "$MODEL_PATH" ] || [ "$local_n" = "0" ]; then
    need=1; reason="not present yet"
elif [ "$local_n" -ne "$expected" ]; then
    need=1; reason="incomplete (${local_n}/${expected} shards — resuming)"
elif [ "${REFRESH_WEIGHTS:-0}" = "1" ]; then
    need=1; reason="REFRESH_WEIGHTS=1"
fi

if [ "$need" = "1" ]; then
    log "downloading ${MODEL} — ${reason}; ~181 GiB / ${expected} shards into ${HF_CACHE_DIR}"
    # hf/huggingface-cli pick up HF_TOKEN / HUGGINGFACE_HUB_TOKEN from the
    # inherited environment automatically.
    "$HF_CLI" download "$MODEL"
    local_n="$(count_shards "$MODEL_PATH")"
    if [ "$local_n" -ne "$expected" ]; then
        warn "local shard count is ${local_n}/${expected} after download — re-run this script to resume"
    fi
else
    log "weights already complete locally: ${local_n}/${expected} shards in ${MODEL_PATH}"
fi

# ---------------------------------------------------------------------------
# sync to the worker
# ---------------------------------------------------------------------------
if [ "${SKIP_SYNC:-0}" = "1" ]; then
    log "SKIP_SYNC=1 — skipping worker sync"
else
    log "syncing to ${WORKER_SSH} (first run moves ~181 GiB over the p2p link) ..."
    worker_ssh "mkdir -p '$WORKER_CACHE_DIR/hub'"
    rsync -a --partial --info=progress2 \
        "$MODEL_PATH/" "${WORKER_SSH}:${WORKER_MODEL_PATH}/"

    worker_n="$(worker_ssh "find '$WORKER_MODEL_PATH/snapshots' -name '*.safetensors' 2>/dev/null | wc -l | tr -d '[:space:]'")"
    [ "$worker_n" = "$local_n" ] \
        || die "worker has ${worker_n} shards but head has ${local_n} — re-run to resume the rsync"
    log "worker in sync: ${worker_n}/${local_n} shards"
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
log "done."
log "  local  : ${MODEL_PATH}  ($(du -sh "$MODEL_PATH" 2>/dev/null | awk '{print $1}'))"
[ "${SKIP_SYNC:-0}" = "1" ] || log "  worker : ${WORKER_SSH}:${WORKER_MODEL_PATH}"
log "next    : ./start.sh   (serves it, TP=2 across both GB10s)"
