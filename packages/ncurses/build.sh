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

# ncurses installs a terminfo *authoring* toolkit next to the two runtime tools. tic
# compiles a terminfo source description into the binary form, captoinfo and infotocap
# convert between termcap and terminfo, infocmp decompiles one back to source, and toe
# lists what is in the database — all of which operate on a database that
# image/build-rootfs.sh has already trimmed to a dozen entries and that nothing in the
# image will ever add to. tset (and its `reset` alias) initialises a terminal from an
# interactive login's guesswork about what it is talking to; the console here is a serial
# line with TERM set by the getty. tabs sets hardware tab stops on a physical terminal.
# ncursesw6-config is the same case as curl-config — it tells a compiler where the
# headers are, and the trim deletes the headers.
#
# `clear` and `tput` stay. They are the two a shell script or a person at the console
# actually calls, they cost about 50 KB together, and they read the trimmed database
# rather than writing to it.
#
# --without-progs would be the tidier switch and takes clear and tput with it, so this
# is a list instead.
#
# The test is `-e || -L` rather than plain `-e`, because several of these are symlinks
# onto each other — captoinfo and infotocap point at tic, reset points at tset — and
# removing the target first leaves the alias dangling, where `-e` is false and a plain
# check would fail the build on its own previous iteration.
for prog in tic captoinfo infotocap infocmp toe tset reset tabs ncursesw6-config; do
    f=/usr/local/rootfs/usr/bin/$prog
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then
        echo "ncurses: $prog is not installed — this removal list is stale" >&2
        exit 1
    fi
    rm -f "$f"
done
