#!/usr/bin/env bash
# A multi-node Kubernetes cluster out of the flfs image, as a demo: boot NODES guests in
# qemu, turn them into one kubeadm control plane and NODES-1 workers, and run something on
# it that has to cross nodes to work.
#
#     ./tools/k8s-demo.sh up                  # boot and form the cluster, then return
#     ./tools/k8s-demo.sh kubectl get pods -A # kubectl from the host, against it
#     ./tools/k8s-demo.sh ssh 2 [cmd...]      # a root shell on k8s-2
#     ./tools/k8s-demo.sh ps                  # the guests: running or not, ports, memory
#     ./tools/k8s-demo.sh down                # power everything off and delete its state
#
# Kubernetes comes as the image's kubernetes system extension (docs/sysext.md): kubelet,
# kubeadm, kubectl, CRI-O and the CNI plugins built from source by packages/ with
# EXTENSION=kubernetes, assembled into a sysext and a confext by tools/build-image.sh. The
# image itself is unchanged. Both extension images are attached to every node the way the
# root is — read-only disks, one file shared by all of them, verified by dm-verity from a
# table on the kernel command line (SYSEXTS in test/qemu-lib.sh) — and systemd-sysext and
# systemd-confext merge them at boot, CRI-O and kubelet start through the Upholds= the
# extension ships, and the paths kubeadm writes are links into /var. So nothing is copied
# into a guest and nothing on it is set up by hand: what this script does after boot is
# kubeadm and the pod network.
#
# Every node gets a /var disk of its own (VAR_DISK in test/qemu-lib.sh). A node needs
# one in any case — its PKI and identity are there — and the extension refuses a tmpfs.
#
# Networking is one segment with a router on it, the shape of a real network. The router
# is one more guest from the same image, configured by nothing but credentials on its
# command line (boot_router): it is the segment's switch, DHCP server and NAT, and the
# only guest the host reaches directly — ssh to the nodes jumps through it. Each node has
# exactly one NIC, on that segment, and boots the image as it is: its own DHCP asks, the
# router's static lease answers with 10.0.0.1N, and kubelet picks that address because it
# is the only one there is. Nothing about the network is node configuration.
#
# The pod network is flannel, from its pinned release manifest, unmodified but for one
# line: VXLAN between the nodes over the router's segment, with its nftables backend, which
# is what the kernel's k8s.config fragment (packages/kernel/build.sh) is written for, as is
# kube-proxy's nftables mode. A stock CNI DaemonSet is the point: it writes its config to
# /etc/cni/net.d and its plugin to /opt/cni/bin, both links into /var the extension ships,
# and delegates to the extension's bridge and host-local plugins.
#
# Overrides:
#   NODES          number of guests, the first is the control plane   (default 3)
#   CP_MEM         RAM of the control plane in MB                      (default 3072)
#   WORKER_MEM     RAM of each worker in MB                            (default 2048)
#   CPUS           vCPUs per guest                                     (default 2)
#   VAR_SIZE       sparse /var disk per guest                          (default 10G)
#   API_PORT       host port forwarded to the API server               (default 6443)
#   ROUTER_MEM     RAM of the router in MB                             (default 384)
#   ROOTFS, KERNEL the image to boot. By default this checkout's own build when there is
#                  one — output/rootfs.erofs from tools/build-image.sh, with the kernel
#                  it was assembled from in rootfs/boot — and otherwise the one
#                  tools/fetch-image.sh downloaded from CI (OUT, ARCH as for
#                  tools/boot-qemu.sh)
#   EXTENSIONS     where extensions/kubernetes.raw and confexts/kubernetes.raw are: by
#                  default next to ROOTFS, which is where both tools/build-image.sh and
#                  tools/fetch-image.sh put them
#
# kubectl runs on the control plane, over ssh, so the host needs no Kubernetes binaries.
# For a kubectl of your own, output/k8s/kubeconfig points at the API server's forward.
#
# State lives in output/k8s/: console logs, the /var disks, the ssh key and config and the
# kubeconfig. `down` removes it; `up` starts from nothing every time.
set -Eeuo pipefail

cd "$(dirname "$0")/.."
source test/qemu-lib.sh

