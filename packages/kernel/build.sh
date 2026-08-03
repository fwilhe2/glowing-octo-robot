# defconfig plus kvm_guest.config is what a qemu guest needs: virtio-blk for the root
# disk and a built-in serial console (8250/ttyS0 on amd64, PL011/ttyAMA0 on arm64), so
# the image boots with no initrd. This builds natively — never cross-compiled — so
# `make defconfig` already resolved to the right arch's defconfig from `uname -m`
# (SUBARCH in the kernel's own top-level Makefile); nothing here passes ARCH= explicitly.
# kvm_guest.config is a generic (arch/-independent) fragment, but a few of the symbols
# in it — CONFIG_PARAVIRT and friends — only exist under arch/x86; merge_config.sh warns
# that it couldn't apply them on arm64 and moves on, which is expected and harmless.
make defconfig
make kvm_guest.config

# ...but neither of them turns on anything a container runtime needs. defconfig
# gives us CGROUPS, the pid/net/ipc/uts namespaces and SECCOMP_FILTER and stops there:
# no USER_NS, no MEMCG, no OVERLAY_FS, no veth. This fragment is the difference between
# "the kernel has namespaces" and "crun can actually start a container". Every symbol in
# it lives outside arch/, so it applies identically on amd64 and arm64.
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

# A second fragment for the other direction: the arch's defconfig is a general-purpose
# config and turns on hardware a VM will never have. Only ever a guest (qemu today,
# rust-vmm-style VMMs next), so this is dead code and, in the wireless case, a boot-time
# error — cfg80211 asks the firmware loader for regulatory.db, which the image does not
# ship and never will, and the failure lands in the journal at every boot.
# Order matters: this comes after container.config so that where the two disagree the
# subtractive fragment is what olddefconfig sees last. Nothing here may take away what
# container.config just turned on — the guest devices are virtio and nothing else.
#
# A handful of lines below (AGP, the IOMMU pair, ACPI_DOCK/ACPI_BGRT,
# X86_CHECK_BIOS_CORRUPTION, EARLY_PRINTK_DBGP, MACINTOSH_DRIVERS, EEEPC_LAPTOP) name
# symbols that only exist under arch/x86; merge_config.sh reports it couldn't find them
# and moves on when this runs on arm64. That is a report, not a failure — nothing here
# depends on them actually applying there.
cat > kernel/configs/vm.config <<'EOF'
# No radio in a virtual machine. Clearing WIRELESS takes CFG80211 and MAC80211 with it.
# CONFIG_WIRELESS is not set
# CONFIG_RFKILL is not set

# No display. Every console we use is the 8250 serial port (`console=ttyS0`, and every
# qemu invocation in test/ and tools/ passes -nographic), so the DRM stack — i915, and
# virtio-gpu from kvm_guest.config — draws for nobody. This is the single biggest driver
# in the tree.
# CONFIG_DRM is not set
# CONFIG_AGP is not set
# CONFIG_SOUND is not set

# No USB controller is on the qemu command line, so the four host controllers, the
# storage and printer class drivers and the HID layer above them are all unreachable.
# Input stays for virtio-input; the exotic gamepad and tablet drivers do not.
# CONFIG_USB_SUPPORT is not set
# CONFIG_HID_SUPPORT is not set
# CONFIG_INPUT_JOYSTICK is not set
# CONFIG_INPUT_TABLET is not set
# CONFIG_INPUT_TOUCHSCREEN is not set
# CONFIG_INPUT_MISC is not set

# The root disk is virtio-blk (`-drive if=virtio`), which leaves defconfig's SATA and
# PATA controllers, the CD-ROM and SCSI generic paths, RAID/device-mapper and PCMCIA
# with nothing to bind to. VIRTIO_BLK, BLK_DEV_SD and SCSI_VIRTIO stay; so does the loop
# device, which is how a container image gets mounted.
# CONFIG_ATA is not set
# CONFIG_BLK_DEV_SR is not set
# CONFIG_CHR_DEV_SG is not set
# CONFIG_MD is not set
# CONFIG_PCCARD is not set
# CONFIG_MACINTOSH_DRIVERS is not set
# CONFIG_EEEPC_LAPTOP is not set
# CONFIG_I2C is not set
# CONFIG_WATCHDOG is not set
# CONFIG_NVRAM is not set
# CONFIG_DMADEVICES is not set

# The NIC is virtio-net (`-nic user,model=virtio-net-pci`). CONFIG_ETHERNET is the menu
# holding every vendor driver — tigon3, e1000, e1000e, sky2, forcedeth, 8139too, r8169,
# tulip — and virtio_net does not live under it, so this drops them all and keeps ours.
# CONFIG_ETHERNET is not set
# CONFIG_NETCONSOLE is not set

