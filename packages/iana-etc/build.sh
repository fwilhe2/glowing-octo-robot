# The one package here with nothing to compile. iana-etc is data: upstream pulls IANA's
# service-name/port-number and protocol-number registries and generates the two files
# glibc reads, so the tarball ships `services` and `protocols` ready to install.
#
# They go to /etc rather than under --prefix=/usr because glibc hardcodes the paths —
# _PATH_SERVICES is "/etc/services", not a configurable one — which is the same reason
# glibc's own install puts /etc/rpc there. image/build-rootfs.sh copies the staging tree
# in before it overlays image/files, and image/files has neither name, so nothing
# collides.
#
# The .xml files beside them in the tarball are the registries these were generated
# from — upstream's inputs, not anything a booted system reads — so they stay out.
# /etc/services is around 550K on its own, which is the price of the complete registry;
# trimming it would mean deciding which ports someone is allowed to look up.
install -D -m 644 services  /usr/local/rootfs/etc/services
install -D -m 644 protocols /usr/local/rootfs/etc/protocols