NODES="${NODES:-3}"
CP_MEM="${CP_MEM:-3072}"
WORKER_MEM="${WORKER_MEM:-2048}"
VAR_SIZE="${VAR_SIZE:-10G}"
API_PORT="${API_PORT:-6443}"
ROUTER_MEM="${ROUTER_MEM:-384}"

STATE=output/k8s
POD_CIDR=10.244.0.0/16   # flannel's "Network" in its manifest, which has to agree
SVC_CIDR=10.96.0.0/12

node_name() { echo "k8s-$1"; }
node_ip()   { echo "10.0.0.$((10 + $1))"; }
node_mac()  { printf '52:54:00:6b:38:%02x' "$1"; }   # 0 is the router's
ROUTER=k8s-router
ROUTER_IP=10.0.0.1

say() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }

# ssh into node N as root.
node_ssh() {
    local n="$1"; shift
    ssh -o ConnectTimeout=10 -F "$STATE/ssh_config" "$(node_name "$n")" "$*"
}

# Run "$@" once per node, in parallel, prefixing each line with the node's name, and
# fail if any of them did. $1 is the first node, so workers can be done without node 1.
on_nodes() { # first-node command...
    local first="$1" n pids=() failed=0; shift
    for n in $(seq "$first" "$NODES"); do
        ( "$@" "$n" 2>&1 | sed -u "s/^/[$(node_name "$n")] /"; exit "${PIPESTATUS[0]}" ) &
        pids+=($!)
    done
    for n in "${pids[@]}"; do wait "$n" || failed=1; done
    return "$failed"
}

# Wait until "$@" succeeds, for up to $1 seconds.
retry() { # seconds command...
    local until=$((SECONDS + $1)); shift
    until "$@" >/dev/null 2>&1; do
        [ "$SECONDS" -lt "$until" ] || { echo "error: timed out waiting for: $*" >&2; return 1; }
        sleep 3
    done
}

# --- the guests --------------------------------------------------------------------------

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# The router: the same image again, and the only guest the host can reach directly. Its
# qemu holds the cluster segment — a hub with one unix stream socket per node, so it is
# the segment's switch — and its user-mode NIC is the way out, with the demo's only two
# port forwards (ssh to the router, the API server). Everything it does as a router is
# systemd-networkd and systemd-socket-proxyd, handed in as credentials:
#
#   - 10.0.0.1 on the segment, a DHCP server whose static leases give node N the address
#     node_ip N by its MAC, and a masquerade out through the user-mode NIC. DNS is qemu's
#     resolver, which the nodes reach through that masquerade.
#   - The API server forward: a socket unit on 6443 relaying to node 1.
#
# slirp itself cannot be on the segment — a hub floods, slirp sees the SYNs between nodes,
# tries the same connections on the host's network and resets them — which is why the
# router is a guest and not qemu's NAT (docs/sysext.md, "The demo's network").
boot_router() {
    local n lan socket service segment=()

    SSH_DIR="$STATE/ssh"
    qemu_ssh_setup
    sed "s/^Host flfs$/Host $ROUTER/" "$SSH_DIR/config" > "$STATE/ssh_config"
    # The authorized key, for the nodes, which get the same one.
    KEY_CREDENTIAL="$QEMU_APPEND_EXTRA"
    QEMU_NIC_EXTRA+=",hostfwd=tcp:127.0.0.1:$API_PORT-:6443"

    lan="[Match]
MACAddress=$(node_mac 0)

[Network]
Address=$ROUTER_IP/24
DHCPServer=yes
IPMasquerade=ipv4
LinkLocalAddressing=no
IPv6AcceptRA=no

[DHCPServer]
PoolOffset=100
EmitDNS=yes
DNS=10.0.2.3
"
    for n in $(seq 1 "$NODES"); do
        lan+="
[DHCPServerStaticLease]
MACAddress=$(node_mac "$n")
Address=$(node_ip "$n")
"
    done
    socket="[Socket]
ListenStream=6443
"
    service="[Service]
ExecStart=/usr/lib/systemd/systemd-socket-proxyd $(node_ip 1):6443
"
    QEMU_APPEND_EXTRA+=" systemd.hostname=$ROUTER"
    QEMU_APPEND_EXTRA+=" systemd.set_credential_binary=network.network.10-k8s-lan:$(b64 "$lan")"
    QEMU_APPEND_EXTRA+=" systemd.set_credential_binary=systemd.extra-unit.k8s-api.socket:$(b64 "$socket")"
    QEMU_APPEND_EXTRA+=" systemd.set_credential_binary=systemd.extra-unit.k8s-api.service:$(b64 "$service")"
    QEMU_APPEND_EXTRA+=" systemd.wants=k8s-api.socket"

    for n in $(seq 1 "$NODES"); do
        segment+=(-netdev "stream,id=node$n,server=on,addr.type=unix,addr.path=$STATE/$(node_name "$n").sock"
                  -netdev "hubport,id=port$n,hubid=0,netdev=node$n")
    done
    segment+=(-netdev hubport,id=lan,hubid=0 -device "virtio-net-pci,netdev=lan,mac=$(node_mac 0)")

    VAR_DISK= MEM="$ROUTER_MEM" CPUS=1 qemu_argv
    "$QEMU" "${QEMU_ARGV[@]}" "${segment[@]}" \
        -pidfile "$STATE/$ROUTER.pid" \
        < /dev/null > "$STATE/$ROUTER.console.log" 2>&1 &
    echo "   $ROUTER  $ROUTER_IP  ${ROUTER_MEM} MB  ssh on 127.0.0.1:$SSH_PORT, API server on 127.0.0.1:$API_PORT"

    # A node's NIC connects to its socket once, at start, so the router has to be
    # listening first.
    for n in $(seq 1 "$NODES"); do retry 10 test -S "$STATE/$(node_name "$n").sock"; done
}

