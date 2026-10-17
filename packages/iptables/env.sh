# iptables, as the nf_tables front end: iptables-nft speaks iptables' command line and
# writes nf_tables rules, which is what lets the image's kernel — built without any of
# the legacy IP_NF_* tables — run software that only knows how to call `iptables`. That
# is most of it: Docker's default firewall backend, kube-proxy's default mode, the CNI
# portmap and firewall plugins, and every firewall script written in the last twenty
# years.
#
# The modern-and-established answer is nft, and for rules this image writes itself it
# would be. But the question here is not which rule language is better, it is which
# binary the software people will run here execs, and that is `iptables`. Debian,
# Fedora, Arch and Alpine all ship it as iptables-nft by default; the legacy backend is
# what they keep for compatibility, and this image does not keep it at all (build.sh).
#
# Versions are not coupled to the kernel's: the nf_tables netlink API is stable, and
# iptables-nft probes for what the running kernel supports.
VERSION="1.8.13"
PACKAGE="iptables-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
URL="https://www.netfilter.org/pub/iptables/${TARBALL}"
SHA256="1afcd33da9e8f913ace6a2126788162e207e26f5d5e29c6573c0e581ffc58b99"
# COPYING is GPLv2. nft.c, libxtables and most extensions say "version 2, or any later
# version"; a handful of extensions (libxt_set, libxt_HMARK, libxt_cluster, ...) say
# version 2 only, and the files with no header of their own fall under COPYING. The
# kernel UAPI headers it vendors under include/linux carry Linux-syscall-note and are
# only compiled against.
LICENSE="GPL-2.0-only AND GPL-2.0-or-later"
