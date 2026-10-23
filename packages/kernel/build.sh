# defconfig plus kvm_guest.config is what a qemu guest needs: virtio-blk for the root
# disk and a built-in serial console (8250/ttyS0 on amd64, PL011/ttyAMA0 on arm64), so
# the image boots with no initrd. This builds natively — never cross-compiled — so
# `make defconfig` already resolved to the right arch's defconfig from `uname -m`
# (SUBARCH in the kernel's own top-level Makefile); nothing here passes ARCH= explicitly.
# kvm_guest.config is a generic (arch/-independent) fragment, but a few of the symbols
# in it — CONFIG_PARAVIRT and friends — only exist under arch/x86; merge_config.sh warns
# that it couldn't apply them on arm64 and moves on, which is expected and harmless.
# Reproducible: kbuild otherwise stamps the build's date, user and host into the version
# string every `uname -v` prints, and a counter from .version that goes up by one with
# every build in the same tree — the `#3` a local rebuild shows. SOURCE_DATE_EPOCH comes
# from build.sh (tools/lib.sh); the identity is the project's rather than the builder
# container's, which is a random hostname.
export KBUILD_BUILD_TIMESTAMP="$(date -u -d "@$SOURCE_DATE_EPOCH")"
export KBUILD_BUILD_USER=flfs KBUILD_BUILD_HOST=flfs KBUILD_BUILD_VERSION=1

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

# The two limits defconfig's CGROUP_SCHED and BLK_CGROUP do not give you on their own.
# CFS_BANDWIDTH is what makes cpu.max exist — docker --cpus and every Kubernetes CPU
# limit write it, and runc fails the whole container when the file is not there.
# BLK_DEV_THROTTLING is the io.max bandwidth/iops half of the io controller, behind
# docker --device-read-bps and friends; without it io.max accepts nothing.
CONFIG_CFS_BANDWIDTH=y
CONFIG_BLK_DEV_THROTTLING=y

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
# builder/deps.txt for exactly that). Only the .BTF section is installed; the
# DWARF stays behind in the build tree.
CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y
# CONFIG_DEBUG_INFO_REDUCED is not set
CONFIG_DEBUG_INFO_BTF=y

# Image layers.
CONFIG_OVERLAY_FS=y

# Containers built for another architecture: `podman run --platform` runs them through a
# qemu-user interpreter the kernel hands their binaries to, and Rosetta on an Apple host
# registers itself the same way. arm64's defconfig has it; x86_64_defconfig does not.
CONFIG_BINFMT_MISC=y

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

# What an engine's own nftables rules use: dockerd's nftables backend writes `ct state`
# and `fib daddr type local`, and loads an ip6 table beside the ip one. Missing the IPv6
# fib makes that table fail to load, which dockerd reports as a warning and IPv6
# container networking quietly lacks.
CONFIG_NFT_CT=y
CONFIG_NFT_FIB_IPV4=y
CONFIG_NFT_FIB_IPV6=y
# netavark, podman's backend, writes one `inet` table for both families rather than an ip
# and an ip6 table, and `fib` inside an inet table is its own expression type: with only
# the two above, nft answers "Could not process rule: No such file or directory" and no
# container gets a network.
CONFIG_NFT_FIB_INET=y
# And `ct mark set`, which netavark uses to mark a published port's connections so its
# postrouting chain knows to masquerade them. The mark lives in the conntrack entry and
# is its own option; without it nft rejects the rule with "Operation not supported".
CONFIG_NF_CONNTRACK_MARK=y

# And what the iptables command line needs on top. There are none of the legacy IP_NF_*
# tables (NETFILTER_XTABLES_LEGACY is off), so packages/iptables is iptables-nft: it
# writes nf_tables rules, and any match or target it cannot express natively it embeds
# as the x_tables extension itself, run by NFT_COMPAT. Without NFT_COMPAT every rule with
# a -m or a -j other than a verdict fails with "Extension ... revision 0 not supported,
# missing kernel module?". The extensions below are the ones Docker's default iptables
# backend uses — conntrack --ctstate, addrtype --dst-type (above), mark, and the
# MASQUERADE, SNAT and DNAT targets — named here even where defconfig already has them,
# so the check after `make vm.config` holds both arches to it.
CONFIG_NFT_COMPAT=y
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y
CONFIG_NETFILTER_XT_MARK=y
CONFIG_NETFILTER_XT_TARGET_MASQUERADE=y
CONFIG_NETFILTER_XT_NAT=y
EOF
make container.config

