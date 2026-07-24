# -Dlibdir=lib: meson otherwise defaults to the Debian multiarch path.
meson setup --prefix /usr -Dlibdir=lib builddir/
meson compile -C builddir/
meson install -C builddir/ --destdir /usr/local/rootfs
