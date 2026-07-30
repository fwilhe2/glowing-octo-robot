# The OCI runtime. crun rather than runc or youki because it is the only one written in
# C: the other two would mean a Go or Rust toolchain in the builder image, and a binary
# that never passes through the --sysroot machinery in lib/build-package.sh.
#
# What stays on:
#   caps     — libcap is a package already, and dropping capabilities is the whole point
#   systemd  — crun asks systemd over sd-bus to create the cgroup v2 scope instead of
#              writing to the unified hierarchy behind its back. We are systemd end to
#              end, so this is the driver that matches; libsystemd is already shipped.
#   dl       — dlopen lives in glibc
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
#   seccomp  — no libseccomp package yet, so a bundle's seccomp profile is accepted and
#              ignored rather than enforced. systemd is built -Dseccomp=disabled for the
#              same reason; packaging libseccomp would let both be turned back on. This
#              one really is a silent downgrade — check `crun features` before trusting
#              a bundle's syscall filter.
#   criu     — checkpoint/restore, which wants libcriu and libprotobuf-c.
#
# --disable-libcrun: crun is also a C library, and installing it puts a 2MB static
# libcrun.a and a libtool .la file in /usr/lib for nothing — we want the runtime
# binary. (--disable-static does not cover this; libcrun.a is built either way.)
./configure --prefix=/usr \
  --disable-libcrun \
  --disable-seccomp \
  --disable-criu
make -j"$(nproc)"
make install DESTDIR=/usr/local/rootfs
