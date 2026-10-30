# Binaries compiled in the builder ask for Debian's library names: bash and others want
# libtinfo.so.6. --with-termlib splits it out, --enable-widec makes it the wide one
# (libtinfow, aliased below), and --with-versioned-syms gives it Debian's symbol versions,
# without which every bash start prints "no version information available".
#
# No C++ binding and no pkg-config files: nothing here links the one, and nothing reads
# the other — every package compiles against the builder's -dev headers, and the .pc
# files landed in a multiarch directory the trim does not clean.
./configure --prefix=/usr \
  --with-shared --with-termlib --enable-widec --with-versioned-syms \
  --without-normal --without-debug --without-ada --without-tests \
  --without-cxx-binding --disable-pc-files --disable-stripping
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

# The form, menu and panel libraries, which configure cannot leave out: nothing in the
# image or its extensions links them (procps, bash and the rest want only ncursesw and
# tinfo).
for lib in formw menuw panelw; do
    drop_installed usr/lib/lib$lib.so usr/lib/lib$lib.so.6 usr/lib/lib$lib.so.6.6
done