# What an orchestrator needs on top of a container runtime: kubelet and CRI-O on the
# host, kube-proxy and a CNI as pods (docs/sysext.md). Its own fragment rather than more
# of container.config, which is about what *a container* needs — this is what a node in
# a cluster needs, and there is no module to load it from later: CONFIG_MODULES is off,
# so a feature a pod expects of the host kernel is in the image or it is nowhere.
#
# kube-proxy runs in nftables mode — GA, and the older iptables mode wants a much longer
# list of x_tables matches for the same job. What its rules use beyond the container
# fragment:
#   NFT_NUMGEN   `numgen random mod N vmap`, how a service picks an endpoint
#   NFT_REJECT   `reject`, which a service with no endpoints answers with
#   NF_CT_NETLINK  kube-proxy deletes stale UDP conntrack entries over netlink when
#                an endpoint goes away; without it DNS to a restarted CoreDNS blackholes
#                until the entry times out
# and for the CNIs that run as pods:
#   VXLAN        the overlay flannel and Calico default to on a multi-node cluster
#   NFT_REDIR    `redirect`, used by service meshes and Calico's nftables dataplane
#   NF_TABLES_NETDEV  the netdev family, ingress hooks on an interface rather than a
#                table — Calico's nftables dataplane and Cilium's host firewall
# and two x_tables extensions that kubeadm's preflight requires of every node, whatever
# mode kube-proxy runs in — its SystemVerification check reads this kernel's config
# (through /usr/lib/modules/<release>/config, below) and refuses to init or join without
# them. They are also what the iptables dataplanes of flannel and Calico use, through
# NFT_COMPAT here:
#   NETFILTER_XT_TARGET_REDIRECT  `-j REDIRECT` (kubeadm asks for it as IP_NF_TARGET_REDIRECT)
#   NETFILTER_XT_MATCH_COMMENT    `-m comment`, which every kube-proxy and CNI rule carries
cat > kernel/configs/k8s.config <<'EOF'
CONFIG_NFT_NUMGEN=y
CONFIG_NFT_REJECT=y
CONFIG_NF_CT_NETLINK=y
CONFIG_VXLAN=y
CONFIG_NFT_REDIR=y
CONFIG_NF_TABLES_NETDEV=y
CONFIG_NETFILTER_XT_TARGET_REDIRECT=y
CONFIG_NETFILTER_XT_MATCH_COMMENT=y
EOF
make k8s.config

# The virtual hardware of the VMMs this image targets, beyond the qemu PCI devices
# kvm_guest.config already turns on. What each one brings:
#
#   Firecracker (and cloud-hypervisor) has no PCI: every device is virtio over MMIO, and
#     on x86 the devices are named on the kernel command line (`virtio_mmio.device=`),
#     which VIRTIO_MMIO_CMDLINE_DEVICES is what parses. It boots an uncompressed vmlinux
#     through the PVH entry point. Its console is an 8250 on both architectures — on
#     arm64 a device-tree one, which SERIAL_OF_PLATFORM drives — and on x86 its "send
#     Ctrl-Alt-Del" goes through an i8042 keyboard controller, which is why SERIO_I8042
#     and ATKBD stay on.
#   Apple's Virtualization.framework (and vfkit on top of it) gives the guest a virtio
#     console (hvc0), virtiofs for shared directories and vsock for host↔guest control,
#     and boots an uncompressed arm64 Image directly.
#   All of them offer a balloon, an entropy source and, after a snapshot restore, a VM
#     generation id: VMGENID is what tells the guest's RNG that it has been cloned and
#     has to reseed, so two VMs restored from one snapshot do not share a key stream.
#
# virtiofs replaces 9p (which kvm_guest.config asks for, and vm.config clears) as the
# way to share a host directory: it is what Virtualization.framework offers, qemu has it
# through virtiofsd, and it is the one with page-cache sharing and real POSIX semantics.
cat > kernel/configs/guest.config <<'EOF'
CONFIG_VIRTIO_MMIO=y
CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_VIRTIO_BALLOON=y
CONFIG_HW_RANDOM=y
CONFIG_HW_RANDOM_VIRTIO=y
CONFIG_VSOCKETS=y
CONFIG_VIRTIO_VSOCKETS=y
CONFIG_FUSE_FS=y
CONFIG_VIRTIO_FS=y
CONFIG_VIRT_DRIVERS=y
CONFIG_VMGENID=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
EOF
# The lines that only exist on one architecture, appended per architecture because the
# check below holds every =y line of this fragment to being in .config. x86: Firecracker's
# PVH entry and i8042 above. arm64: qemu virt's PL011 console, PL031 clock and PL061 GPIO
# with gpio-keys on top (its power button is a GPIO line), the generic ECAM host bridge
# that both qemu virt and Virtualization.framework expose, and Firecracker's 8250. The
# defconfig has all of these already; naming them is what makes losing one an error.
case "$(uname -m)" in
    x86_64)  printf '%s\n' CONFIG_PVH=y CONFIG_SERIO_I8042=y CONFIG_KEYBOARD_ATKBD=y ;;
    aarch64) printf '%s\n' CONFIG_SERIAL_OF_PLATFORM=y CONFIG_SERIAL_AMBA_PL011=y \
                 CONFIG_SERIAL_AMBA_PL011_CONSOLE=y CONFIG_PCI_HOST_GENERIC=y \
                 CONFIG_RTC_DRV_PL031=y CONFIG_GPIO_PL061=y CONFIG_KEYBOARD_GPIO=y ;;
