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
# and then re-runs olddefconfig, so anything these symbols select gets pulled in too — and
# anything they ask for that olddefconfig cannot honour is dropped in silence. Nothing
# upstream complains about that; the check after `make vm.config` below is what does.
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
# BPF_JIT: BPF_LSM depends on it, and defconfig leaves it off.
# FTRACE: BPF_LSM also depends on BPF_EVENTS, which is not a knob — it is `default y`
#   behind (KPROBE_EVENTS || UPROBE_EVENTS) && PERF_EVENTS, and both of those probe
#   types live inside the FTRACE menu. x86_64_defconfig leaves FTRACE on and arm64's
#   defconfig switches it off explicitly, so asking for BPF_LSM got a kernel with it on
#   amd64 and a kernel silently without it on arm64. UPROBE_EVENTS is enough on its own
#   (it only wants ARCH_SUPPORTS_UPROBES, which both arches have), so this does not also
#   need KPROBES.
# BPF_LSM: the hook type behind RestrictFileSystems= and nsresourced's user-namespace
#   lockdown. CONFIG_LSM already lists "bpf", so enabling this is all it takes to make
#   it show up as active.
# SECURITYFS: how a booted system reports which LSMs are on, in
#   /sys/kernel/security/lsm. systemd reads exactly that file to decide whether bpf-lsm
#   is available, so without securityfs the answer is "no" no matter what is compiled in.
CONFIG_BPF_JIT=y
CONFIG_FTRACE=y
CONFIG_BPF_LSM=y
CONFIG_SECURITYFS=y

# An LSM program is attached by naming the kernel function it hooks, and resolving that
# name needs the kernel's own BTF in /sys/kernel/btf/vmlinux. Without it the program
# loads and then fails to attach — systemd says "bpf-restrict-fs: Failed to load BPF
# object: No such process" at every boot.
#
# DEBUG_INFO_BTF alone does not get there, and used not to: it lives inside `if
# DEBUG_INFO`, and DEBUG_INFO is not a knob either — it is selected by the "Debug
# information" choice, which x86_64_defconfig leaves at None and arm64's defconfig sets
# to REDUCED. Under a None or a REDUCED choice the symbol does not exist to be set, so
# the line below it was a no-op on both arches. Settling that choice here is what makes
# it real, and what makes this the expensive option it was always described as: the
# kernel is compiled with full debug info and pahole runs over vmlinux (dwarves is in
# this package's EXTRA_DEPS for exactly that). Only the .BTF section is installed; the
# DWARF stays behind in the build tree.
CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y
# CONFIG_DEBUG_INFO_REDUCED is not set
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
# A handful of lines below (AGP, the IOMMU pair, ACPI_DOCK/ACPI_BGRT, SCHED_MC_PRIO,
# X86_CHECK_BIOS_CORRUPTION, EARLY_PRINTK_DBGP, MACINTOSH_DRIVERS, EEEPC_LAPTOP) name
# symbols that only exist under arch/x86, and simply do not appear in the .config when
# this runs on arm64. That is fine and the check below allows it: a subtraction only has
# to hold for symbols this architecture actually has.
cat > kernel/configs/vm.config <<'EOF'
# arm64's defconfig is a multi-platform config: it turns on every ARM SoC vendor's
# platform support, and each one drags in that SoC's pinctrl, clocks, PHYs, regulators,
# MMC, SPI and RTC behind it. That is 2484 symbols built in on arm64 that amd64 never
# has, and it is why the arm64 kernel is 54 MB against amd64's 11 MB and takes twice as
# long to compile. qemu's virt board needs none of it: there is no ARCH_VIRT symbol
# because the board is described entirely by the device tree qemu passes in and driven
# by generic drivers — GICv3, the PL011 UART, the architected timer, PSCI and virtio.
# These are all arm64-only symbols, so on amd64 they simply do not appear.
# CONFIG_ARCH_ACTIONS is not set
# CONFIG_ARCH_AIROHA is not set
# CONFIG_ARCH_ALPINE is not set
# CONFIG_ARCH_APPLE is not set
# CONFIG_ARCH_ARTPEC is not set
# CONFIG_ARCH_AXIADO is not set
# CONFIG_ARCH_BCM2835 is not set
# CONFIG_ARCH_BCMBCA is not set
# CONFIG_ARCH_BCM_IPROC is not set
# CONFIG_ARCH_BERLIN is not set
# CONFIG_ARCH_BLAIZE is not set
# CONFIG_ARCH_BRCMSTB is not set
# CONFIG_ARCH_BST is not set
# CONFIG_ARCH_CIX is not set
# CONFIG_ARCH_EXYNOS is not set
# CONFIG_ARCH_HISI is not set
# CONFIG_ARCH_INTEL_SOCFPGA is not set
# CONFIG_ARCH_K3 is not set
# CONFIG_ARCH_KEEMBAY is not set
# CONFIG_ARCH_LAYERSCAPE is not set
# CONFIG_ARCH_LG1K is not set
# CONFIG_ARCH_MA35 is not set
# CONFIG_ARCH_MEDIATEK is not set
# CONFIG_ARCH_MESON is not set
# CONFIG_ARCH_MVEBU is not set
# CONFIG_ARCH_MXC is not set
# CONFIG_ARCH_NPCM is not set
# CONFIG_ARCH_QCOM is not set
# CONFIG_ARCH_REALTEK is not set
# CONFIG_ARCH_RENESAS is not set
# CONFIG_ARCH_ROCKCHIP is not set
# CONFIG_ARCH_S32 is not set
# CONFIG_ARCH_SEATTLE is not set
# CONFIG_ARCH_SOPHGO is not set
# CONFIG_ARCH_SPARX5 is not set
# CONFIG_ARCH_SPRD is not set
# CONFIG_ARCH_STM32 is not set
# CONFIG_ARCH_SUNXI is not set
# CONFIG_ARCH_SYNQUACER is not set
# CONFIG_ARCH_TEGRA is not set
# CONFIG_ARCH_TESLA_FSD is not set
# CONFIG_ARCH_THUNDER is not set
# CONFIG_ARCH_THUNDER2 is not set
# CONFIG_ARCH_UNIPHIER is not set
# CONFIG_ARCH_VEXPRESS is not set
# CONFIG_ARCH_VISCONTI is not set
# CONFIG_ARCH_XGENE is not set
# CONFIG_ARCH_ZYNQMP is not set

