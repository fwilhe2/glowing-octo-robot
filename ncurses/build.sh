# Our binaries are compiled in the Debian builder, so they ask for Debian's library
# names: bash and the util-linux text tools want libtinfo.so.6, while cfdisk and irqtop
# want libncursesw.so.6. Satisfying both means:
#
#   --with-termlib   split the terminfo routines into their own library. Upstream's
#                    default folds them into libncurses and ships no libtinfo at all.
#   --enable-widec   build the wide-character curses library, i.e. libncursesw.
#
# Together these name the terminfo library libtinfow, so it gets aliased below.
./configure --prefix=/usr \
  --with-shared --with-termlib --enable-widec \
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