esac >> kernel/configs/guest.config
make guest.config

# The root filesystem. The image is EROFS — read-only by construction, compressed, and
# what image/build-rootfs.sh lays the tree out as — so the kernel has to mount it with no
# initrd to load a driver from. ZIP is the compressed-file support, with LZ4 always built
# in; ZIP_ZSTD is the one mkfs.erofs is asked for, because on this tree it makes an image
# 28% smaller than LZ4HC at the same cluster size and still decompresses faster than a
# virtio disk reads (see image/build-rootfs.sh). Its own fragment rather
# than a line in container.config: it is what boots the machine, not what runs containers
# on it, and the check below holds both to the same standard.
#
# And the integrity check underneath it: dm-verity verifies every block read from the
# image against a hash tree whose root hash is on the kernel command line, so the image
# is not only unwritable but unforgeable — a changed byte is an I/O error, not a changed
# file. DM_INIT is what makes that possible without an initrd: it builds the verity
# device from `dm-mod.create=` before the root is mounted, which is otherwise the job of
# veritysetup in an initramfs. MD is only the menu device-mapper lives in.
cat > kernel/configs/rootfs.config <<'EOF'
CONFIG_EROFS_FS=y
CONFIG_EROFS_FS_ZIP=y
CONFIG_EROFS_FS_ZIP_ZSTD=y
CONFIG_MD=y
CONFIG_BLK_DEV_DM=y
CONFIG_DM_INIT=y
CONFIG_DM_VERITY=y
EOF
make rootfs.config

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
# PATA controllers, the CD-ROM and SCSI generic paths, software RAID and PCMCIA with
# nothing to bind to. VIRTIO_BLK, BLK_DEV_SD and SCSI_VIRTIO stay; so does the loop
# device, which is how a container image gets mounted. Device-mapper stays too, for
# dm-verity (rootfs.config), but only that target: the MD menu it lives in is kept,
# and RAID inside it is not, nor the two other targets defconfig turns on.
# CONFIG_DM_MIRROR is not set
# CONFIG_DM_ZERO is not set
# CONFIG_ATA is not set
# CONFIG_BLK_DEV_SR is not set
# CONFIG_CHR_DEV_SG is not set
# CONFIG_BLK_DEV_MD is not set
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

# Everything below this line is the same rule applied further: hardware no VMM this
# image targets (qemu, Firecracker, Virtualization.framework) puts in a guest, and
# kernel features with nothing in the image to use them. Most of it is arm64's, whose
# defconfig is a board-support config and turns these on outside the ARCH_* gates above;
# the lines that only exist on one architecture vanish on the other, as above.
#
# Other hypervisors' guest support, and being a hypervisor: KVM is the host side, which a
# guest only needs for nested virtualization, and VFIO is passing a device through to a
# guest of our own. Xen is a platform this image does not run on.
# CONFIG_XEN is not set
# CONFIG_KVM is not set
# CONFIG_VFIO is not set

