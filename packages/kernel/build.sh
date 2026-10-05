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

# The two fragments are files beside this script — container.config turns on what a
# container runtime needs, vm.config clears the hardware a VM never has; each says why at
# its top. They are copied into kernel/configs/ because that is where `make <name>.config`
# looks. That runs scripts/kconfig/merge_config.sh, which merges the fragment and then
# re-runs olddefconfig, so anything these symbols select gets pulled in too — and anything
# they ask for that olddefconfig cannot honour is dropped in silence. Nothing upstream
# complains about that; the checks below are what does.
#
# Order matters: vm.config comes second so that where the two disagree the subtractive
# fragment is what olddefconfig sees last. Nothing in it may take away what
# container.config turns on.
cp "$PKGDIR/container.config" kernel/configs/container.config
make container.config
cp "$PKGDIR/vm.config" kernel/configs/vm.config
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
# this architecture — its x86-only lines vanish on arm64 and its ARCH_* lines on amd64 —
# so the bar there is that nothing it clears came back on...
#
# ...and that every symbol either fragment names is still defined by *some* Kconfig file
# in the tree, on any architecture. Without that, "not on this arch" and "not any more"
# look the same: a cleared symbol upstream renamed is a line that does nothing, and the
# driver it was clearing comes back under its new name with no check able to notice.
unapplied=""

kconfig_symbols=$(find . -name 'Kconfig*' -not -path './Documentation/*' -print0 \
    | xargs -0 sed -n -E 's/^[[:space:]]*(menu)?config[[:space:]]+([A-Z0-9_]+)[[:space:]]*$/\2/p' \
    | sort -u)
while read -r sym; do
    if ! grep -qx "$sym" <<< "$kconfig_symbols"; then
        unapplied="$unapplied  CONFIG_$sym  (no Kconfig in this kernel defines it — renamed or removed?)"$'\n'
    fi
done < <(sed -n -E 's/^# CONFIG_([A-Z0-9_]+) is not set$/\1/p; s/^CONFIG_([A-Z0-9_]+)=.*/\1/p' \
             kernel/configs/container.config kernel/configs/vm.config | sort -u)

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

# The lock. The fragments say what we *intend*; config-<arch>.lock beside this script
# records what that *resolved to*: every symbol that is set, with its value, sorted. The
# fragments only constrain the symbols they name, and everything else comes from
# defconfig, which changes with every kernel release — a new `default y` driver, or one
# added to defconfig, is built in with nothing here naming it. Comparing against the lock
# turns that into a diff someone has to accept, before the half-hour compile rather than
# after it.
#
# Left out: symbols whose value Kconfig computes from the toolchain — `$(cc-option ...)`,
# `$(CC_VERSION_TEXT)`, the pahole version. A Debian snapshot bump moves those without
# anything about the kernel having changed, and a lock that changes on every toolchain
# bump teaches people to accept it without reading. They are found from the Kconfig files
# themselves, so a new toolchain probe upstream needs no edit here.
case "$(uname -m)" in
    x86_64)  arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) echo "error: unsupported build architecture: $(uname -m) (expected x86_64 or aarch64)" >&2
       exit 1 ;;
esac

