# util-linux's login hard-requires PAM, so we ship it rather than strip it.
# Disable the features that would pull in libs we don't build (libaudit, libselinux,
# libeconf, NIS) and the docs toolchain.
meson_install \
  -Ddocs=disabled -Daudit=disabled -Dselinux=disabled \
  -Deconf=disabled -Dnis=disabled -Dexamples=false

# libpamc is the client half of PAM's binary-prompt protocol, which no module or program
# here speaks.
drop_installed usr/lib/libpamc.so usr/lib/libpamc.so.0 usr/lib/libpamc.so.0.82.1
