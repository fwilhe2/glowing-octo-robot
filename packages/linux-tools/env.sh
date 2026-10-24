# perf and bpftool, which live in the kernel's source tree (tools/perf, tools/bpf) and
# are released with it. perf is the kernel's own profiler and tracer — counters,
# sampling, `perf trace` for every process at once; bpftool lists the BPF programs
# loaded right now, which on this image means systemd's sandboxing and crun's device
# controller, and nothing else can show them.
#
# The kernel's tarball, the kernel's version: sourced rather than copied, so a kernel
# bump moves these with it and the two can never disagree. That makes this the one
# package that is not its own upstream — FOLLOWS says so, and tools/check-updates.sh
# and tools/bump-version.sh read it and leave the package to packages/kernel.
source packages/kernel/env.sh
FOLLOWS=kernel
# The kernel is freestanding; these are ordinary programs against our glibc.
unset NO_SYSROOT
# libtraceevent is the second tarball, for the same reason libpcap is tcpdump's: an
# extension's packages cannot compile against each other, and perf is its only
# consumer. Without it perf builds, but `perf trace` does not and tracepoints print as
# raw bytes. A snapshot of the tag, which is how Debian fetches it too and which came
# back byte-identical on repeated downloads when this was pinned.
LIBTRACEEVENT_VERSION="1.9.1"
VENDOR_TARBALL="libtraceevent-${LIBTRACEEVENT_VERSION}.tar.gz"
VENDOR_URL="https://git.kernel.org/pub/scm/libs/libtrace/libtraceevent.git/snapshot/${VENDOR_TARBALL}"
VENDOR_SHA256="3bc19dd940914260ba591b5276723bf84bb43f82c7c3d4267622bee4d016ea55"
LICENSE="GPL-2.0-only AND (LGPL-2.1-only OR BSD-2-Clause) AND LGPL-2.1-only"
# In the debug system extension (docs/debugging.md).
EXTENSION=debug
