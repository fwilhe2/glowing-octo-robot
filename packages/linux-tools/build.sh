# perf and bpftool, from the kernel tree (env.sh has why they share its tarball). Neither
# is built the way the kernel is: the kernel is freestanding, these are programs linked
# against our glibc, so they get the sysroot flags every other package does — handed
# over by name, because kbuild's tools Makefiles start their CFLAGS from scratch and read
# what they are given as EXTRA_CFLAGS.

# libtraceevent first, from the second tarball, as a static library under /tmp that only
# perf sees: perf's Makefile finds it through pkg-config, and with the .so taken away
# the linker takes the archive. The plugins — per-subsystem pretty-printers perf loads
# from a directory at runtime — are not built; tracepoints print through their format
# strings without them.
tep=/tmp/libtraceevent
rm -rf "$tep"
make -C libtraceevent-*/ prefix="$tep" libdir_relative=lib install_libs
rm -f "$tep"/lib/libtraceevent.so*

# perf. Out of tree with O=, so a rebuild starts clean. Each NO_ names something perf
# would otherwise look for, and is here so the answer does not depend on what the
# builder happens to have: the Python and Perl script engines (constraint 5), libdw for
# DWARF unwinding and `perf probe` on source lines (the base trims it — packages/
# elfutils), libunwind, slang for the TUI, numa, babeltrace for CTF export, capstone and
# LLVM for disassembly, libpfm4's event names and systemtap's SDT markers. NO_JEVENTS
# drops the generated tables of vendor PMU events, several megabytes of names for
# counters a VM's virtual CPU mostly does not expose; the architectural events (cycles,
# instructions, cache-misses) and every software event and tracepoint stay.
#
# BPF skeletons stay on: `perf trace` uses one to read syscall arguments behind
# pointers, and `perf lock contention` and `perf stat --bpf-counters` are built on them.
# They are compiled against perf's own minimal vmlinux.h, not the build host's BTF, so
# the result does not depend on the machine — GEN_VMLINUX_H is what would change that.
perf_out=/tmp/build-perf
rm -rf "$perf_out"
mkdir -p "$perf_out"
make -C tools/perf O="$perf_out" prefix=/usr \
    EXTRA_CFLAGS="$CFLAGS" \
    PKG_CONFIG_PATH="$tep/lib/pkgconfig" \
    NO_LIBPYTHON=1 NO_LIBPERL=1 \
    NO_LIBDW=1 NO_LIBUNWIND=1 \
    NO_SLANG=1 NO_GTK2=1 NO_LIBNUMA=1 NO_LIBBABELTRACE=1 NO_BABELTRACE2=1 \
    NO_CAPSTONE=1 NO_LIBLLVM=1 NO_LIBPFM4=1 NO_SDT=1 NO_JVMTI=1 \
    NO_JEVENTS=1 NO_RUST=1 NO_LIBDEBUGINFOD=1 \
    BUILD_BPF_SKEL=1
# Just the binary. `make install` would add perf-archive and perf-iostat (shell),
# the scripts/ tree that is Perl and Python, and tests.
install -D -m 755 "$perf_out/perf" $ROOTFS/usr/bin/perf
# `perf trace` groups its -e names (-e file, -e network) by these lists, which it reads
# from the install prefix at runtime.
install -d $ROOTFS/usr/share/perf-core/strace/groups
install -m 644 tools/perf/trace/strace/groups/* $ROOTFS/usr/share/perf-core/strace/groups/
assert_not_linked libtraceevent usr/bin/perf
assert_not_linked libpython usr/bin/perf
assert_not_linked libperl usr/bin/perf

# bpftool. It builds its own libbpf, statically, from the same tree. The skippable
# dependencies are skipped: LLVM and libbfd only disassemble JIT-compiled programs, and
# libcrypto only signs them. And its BPF skeletons — `bpftool prog profile`, and the
# column of `prog show` naming which process holds each program — are left out, because
# they compile against a vmlinux.h made from whatever kernel BTF it finds, which here
# would be the build host's /sys/kernel/btf/vmlinux: a different binary on every machine.
# An empty VMLINUX_BTF is what turns that search off.
bpftool_out=/tmp/build-bpftool/
rm -rf "$bpftool_out"
mkdir -p "$bpftool_out"
make -C tools/bpf/bpftool OUTPUT="$bpftool_out" prefix=/usr \
    EXTRA_CFLAGS="$CFLAGS" EXTRA_LDFLAGS="$LDFLAGS" \
    SKIP_LLVM=1 SKIP_LIBBFD=1 SKIP_CRYPTO=1 \
    VMLINUX_BTF=
install -D -m 755 "$bpftool_out/bpftool" $ROOTFS/usr/bin/bpftool
