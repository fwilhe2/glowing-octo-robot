FROM debian:sid

# The native binutils/g++ metapackages pull in a triplet-suffixed package named after the
# *build* architecture (binutils-x86-64-linux-gnu on amd64, binutils-aarch64-linux-gnu on
# arm64) rather than something apt can resolve on its own, so builder/base.sh works out
# which triplet matches the host and passes it in — there is no single package list that
# is correct on both architectures.
ARG DEB_ARCH_TRIPLE

RUN apt-get update && apt-get -y install autoconf automake autopoint autotools-dev binutils binutils-common "binutils-$DEB_ARCH_TRIPLE" bsdextrautils build-essential bzip2 cpp debhelper debugedit dh-autoreconf dh-strip-nondeterminism dpkg-dev dwz file g++ g++-13 "g++-13-$DEB_ARCH_TRIPLE" "g++-$DEB_ARCH_TRIPLE" gettext gettext-base groff-base intltool-debian m4 make man-db patch perl po-debconf rpcsvc-proto xz-utils zip e2fsprogs cpio texlive-latex-base texlive-fonts-recommended man2html-base

WORKDIR /usr/local/src