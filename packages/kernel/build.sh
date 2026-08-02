# defconfig plus kvm_guest.config is what a qemu guest needs: virtio-blk for the root
# disk and the 8250 serial console, both built in, so the image boots with no initrd.
make defconfig
make kvm_guest.config

# ...but neither of them turns on anything a container runtime needs. x86_64_defconfig
# gives us CGROUPS, the pid/net/ipc/uts namespaces and SECCOMP_FILTER and stops there:
# no USER_NS, no MEMCG, no OVERLAY_FS, no veth. This fragment is the difference between
# "the kernel has namespaces" and "crun can actually start a container".
#
# It is written out here rather than kept as a file next to this one because only
# build.sh is bind-mounted into the builder — the rest of kernel/ isn't there to copy.
# `make <name>.config` runs scripts/kconfig/merge_config.sh, which merges the fragment
# and then re-runs olddefconfig, so anything these symbols select gets pulled in too and
# a value that could not be applied is reported as a warning.
cat > kernel/configs/container.config <<'EOF'
# Namespaces and cgroup v2 controllers. CGROUPS, CGROUP_PIDS, CGROUP_FREEZER,
# CGROUP_DEVICE, BLK_CGROUP and CGROUP_SCHED are already on; MEMCG is what makes
# memory.max exist, and a bundle that asks for a memory limit fails without it.
CONFIG_USER_NS=y
CONFIG_MEMCG=y

# The cgroup v2 device controller is a BPF program attached to the cgroup, not a
# knob — no BPF_SYSCALL means no device whitelisting at all.
CONFIG_BPF_SYSCALL=y
CONFIG_CGROUP_BPF=y

# systemd's own sandboxing is BPF too, and it needs more than the syscall. It loads its
# programs through libbpf (the libbpf package) and logs "cgroup BPF features disabled"
# without it; these are what make the loaded programs actually run.
#
# BPF_JIT: BPF_LSM depends on it, and defconfig leaves it off. BPF_EVENTS is already y.
# BPF_LSM: the hook type behind RestrictFileSystems= and nsresourced's user-namespace
#   lockdown. CONFIG_LSM already lists "bpf", so enabling this is all it takes to make
#   it show up as active.
# SECURITYFS: how a booted system reports which LSMs are on, in
#   /sys/kernel/security/lsm. systemd reads exactly that file to decide whether bpf-lsm
#   is available, so without securityfs the answer is "no" no matter what is compiled in.
# DEBUG_INFO_BTF: an LSM program is attached by naming the kernel function it hooks, and
#   resolving that name needs the kernel's own BTF in /sys/kernel/btf/vmlinux. Without
#   it the program loads and then fails to attach. It costs a kernel compiled with debug
#   info and a pahole pass over vmlinux — dwarves is already in this package's
#   EXTRA_DEPS for exactly this.
CONFIG_BPF_JIT=y
CONFIG_BPF_LSM=y
CONFIG_SECURITYFS=y
CONFIG_DEBUG_INFO_BTF=y

# Image layers.
CONFIG_OVERLAY_FS=y

# Container networking: a veth pair per container into a bridge, tun for anything
# doing userspace networking (slirp4netns and friends).
CONFIG_VETH=y
CONFIG_BRIDGE=y
CONFIG_TUN=y

# Port publishing is NAT, and nftables is hidden behind NETFILTER_ADVANCED, which
# defconfig leaves off. NF_CONNTRACK and NF_NAT are already on.
CONFIG_NETFILTER_ADVANCED=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_NF_TABLES=y
CONFIG_NF_TABLES_INET=y
CONFIG_NFT_NAT=y
CONFIG_NFT_MASQ=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
EOF
make container.config

# A second fragment for the other direction: x86_64_defconfig is a general-purpose
# config and turns on hardware a VM will never have. Only ever a guest (qemu today,
# rust-vmm-style VMMs next), so this is dead code and, in the wireless case, a boot-time
# error — cfg80211 asks the firmware loader for regulatory.db, which the image does not
# ship and never will, and the failure lands in the journal at every boot.
cat > kernel/configs/vm.config <<'EOF'
# No radio in a virtual machine. Clearing WIRELESS takes CFG80211 and MAC80211 with it.
# CONFIG_WIRELESS is not set
EOF
make vm.config

make -j"$(nproc)"

# The rootfs image is what CI hands to qemu, so the kernel rides along inside it. It is
# never loaded from there — qemu is passed -kernel — but keeping the two together means
# a build artifact is always bootable on its own.
install -D -m 644 arch/x86/boot/bzImage /usr/local/rootfs/boot/bzImage