# Firmware interfaces and management controllers of real machines: ChromeOS's embedded
# controller and coreboot tables, TrustZone (OP-TEE), the TPM, IPMI BMCs, memory error
# reporting, ARM's SoC power/clock firmware (SCMI, SCPI) and its mailboxes, UEFI capsule
# updates, and coprocessors (remoteproc, rpmsg).
# CONFIG_CHROME_PLATFORMS is not set
# CONFIG_GOOGLE_FIRMWARE is not set
# CONFIG_TEE is not set
# CONFIG_TCG_TPM is not set
# CONFIG_IPMI_HANDLER is not set
# CONFIG_EDAC is not set
# CONFIG_ACPI_APEI_EINJ is not set
# CONFIG_ARM_SCMI_PROTOCOL is not set
# CONFIG_ARM_SCPI_PROTOCOL is not set
# CONFIG_MAILBOX is not set
# CONFIG_EFI_CAPSULE_LOADER is not set
# CONFIG_REMOTEPROC is not set
# CONFIG_RPMSG is not set
# CONFIG_RPMSG_VIRTIO is not set

# SoC buses and the device classes that only exist on boards: industrial I/O sensors,
# PWM, FPGAs, LEDs, batteries and chargers, thermal zones and fans, hardware monitoring,
# the power-reset drivers (PSCI and ACPI already power a guest off), on-chip
# interconnects, memory controllers, muxes, hardware spinlocks and timestamping, device
# frequency scaling, infrared remotes, HDMI CEC, CoreSight tracing, and the staging tree.
# POWER_SUPPLY and POWER_RESET themselves are selected by ARM64, so on arm64 it is the
# drivers under them that go. THERMAL is selected by ACPI_PROCESSOR, which ACPI CPU
# hotplug needs, so only ACPI's thermal zone goes (below), not the framework.
# CONFIG_SLIMBUS is not set
# CONFIG_SPMI is not set
# CONFIG_GREYBUS is not set
# CONFIG_MHI_BUS is not set
# CONFIG_IIO is not set
# CONFIG_PWM is not set
# CONFIG_FPGA is not set
# CONFIG_NEW_LEDS is not set
# CONFIG_BATTERY_BQ27XXX is not set
# CONFIG_POWER_RESET_GPIO is not set
# CONFIG_POWER_RESET_GPIO_RESTART is not set
# CONFIG_POWER_RESET_SYSCON is not set
# CONFIG_POWER_RESET_SYSCON_POWEROFF is not set
# CONFIG_POWER_RESET_XGENE is not set
# CONFIG_HWMON is not set
# CONFIG_INTERCONNECT is not set
# CONFIG_MEMORY is not set
# CONFIG_MULTIPLEXER is not set
# CONFIG_MDIO_BUS_MUX_MULTIPLEXER is not set
# CONFIG_EXTCON is not set
# CONFIG_COUNTER is not set
# CONFIG_HWSPINLOCK is not set
# CONFIG_HTE is not set
# CONFIG_PM_DEVFREQ is not set
# CONFIG_RC_CORE is not set
# CONFIG_MEDIA_CEC_SUPPORT is not set
# CONFIG_CORESIGHT is not set
# CONFIG_STM is not set
# CONFIG_STAGING is not set

# Radios other than the Wi-Fi and Bluetooth already cleared: NFC, cellular modems, GPS.
# CONFIG_NFC is not set
# CONFIG_WWAN is not set
# CONFIG_GNSS is not set

# PCI from the other side, and PCI host controllers of real SoCs. qemu's virt board and
# Virtualization.framework both expose a generic ECAM host (PCI_HOST_GENERIC, kept in
# guest.config); x86 has no host driver to choose. A guest is never a PCI endpoint, and
# SR-IOV's PF side belongs to the host. The IOMMU a guest could be given is virtio-iommu,
# not an SMMU.
# CONFIG_PCI_ENDPOINT is not set
# CONFIG_PCI_IOV is not set
# CONFIG_PCIE_ALTERA is not set
# CONFIG_PCIE_KIRIN is not set
# CONFIG_PCIE_XILINX is not set
# CONFIG_PCI_MESON is not set
# CONFIG_PCI_XGENE is not set
# CONFIG_PCI_HOST_THUNDER_ECAM is not set
# CONFIG_PCI_HOST_THUNDER_PEM is not set
# CONFIG_ARM_SMMU is not set
# CONFIG_ARM_SMMU_V3 is not set

