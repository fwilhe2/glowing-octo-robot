# --disable-kill: util-linux already installs kill, and the staging tree is shared — the
# second package to install a name silently wins it. util-linux's is the one the rest of
# the image was tested with, so procps gives way.
#
# --with-systemd: ps learns the unit, slice and session columns (`ps -o unit`), and w and
# uptime count sessions from logind instead of utmp. logind is the session record here
# (pam_systemd registers every login with it; packages/util-linux/build.sh drops last and
# utmpdump on the same grounds), and procps itself prefers it when built this way.
# libsystemd.so.0 is in both flavours of the image (see the subtractions block in
# image/build-rootfs.sh), so this costs no library.
#
# --enable-watch8bit: links the curses tools against libncursesw rather than libncurses.
# Our ncurses is built --enable-widec and ships only the wide library, so without this
# top, watch and slabtop would ask for a libncurses.so.6 that is not in the image —
# configure finds Debian's in the builder and the build succeeds regardless.
#
# --disable-nls for the same reason as util-linux: the image is C-locale only.
./configure --prefix=/usr \
    --disable-static \
    --disable-nls \
    --disable-kill \
    --with-systemd \
    --enable-watch8bit
make
make install DESTDIR=$ROOTFS

# The narrow-character library would have to be named exactly: assert_not_linked matches
# a substring, and libncurses is one of libncursesw.
for bin in usr/bin/top usr/bin/watch usr/bin/slabtop; do
    if readelf -d "$ROOTFS/$bin" | grep -q 'NEEDED.*\[libncurses\.so'; then
        echo "error: $bin is linked against libncurses.so, which the image does not ship" >&2
        exit 1
    fi
done
