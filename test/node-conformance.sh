#!/usr/bin/env bash
# Kubernetes node conformance: the image and its kubernetes extension, held to the
# [NodeConformance] specs of upstream's node e2e suite.
#
#     ./test/node-conformance.sh [rootfs.erofs] [bzImage]
#     ./test/node-conformance.sh output/boot-image/rootfs.erofs output/boot-image/bzImage   # CI's, from tools/fetch-image.sh
#
# The suite is Kubernetes' own e2e_node.test, built by tools/build-node-e2e.sh from the
# tarball packages/kubernetes pins, and driven by ginkgo inside the guest. It needs no
# cluster: it runs etcd and kube-apiserver linked into itself, and starts the node's
# kubelet — the extension's /usr/bin/kubelet — through systemd-run against the
# extension's CRI-O. This is how upstream's node e2e jobs run it, and what replaced the
# containerized node-test image the Kubernetes documentation still describes, which
# expects the API server's long-gone insecure port.
#
# One node, booted like a tools/k8s-demo.sh node: the kubernetes extension attached
# (SYSEXTS), a /var disk, user-mode networking for the images the specs pull from
# registry.k8s.io. Before the suite, the guest gets what upstream's test nodes have and
# a real node would get from its cluster, all of it under /run or /var, so nothing the
# image ships is changed:
#
#   - the extension's kubelet.service masked, since the suite starts a kubelet of its own
#   - a bridge CNI config, as a cluster's CNI DaemonSet would write it
#   - a CRI-O runtime handler named test-handler, which the RuntimeClass and PodOverhead
#     specs expect every test node to define (crun, under another name)
#
# Failures are listed by spec name at the end, with each one's location, and in CI also
# as error annotations and in the job summary. The full ginkgo output is in
# output/node-conformance/run.log, and the suite's own results — junit, kubelet.log,
# services.log (etcd and the API server), crio.log — in output/node-conformance/results/.
# The guest's console is output/node-conformance-console.log.
#
# Overrides:
#   FOCUS, SKIP     ginkgo regexes (default \[NodeConformance\], minus Flaky, Slow and
#                   Serial — what upstream's pull-request job runs)
#   PROCS           parallel ginkgo processes (default CPUS)
#   MEM, CPUS       the guest (default 6144 MB, 4)
#   SUITE_TIMEOUT   ginkgo's limit for the whole run (default 2h)
#   KEEP=1          leave the guest running afterwards, to look around (it says how)
#
# It needs KVM: under emulation a run would take most of a day. Without a writable
# /dev/kvm it skips, with a note, as test/k8s.sh does.
set -euo pipefail

cd "$(dirname "$0")/.."
mem="${MEM:-6144}" cpus="${CPUS:-4}"
source test/qemu-lib.sh
MEM="$mem" CPUS="$cpus"

ROOTFS="${1:-${ROOTFS:-output/rootfs.erofs}}"
KERNEL="${2:-${KERNEL:-rootfs/boot/bzImage}}"
INIT="${INIT:-/usr/lib/systemd/systemd}"
FOCUS="${FOCUS:-\[NodeConformance\]}"
SKIP="${SKIP:-\[Flaky\]|\[Slow\]|\[Serial\]}"
PROCS="${PROCS:-$CPUS}"
SUITE_TIMEOUT="${SUITE_TIMEOUT:-2h}"
STATE=output/node-conformance
LOG=output/node-conformance-console.log

if [ ! -w /dev/kvm ]; then
    echo "note: no writable /dev/kvm on this host, skipping node conformance"
    exit 0
fi

qemu_setup
QEMU_HINT="(run ./tools/build-image.sh, or ./tools/fetch-image.sh for CI's)"
qemu_preflight
ARCH="$ARCH" ./tools/build-node-e2e.sh
suite="output/node-e2e/$ARCH"

rm -rf "$STATE"
mkdir -p "$STATE/results"

SSH_DIR="$STATE/ssh" qemu_ssh_setup
VAR_DISK="$STATE/var.img" VAR_SIZE=30G SYSEXTS=kubernetes \
    QEMU_APPEND_EXTRA+=" systemd.hostname=node-e2e" qemu_argv
"$QEMU" "${QEMU_ARGV[@]}" < /dev/null > "$LOG" 2>&1 &
qemu_pid=$!
cleanup() {
    if [ "${KEEP:-0}" = 1 ] && kill -0 "$qemu_pid" 2>/dev/null; then
        echo ">> KEEP=1: the guest is still running (pid $qemu_pid)."
        echo "   ssh -F $STATE/ssh/config flfs      # root; the suite is in /var/lib/node-e2e"
        echo "   kill $qemu_pid; rm -rf $STATE      # when done"
        return
    fi
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    rm -rf "$STATE/ssh" "$STATE/var.img" "$STATE/var.img.machine-id"
}
trap cleanup EXIT

g() { ssh -F "$STATE/ssh/config" -o ServerAliveInterval=30 flfs "$@"; }

echo ">> booting $ROOTFS with $KERNEL and the kubernetes extension, ${MEM} MB, $CPUS vCPUs"
deadline=$((SECONDS + TIMEOUT))
until g true 2>/dev/null; do
    kill -0 "$qemu_pid" 2>/dev/null || { echo "error: the guest exited during boot; see $LOG" >&2; exit 1; }
    [ "$SECONDS" -lt "$deadline" ] || { echo "error: no ssh after ${TIMEOUT}s; see $LOG" >&2; exit 1; }
    sleep 3