# Buses and device classes the virt board does not expose, all of which x86_64_defconfig
# already leaves off — so these lines only ever do anything on arm64, and what they do is
# close the gap rather than take anything away from amd64. Note SERIAL_8250 is *not* here
# even though the virt board has no 8250 either: this fragment is shared, and amd64's
# console is exactly that.
# CONFIG_MTD is not set
# CONFIG_MMC is not set
# CONFIG_SPI is not set
# CONFIG_REGULATOR is not set
# CONFIG_BT is not set
# CONFIG_CAN is not set

# No radio in a virtual machine. Clearing WIRELESS takes CFG80211 and MAC80211 with it —
# but only once WLAN goes too: WLAN is `default y` and `select WIRELESS`, so clearing
# WIRELESS on its own was undone by olddefconfig on the spot, on both arches. The
# leftover cfg80211 is what asks the firmware loader for a regulatory.db the image does
# not ship, which is the boot-time error this was written to remove in the first place.
# CONFIG_WLAN is not set
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
# No camera, tuner or capture card on any qemu command line here, and MEDIA_SUPPORT is
# what drags I2C back in behind it (MEDIA_SUBDRV_AUTOSELECT selects it), so clearing I2C
# alone did nothing on arm64, whose defconfig has the media stack and x86_64's does not.
# CONFIG_MEDIA_SUPPORT is not set
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
# SCHED_MC_PRIO is `default y` on x86 and selects CPU_FREQ, so that one had to go first
# or the governor stack came back with it.
# CONFIG_SCHED_MC_PRIO is not set
# CONFIG_CPU_FREQ is not set
# CONFIG_ACPI_DOCK is not set
# CONFIG_ACPI_BGRT is not set

# Filesystems with nothing to mount: no optical media, no FAT partition (there is no
# ESP — we are booted with -kernel), no NFS server anywhere near this image, and quotas
# on a single-user appliance root. ext4 is the root, 9p stays for host directory
# sharing, and autofs stays because systemd's .automount units need it.
# CONFIG_ISO9660_FS is not set
# VFAT_FS is the one both defconfigs actually set, and it selects FAT_FS, so clearing
# FAT_FS on its own came straight back.
# CONFIG_VFAT_FS is not set
# CONFIG_MSDOS_FS is not set
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

# Now check that the two fragments above actually took, because nothing else does.
# merge_config.sh only verifies its own work when it is the thing that runs the config
# command; `make <name>.config` passes it -m and re-runs olddefconfig separately, so a
# symbol whose dependencies are unmet is dropped between the two steps without a word.
# Every one of the silent failures this file has had went that way: DEBUG_INFO_BTF asked
# for inside a `if DEBUG_INFO` that was off, BPF_LSM asked for without the BPF_EVENTS
# under it, WIRELESS cleared and immediately selected back by WLAN. A fragment that
# quietly does nothing is worse than one that fails, so fail.
#
# The two halves are not checked the same way. Everything container.config turns on has
# to be there, no exceptions. vm.config is allowed to name symbols that do not exist on
# this architecture — the x86-only lines above are expected to vanish on arm64 — so the
# bar there is only that nothing it clears came back on.
unapplied=""
while read -r sym; do
    if ! grep -qx "$sym" .config; then
        unapplied="$unapplied  $sym  (asked for, not in .config)"$'\n'
    fi
done < <(grep -E '^CONFIG_[A-Z0-9_]+=y$' kernel/configs/container.config)

while read -r sym; do
    if grep -qx "$sym=y" .config; then
        unapplied="$unapplied  $sym  (cleared, came back =y)"$'\n'
    fi
done < <(sed -n 's/^# \(CONFIG_[A-Z0-9_]*\) is not set$/\1/p' \
             kernel/configs/container.config kernel/configs/vm.config)

if [ -n "$unapplied" ]; then
    echo "error: config fragments did not apply as written:" >&2
    printf '%s' "$unapplied" >&2
    exit 1
fi

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

# The resolved config rides along beside it, the way a distro ships /boot/config-*. The
# check above proves the fragments applied; test/kernel-caps.sh reads this to prove the
# result can actually run a container, which is a different question — a capability the
# defconfig used to provide for free can stop being provided without any fragment
# changing. It is ~250 KB and it is the only record of how the kernel next to it was
# configured, which is worth that on its own when a boot misbehaves.
install -D -m 644 .config /usr/local/rootfs/boot/config
