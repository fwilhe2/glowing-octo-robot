# Our binaries are compiled in the Debian builder, so they ask for Debian's library
# names: bash and the util-linux text tools want libtinfo.so.6, while cfdisk and irqtop
# want libncursesw.so.6. Satisfying both means:
#
#   --with-termlib        split the terminfo routines into their own library. Upstream's
#                         default folds them into libncurses and ships no libtinfo.
#   --enable-widec        build the wide-character curses library, i.e. libncursesw.
#   --with-versioned-syms attach ncurses' symbol versions (NCURSES6_TINFO_5.0.19991023
#                         and friends). Debian builds with these, so our binaries carry
#                         version requirements for them; without the matching version
#                         definitions the loader falls back to an unversioned lookup and
#                         every bash startup prints
#                             /lib64/libtinfo.so.6: no version information available
#
# --with-termlib and --enable-widec together name the terminfo library libtinfow, so it
# gets aliased below.
./configure --prefix=/usr \
  --with-shared --with-termlib --enable-widec --with-versioned-syms \
  --without-normal --without-debug --without-ada --without-tests \
  --enable-pc-files --disable-stripping
make
make install DESTDIR=/usr/local/rootfs

# The wide and non-wide terminfo ABIs are identical — widec only changes the curses
# layer on top — so libtinfo.so.6 can just point at libtinfow.so.6. Debian likewise
# ships a single libtinfo built from its wide-character configuration.
libdir=/usr/local/rootfs/usr/lib
if [ ! -e "$libdir/libtinfow.so.6" ]; then
    echo "error: --with-termlib produced no libtinfow.so.6 in $libdir" >&2
    exit 1
fi
ln -sfv libtinfow.so.6 "$libdir/libtinfo.so.6"
