# systemd is already built with -Dbpf-framework enabled: its BPF programs are compiled
# by clang in the builder image and embedded as skeletons, and it *dlopens* libbpf.so.1
# at runtime to load them. We just never shipped the library, so every boot logged
#
#     Neither libbpf.so.1 nor libbpf.so.0 are installed, cgroup BPF features disabled.
#
# and IPAddressAllow/Deny, RestrictNetworkInterfaces, SocketBind* and RestrictFileSystems
# all silently did nothing. Note this is not what crun needs — crun talks to the cgroup
# v2 device controller through raw bpf(2) calls and reports +EBPF without any library.
#
# libbpf has no configure; its Makefile lives in src/ and takes the install paths as
# variables. LIBDIR=/usr/lib rather than the default $(PREFIX)/lib64: everything here is
# merged-/usr with lib64 a symlink to usr/lib, and an install into a symlinked directory
# is exactly how a package ends up shipping its files twice.
#
# BUILD_STATIC_ONLY is off by default, so this builds the shared library; the static
# archive is built alongside it and installed, which costs nothing at runtime.
#
# `install` deliberately does not pull in install_uapi_headers: that target drops the
# kernel's linux/bpf.h and friends into /usr/include, which is a different package's job
# on any normal system and nothing here compiles BPF programs anyway.
make -C src -j"$(nproc)" PREFIX=/usr LIBDIR=/usr/lib
make -C src install PREFIX=/usr LIBDIR=/usr/lib DESTDIR=/usr/local/rootfs
