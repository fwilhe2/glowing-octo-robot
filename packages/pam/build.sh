# util-linux's login hard-requires PAM, so we ship it rather than strip it.
# Disable the features that would pull in libs we don't build (libaudit, libselinux,
# libeconf, NIS) and the docs toolchain.
meson_install \
  -Ddocs=disabled -Daudit=disabled -Dselinux=disabled \
  -Deconf=disabled -Dnis=disabled -Dexamples=false
