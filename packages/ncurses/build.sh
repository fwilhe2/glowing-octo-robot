# Binaries compiled in the builder ask for Debian's library names: bash and others want
# libtinfo.so.6. --with-termlib splits it out, --enable-widec makes it the wide one
# (libtinfow, aliased below), and --with-versioned-syms gives it Debian's symbol versions,
# without which every bash start prints "no version information available".
./configure --prefix=/usr \
  --with-shared --with-termlib --enable-widec --with-versioned-syms \
  --without-normal --without-debug --without-ada --without-tests \
  --enable-pc-files --disable-stripping
make
make install DESTDIR=$ROOTFS

# The terminfo ABI is the same wide or not, so libtinfo.so.6 is an alias, as in Debian.
libdir=$ROOTFS/usr/lib
if [ ! -e "$libdir/libtinfow.so.6" ]; then
    echo "error: --with-termlib produced no libtinfow.so.6 in $libdir" >&2
    exit 1
fi
ln -sfv libtinfow.so.6 "$libdir/libtinfo.so.6"

# The terminfo authoring tools, tset and tabs, and the config script for headers the trim
# deletes. clear and tput stay (--without-progs would take them too). drop_installed
# counts the dangling alias links as installed.
drop_installed tic captoinfo infotocap infocmp toe tset reset tabs ncursesw6-config