# One node: the same machine tools/boot-qemu.sh boots (qemu_argv), plus a /var disk, a
# hostname and the kubernetes extension, with its one NIC on the router's segment instead
# of a NAT of its own. Nothing about the network is configured on the node: the image's
# own 20-wired.network asks for DHCP, and the router's static lease answers. In the
# background, with its console in output/k8s/k8s-N.console.log and its pid in
# output/k8s/k8s-N.pid.
boot_node() {
    local n="$1" name ip
    name=$(node_name "$n") ip=$(node_ip "$n")

    sed -e "s/^Host flfs$/Host $name/" -e "s/^    HostName 127.0.0.1$/    HostName $ip\n    ProxyJump $ROUTER/" \
        -e '/^    Port /d' "$STATE/ssh/config" >> "$STATE/ssh_config"
    QEMU_APPEND_EXTRA="$KEY_CREDENTIAL systemd.hostname=$name"
    QEMU_NIC_ARGS=(-netdev "stream,id=net0,server=off,addr.type=unix,addr.path=$STATE/$name.sock"
                   -device "virtio-net-pci,netdev=net0,mac=$(node_mac "$n")")

    VAR_DISK="$STATE/$name-var.img"
    if [ "$n" = 1 ]; then MEM="$CP_MEM"; else MEM="$WORKER_MEM"; fi
    SYSEXTS=kubernetes qemu_argv

    "$QEMU" "${QEMU_ARGV[@]}" \
        -pidfile "$STATE/$name.pid" \
        < /dev/null > "$STATE/$name.console.log" 2>&1 &
    echo "   $name  $ip  ${MEM} MB"
}

# --- the cluster -------------------------------------------------------------------------

init_control_plane() {
    local hex
    hex=$(od -An -tx1 -N11 /dev/urandom | tr -d ' \n')
    TOKEN="${hex:0:6}.${hex:6:16}"
    node_ssh 1 "cat > /run/kubeadm.yaml" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
bootstrapTokens:
  - token: $TOKEN
localAPIEndpoint:
  advertiseAddress: $(node_ip 1)
  bindPort: 6443
nodeRegistration:
  name: $(node_name 1)
  criSocket: unix:///run/crio/crio.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: $K8S_VERSION
clusterName: flfs
networking:
  podSubnet: $POD_CIDR
  serviceSubnet: $SVC_CIDR
apiServer:
  certSANs: [127.0.0.1, localhost]
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: nftables
EOF
    node_ssh 1 "kubeadm init --config /run/kubeadm.yaml"

    # The admin kubeconfig, pointed at the host's forward rather than the cluster segment
    # the host cannot reach.
    node_ssh 1 cat /etc/kubernetes/admin.conf |
        sed "s#server: https://.*#server: https://127.0.0.1:$API_PORT#" > "$STATE/kubeconfig"
    chmod 600 "$STATE/kubeconfig"

    CA_HASH="sha256:$(node_ssh 1 "openssl x509 -pubkey -noout -in /etc/kubernetes/pki/ca.crt |
        openssl pkey -pubin -outform der | sha256sum" | cut -d' ' -f1)"
}

