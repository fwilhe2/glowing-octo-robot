# Four small programs, of which `ping` is the one anyone asked for. What is switched off:
#
#   USE_IDN         libidn2 is in neither builder/deps.txt nor the image, so meson would
#                   not find it today. Saying so anyway is what keeps a future deps.txt
#                   line added for some other package from silently putting
#                   libidn2.so.0 into ping's NEEDED.
#   USE_GETTEXT     the image is C-locale only and the trim deletes share/locale, so the
#                   catalogues would be built and installed to be thrown away.
#   BUILD_MANS      the man pages are docbook, and there is no man to read them anyway.
#   BUILD_CLOCKDIFF ICMP timestamp requests, which every firewall built this century
#                   drops. Debian still ships it; nothing here would use it.
#   SKIP_TESTS      the test suite is pytest, which the builder image has no reason to
#                   grow for four programs.
#
# USE_CAP stays on: libcap is a package, and ping uses it to drop CAP_NET_RAW as soon as
# the socket is open rather than staying privileged for the run.
#
# NO_SETCAP_OR_SUID defaults to true, which is what we want — nothing here installs
# setuid, and file capabilities would not survive the image build in any case. That
# leaves ping working for root, and for everyone else through the datagram ICMP socket
# image/files/etc/sysctl.d/50-ping-group-range.conf enables.
meson setup --prefix /usr \
  -DUSE_IDN=false \
  -DUSE_GETTEXT=false \
  -DBUILD_MANS=false \
  -DBUILD_CLOCKDIFF=false \
  -DSKIP_TESTS=true \
  build
meson compile -C build
meson install -C build --destdir /usr/local/rootfs
