# cargo_build (builder/build-package.sh) is the whole compile: vendored crates, our glibc,
# and the static unwinder in place of libgcc_s. The rest is upstream's install list, from
# packaging/arch/PKGBUILD, minus what the image has no use for.
cargo_build

install -Dm755 target/release/nspawn "$ROOTFS/usr/bin/nspawn"
assert_not_linked libgcc_s usr/bin/nspawn

# The root service the CLI talks to. Bus-activated by its D-Bus name rather than enabled:
# nothing starts it at boot, so a daemon that cannot work yet — see env.sh — costs no
# failed unit and no `degraded` until somebody actually asks it for something.
install -Dm644 packaging/systemd/nspawn.service "$ROOTFS/usr/lib/systemd/system/nspawn.service"
install -Dm644 packaging/systemd/journald@nspawn.conf "$ROOTFS/usr/lib/systemd/journald@nspawn.conf"
install -Dm644 packaging/dbus/org.nspawn.service "$ROOTFS/usr/share/dbus-1/system-services/org.nspawn.service"
install -Dm644 packaging/dbus/org.nspawn.conf "$ROOTFS/usr/share/dbus-1/system.d/org.nspawn.conf"
install -dm755 "$ROOTFS/etc/nspawn"
install -dm711 "$ROOTFS/var/lib/nspawn"

# Left out, each for a reason rather than for size:
#
#   packaging/polkit/*        there is no polkitd; systemd is built -Dpolkit=disabled
#   packaging/selinux/*       no SELinux userspace or policy (kernel vm.config clears it)
#   completions, manpage      upstream generates them by running the binary; the image
#                             trims share/man and shell completions anyway
#   README, docs, LICENSE*    usr/share/doc is trimmed too; the license is in the SBOM