# Storage controllers no target VMM emulates: the root and /var are virtio-blk, and
# virtio-scsi stays for the VMMs that prefer it. NVMe, SAS HBAs and UFS do not.
# CONFIG_BLK_DEV_NVME is not set
# CONFIG_MEGARAID_SAS is not set
# CONFIG_SCSI_MPT3SAS is not set
# CONFIG_SCSI_UFSHCD is not set

# Filesystems with nothing to mount, as above: the image is EROFS, /var is ext4, a host
# directory is virtiofs (guest.config) rather than 9p, and nothing ships a btrfs or
# squashfs. CUSE is character devices in userspace, which nothing here implements.
# CONFIG_NET_9P is not set
# CONFIG_9P_FS is not set
# CONFIG_BTRFS_FS is not set
# CONFIG_SQUASHFS is not set
# CONFIG_CUSE is not set

# Networking for switch silicon and time-sensitive networking: DSA drives the switch chip
# on a router board, HSR/PRP is industrial ring redundancy, and CBS/ETF/TAPRIO/MQPRIO
# schedule hardware transmit queues a virtio NIC does not have. Ethernet PHYs are the
# chip under a NIC driver, and the NIC drivers went with CONFIG_ETHERNET — PHYLIB itself
# is what the Synopsys PCS (an stmmac part) selects, and the generic PHY framework is what
# the Cadence SerDes and MIPI D-PHYs and the CAN transceiver select. IPVS is kube-proxy's
# third mode, behind the nftables one k8s.config is for.
# CONFIG_NET_DSA is not set
# CONFIG_HSR is not set
# CONFIG_NET_SCH_CBS is not set
# CONFIG_NET_SCH_ETF is not set
# CONFIG_NET_SCH_TAPRIO is not set
# CONFIG_NET_SCH_MQPRIO is not set
# CONFIG_PCS_XPCS is not set
# CONFIG_PHYLIB is not set
# CONFIG_PHY_CADENCE_TORRENT is not set
# CONFIG_PHY_CADENCE_DPHY is not set
# CONFIG_PHY_CADENCE_DPHY_RX is not set
# CONFIG_PHY_CADENCE_SIERRA is not set
# CONFIG_PHY_CADENCE_SALVO is not set
# CONFIG_PHY_CAN_TRANSCEIVER is not set
# CONFIG_IP_VS is not set

# No display, as with DRM above: no framebuffer and no boot logo. The virtual terminal
# layer stays, though every console here is a serial line or hvc0: VT only has a prompt
# under CONFIG_EXPERT, and turning EXPERT on changes defaults all over the tree to buy one
# subtraction — exactly the kind of silent change this file exists to avoid.
# CONFIG_FB is not set
# CONFIG_LOGO is not set

# Input devices of a desk: a PS/2 mouse, ARM's PS/2 controller, polled GPIO keys. The
# i8042 keyboard on x86 and the GPIO power key on arm64 stay (guest.config).
# CONFIG_INPUT_MOUSE is not set
# CONFIG_SERIO_AMBAKMI is not set
# CONFIG_KEYBOARD_GPIO_POLLED is not set

# UARTs. Every console here is a plain 8250/16550 (x86 qemu, Firecracker), a PL011
# (arm64 qemu) or hvc0, so the many-ports and RSA extensions, the PCI serial cards and
# the vendor variants — Intel's LPSS and MID, Exar, Pericom, DesignWare, Freescale,
# Xilinx — and the serdev bus for devices hanging off a UART have nothing to drive. To
# repeat the warning above: SERIAL_8250 itself is amd64's console and must never be here.
# CONFIG_SERIAL_8250_EXTENDED is not set
# CONFIG_SERIAL_8250_PCI is not set
# CONFIG_SERIAL_8250_EXAR is not set
# CONFIG_SERIAL_8250_LPSS is not set
# CONFIG_SERIAL_8250_MID is not set
# CONFIG_SERIAL_8250_PERICOM is not set
# CONFIG_SERIAL_8250_DW is not set
# CONFIG_SERIAL_FSL_LPUART is not set
# CONFIG_SERIAL_FSL_LINFLEXUART is not set
# CONFIG_SERIAL_XILINX_PS_UART is not set
# CONFIG_SERIAL_DEV_BUS is not set

