# systemd-logind and everything else with a D-Bus API needs a system bus to connect to;
# without one logind exits with "Failed to connect to system bus" and systemd restarts
# it until it hits the start limit.
#
# -Dsystemd=enabled is what makes this a *systemd* bus rather than a standalone daemon:
# it installs dbus.service/dbus.socket, the sysusers.d snippet that creates the
# messagebus user on first boot and the tmpfiles.d snippet that creates /run/dbus, and
# it enables itself through the .target.wants symlinks in its own unit directory.
#
# The disabled features drop optional runtime libs we don't ship (libselinux, libaudit,
# libapparmor, and libX11 — dbus-launch would autolaunch a session bus from an X display
# and there is no X here) and the documentation toolchain; expat is built as a package.
# -Dlibdir=lib: meson defaults libdir to the Debian multiarch path on this builder,
# which the rest of the system doesn't search.
# --buildtype=release: meson's default is `debug`, which is -O0. See "the three things
# that break silently" in CLAUDE.md.
meson setup --prefix /usr --buildtype=release -Dlibdir=lib \
  -Dsystemd=enabled -Dsystemd_system_unitdir=/usr/lib/systemd/system \
  -Dmessage_bus=true -Dtools=true \
  -Dselinux=disabled -Dapparmor=disabled -Dlibaudit=disabled \
  -Dx11_autolaunch=disabled \
  -Dxml_docs=disabled -Dducktype_docs=disabled -Ddoxygen_docs=disabled \
  -Dmodular_tests=disabled -Dinstalled_tests=false \
  -Dsystem_socket=/run/dbus/system_bus_socket -Dsystem_pid_file=/run/dbus/pid \
  build
meson compile -C build
meson install -C build --destdir /usr/local/rootfs