join_worker() {
    local n="$1"
    node_ssh "$n" "cat > /run/kubeadm.yaml" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: $(node_ip 1):6443
    token: $TOKEN
    caCertHashes: [$CA_HASH]
nodeRegistration:
  name: $(node_name "$n")
  criSocket: unix:///run/crio/crio.sock
EOF
    node_ssh "$n" "kubeadm join --config /run/kubeadm.yaml"
}

# kubectl on the control plane, with the admin kubeconfig kubeadm wrote there. Each
# argument is quoted for the remote shell; stdin goes along, for `apply -f -`.
k() { node_ssh 1 "kubectl --kubeconfig=/etc/kubernetes/admin.conf $(printf '%q ' "$@")"; }

# flannel's release manifest, pinned to the bytes it had when FLANNEL_VERSION was chosen
# and kept in downloads/k8s/. One line differs from upstream's: the nftables backend, for a
# kernel with no legacy iptables tables (packages/kernel/build.sh) — checked, so that a
# manifest whose default moved is an error rather than a silent no-op.
FLANNEL_VERSION=v0.28.10
FLANNEL_SHA256=393bdbce53eb50c8eb97dd513b218518b7d6e7985dc7b889be956e112a711084
flannel_manifest() {
    local file="downloads/k8s/kube-flannel-$FLANNEL_VERSION.yml"
    mkdir -p downloads/k8s
    if [ ! -f "$file" ]; then
        "${CURL_DOWNLOAD[@]}" -o "$file.part" \
            "https://github.com/flannel-io/flannel/releases/download/$FLANNEL_VERSION/kube-flannel.yml"
        mv "$file.part" "$file"
    fi
    echo "$FLANNEL_SHA256  $file" | sha256sum --check --quiet || {
        echo "error: $file is not the manifest $FLANNEL_VERSION was pinned to — delete it and try again" >&2
        rm -f "$file"
        exit 1
    }
    grep -q '"EnableNFTables": false' "$file" || { echo "error: $file has no EnableNFTables line to set" >&2; exit 1; }
    sed 's/"EnableNFTables": false/"EnableNFTables": true/' "$file"
}

# flannel takes the /24 the controller manager gives each node, writes the CNI config and
# installs its plugin through the extension's links into /var, and routes between nodes
# over VXLAN; a node turns Ready once its config exists.
pod_network() {
    flannel_manifest | k apply -f -
    k -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=300s
    local n
    for n in $(seq 1 "$NODES"); do
        echo "   $(node_name "$n")  pods in $(k get node "$(node_name "$n")" -o jsonpath='{.spec.podCIDR}'), $(node_ssh "$n" ls /etc/cni/net.d | tr '\n' ' ')"
    done
}