# Entropy sources of particular CPUs and SoCs. The guest's are virtio-rng (guest.config)
# and, on arm64, the SMCCC TRNG KVM offers, which stays; RDRAND needs no driver.
# CONFIG_HW_RANDOM_INTEL is not set
# CONFIG_HW_RANDOM_AMD is not set
# CONFIG_HW_RANDOM_VIA is not set
# CONFIG_HW_RANDOM_ATMEL is not set
# CONFIG_HW_RANDOM_CN10K is not set
# CONFIG_HW_RANDOM_HISI_TRNG is not set

# Performance counters of the physical machine. A guest gets the architected core PMU
# (x86's, ARM's PMUv3) virtualized, and nothing else: uncore, power and C-state counters,
# ARM's interconnect and memory-controller PMUs and its statistical profiling are host
# hardware no VMM passes in.
# CONFIG_PERF_EVENTS_INTEL_UNCORE is not set
# CONFIG_PERF_EVENTS_INTEL_RAPL is not set
# CONFIG_PERF_EVENTS_INTEL_CSTATE is not set
# CONFIG_PERF_EVENTS_AMD_UNCORE is not set
# CONFIG_ARM_CCI_PMU is not set
# CONFIG_ARM_CCN is not set
# CONFIG_ARM_CMN is not set
# CONFIG_ARM_DMC620_PMU is not set
# CONFIG_ARM_DSU_PMU is not set
# CONFIG_ARM_SPE_PMU is not set
# CONFIG_ARM_SMMU_V3_PMU is not set
# CONFIG_ARM_CORESIGHT_PMU_ARCH_SYSTEM_PMU is not set
# CONFIG_HISI_PMU is not set

# A laptop's ACPI devices: no battery, no AC adapter, no fan, no thermal zone, no
# backlight (ACPI_VIDEO, which selects THERMAL on its own account).
# CONFIG_ACPI_VIDEO is not set
# CONFIG_ACPI_AC is not set
# CONFIG_ACPI_BATTERY is not set
# CONFIG_ACPI_FAN is not set
# CONFIG_ACPI_THERMAL is not set

