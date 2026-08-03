# elfutils is here for exactly one file: libelf.so.1, which libbpf needs to parse the
# BPF ELF objects systemd has compiled into itself. libdw.so.1 comes along with it and
# is not wasted either — systemd dlopens it for coredump stack traces.
#
# --disable-debuginfod / --enable-libdebuginfod=dummy: the debuginfod client and server
# want libcurl, libmicrohttpd and sqlite3, none of which we ship. The dummy libdebuginfod
# is a stub with the same ABI, so anything that links it still resolves, and nothing in
# the image asks it to fetch anything.
#
# --without-bzlib: libbz2 is not a package here, and it would only be used to read
# bzip2-compressed debug sections. liblzma and libzstd are packages (xz, zstd), so those
# stay on.
#
# --disable-nls: no gettext catalogues in the image, and it keeps libintl out of the
# link.
#
# CFLAGS: elfutils puts -Werror in AM_CFLAGS and has no --disable-werror to turn it off,
# and sid's gcc finds new things to warn about in released tarballs on a regular basis —
# which says nothing about this image. CFLAGS is appended after AM_CFLAGS on the compile
# line, so -Wno-error there wins. It has to carry the exported $CFLAGS over by hand:
# passing CFLAGS to configure replaces the environment variable rather than adding to
# it, and those are the flags that point the compiler at our glibc.
./configure --prefix=/usr --libdir=/usr/lib \
  --disable-debuginfod --enable-libdebuginfod=dummy \
  --without-bzlib \
  --disable-nls \
  CFLAGS="${CFLAGS:-} -Wno-error"
make -j"$(nproc)"
make install DESTDIR=/usr/local/rootfs

# The eu-* tools (readelf, nm, strip, addr2line, …) are not why elfutils is here, and
# shipping them is what makes the build fail check-rootfs-deps: eu-srcfiles is the one
# C++ program in the tree, so it drags in libstdc++.so.6 and libgcc_s.so.1, and it links
# libarchive.so.13 whenever the builder image happens to have it. None of the three is a
# package here. Configuring them away is not an option — --disable-demangler drops the
# libstdc++ *demangle* call but srcfiles.cxx still links the C++ runtime, and the tools
# are built unconditionally. Dropping the binaries after the install keeps the libraries,
# which is all libbpf and systemd ever wanted, and leaves the image with no dependency the
# rootfs cannot resolve. The glob covers the bin_SCRIPTS entry (eu-make-debug-archive)
# too: configure defaults program_prefix to "eu-" for everything in bin_PROGRAMS.
rm -f /usr/local/rootfs/usr/bin/eu-*
