# The OCI runtime. crun rather than runc or youki: it is podman's default runtime and
# from the same project, it is C and so the smallest of the three by a wide margin, and it
# is the one that starts fastest — which a VM that boots straight into containers notices.
# The builder has Go and Rust now (for podman and netavark), so this is no longer forced;
# it is simply still the right answer.
#
# What stays on:
#   caps     — libcap is a package already, and dropping capabilities is the whole point
#   systemd  — crun asks systemd over sd-bus to create the cgroup v2 scope instead of
#              writing to the unified hierarchy behind its back. We are systemd end to
#              end, so this is the driver that matches; libsystemd is already shipped.
#   dl       — dlopen lives in glibc
#   seccomp  — a bundle's syscall filter enforced, through packages/libseccomp. It was
#              --disable-seccomp until that package existed, which meant every profile,
#              Docker's and podman's default ones included, was accepted and silently
#              ignored. `crun features` reports it.
#   bpf      — NOT optional in practice, despite reading like a feature flag. On cgroup
#              v2 the device controller *is* a BPF program: write_devices_resources_v2()
#              calls libcrun_ebpf_load() unconditionally, and a crun built --disable-bpf
#              fails there with "eBPF not supported" rather than skipping the rule. The
#              default `crun spec` output carries a deny-all devices rule, so that is
#              every container, not an exotic bundle. It costs nothing to keep: eBPF
#              here is a raw syscall plus linux/bpf.h, with no library to ship or miss.
#              The kernel fragment turns BPF_SYSCALL and CGROUP_BPF on for this.
#
# What is off, and what it costs:
#   criu     — checkpoint/restore, which wants libcriu and libprotobuf-c.
#
# --disable-libcrun: crun is also a C library, and installing it puts a 2MB static
# libcrun.a and a libtool .la file in /usr/lib for nothing — we want the runtime
# binary. (--disable-static does not cover this; libcrun.a is built either way.)
./configure --prefix=/usr \
  --disable-libcrun \
  --disable-criu
make
make install DESTDIR=$ROOTFS

# configure finds libseccomp or quietly builds without it, so check the binary rather
# than trusting the flag (see packages/iproute2/build.sh for the other direction).
readelf -d $ROOTFS/usr/bin/crun | grep -q 'libseccomp\.so' || {
    echo "crun: built without libseccomp — seccomp profiles would be ignored" >&2
    exit 1
}