# Board support that arm64's defconfig turns on outside the ARCH_* gates, because the
# driver has a COMPILE_TEST or OF alternative to the platform symbol: the ASPEED BMC
# family, Microchip PolarFire, Xilinx, the Raspberry Pi 5's RP1 southbridge, ARM's
# Versatile Express, TI's SoC glue, Freescale's power controller, Socionext's interrupt
# bridge, the MediaTek and HiSilicon PMICs behind phone and board power rails, SoC GPIO
# blocks, SoC reset and pin controllers, the backlight a panel would have, the power
# sequencing of Qualcomm's Wi-Fi/Bluetooth combo, Qualcomm's IPC router, an accelerator
# framework, a reserved-memory NVMEM, and the reboot-mode plumbing for a bootloader that
# reads a magic value, and the generic PCI slot power control that pulls power
# sequencing in. qemu's virt board needs the PL011, PL031, PL061 and GPIO keys
# (guest.config), and nothing in this list.
# CONFIG_ASPEED_LPC_CTRL is not set
# CONFIG_ASPEED_LPC_SNOOP is not set
# CONFIG_ASPEED_P2A_CTRL is not set
# CONFIG_ASPEED_SOCINFO is not set
# CONFIG_ASPEED_UART_ROUTING is not set
# CONFIG_COMMON_CLK_ASPEED is not set
# CONFIG_COMMON_CLK_RP1 is not set
# CONFIG_COMMON_CLK_XGENE is not set
# CONFIG_COMMON_CLK_XLNX_CLKWZRD is not set
# CONFIG_MCHP_CLK_MPFS is not set
# CONFIG_VEXPRESS_CONFIG is not set
# CONFIG_ARM_TIMER_SP804 is not set
# CONFIG_MISC_RP1 is not set
# CONFIG_PINCTRL_RP1 is not set
# CONFIG_PINCTRL_SINGLE is not set
# CONFIG_POLARFIRE_SOC_IRQ_MUX is not set
# CONFIG_POLARFIRE_SOC_SYSCONS is not set
# CONFIG_RESET_POLARFIRE_SOC is not set
# CONFIG_RESET_TI_SYSCON is not set
# CONFIG_RESET_GPIO is not set
# CONFIG_SOC_TI is not set
# CONFIG_FSL_RCPM is not set
# CONFIG_SOCIONEXT_SYNQUACER_PREITS is not set
# CONFIG_XILINX_INTC is not set
# CONFIG_XILINX_SDFEC is not set
# CONFIG_XILINX_VCU is not set
# CONFIG_MFD_HI6421_PMIC is not set
# CONFIG_MFD_MT6397 is not set
# CONFIG_RTC_DRV_ZYNQMP is not set
# CONFIG_GPIO_ALTERA is not set
# CONFIG_GPIO_CADENCE is not set
# CONFIG_GPIO_DWAPB is not set
# CONFIG_GPIO_MB86S7X is not set
# CONFIG_GPIO_SYSCON is not set
# CONFIG_GPIO_XGENE is not set
# CONFIG_GPIO_XILINX is not set
# CONFIG_GPIO_AGGREGATOR is not set
# CONFIG_BACKLIGHT_CLASS_DEVICE is not set
# CONFIG_PCI_PWRCTRL_GENERIC is not set
# CONFIG_POWER_SEQUENCING is not set
# CONFIG_QRTR is not set
# CONFIG_UACCE is not set
# CONFIG_PCI_ENDPOINT_TEST is not set
# CONFIG_NVMEM_RMEM is not set
# CONFIG_NVMEM_LAYOUT_SL28_VPD is not set
# CONFIG_NVMEM_REBOOT_MODE is not set
# CONFIG_SYSCON_REBOOT_MODE is not set
# CONFIG_IOMMU_IO_PGTABLE_DART is not set
# CONFIG_IOMMU_IO_PGTABLE_ARMV7S is not set
# CONFIG_SCSI_SAS_LIBSAS is not set

# And x86's equivalent: Intel's Management Engine interface, the WMI and laptop-platform
# drivers, Microsoft Surface support, the package-temperature and thermal-control-circuit
# drivers, which read MSRs a VMM does not virtualize, and ACPI's debug statements and
# initrd table override.
# CONFIG_INTEL_MEI is not set
# CONFIG_X86_PLATFORM_DEVICES is not set
# CONFIG_ACPI_WMI is not set
# CONFIG_SURFACE_PLATFORMS is not set
# CONFIG_X86_PKG_TEMP_THERMAL is not set
# CONFIG_INTEL_TCC_COOLING is not set
# CONFIG_ACPI_DEBUG is not set
# CONFIG_ACPI_TABLE_UPGRADE is not set
# CONFIG_PNP_DEBUG_MESSAGES is not set

# Hardware features of block devices and switches no virtual one has: inline encryption
# engines, T10 protection information, uploading firmware into a device, VLAN and
# multicast registration with a physical switch (GVRP, MVRP), switchdev offload, the
# per-stream gate of time-sensitive networking, and the macvtap device a host gives *its*
# guests. MACVLAN and 802.1Q VLANs themselves stay: they are container networking.
# CONFIG_BLK_INLINE_ENCRYPTION is not set
# CONFIG_BLK_DEV_INTEGRITY is not set
# CONFIG_FW_UPLOAD is not set
# CONFIG_VLAN_8021Q_GVRP is not set
# CONFIG_VLAN_8021Q_MVRP is not set
# CONFIG_NET_SWITCHDEV is not set
# CONFIG_NET_ACT_GATE is not set
# CONFIG_MACVTAP is not set

