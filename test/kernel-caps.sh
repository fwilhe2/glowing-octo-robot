#!/usr/bin/env bash
# Assert the kernel can actually run a container — and boot on the VMMs this image
# targets, and be a Kubernetes node:
#
#     ./test/kernel-caps.sh [rootfs]      # default rootfs/, reads rootfs/boot/config
#
# This is deliberately not the same check as the one in packages/kernel/build.sh. That
# one asks "did every line of container.config and vm.config apply", which is a question
# about the fragments. This one asks "does the kernel have what a container needs",
# which is a question about the answer — and the two come apart in both directions:
#
#   - a capability can arrive from defconfig rather than from our fragment, and then
#     stop arriving. CGROUPS, the pid/net/ipc/uts namespaces and SECCOMP_FILTER are all
#     in that category: they have never been in container.config because defconfig
#     provided them, so nothing here would notice them going away.
#   - a subtraction in vm.config can take out something no line of it names. Turning off
#     all 48 arm64 SoC platforms removed 1594 symbols, and the only reason to believe
#     none of them mattered is a list like this one saying so.
#
# It runs in the `rootfs` CI job, next to check-rootfs-deps.sh, because it needs nothing
# but the staged tree — no boot, no qemu, a few milliseconds. test/container.sh is the
# other half: it boots the thing and starts a real container. Both are worth having, and
# this one says *which* capability is missing rather than "crun exited 1".
set -euo pipefail

cd "$(dirname "$0")/.."

ROOT="${1:-rootfs}"
CONFIG="$ROOT/boot/config"

[ -f "$CONFIG" ] || {
    echo "error: no kernel config at $CONFIG" >&2
    echo "       packages/kernel/build.sh stages it next to the image; build the kernel first" >&2
    exit 1
}