# Something that only works if the cluster does: four replicas of agnhost's HTTP server
# (the Kubernetes e2e tests' own utility image), spread over the workers, behind a
# Service. Then one pod asks the Service, by its DNS name, who it is talking to — which
# goes pod → CoreDNS → kube-proxy's nftables → a pod on whichever node, and back.
demo() {
    say "Deploying the demo: 4 × agnhost netexec behind Service 'hello'"
    k apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
spec:
  replicas: 4
  selector:
    matchLabels: {app: hello}
  template:
    metadata:
      labels: {app: hello}
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: {app: hello}
      containers:
        - name: agnhost
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args: [netexec, --http-port=8080]
          ports: [{containerPort: 8080}]
          readinessProbe:
            httpGet: {path: /healthz, port: 8080}
---
apiVersion: v1
kind: Service
metadata:
  name: hello
spec:
  selector: {app: hello}
  ports: [{port: 80, targetPort: 8080}]
EOF
    k rollout status deployment/hello --timeout=300s
    k get pods -l app=hello -o wide

    local pod ip node where
    pod=$(k get pods -l app=hello -o jsonpath='{.items[0].metadata.name}')
    ip=$(k get pod "$pod" -o jsonpath='{.status.podIP}')
    node=$(k get pod "$pod" -o jsonpath='{.spec.nodeName}')
    where=$(k get pods -l app=hello -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}')
    say "From pod $pod on $node: 32 requests to http://hello.default.svc.cluster.local/hostname"
    # netexec's /dial makes the requests from inside the pod and reports who answered.
    local answers count name nodes want
    answers=$(node_ssh 1 "curl -fsS 'http://$ip:8080/dial?request=hostname&protocol=http&host=hello.default.svc.cluster.local&port=80&tries=32'" |
        grep -o '"hello-[a-z0-9-]*"' | tr -d '"' | sort | uniq -c || true)
    while read -r count name; do
        [ -n "$name" ] || continue
        printf '   %2d × %s on %s\n' "$count" "$name" "$(awk -v p="$name" '$1 == p {print $2}' <<< "$where")"
    done <<< "$answers"

    # The point of the demo, checked: the answers came from more than one node, so the
    # Service reached across the cluster network. With pods on two workers, all 32
    # requests landing on one node's pods by chance is (3/4)^32 at worst — 1 in 10^4.
    nodes=$(awk '{print $2}' <<< "$answers" | while read -r name; do
        [ -z "$name" ] || awk -v p="$name" '$1 == p {print $2}' <<< "$where"
    done | sort -u | wc -l)
    want=$(( NODES - 1 < 2 ? NODES - 1 : 2 ))
    if [ "$nodes" -lt "$want" ]; then
        echo "error: the Service answered from $nodes node(s), expected $want" >&2
        return 1
    fi
}

# --- commands ----------------------------------------------------------------------------

# One line per guest this state directory knows about: whether its qemu is still alive,
# how long it has been up and how much of the host's memory it really uses (the RSS, not
# the -m it was given), where to reach it, and what the cluster thinks of it. The last
# column is asked of the API server with a short timeout, so a cluster that is down or
# still forming shows "-" rather than hanging the command.
ps_nodes() {
    local pidfile name pid state up rss mem address ssh role ready nodes=""
    [ -n "$(ls "$STATE"/*.pid 2>/dev/null)" ] || { echo "no guests (./tools/k8s-demo.sh up)"; return 0; }
    nodes=$(k get nodes --request-timeout=5s --no-headers 2>/dev/null || true)
    printf '%-10s %-8s %-8s %-11s %-10s %-11s %-16s %-14s %s\n' \
        NODE PID STATE UP ADDRESS RSS/RAM SSH ROLE STATUS
    for pidfile in "$STATE"/k8s-*.pid; do
        name=$(basename "$pidfile" .pid)
        pid=$(cat "$pidfile")
        state=exited up=- rss=-
        if kill -0 "$pid" 2>/dev/null; then
            state=running
            up=$(ps -o etime= -p "$pid" | tr -d ' ')
            rss="$(( $(ps -o rss= -p "$pid") / 1024 ))M"
        fi
        mem=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n '/^-m$/{n;p;q}')
        if [ "$name" = "$ROUTER" ]; then
            address=$ROUTER_IP role=router
            ssh="127.0.0.1:$(awk -v h="$name" '$1 == "Host" {on = ($2 == h)} on && $1 == "Port" {print $2; exit}' "$STATE/ssh_config")"
        else
            address=$(node_ip "${name#k8s-}") ssh="via $ROUTER"
            role=$(awk -v n="$name" '$1 == n {print ($3 == "<none>" ? "worker" : $3)}' <<< "$nodes")
        fi
        ready=$(awk -v n="$name" '$1 == n {print $2}' <<< "$nodes")
        printf '%-10s %-8s %-8s %-11s %-10s %-11s %-16s %-14s %s\n' \
            "$name" "$pid" "$state" "$up" "$address" "$rss/${mem:--}M" \
            "$ssh" "${role:--}" "${ready:--}"
    done
}

