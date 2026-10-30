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
meson_install \
  -Dsystemd=enabled -Dsystemd_system_unitdir=/usr/lib/systemd/system \
  -Dmessage_bus=true -Dtools=true \
  -Dselinux=disabled -Dapparmor=disabled -Dlibaudit=disabled \
  -Dx11_autolaunch=disabled \
  -Dxml_docs=disabled -Dducktype_docs=disabled -Ddoxygen_docs=disabled \
  -Dmodular_tests=disabled -Dinstalled_tests=false \
  -Dsystem_socket=/run/dbus/system_bus_socket -Dsystem_pid_file=/run/dbus/pid \
  -Dtraditional_activation=false

# -Dtraditional_activation=false: no dbus-daemon-launch-helper. It starts a service the
# bus activates without systemd, which none here is (each names SystemdService=, and
# systemd1's is Exec=/bin/false on purpose), and it needs setuid root, which nothing in
# this image is allowed.
#
# -Dtools has no finer switch. dbus-send and dbus-monitor stay, for poking at the bus.
# The rest are for a session bus systemd's user instance already provides: dbus-launch
# and dbus-run-session start one by hand, dbus-update-activation-environment feeds a
# desktop session's environment to it, dbus-cleanup-sockets removes what such hand-
# started buses leave in /tmp, dbus-uuidgen writes the machine ID systemd already owns,
# and dbus-test-tool is a test fixture. The arch header is for building against libdbus.
drop_installed dbus-launch dbus-run-session dbus-update-activation-environment \
               dbus-cleanup-sockets dbus-uuidgen dbus-test-tool \
               usr/lib/dbus-1.0/include
