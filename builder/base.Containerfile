FROM debian:sid

RUN apt-get update && apt-get -y install autoconf automake autopoint autotools-dev binutils binutils-common binutils-x86-64-linux-gnu bsdextrautils build-essential bzip2 cpp debhelper debugedit dh-autoreconf dh-strip-nondeterminism dpkg-dev dwz file g++ g++-13 g++-13-x86-64-linux-gnu g++-x86-64-linux-gnu gettext gettext-base groff-base intltool-debian m4 make man-db patch perl po-debconf rpcsvc-proto xz-utils zip e2fsprogs cpio texlive-latex-base texlive-fonts-recommended man2html-base

WORKDIR /usr/local/src