down() {
    local pidfile
    local pidfile pid
    for pidfile in "$STATE"/*.pid; do
        [ -f "$pidfile" ] || continue
        pid=$(cat "$pidfile")
        kill "$pid" 2>/dev/null || continue
        # Gone before its ports and its place on the cluster segment are reused.
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    done
    rm -rf "$STATE"
}

up() {
    qemu_setup
    if [ -z "${ROOTFS:-}${KERNEL:-}" ] && [ "$ARCH" = "$(normalize_arch)" ] &&
       [ -f output/rootfs.erofs ] && [ -f rootfs/boot/bzImage ]; then
        ROOTFS=output/rootfs.erofs KERNEL=rootfs/boot/bzImage
    fi
    fetched_image_defaults
    QEMU_HINT="(run ./tools/build-image.sh, or ./tools/fetch-image.sh for CI's)"
    qemu_preflight
    EXTENSIONS="${EXTENSIONS:-$(dirname "$ROOTFS")}"
    local f
    for f in extensions/kubernetes.raw confexts/kubernetes.raw; do
        [ -f "$EXTENSIONS/$f" ] || {
            echo "error: missing $EXTENSIONS/$f (./tools/build-image.sh builds it with the image," >&2
            echo "       ./tools/fetch-image.sh downloads CI's)" >&2
            exit 1
        }
    done
    [ "$NODES" -ge 2 ] || { echo "error: NODES=$NODES — a multi-node cluster needs at least 2" >&2; exit 1; }
    [ -w /dev/kvm ] || echo "warning: no KVM — $NODES emulated guests will take a long time to do this"

    down
    mkdir -p "$STATE"
    trap 'echo; echo ">> failed — consoles are in $STATE/*.console.log; ./tools/k8s-demo.sh down when done" >&2' ERR

    say "Booting $NODES nodes from $ROOTFS with $KERNEL, and the kubernetes extension from $EXTENSIONS"
    boot_router
    local n
    for n in $(seq 1 "$NODES"); do boot_node "$n"; done
    for n in $(seq 1 "$NODES"); do retry "$TIMEOUT" node_ssh "$n" true; done

    # What the extension started by itself, through Upholds=. kubelet is up but waiting
    # for kubeadm, so CRI-O answering is the readiness that matters.
    say "CRI-O from the extension, on every node"
    for n in $(seq 1 "$NODES"); do retry 120 node_ssh "$n" crictl info; done
    K8S_VERSION=$(node_ssh 1 kubelet --version | awk '{print $2}')
    echo "   kubelet $K8S_VERSION, $(node_ssh 1 crio --version | awk 'NR == 1 {print "CRI-O " $3}'), $(node_ssh 1 crun --version | head -1)"

    say "kubeadm init on $(node_name 1)"
    init_control_plane

    say "kubeadm join on the workers"
    on_nodes 2 join_worker

    say "Pod network: flannel $FLANNEL_VERSION"
    pod_network
    k wait --for=condition=Ready nodes --all --timeout=300s
    # kube-proxy too: a worker that joined seconds ago may not have its Service rules yet,
    # and the demo would then only ever reach the pods on its own node.
    k -n kube-system rollout status deployment/coredns --timeout=300s
    k -n kube-system rollout status daemonset/kube-proxy --timeout=300s

    say "The cluster"
    k get nodes -o wide
    echo
    k get pods -A -o wide

    demo

    trap - ERR
    cat <<EOF

>> The cluster is up and stays up. From here:

   ./tools/k8s-demo.sh kubectl get pods -A     # or: export KUBECONFIG=$STATE/kubeconfig
   ./tools/k8s-demo.sh ssh 1                   # root on $(node_name 1); also: ssh -F $STATE/ssh_config $(node_name 2)
   ./tools/k8s-demo.sh down                    # power off and delete $STATE
EOF
}

case "${1:-}" in
    up)      up ;;
    down)    down; echo ">> cluster gone" ;;
    kubectl) shift; k "$@" ;;
    ps)      ps_nodes ;;
    ssh)     shift; n="${1:?usage: $0 ssh <node number> [command...]}"; shift
             if [ $# -gt 0 ]; then node_ssh "$n" "$@"
             else exec ssh -F "$STATE/ssh_config" "$(node_name "$n")"; fi ;;
    *)       sed -n '2,/^set -E/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
