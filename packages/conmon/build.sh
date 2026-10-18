# meson rather than the Makefile: the Makefile sets its own CFLAGS with `?=`, which the
# exported sysroot flags would replace wholesale, while meson_install hands the sysroot
# over the way every other meson package here gets it. upstream's own -Os comes after
# the buildtype and wins, which is their choice for a process that runs once per
# container.
#
# Into /usr/libexec/podman, the first directory podman searches for it. libsystemd is
# for the journald log driver, which is podman's default here. libseccomp is found and
# *not* linked, correctly: seccomp notify (`--seccomp-policy`) is the raw seccomp(2)
# syscall, and <seccomp.h> is only included for its types.
meson_install -Dbindir=libexec/podman

for lib in libglib-2.0 libsystemd; do
    readelf -d $ROOTFS/usr/libexec/podman/conmon | grep -q "NEEDED.*$lib" || {
        echo "conmon: not linked against $lib, which meson finds or quietly skips" >&2
        exit 1
    }
done
