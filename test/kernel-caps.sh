#!/usr/bin/env bash
# Assert the kernel can actually run a container:
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
CGROUP_SCHED        cpu.max does not exist
BLK_CGROUP          io.max does not exist
CGROUP_BPF          the cgroup v2 device controller is a BPF program, not a knob
BPF_SYSCALL         crun loads that program with bpf(2); without it, no device rules
BPF_JIT             BPF_LSM depends on it
BPF_LSM             systemd's RestrictFileSystems= and nsresourced's userns lockdown
BPF_EVENTS          BPF_LSM depends on it, and it needs a probe type under FTRACE
SECURITYFS          how /sys/kernel/security/lsm reports that bpf-lsm is on
DEBUG_INFO_BTF      an LSM program names the kernel function it hooks; resolving it
OVERLAY_FS          image layers
VETH                a container's end of the network
BRIDGE              the host end of it
TUN                 slirp4netns and friends
NF_TABLES           port publishing is NAT
NF_NAT              the same
NETFILTER_XT_MATCH_ADDRTYPE  the address-type match port publishing generates
SECCOMP             crun accepts a seccomp profile in the bundle
SECCOMP_FILTER      and this is what would enforce it
EXT4_FS             the root filesystem
PROC_FS             /proc, which every container mounts
SYSFS               /sys, likewise
TMPFS               /dev/shm and /run
EOF
)

missing=()
while read -r sym why; do
    [ -n "$sym" ] || continue
    grep -qx "CONFIG_$sym=y" "$CONFIG" || missing+=("CONFIG_$sym — $why")
done <<<"$REQUIRED"

if [ ${#missing[@]} -gt 0 ]; then
    echo "error: the kernel is missing container capabilities:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi

echo "kernel capabilities OK ($(grep -c '=y$' "$CONFIG") symbols built in, $(wc -l <<<"$REQUIRED") required present)"
