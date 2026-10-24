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
# Nothing Kubernetes is compiled here and nothing in the image changes. The upstream
# release binaries — kubeadm, kubelet and kubectl from dl.k8s.io, CRI-O's static bundle
# for the CRI — are downloaded on the host into downloads/k8s/, checked against the
# checksums published next to them, and copied into each guest's /var over ssh. The
# container runtime underneath CRI-O is the image's own: crun (/usr/bin/crun) and conmon
# (/usr/libexec/podman/conmon), not the copies the bundle carries.
#
# What it takes from the image, and what it has to work around:
#
#   - The root is a read-only, dm-verity-checked EROFS, and kubeadm hardcodes
#     /etc/kubernetes. So each node lays an overlayfs over /etc whose upper half is on
#     /var — the biggest demo-only liberty here. Everything the cluster wrote into /etc
#     is in /var/lib/flfs-k8s/etc-upper on that node, and nowhere else.
#   - /usr is read-only too, so the binaries live in /var/lib/flfs-k8s/bin and the units
#     in /run/systemd/system; kubelet's and the controller manager's FlexVolume
#     directory (/usr/libexec/kubernetes by default, created at start) is moved under
#     /var/lib/kubelet.
#   - Every guest gets a /var disk of its own (VAR_DISK in test/qemu-lib.sh), because
#     the control plane's images and etcd do not fit comfortably in a RAM /var.
#
# Networking. qemu's user-mode NIC, which every guest gets from test/qemu-lib.sh, is a
# private NAT per guest: outbound works, guests cannot see each other, and all of them are
# 10.0.2.15. So each guest gets a second NIC on a shared L2 segment — qemu's multicast
# socket backend, which needs no root and no bridge on the host — with a static address
# 10.0.0.1N, handed to systemd-networkd as a network.network.* credential at boot. The
# cluster runs on that segment (kubelet's --node-ip, the API server's advertise address);
# image pulls go out through the user-mode NIC as before.
#
# Pod networking is deliberately the dullest thing that works, so that the demo is about
# the image rather than a CNI: the bridge and host-local plugins from CRI-O's bundle, one
# /24 per node as the controller manager allocates them, a static route per peer node
# across the shared segment, and a masquerade for traffic leaving the pod network. No
# CNI daemonset, nothing to pull for it. kube-proxy runs in nftables mode, which is what
# the kernel's k8s.config fragment (packages/kernel/build.sh) is written for.
#
# Overrides:
#   NODES          number of guests, the first is the control plane   (default 3)
#   CP_MEM         RAM of the control plane in MB                      (default 3072)
#   WORKER_MEM     RAM of each worker in MB                            (default 2048)
#   CPUS           vCPUs per guest                                     (default 2)
#   VAR_SIZE       sparse /var disk per guest                          (default 10G)
#   K8S_VERSION    kubeadm/kubelet/kubectl release                     (default below)
#   CRIO_VERSION   CRI-O release; its minor has to match Kubernetes'   (default below)
#   API_PORT       host port forwarded to the API server               (default 6443)
#   MCAST          multicast group:port of the cluster segment         (default 230.0.0.1:12345)
#   ROOTFS, KERNEL the image to boot. By default this checkout's own build when there is
#                  one — output/rootfs.erofs from tools/build-image.sh, with the kernel
#                  it was assembled from in rootfs/boot — and otherwise the one
#                  tools/fetch-image.sh downloaded from CI (OUT, ARCH as for
#                  tools/boot-qemu.sh)
#
# State lives in output/k8s/: console logs, the /var disks, the ssh key and config, the
# kubeconfig and a host kubectl. `down` removes it; `up` starts from nothing every time.
set -Eeuo pipefail

cd "$(dirname "$0")/.."
source test/qemu-lib.sh