done
echo "   kubelet $(g kubelet --version | cut -d' ' -f2), $(g crio --version | awk 'NR == 1 {print "CRI-O " $3}'), $(g crun --version | head -1), kernel $(g uname -r)"

echo ">> the test node's fixtures"
g bash -s <<'GUEST'
set -euo pipefail
systemctl mask --runtime --now kubelet.service

cat > /etc/cni/net.d/10-node-e2e.conflist <<'EOF'
{
  "cniVersion": "1.0.0",
  "name": "node-e2e",
  "plugins": [
    {
      "type": "bridge", "bridge": "cni0", "isGateway": true, "ipMasq": true, "hairpinMode": true,
      "ipam": {"type": "host-local", "routes": [{"dst": "0.0.0.0/0"}], "ranges": [[{"subnet": "10.85.0.0/16"}]]}
    },
    {"type": "portmap", "capabilities": {"portMappings": true}}
  ]
}
EOF

# CRI-O reads one drop-in directory, and the confext's is read-only: a copy of it in /run,
# plus the handler, named on CRI-O's command line for this boot only.
mkdir -p /run/node-e2e/crio.conf.d /run/systemd/system/crio.service.d
cp /etc/crio/crio.conf.d/* /run/node-e2e/crio.conf.d/
cat > /run/node-e2e/crio.conf.d/90-test-handler.conf <<'EOF'
[crio.runtime.runtimes.test-handler]
runtime_path = "/usr/bin/crun"
runtime_root = "/run/crun"
EOF
printf '[Service]\nExecStart=\nExecStart=/usr/bin/crio --config-dir=/run/node-e2e/crio.conf.d\n' \
    > /run/systemd/system/crio.service.d/90-node-e2e.conf
systemctl daemon-reload
systemctl restart crio
crictl info > /dev/null
mkdir -p /var/lib/node-e2e
# The suite looks for the kubelet next to itself.
ln -sfn /usr/bin/kubelet /var/lib/node-e2e/kubelet
GUEST

scp -q -F "$STATE/ssh/config" "$suite/e2e_node.test" "$suite/ginkgo" flfs:/var/lib/node-e2e/

echo ">> running the suite: focus $FOCUS, skip $SKIP, $PROCS processes (full output in $STATE/run.log)"
set +e
g "cd /var/lib/node-e2e && ./ginkgo --no-color --silence-skips --procs=$PROCS --timeout=$SUITE_TIMEOUT \
    --focus=$(printf '%q' "$FOCUS") --skip=$(printf '%q' "$SKIP") ./e2e_node.test -- \
    --container-runtime-endpoint=unix:///run/crio/crio.sock \
    --container-runtime-process-name=/usr/bin/crio --container-runtime-pid-file= \
    --kubelet-flags='--cgroup-driver=systemd --cgroups-per-qos=true --cgroup-root=/ --runtime-cgroups=/system.slice/crio.service' \
    --report-dir=/var/lib/node-e2e/results --prepull-images=false" 2>&1 | tee "$STATE/run.log"
status=${PIPESTATUS[0]}
set -e

g 'journalctl -u crio --no-pager > /var/lib/node-e2e/results/crio.log; tar -C /var/lib/node-e2e -c results' |
    tar -x -C "$STATE" || echo "warning: could not copy the suite's results out of the guest" >&2

# The verdict, from ginkgo's own closing lines: "Ran N of M Specs", the pass/fail counts,
# and under "Summarizing N Failures" each failed spec with its location on the next line.
ran=$(grep -a '^Ran [0-9]* of [0-9]* Specs' "$STATE/run.log" | tail -1 || true)
counts=$(grep -aE '^(SUCCESS|FAIL)! -- ' "$STATE/run.log" | tail -1 || true)
failed=$(sed -n '/^Summarizing [0-9]* Failure/,/^Ran /p' "$STATE/run.log" |
    grep -aE '^  \[(FAIL|TIMEDOUT|PANICKED|INTERRUPTED)\] ' | sed 's/^  //' || true)

echo
echo ">> node conformance on $ARCH: ${ran:-the suite did not finish}"
[ -z "$counts" ] || echo "   $counts"
if [ -n "$failed" ]; then
    echo "   failed:"
    sed 's/^/     /' <<< "$failed"
fi

if [ -n "${GITHUB_ACTIONS:-}" ]; then
    while IFS= read -r spec; do
        [ -n "$spec" ] && echo "::error title=node conformance ($ARCH)::$spec"
    done <<< "$failed"
    if [ "$status" != 0 ] && [ -z "$failed" ]; then
        echo "::error title=node conformance ($ARCH)::the suite exited $status without a list of failures; see run.log"
    fi
    {
        echo "### Node conformance ($ARCH)"
        echo
        echo "${ran:-The suite did not finish (exit $status).}"
        [ -z "$counts" ] || { echo; echo "$counts"; }
        if [ -n "$failed" ]; then
            echo
            sed 's/^/- /' <<< "$failed"
        fi
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi

if [ "$status" != 0 ]; then
    echo ">> node conformance FAILED — $STATE/run.log, $STATE/results/, $LOG" >&2
    exit 1
fi
echo ">> node conformance OK"
