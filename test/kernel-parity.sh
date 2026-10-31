#!/usr/bin/env bash
# Hold the amd64 and arm64 kernels to the same features:
#
#     ./test/kernel-parity.sh <amd64 config> <arm64 config>    # each a .config, or a tree with boot/config
#
# Each kernel is its arch's defconfig plus the same fragments, and the two defconfigs
# disagree about a great deal that has nothing to do with the architecture: amd64's had
# policy routing, IPsec and SYN cookies and no sock_diag, arm64's had macvlan, tc and
# five boards' crypto engines. parity.config in packages/kernel/build.sh decides those
# once for both; this fails on any symbol both configs define with different values,
# so a defconfig change upstream that brings a difference back is a named failure, not
# something found on one arch at runtime (test/listeners.sh, on arm64 only, is how the
# last one was found).
#
# A symbol only one config defines is the architecture's own, or sits under a menu the
# other has off — and then the menu is what differs, and is reported. What may differ is
# listed below with the reason; keep that list to what is the architecture's own.
#
# It needs both arches' kernels, so CI runs it in a job of its own after the kernel builds
# (`kernel-parity`). Locally, a fetched arm64 kernel config is enough (tools/fetch-image.sh
# ARCH=arm64), or the config from CI's package-kernel-arm64 artifact.
set -euo pipefail

cd "$(dirname "$0")/.."

config_of() {
    if [ -d "$1" ]; then echo "$1/boot/config"; else echo "$1"; fi
}
AMD64=$(config_of "${1:?usage: $0 <amd64 config> <arm64 config>}")
ARM64=$(config_of "${2:?usage: $0 <amd64 config> <arm64 config>}")
for c in "$AMD64" "$ARM64"; do
    [ -f "$c" ] || { echo "error: no kernel config at $c" >&2; exit 1; }
done

# symbol : why it may differ. The architecture's own hardware model, firmware interface
# and toolchain, nothing a program in the image would see differently.
ALLOWED=$(cat <<'EOF'
ACPI_EC                         x86's ACPI embedded controller
ACPI_HED                        arm64's ACPI hardware error device, part of its ACPI core
HOTPLUG_PCI_ACPI                PCI hotplug through ACPI, how arm64's virt board does it
OF                              device tree: arm64 boots with one, amd64 does not
COMMON_CLK                      arm64's clock framework
GPIOLIB                         arm64: the virt board's power button is a GPIO key
PINCTRL                         arm64's pin controllers
POWER_RESET                     arm64's reset drivers
RESET_CONTROLLER                arm64's reset controllers
MFD_SYSCON                      arm64's system controller registers
GENERIC_PHY                     arm64's PHY framework
NVMEM_LAYOUTS                   arm64's NVMEM, which its platform selects
RTC_HCTOSYS                     arm64 sets the clock from the PL031; amd64 reads the CMOS
VT_HW_CONSOLE_BINDING           follows the console drivers each arch has
MEMORY_HOTPLUG                  arm64's ACPI memory hotplug
BLK_DEV_BSGLIB                  selected by arm64's SCSI transport classes
IRQ_POLL                        selected by arm64's block drivers
PACKING                         a library arm64's drivers select
PAGE_POOL_STATS                 arm64's defconfig default for network page pools
IRQ_TIME_ACCOUNTING             per-arch default for IRQ time in CPU accounting
WQ_POWER_EFFICIENT_DEFAULT      arm64's power-saving workqueue default
IOMMU_DEFAULT_DMA_LAZY          per-arch IOMMU default; a VM's virtio devices use none
IOMMU_DEFAULT_DMA_STRICT        the same choice, from arm64's side
PCI_PRI                         x86's IOMMU page requests
NO_HZ                           x86's legacy alias for NO_HZ_IDLE
WERROR                          build setting (x86's defconfig)
LD_ORPHAN_WARN_LEVEL            build setting
CC_VERSION_TEXT                 build setting
FUNCTION_ALIGNMENT              code generation
ARCH_MMAP_RND_BITS              ASLR entropy, from each arch's address space
ARCH_MMAP_RND_BITS_MIN          the same
ARCH_MMAP_RND_BITS_MAX          the same
ARCH_MMAP_RND_COMPAT_BITS       the same, for 32-bit processes
ARCH_MMAP_RND_COMPAT_BITS_MIN   the same
ARCH_PKEY_BITS                  memory protection keys, per arch
CRYPTO_LIB_POLY1305_RSIZE       the arch's Poly1305 implementation
NODES_SHIFT                     NUMA node count, per arch default
SERIAL_8250_NR_UARTS            per-arch default
NLS_DEFAULT                     unused: no filesystem here takes a codepage
EOF
)
allowed=$(awk '{print "CONFIG_" $1}' <<<"$ALLOWED" | sort -u)

# name<TAB>value for every symbol a config defines, "n" for one it says is not set.
values() {
    sed -n -E 's/^(CONFIG_[A-Z0-9_]+)=(.*)$/\1\t\2/p; s/^# (CONFIG_[A-Z0-9_]+) is not set$/\1\tn/p' "$1" |
        LC_ALL=C sort -t $'\t' -k1,1
}

diffs=$(LC_ALL=C join -t $'\t' <(values "$AMD64") <(values "$ARM64") |
        awk -F'\t' '$2 != $3' |
        LC_ALL=C join -t $'\t' -v1 - <(printf '%s\n' "$allowed"))

if [ -n "$diffs" ]; then
    echo "error: the amd64 and arm64 kernels differ (symbol, amd64, arm64):" >&2
    awk -F'\t' '{ printf "  %-40s %-8s %s\n", $1, $2, $3 }' <<<"$diffs" >&2
    echo "Decide it for both in parity.config (packages/kernel/build.sh), clear it in vm.config" >&2
    echo "if it is hardware, or list it in $0 if it is the architecture's own." >&2
    exit 1
fi
echo "kernel parity OK: every symbol both arches define agrees ($(wc -l <<<"$allowed") allowed to differ)"
