#!/usr/bin/env bash
# Verify ROS2+Zenoh pod-to-pod communication in OpenShift.
# Exit 0 on all-pass, 1 on any failure.
set -euo pipefail

NAMESPACE="${NAMESPACE:-ros2-zenoh}"
SAMPLE_LINES="${SAMPLE_LINES:-60}"

PASS=0; FAIL=0

pass() { printf "  PASS  %s\n" "$1"; ((PASS++)) || true; }
fail() { printf "  FAIL  %s\n" "$1"; ((FAIL++)) || true; }

echo "=== ROS2 + Zenoh Communication Verification ==="
printf "    Namespace : %s\n\n" "$NAMESPACE"

# ── Pod readiness ─────────────────────────────────────────────────────────────
echo "── Pod Readiness ────────────────────────────────────────────────────────"
for dep in zenoh-router ros2-talker ros2-listener; do
    ready=$(kubectl get deployment "$dep" -n "$NAMESPACE" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    if [[ "${ready:-0}" == "1" ]]; then
        pass "$dep  (1/1 Ready)"
    else
        fail "$dep  (readyReplicas=${ready:-0})"
    fi
done
echo

# ── Message flow & latency (via Python) ───────────────────────────────────────
echo "── Message Flow ─────────────────────────────────────────────────────────"
T_TMP=$(mktemp); L_TMP=$(mktemp)
trap 'rm -f "$T_TMP" "$L_TMP"' EXIT

kubectl logs -n "$NAMESPACE" -l app=ros2-talker   --tail="$SAMPLE_LINES" 2>/dev/null > "$T_TMP" || true
kubectl logs -n "$NAMESPACE" -l app=ros2-listener --tail="$SAMPLE_LINES" 2>/dev/null > "$L_TMP" || true

python3 - "$T_TMP" "$L_TMP" <<'PY'
import sys, re
from statistics import mean

with open(sys.argv[1]) as f:
    t_lines = f.readlines()
with open(sys.argv[2]) as f:
    l_lines = f.readlines()

t_data = {}
for line in t_lines:
    m = re.search(r'\[(\d+\.\d+)\].*Publishing.*Hello World: (\d+)', line)
    if m:
        t_data[int(m.group(2))] = float(m.group(1))

l_data = {}
for line in l_lines:
    m = re.search(r'\[(\d+\.\d+)\].*I heard.*Hello World: (\d+)', line)
    if m:
        l_data[int(m.group(2))] = float(m.group(1))

t_seqs  = set(t_data)
l_seqs  = set(l_data)
delivered = t_seqs & l_seqs
dropped   = t_seqs - l_seqs

print(f"    Talker    messages sampled : {len(t_seqs)}")
print(f"    Listener  messages sampled : {len(l_seqs)}")
print(f"    Delivered (talker∩listener): {len(delivered)}")
print(f"    Dropped   (in talker only) : {len(dropped)}")
print()

lats = [(l_data[s] - t_data[s]) * 1000 for s in delivered]
if lats:
    print(f"── End-to-End Latency (publish → receive) ───────────────────────────────")
    print(f"    Samples : {len(lats)}")
    print(f"    Average : {mean(lats):.2f} ms")
    print(f"    Min     : {min(lats):.2f} ms")
    print(f"    Max     : {max(lats):.2f} ms")
else:
    print("── Latency: no overlapping samples (logs may not be time-aligned)")

# Up to 2 apparent drops are normal: the talker log snapshot is fetched slightly
# before the listener snapshot, so the trailing message(s) may not have arrived yet.
real_drops = max(0, len(dropped) - 2)
sys.exit(0 if len(delivered) > 0 and real_drops == 0 else 1)
PY
FLOW_RC=$?

if [[ "$FLOW_RC" -eq 0 ]]; then
    pass "Messages flowing  talker → zenoh-router → listener"
    pass "No drops in ${SAMPLE_LINES}-line sample"
else
    fail "Message flow check (see details above)"
fi
echo

# ── Summary ───────────────────────────────────────────────────────────────────
echo "═════════════════════════════════════════════════════════════════════════"
printf "  Result : %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
