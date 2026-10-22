# elfutils is here for exactly one file: libelf.so.1, which libbpf needs to parse the
# BPF ELF objects systemd has compiled into itself, and `ip` and `tc` link for the same
# reason (attaching a BPF object to a link or a qdisc). Everything else it installs goes — see the end of this file.
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
make
make install DESTDIR=$ROOTFS

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
rm -f $ROOTFS/usr/bin/eu-*

# What is not libelf. libdw (0.7 MiB) and libasm are the DWARF reader and assembler the
# eu-* tools above were built on; systemd is the one thing that would dlopen libdw, for
# coredump backtraces, and packages/systemd/build.sh builds it -Delfutils=disabled
# -Dcoredump=false, so its .note.dlopen does not name it. libdebuginfod is the dummy stub
# configure was asked for, and debuginfod-find is its client — a command that can only
# answer that it was built without debuginfod. The profile.d snippets export
# DEBUGINFOD_URLS for that same client, into every login shell, from a usr/etc that
# nothing reads.
rm -f $ROOTFS/usr/lib/libdw[.-]* $ROOTFS/usr/lib/libasm[.-]* $ROOTFS/usr/lib/libdebuginfod[.-]*
rm -rf $ROOTFS/usr/etc/profile.d/debuginfod.* $ROOTFS/usr/share/fish/vendor_conf.d/debuginfod.fish
drop_installed debuginfod-find