# symbol : what breaks without it. Keep the second column concrete — the point of this
# file is that a failure names the feature, not just the symbol.
REQUIRED=$(cat <<'EOF'
NAMESPACES          every namespace below hangs off this
PID_NS              the container gets the host's pid 1
NET_NS              no network isolation, and veth has nothing to move between
IPC_NS              System V IPC shared with the host
UTS_NS              the container cannot set its own hostname
USER_NS             no rootless containers, and no uid mapping at all
CGROUPS             no resource control of any kind
CGROUP_PIDS         pids.max does not exist
CGROUP_FREEZER      crun pause/resume
CGROUP_DEVICE       the cgroup the device controller attaches to
MEMCG               memory.max does not exist; a bundle with a memory limit fails
CGROUP_SCHED        no cpu controller at all
CFS_BANDWIDTH       cpu.max does not exist; docker --cpus and Kubernetes CPU limits fail
BLK_CGROUP          no io controller at all
BLK_DEV_THROTTLING  io.max takes no bandwidth or iops limit
CGROUP_BPF          the cgroup v2 device controller is a BPF program, not a knob
BPF_SYSCALL         crun loads that program with bpf(2); without it, no device rules
BPF_JIT             BPF_LSM depends on it
BPF_LSM             systemd's RestrictFileSystems=
BPF_EVENTS          BPF_LSM depends on it, and it needs a probe type under FTRACE
SECURITYFS          how /sys/kernel/security/lsm reports that bpf-lsm is on
DEBUG_INFO_BTF      an LSM program names the kernel function it hooks; resolving it
OVERLAY_FS          image layers
BINFMT_MISC         containers for another architecture, through qemu-user or Rosetta
VETH                a container's end of the network
BRIDGE              the host end of it
TUN                 slirp4netns and friends
NF_TABLES           port publishing is NAT
NF_NAT              the same
NETFILTER_XT_MATCH_ADDRTYPE  the address-type match port publishing generates
NFT_NAT             nftables NAT, which port publishing and masquerade are
NFT_MASQ            outbound traffic from a container's bridge
NFT_CT              connection-state matches, in every engine's forward rules
NFT_FIB_IPV4        `fib daddr type local`, how dockerd matches traffic to the host
NFT_FIB_IPV6        the same for IPv6; dockerd's ip6 table fails to load without it
NFT_FIB_INET        the same in an inet table, which is the only kind netavark writes
NF_CONNTRACK_MARK   `ct mark set`, netavark's marker for published-port traffic
NFT_COMPAT          iptables-nft runs every -m and non-verdict -j through it
NETFILTER_XT_MATCH_CONNTRACK  -m conntrack --ctstate, in every engine's forward rules
NETFILTER_XT_MARK   -m mark and -j MARK
NETFILTER_XT_TARGET_MASQUERADE  -j MASQUERADE, outbound traffic from a container bridge
NETFILTER_XT_NAT    -j DNAT and -j SNAT, which is what -p publishes a port with
SECCOMP             crun accepts a seccomp profile in the bundle
SECCOMP_FILTER      and this is what would enforce it
EXT4_FS             the root filesystem
PROC_FS             /proc, which every container mounts
SYSFS               /sys, likewise
TMPFS               /dev/shm and /run
NFT_NUMGEN          kube-proxy (nftables mode) picks a service's endpoint with numgen
NFT_REJECT          kube-proxy rejects connections to a service with no endpoints
NF_CT_NETLINK       kube-proxy flushes stale UDP conntrack entries, or DNS blackholes
VXLAN               flannel's and Calico's multi-node overlay
NFT_REDIR           `redirect`, for service meshes and Calico's nftables dataplane
NF_TABLES_NETDEV    netdev-family ingress hooks: Calico nftables, Cilium's host firewall
VIRTIO_BLK          the root and /var disks on every VMM
VIRTIO_NET          the network on every VMM
VIRTIO_PCI          qemu's and Virtualization.framework's devices
VIRTIO_MMIO         Firecracker's devices, which have no PCI bus
VIRTIO_MMIO_CMDLINE_DEVICES  Firecracker on x86 lists its devices on the command line
VIRTIO_CONSOLE      hvc0, Virtualization.framework's console
SERIAL_8250_CONSOLE ttyS0, the console on x86 qemu and on Firecracker
VIRTIO_FS           host directories in Virtualization.framework and qemu+virtiofsd
VIRTIO_VSOCKETS     host↔guest control without a network, as vfkit uses
HW_RANDOM_VIRTIO    an entropy source from the host
VIRTIO_BALLOON      the host taking memory back from an idle guest
VMGENID             reseeding the RNG after a snapshot restore, so clones differ
DM_VERITY           the root is a verity device; a kernel without it cannot mount /
DM_INIT             building that device from the command line, with no initrd
EROFS_FS            the root filesystem's format
EROFS_FS_ZIP_ZSTD   and its compression; without it every compressed file is an I/O error
EOF
)
# Architecture-specific halves of the same: what boots the machine at all on each.
case "$(sed -n 's/^# Linux\/\([a-z0-9_]*\) .*/\1/p' "$CONFIG")" in
    x86)   REQUIRED+=$'\n'$(cat <<'EOF2'
PVH                 Firecracker boots an uncompressed vmlinux through PVH
EOF2
) ;;
    arm64) REQUIRED+=$'\n'$(cat <<'EOF2'
SERIAL_AMBA_PL011_CONSOLE  ttyAMA0, arm64 qemu's console
SERIAL_OF_PLATFORM  Firecracker's arm64 console, a device-tree 8250
PCI_HOST_GENERIC    the ECAM host bridge of qemu virt and Virtualization.framework
GPIO_PL061          qemu virt's power button is a GPIO line on a PL061...
KEYBOARD_GPIO       ...and gpio-keys is what turns it into KEY_POWER
EOF2
) ;;
esac

missing=()
while read -r sym why; do
    [ -n "$sym" ] || continue
    grep -qx "CONFIG_$sym=y" "$CONFIG" || missing+=("CONFIG_$sym — $why")
done <<<"$REQUIRED"

if [ ${#missing[@]} -gt 0 ]; then
    echo "error: the kernel is missing capabilities this image depends on:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi

echo "kernel capabilities OK ($(grep -c '=y$' "$CONFIG") symbols built in, $(wc -l <<<"$REQUIRED") required present)"