K8S_VERSION="${K8S_VERSION:-v1.37.1}"
CRIO_VERSION="${CRIO_VERSION:-v1.37.2}"
NODES="${NODES:-3}"
CP_MEM="${CP_MEM:-3072}"
WORKER_MEM="${WORKER_MEM:-2048}"
VAR_SIZE="${VAR_SIZE:-10G}"
API_PORT="${API_PORT:-6443}"
MCAST="${MCAST:-230.0.0.1:12345}"

STATE=output/k8s
DL=downloads/k8s
POD_CIDR=10.244.0.0/16
SVC_CIDR=10.96.0.0/12
# Where everything goes in a guest. /var is the only writable disk it has.
GUEST_DIR=/var/lib/flfs-k8s

node_name() { echo "k8s-$1"; }
node_ip()   { echo "10.0.0.$((10 + $1))"; }
node_mac()  { printf '52:54:00:6b:38:%02x' "$1"; }

say() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }

# ssh into node N as root, with the cluster's binaries on PATH.
node_ssh() {
    local n="$1"; shift
    ssh -o ConnectTimeout=10 -F "$STATE/ssh_config" "$(node_name "$n")" "export PATH=$GUEST_DIR/bin:\$PATH; $*"
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

# --- downloads ---------------------------------------------------------------------------

# Every file is checked against the checksum its publisher puts next to it, and kept in
# downloads/k8s/ so a second `up` downloads nothing.
download() { # url file sha256-url
    local url="$1" out="$DL/$2" sum
    if [ ! -f "$out" ]; then
        echo "   $url"
        "${CURL_DOWNLOAD[@]}" -o "$out.part" "$url"
        mv "$out.part" "$out"
    fi
    sum=$(fetch "$3" | awk '{print $1}')
    echo "$sum  $out" | sha256sum --check --quiet || {
        echo "error: checksum mismatch for $out — delete it and try again" >&2
        rm -f "$out"
        exit 1
    }
}

fetch_binaries() {
    say "Fetching Kubernetes $K8S_VERSION and CRI-O $CRIO_VERSION for $ARCH"
    mkdir -p "$DL/$K8S_VERSION-$ARCH"
    local b
    for b in kubeadm kubelet kubectl; do
        download "https://dl.k8s.io/release/$K8S_VERSION/bin/linux/$ARCH/$b" \
            "$K8S_VERSION-$ARCH/$b" \
            "https://dl.k8s.io/release/$K8S_VERSION/bin/linux/$ARCH/$b.sha256"
    done
    local crio="cri-o.$ARCH.$CRIO_VERSION.tar.gz"
    download "https://storage.googleapis.com/cri-o/artifacts/$crio" "$crio" \
        "https://storage.googleapis.com/cri-o/artifacts/$crio.sha256sum"

    # What goes into each guest, as one directory: the three Kubernetes binaries, CRI-O,
    # pinns and crictl from the bundle (not its crun, runc or conmon — the image has
    # those), the CNI plugins, and the script that sets a node up.
    local payload="$STATE/payload"
    rm -rf "$payload"
    mkdir -p "$payload/bin" "$payload/cni/bin"
    install -m 755 "$DL/$K8S_VERSION-$ARCH"/kube{adm,let,ctl} "$payload/bin/"
    tar -xzf "$DL/$crio" -C "$payload" --strip-components=2 \
        cri-o/bin/crio cri-o/bin/pinns cri-o/bin/crictl
    mv "$payload"/{crio,pinns,crictl} "$payload/bin/"
    tar -xzf "$DL/$crio" -C "$payload/cni/bin" --strip-components=2 \
        cri-o/cni-plugins/bridge cri-o/cni-plugins/host-local \
        cri-o/cni-plugins/loopback cri-o/cni-plugins/portmap
    write_node_setup > "$payload/setup-node.sh"

    # kubectl for the host as well, when the host can run it.
    if [ "$(uname -s)" = Linux ]; then
        install -m 755 "$DL/$K8S_VERSION-$ARCH/kubectl" "$STATE/kubectl"
    fi
}

# --- the guests --------------------------------------------------------------------------

# SSH_PORT: the first port from 2222 nothing listens on and no earlier node was given.
# Not in a subshell, so that the ports taken so far are remembered: the guests are all
# launched before any of them has bound its forward.
pick_ssh_port() {
    SSH_PORT=2222
    while (exec 9<>"/dev/tcp/127.0.0.1/$SSH_PORT") 2>/dev/null || [[ " ${TAKEN_PORTS:-} " == *" $SSH_PORT "* ]]; do
        SSH_PORT=$((SSH_PORT + 1))
    done
    TAKEN_PORTS="${TAKEN_PORTS:-} $SSH_PORT"
}

# One guest: the same machine tools/boot-qemu.sh boots (qemu_argv), plus a /var disk, a
# hostname, the cluster NIC and its static address. In the background, with its console
# in output/k8s/k8s-N.console.log and its pid in output/k8s/k8s-N.pid.
boot_node() {
    local n="$1" name ip mac network
    name=$(node_name "$n") ip=$(node_ip "$n") mac=$(node_mac "$n")

    SSH_DIR="$STATE/ssh/$name"
    pick_ssh_port
    qemu_ssh_setup
    sed "s/^Host flfs$/Host $name/" "$SSH_DIR/config" >> "$STATE/ssh_config"
    [ "$n" != 1 ] || QEMU_NIC_EXTRA+=",hostfwd=tcp:127.0.0.1:$API_PORT-:6443"

    # The address on the cluster segment, as a .network file systemd-network-generator
    # puts into /run/systemd/network at boot. 10- sorts before the image's 20-wired, so
    # this NIC is not also asked to DHCP on a segment that has no server.
    network="[Match]
MACAddress=$mac

[Network]
Address=$ip/24
LinkLocalAddressing=no
IPv6AcceptRA=no
"
    QEMU_APPEND_EXTRA+=" systemd.hostname=$name"
    QEMU_APPEND_EXTRA+=" systemd.set_credential_binary=network.network.10-k8s-cluster:$(printf '%s' "$network" | base64 | tr -d '\n')"

    VAR_DISK="$STATE/$name-var.img"
    if [ "$n" = 1 ]; then MEM="$CP_MEM"; else MEM="$WORKER_MEM"; fi
    qemu_argv

    "$QEMU" "${QEMU_ARGV[@]}" \
        -netdev "socket,id=cluster,mcast=$MCAST,localaddr=127.0.0.1" \
        -device "virtio-net-pci,netdev=cluster,mac=$mac" \
        -pidfile "$STATE/$name.pid" \
        < /dev/null > "$STATE/$name.console.log" 2>&1 &
    echo "   $name  $ip  ${MEM} MB  ssh on 127.0.0.1:$SSH_PORT$([ "$n" != 1 ] || echo ", API server on 127.0.0.1:$API_PORT")"
}

# The script each guest runs, as root, once its payload is in $GUEST_DIR. Takes the
# node's own cluster address.
write_node_setup() {
    cat <<EOF
#!/bin/bash
set -Eeuo pipefail
GUEST_DIR=$GUEST_DIR
POD_CIDR=$POD_CIDR
EOF
    cat <<'EOF'
NODE_IP="$1"

# A writable /etc, layered over the read-only one, its changes kept on the /var disk.
if [ "$(stat -f -c %T /etc)" != overlayfs ]; then
    mkdir -p "$GUEST_DIR/etc-upper" "$GUEST_DIR/etc-work"
    mount -t overlay overlay \
        -o "lowerdir=/etc,upperdir=$GUEST_DIR/etc-upper,workdir=$GUEST_DIR/etc-work" /etc
fi

cat > /etc/profile.d/flfs-k8s.sh <<PROFILE
export PATH=$GUEST_DIR/bin:\$PATH
export KUBECONFIG=/etc/kubernetes/admin.conf
PROFILE

# CRI-O on the image's crun and conmon. The policy and registries are podman's, which the
# image already ships in /etc/containers.
mkdir -p /etc/crio/crio.conf.d /etc/cni/net.d
cat > /etc/crio/crio.conf.d/10-flfs.conf <<CONF
[crio.runtime]
default_runtime = "crun"
pinns_path = "$GUEST_DIR/bin/pinns"

[crio.runtime.runtimes.crun]
runtime_path = "/usr/bin/crun"
runtime_root = "/run/crun"
monitor_path = "/usr/libexec/podman/conmon"

[crio.image]
signature_policy = "/etc/containers/policy.json"

[crio.network]
network_dir = "/etc/cni/net.d/"
plugin_dirs = ["$GUEST_DIR/cni/bin"]
CONF
cat > /etc/crictl.yaml <<CONF
runtime-endpoint: unix:///run/crio/crio.sock
CONF

# The units go in /run: the unit search path's writable directory that needs no /etc,
# and the right lifetime for a demo.
cat > /run/systemd/system/crio.service <<UNIT
[Unit]
Description=Container Runtime Interface for OCI (CRI-O)
Wants=network-online.target
After=network-online.target
Before=kubelet.service

[Service]
Type=notify
ExecStart=$GUEST_DIR/bin/crio
ExecReload=/bin/kill -s HUP \$MAINPID
TasksMax=infinity
LimitNOFILE=1048576
OOMScoreAdjust=-999
TimeoutStartSec=0
Restart=on-failure
RestartSec=10
UNIT

# kubeadm's own unit and drop-in, folded into one: kubeadm writes the flags and the
# config, then restarts this.
cat > /run/systemd/system/kubelet.service <<UNIT
[Unit]
Description=kubelet: The Kubernetes Node Agent
Wants=network-online.target crio.service
After=network-online.target crio.service

[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
ExecStart=$GUEST_DIR/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# Pod traffic leaving the pod network leaves as the node; pod to pod, across nodes,
# keeps its own address (the per-node routes added once podCIDRs are known).
nft -f - <<NFT
table ip flfs-k8s
delete table ip flfs-k8s
table ip flfs-k8s {
    chain postrouting {
        type nat hook postrouting priority srcnat + 10;
        ip saddr $POD_CIDR ip daddr != $POD_CIDR masquerade
    }
}
NFT

systemctl daemon-reload
systemctl enable --runtime kubelet.service
systemctl start crio.service
echo "CRI-O is up on $(crun --version | head -1); node address $NODE_IP"
EOF
}

provision_node() {
    local n="$1"
    tar -C "$STATE/payload" --owner=0 --group=0 --numeric-owner -cf - . | node_ssh "$n" "mkdir -p $GUEST_DIR && tar -C $GUEST_DIR -xf -"
    node_ssh "$n" "bash $GUEST_DIR/setup-node.sh $(node_ip "$n")"
}

# --- the cluster -------------------------------------------------------------------------

init_control_plane() {
    local hex
    hex=$(od -An -tx1 -N11 /dev/urandom | tr -d ' \n')
    TOKEN="${hex:0:6}.${hex:6:16}"
    node_ssh 1 "cat > $GUEST_DIR/kubeadm.yaml" <<EOF
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
  kubeletExtraArgs:
    - name: node-ip
      value: $(node_ip 1)
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
controllerManager:
  extraArgs:
    - name: flex-volume-plugin-dir
      value: /var/lib/kubelet/volumeplugins
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
volumePluginDir: /var/lib/kubelet/volumeplugins
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: nftables
EOF
    node_ssh 1 "kubeadm init --config $GUEST_DIR/kubeadm.yaml"

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
    node_ssh "$n" "cat > $GUEST_DIR/kubeadm.yaml" <<EOF
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
  kubeletExtraArgs:
    - name: node-ip
      value: $(node_ip "$n")
EOF
    node_ssh "$n" "kubeadm join --config $GUEST_DIR/kubeadm.yaml"
}

k() { "$STATE/kubectl" --kubeconfig "$STATE/kubeconfig" "$@"; }

has_pod_cidr() {
    [ -n "$(k get node "$(node_name "$1")" -o jsonpath='{.spec.podCIDR}')" ]
}

# Once the controller manager has given every node its /24: each node bridges its own pods
# and routes every other node's /24 to that node across the cluster segment. CRI-O picks
# the config up from /etc/cni/net.d by itself, and the node turns Ready.
pod_network() {
    local n m cidr
    for n in $(seq 1 "$NODES"); do retry 120 has_pod_cidr "$n"; done
    for n in $(seq 1 "$NODES"); do
        cidr=$(k get node "$(node_name "$n")" -o jsonpath='{.spec.podCIDR}')
        echo "   $(node_name "$n")  pods in $cidr"
        node_ssh "$n" "cat > /etc/cni/net.d/10-flfs.conflist" <<EOF
{
  "cniVersion": "1.0.0",
  "name": "flfs",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": false,
      "hairpinMode": true,
      "ipam": {
        "type": "host-local",
        "ranges": [[{ "subnet": "$cidr" }]],
        "routes": [{ "dst": "0.0.0.0/0" }]
      }
    },
    { "type": "portmap", "capabilities": { "portMappings": true } }
  ]
}
EOF
        for m in $(seq 1 "$NODES"); do
            [ "$m" = "$n" ] || node_ssh "$m" "ip route replace $cidr via $(node_ip "$n")"
        done
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
    local pidfile name pid state up rss mem port role ready nodes=""
    [ -n "$(ls "$STATE"/*.pid 2>/dev/null)" ] || { echo "no guests (./tools/k8s-demo.sh up)"; return 0; }
    if [ -x "$STATE/kubectl" ]; then
        nodes=$(k get nodes --request-timeout=5s --no-headers 2>/dev/null || true)
    fi
    printf '%-7s %-8s %-8s %-11s %-10s %-11s %-16s %-14s %s\n' \
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
        port=$(awk -v h="$name" '$1 == "Host" {on = ($2 == h)} on && $1 == "Port" {print $2; exit}' "$STATE/ssh_config")
        role=$(awk -v n="$name" '$1 == n {print ($3 == "<none>" ? "worker" : $3)}' <<< "$nodes")
        ready=$(awk -v n="$name" '$1 == n {print $2}' <<< "$nodes")
        printf '%-7s %-8s %-8s %-11s %-10s %-11s %-16s %-14s %s\n' \
            "$name" "$pid" "$state" "$up" "$(node_ip "${name#k8s-}")" "$rss/${mem:--}M" \
            "127.0.0.1:${port:--}" "${role:--}" "${ready:--}"
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
    command -v curl >/dev/null || { echo "error: curl not found" >&2; exit 1; }
    [ "$NODES" -ge 2 ] || { echo "error: NODES=$NODES — a multi-node cluster needs at least 2" >&2; exit 1; }
    [ -w /dev/kvm ] || echo "warning: no KVM — $NODES emulated guests will take a long time to do this"

    down
    mkdir -p "$STATE" "$DL"
    trap 'echo; echo ">> failed — consoles are in $STATE/*.console.log; ./tools/k8s-demo.sh down when done" >&2' ERR

    fetch_binaries

    say "Booting $NODES guests from $ROOTFS with $KERNEL"
    : > "$STATE/ssh_config"
    local n
    for n in $(seq 1 "$NODES"); do boot_node "$n"; done
    for n in $(seq 1 "$NODES"); do retry "$TIMEOUT" node_ssh "$n" true; done

    say "Installing CRI-O and the Kubernetes binaries into each guest's /var"
    on_nodes 1 provision_node

    say "kubeadm init on $(node_name 1)"
    init_control_plane

    say "kubeadm join on the workers"
    on_nodes 2 join_worker

    say "Pod network"
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
