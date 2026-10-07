#!/usr/bin/env bash
# Starves the leader of CPU while the cluster streams, then gives it back.
#
# THE FAULT: the leader's container is capped at CPUS CPUs while it runs (docker update --cpus). Every thread in it,
# from the consensus module to the garbage collector, now runs only until the container has spent its share of
# each 100 ms period and then waits out the rest. The leader is alive and connected but too slow to lead: a gray
# failure, which neither a kill nor a network fault produces.
#
# WHAT IT ASSERTS:
#   1. The cap is in place.
#   2. The cluster replaces the starved leader.
#   3. A ClusterProbe confirm producer on a follower, streaming throughout, sees every frame on its tap exactly once,
#      in order.
#   4. With its CPU back, the old leader rejoins as a follower and its tap catches up.
set -uo pipefail

LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/logs/throttled-leader"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CPUS="${CPUS:-0.05}"
FAULT_SECS="${FAULT_SECS:-20}"
CONFIRM_COUNT="${CONFIRM_COUNT:-60000}"

start_cluster
OLD="$(await_leader "$(deadline 60)")" || {
    echo "no initial leader emerged"
    exit 1
}
P=$(((OLD + 1) % NODE_COUNT))
echo "leader = member ${OLD}; producing on follower ${P}"

confirm "${P}" 11 > "${LOG_DIR}/confirm.log" 2>&1 &
CONFIRM_PID=$!
wait_for_log "${LOG_DIR}/confirm.log" "confirm: sending" "$(deadline 60)" || {
    echo "confirm producer never started; see ${LOG_DIR}/confirm.log"
    exit 1
}
echo "confirm producer streaming on member ${P}"

# ── fault ──────────────────────────────────────────────────────────────────────────────────────────
throttle "${OLD}" "${CPUS}"
FAULT_START=${SECONDS}
CAP="$(docker exec "node-${OLD}" cat /sys/fs/cgroup/cpu.max)"
echo "node-${OLD} capped at ${CPUS} CPUs (cpu.max ${CAP})"

NEW="$(await_leader "$(deadline 30)" "${OLD}")"
if [[ -n "${NEW}" ]]; then
    echo "new leader = member ${NEW}, $((SECONDS - FAULT_START))s into the fault"
else
    echo "no other member took over"
fi
REMAINING=$((FAULT_SECS - (SECONDS - FAULT_START)))
((REMAINING > 0)) && sleep "${REMAINING}"

RUNNING="$(docker inspect -f '{{.State.Running}}' "node-${OLD}")"
[[ "${RUNNING}" == true ]] || echo "node-${OLD} exited: $(docker inspect -f '{{.State.ExitCode}}' "node-${OLD}")"
unthrottle "${OLD}"
HEALED=${SECONDS}
echo "node-${OLD} given its CPU back after $((HEALED - FAULT_START))s"

REJOINED=0
CAUGHT_UP=0
if [[ "${RUNNING}" == true && -n "${NEW}" ]] && await_follower "${OLD}" "${NEW}" "$(deadline 60)"; then
    REJOINED=1
    for ((attempt = 1; attempt <= 5; attempt++)); do
        if ping_tap "${OLD}" >> "${LOG_DIR}/ping-after.log" 2>&1; then
            CAUGHT_UP=1
            break
        fi
    done
fi
echo "node-${OLD} rejoined / caught up: ${REJOINED} / ${CAUGHT_UP} ($((SECONDS - HEALED))s after)"

wait "${CONFIRM_PID}"
CONFIRM_RC=$?

echo ""
echo "=== RESULT ==="
echo "cap                         : ${CPUS} CPUs, cpu.max ${CAP}"
echo "new leader                  : ${NEW:-none}"
echo "old leader running          : ${RUNNING}"
echo "old leader rejoined / tap   : ${REJOINED} / ${CAUGHT_UP}"
echo "PendingSends producer       : $(grep -h 'confirm:' "${LOG_DIR}/confirm.log" | tail -1)"

PASS=1
[[ "${CAP}" == "$(awk -v c="${CPUS}" 'BEGIN { printf "%d", c * 100000 }') 100000" ]] || {
    echo "FAIL: the cap was not applied"
    PASS=0
}
[[ -n "${NEW}" ]] || {
    echo "FAIL: the starved leader kept leading"
    PASS=0
}
((CONFIRM_RC == 0)) || {
    echo "FAIL: the PendingSends producer was not exact"
    PASS=0
}
((REJOINED == 1 && CAUGHT_UP == 1)) || {
    echo "FAIL: node-${OLD} did not rejoin and catch up"
    PASS=0
}

echo ""
if ((PASS == 1)); then
    echo "THROTTLED LEADER TEST: PASS"
    exit 0
fi
echo "THROTTLED LEADER TEST: FAIL"
exit 1
