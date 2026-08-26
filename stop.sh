#!/usr/bin/env bash
# ============================================================================
# stop.sh — stop the GLM-5.3-Flash vLLM server started by start.sh
# ============================================================================
# Removes glm53-flash-head on this machine (spark1) and glm53-flash-worker on
# spark2 (zurih@10.0.0.2). Killing the containers also tears down the Ray
# cluster and NCCL groups inside them.
#
# It only touches the two containers above — other deployments (e.g.
# qwen38-flash-next-*) and the persistent data (HF weights cache on both
# nodes, the glm53-flash-cache compile-cache volume) are left alone, so a
# later ./start.sh restarts quickly.
#
# Equivalent to: ./start.sh stop
# ============================================================================
set -u

WORKER_SSH="${WORKER_SSH:-zurih@10.0.0.2}"
CONTAINER_HEAD="${CONTAINER_HEAD:-glm53-flash-head}"
CONTAINER_WORKER="${CONTAINER_WORKER:-glm53-flash-worker}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

log()  { printf '\033[1;36m[glm53]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[glm53]\033[0m %s\n' "$*" >&2; }

# ---- head ------------------------------------------------------------------
if docker inspect "$CONTAINER_HEAD" >/dev/null 2>&1; then
    log "stopping ${CONTAINER_HEAD} on $(hostname) ..."
    # docker rm -f = SIGTERM, then SIGKILL after the container's stop-timeout
    docker rm -f "$CONTAINER_HEAD" >/dev/null 2>&1 \
        || warn "failed to remove ${CONTAINER_HEAD} on head"
else
    log "no ${CONTAINER_HEAD} container on head"
fi

# ---- worker ----------------------------------------------------------------
if ssh "${SSH_OPTS[@]}" "$WORKER_SSH" "docker inspect '$CONTAINER_WORKER' >/dev/null 2>&1"; then
    log "stopping ${CONTAINER_WORKER} on ${WORKER_SSH} ..."
    ssh "${SSH_OPTS[@]}" "$WORKER_SSH" "docker rm -f '$CONTAINER_WORKER'" >/dev/null 2>&1 \
        || warn "failed to remove ${CONTAINER_WORKER} on worker"
else
    log "no ${CONTAINER_WORKER} container on worker (or worker unreachable)"
fi

# ---- verify ----------------------------------------------------------------
sleep 2
rc=0
if docker inspect "$CONTAINER_HEAD" >/dev/null 2>&1; then
    warn "${CONTAINER_HEAD} is still present — try: docker rm -f ${CONTAINER_HEAD}"
    rc=1
fi
if ssh "${SSH_OPTS[@]}" "$WORKER_SSH" "docker inspect '$CONTAINER_WORKER' >/dev/null 2>&1"; then
    warn "${CONTAINER_WORKER} is still present on the worker — try: ssh ${WORKER_SSH} docker rm -f ${CONTAINER_WORKER}"
    rc=1
fi
[ "$rc" = 0 ] && log "stopped. (weights and compile caches are kept — ./start.sh restarts fast)"
exit "$rc"