# IOMMU emulation is for passing host devices into a guest, which is the other side of
# the boundary we live on.
# CONFIG_AMD_IOMMU is not set
# CONFIG_INTEL_IOMMU is not set

# Power management a VM does not do: there is no disk to suspend to, no CPU frequency to
# scale (the vCPU's clock is the host's problem), and no dock or boot splash.
# CONFIG_HIBERNATION is not set
# CONFIG_CPU_FREQ is not set
# CONFIG_ACPI_DOCK is not set
# CONFIG_ACPI_BGRT is not set

# Filesystems with nothing to mount: no optical media, no FAT partition (there is no
# ESP — we are booted with -kernel), no NFS server anywhere near this image, and quotas
# on a single-user appliance root. ext4 is the root, 9p stays for host directory
# sharing, and autofs stays because systemd's .automount units need it.
# CONFIG_ISO9660_FS is not set
# CONFIG_FAT_FS is not set
# CONFIG_NFS_FS is not set
# CONFIG_QUOTA is not set
# CONFIG_NLS_CODEPAGE_437 is not set
# CONFIG_NLS_ISO8859_1 is not set

# SELinux is compiled in by defconfig, but every package here is built --without-selinux
# and the image ships no policy, so the hooks can never do anything. NETLABEL and the
# secmark netfilter targets exist only to label packets for it. SECURITY itself stays:
# BPF_LSM hangs off it.
# CONFIG_SECURITY_SELINUX is not set
# CONFIG_NETLABEL is not set
# CONFIG_NETFILTER_XT_TARGET_SECMARK is not set
# CONFIG_NETFILTER_XT_TARGET_CONNSECMARK is not set

# The audit subsystem has no consumer: systemd is built -Daudit=disabled and there is no
# auditd to read the netlink socket.
# CONFIG_AUDIT is not set

# Everything in this config is built in and `make modules_install` is never run, so a
# symbol that ends up =m is silently dropped from the image instead of failing the
# build. Turning modules off makes that impossible: kconfig has to resolve every
# tristate to y or n, and the module loader, its signature checking and the /proc and
# sysfs interfaces around it stop being built at all.
# CONFIG_MODULES is not set

# Kernel debugging left on by defconfig. DEBUG_KERNEL itself has to stay — kvm_guest.config
# asks for it and DEBUG_INFO_BTF needs it — but the expensive checks under it do not.
# CONFIG_DEBUG_ENTRY is not set
# CONFIG_DEBUG_WX is not set
# CONFIG_DEBUG_STACK_USAGE is not set
# CONFIG_DEBUG_DEVRES is not set
# CONFIG_DEBUG_BOOT_PARAMS is not set
# CONFIG_PM_DEBUG is not set
# CONFIG_CGROUP_DEBUG is not set
# CONFIG_SCHEDSTATS is not set
# CONFIG_BLK_DEV_IO_TRACE is not set
# CONFIG_PROC_KCORE is not set
# CONFIG_PROFILING is not set
# CONFIG_KEXEC is not set
# CONFIG_PROVIDE_OHCI1394_DMA_INIT is not set
# CONFIG_EARLY_PRINTK_DBGP is not set
# CONFIG_X86_CHECK_BIOS_CORRUPTION is not set

# cgroup controllers for hardware this kernel no longer has drivers for.
# CONFIG_CGROUP_RDMA is not set
EOF
make vm.config

make -j"$(nproc)"

# Building natively rather than cross-compiling means `make defconfig` already picked
# x86_64_defconfig or arm64 defconfig on its own, from SUBARCH's `uname -m` — nothing
# above this line is arch-conditional. But the two arches don't put the finished image
# in the same place or call it the same thing: x86 emits a self-decompressing bzImage,
# arm64 emits a plain Image (qemu-system-aarch64's -kernel loads that directly; there is
# no bzImage equivalent). Staged under one conventional name either way, so nothing
# downstream (test/, tools/, ci.yml) needs to know which arch built it.
case "$(uname -m)" in
    x86_64)  kernel_image=arch/x86/boot/bzImage ;;
    aarch64) kernel_image=arch/arm64/boot/Image ;;
    *) echo "error: unsupported build architecture: $(uname -m) (expected x86_64 or aarch64)" >&2
       exit 1 ;;
esac

# The rootfs image is what CI hands to qemu, so the kernel rides along inside it. It is
# never loaded from there — qemu is passed -kernel — but keeping the two together means
# a build artifact is always bootable on its own.
install -D -m 644 "$kernel_image" /usr/local/rootfs/boot/bzImage
