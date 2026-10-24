#!/usr/bin/env bash
# Form a multi-node Kubernetes cluster from the image and check that it works as one.
#
#     ./test/k8s.sh [rootfs.erofs] [bzImage]
#
# tools/k8s-demo.sh does all of it — three guests, kubeadm init and join, a pod network,
# and four replicas behind a Service that a pod then queries by DNS name — and fails on
# its own if any step does: a node that never turns Ready, CoreDNS or kube-proxy that
# never rolls out, or a Service whose answers do not come from more than one node. The
# demo has no fallback for the kernel, so what is checked is the image as built: that
# kubeadm's preflight accepts the kernel (/usr/lib/modules/<release>/config and the
# k8s.config symbols) and that kube-proxy starts with its hostPath /lib/modules.
#
# What the cluster runs on is the image and its kubernetes system extension, as CI built
# them: the pair is next to the image (tools/k8s-demo.sh's EXTENSIONS), merged at boot from
# each node's /var disk, and the pod network is a stock flannel DaemonSet writing through
# the extension's links into /var.
#
# It needs KVM. Three guests running a control plane under emulation take long enough
# that a timeout would say nothing about the image, so without a writable /dev/kvm this
# skips, with a note. It also needs the network: registry.k8s.io, for the control plane's
# and the demo's images.
#
# The consoles end up in output/k8s-test-<node>.log either way, where CI uploads them.
set -euo pipefail

cd "$(dirname "$0")/.."

export ROOTFS="${1:-${ROOTFS:-output/rootfs.erofs}}"
export KERNEL="${2:-${KERNEL:-rootfs/boot/bzImage}}"

if [ ! -w /dev/kvm ]; then
    echo "note: no writable /dev/kvm on this host, skipping the Kubernetes check"
    exit 0
fi

keep_logs() {
    local log
    for log in output/k8s/*.console.log; do
        [ -f "$log" ] && cp "$log" "output/k8s-test-$(basename "$log" .console.log).log"
    done
    ./tools/k8s-demo.sh down > /dev/null
}
trap keep_logs EXIT

./tools/k8s-demo.sh up
./tools/k8s-demo.sh ps
echo ">> k8s OK"