# Kernel features with nothing in the image to use them: loading another kernel or
# writing a crash dump (no kexec-tools, no kdump), merging identical pages (a host
# feature, for its guests), the contiguous allocator and DMA-buf heaps (for camera and
# display pipelines), and /proc/config.gz (the config is shipped as /boot/config).
# CONFIG_KEXEC_FILE is not set
# CONFIG_CRASH_DUMP is not set
# CONFIG_KSM is not set
# CONFIG_CMA is not set
# CONFIG_DMABUF_HEAPS is not set
# CONFIG_IKCONFIG is not set
# Nor for a RAM-backed oops log, which needs a memory region a bootloader reserves, or
# one in EFI variables, the boot-time memory test, or the BSD-style ptys that predate
# /dev/pts. pstore itself stays on arm64, where ACPI_APEI selects it for error records.
# CONFIG_PSTORE_RAM is not set
# CONFIG_EFI_VARS_PSTORE is not set
# CONFIG_MEMTEST is not set
# CONFIG_LEGACY_PTYS is not set
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
# The two halves are not checked the same way. Everything container.config,
# rootfs.config, k8s.config and guest.config turn on has to be there, no exceptions.
# vm.config is allowed to name symbols that do not exist on this architecture — the
# x86-only lines above are expected to vanish on arm64 — so the bar there is that nothing
# it clears came back on...
#
# ...and that every symbol any fragment names is still defined by *some* Kconfig file in
# the tree, on any architecture. Without that, "not on this arch" and "not any more" look
# the same: a cleared symbol upstream renamed is a line that does nothing, and the driver
# it was clearing comes back under its new name with no check able to notice. This is the
# one that keeps following the latest stable kernel safe — a release that renames a
# symbol fails here, before the compile, instead of quietly changing the image. The cost
# is that a fragment cannot clear a symbol before the kernel it is pinned to has it: a
# line for a driver the next release adds goes in with the bump, not ahead of it.
unapplied=""

kconfig_symbols=$(find . -name 'Kconfig*' -not -path './Documentation/*' -print0 \
    | xargs -0 sed -n -E 's/^[[:space:]]*(menu)?config[[:space:]]+([A-Z0-9_]+)[[:space:]]*$/\2/p' \
    | sort -u)
while read -r sym; do
    if ! grep -qx "$sym" <<< "$kconfig_symbols"; then
        unapplied="$unapplied  CONFIG_$sym  (no Kconfig in this kernel defines it — renamed or removed?)"$'\n'
    fi
done < <(sed -n -E 's/^# CONFIG_([A-Z0-9_]+) is not set$/\1/p; s/^CONFIG_([A-Z0-9_]+)=.*/\1/p' \
             kernel/configs/container.config kernel/configs/rootfs.config \
             kernel/configs/k8s.config kernel/configs/guest.config \
             kernel/configs/vm.config | sort -u)
while read -r sym; do
    if ! grep -qx "$sym" .config; then
        unapplied="$unapplied  $sym  (asked for, not in .config)"$'\n'
    fi
done < <(grep -hE '^CONFIG_[A-Z0-9_]+=y$' kernel/configs/container.config \
             kernel/configs/rootfs.config kernel/configs/k8s.config \
             kernel/configs/guest.config)

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

make

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
install -D -m 644 "$kernel_image" $ROOTFS/boot/bzImage

# The resolved config rides along beside it, the way a distro ships /boot/config-*. The
# check above proves the fragments applied; test/kernel-caps.sh reads this to prove the
# result can actually run a container, which is a different question — a capability the
# defconfig used to provide for free can stop being provided without any fragment
# changing. It is ~250 KB and it is the only record of how the kernel next to it was
# configured, which is worth that on its own when a boot misbehaves.
install -D -m 644 .config $ROOTFS/boot/config

# And under the name software asks for it by. There are no modules, but there is a
# /usr/lib/modules/<release>, for two consumers that look there and nowhere this image
# has: kubeadm's preflight reads the kernel config from a list of conventional paths
# (/proc/config.gz, /boot/config-<release>, /usr/lib/modules/<release>/config — the
# last is where Fedora ships it) and fails the node when it finds none; and kube-proxy's
# DaemonSet, like Calico's and Cilium's, bind-mounts the host's /lib/modules, which on a
# read-only root nothing can create at runtime, so every one of its pods fails with
# "mkdir /lib/modules: read-only file system". A symlink rather than a second copy, and
# /proc/config.gz stays off (vm.config) for the same reason: one copy is enough.
release=$(make -s kernelrelease)
install -d $ROOTFS/usr/lib/modules/$release
ln -sfn ../../../../boot/config $ROOTFS/usr/lib/modules/$release/config