# One pass reads every Kconfig into "symbol has-prompt uses-$( referenced-symbols…"; the
# second takes the prompt-less symbols with a `$(` in their defaults or dependencies and
# closes over the prompt-less symbols that depend on those — CC_HAS_COUNTED_BY is
# `default y if GCC_VERSION >= …`, with no `$(` of its own. A symbol with a prompt is never
# dropped: that is a choice somebody can make, so its changing is worth seeing whatever
# moved it.
toolchain_symbols=$(find . -name 'Kconfig*' -not -path './Documentation/*' -print0 \
    | xargs -0 awk '
        function flush() { if (sym != "") print sym, prompt, dollar, refs; sym = "" }
        /^[[:space:]]*(menu)?config[[:space:]]+[A-Z0-9_]+[[:space:]]*$/ {
            flush(); sym = $2; prompt = 0; dollar = 0; refs = ""; next }
        /^[a-z]/ { flush(); next }
        sym == "" { next }
        /^[[:space:]]+(bool|tristate|string|int|hex|prompt)[[:space:]]+"/ { prompt = 1 }
        /^[[:space:]]+(def_bool|def_tristate|def_int|def_hex|def_string|default|depends[[:space:]]+on)[[:space:]]/ {
            if ($0 ~ /\$\(/) dollar = 1
            line = $0; sub(/^[[:space:]]+[a-z_]+([[:space:]]+on)?/, "", line)
            while (match(line, /[A-Z][A-Z0-9_]+/)) {
                refs = refs " " substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH) }
        }
        END { flush() }' \
    | awk '
        { if ($2) prompted[$1] = 1
          if ($3) seed[$1] = 1
          for (i = 4; i <= NF; i++) ref[$1] = ref[$1] " " $i }
        END {
            for (s in seed) if (!(s in prompted)) tc[s] = 1
            do {
                grew = 0
                for (s in ref) {
                    if ((s in tc) || (s in prompted)) continue
                    n = split(ref[s], r, " ")
                    for (i = 1; i <= n; i++) if (r[i] in tc) { tc[s] = 1; grew = 1; break }
                }
            } while (grew)
            for (s in tc) print s
        }' \
    | LC_ALL=C sort)

lock="$PKGDIR/config-$arch.lock"
resolved="config-$arch.lock.new"
{
    echo "# The kernel config packages/kernel/build.sh resolved for $arch: every symbol that is"
    echo "# set, minus those Kconfig derives from the toolchain. Generated; see build.sh."
    grep -E '^CONFIG_[A-Z0-9_]+=' .config \
        | awk -F= -v skip="$(tr '\n' ' ' <<< "$toolchain_symbols")" '
            BEGIN { n = split(skip, s, " "); for (i = 1; i <= n; i++) drop["CONFIG_" s[i]] = 1 }
            !($1 in drop)' \
        | LC_ALL=C sort
} > "$resolved"

if ! diff -q <(grep -v '^#' "$lock" 2>/dev/null) <(grep -v '^#' "$resolved") >/dev/null; then
    echo "error: the resolved kernel config differs from packages/kernel/config-$arch.lock:" >&2
    if [ ! -f "$lock" ]; then
        echo "  (there is no lock for $arch yet)" >&2
    else
        diff <(grep -v '^#' "$lock") <(grep -v '^#' "$resolved") | grep '^[<>]' \
            | sed -e 's/^</  -/' -e 's/^>/  +/' >&2 || true
    fi
    echo >&2
    echo "A kernel bump, a fragment edit or a toolchain change moved what is built in. Read" >&2
    echo "the lines above: keep each one by accepting the new lock, or clear it in vm.config." >&2
    echo "The proposed lock is packages/kernel/linux-${FLFS_VERSION:-<version>}/$resolved;" >&2
    echo "tools/kernel-config-lock.sh copies it into place (or fetches it from a CI run)." >&2
    exit 1
fi

make

# Building natively rather than cross-compiling means `make defconfig` already picked
# x86_64_defconfig or arm64 defconfig on its own, from SUBARCH's `uname -m` — the
# configuration is not arch-conditional, only the lock it is compared against. But the two arches don't put the finished image
# in the same place or call it the same thing: x86 emits a self-decompressing bzImage,
# arm64 emits a plain Image (qemu-system-aarch64's -kernel loads that directly; there is
# no bzImage equivalent). Staged under one conventional name either way, so nothing
# downstream (test/, tools/, ci.yml) needs to know which arch built it.
case "$arch" in
    amd64) kernel_image=arch/x86/boot/bzImage ;;
    arm64) kernel_image=arch/arm64/boot/Image ;;
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
