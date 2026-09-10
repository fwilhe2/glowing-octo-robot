# The SSH server, and the first thing this image ever *listens* on — which is a change of
# security posture rather than merely another package, and is the reason this one is worth
# arguing about before it is worth packaging.
#
# It is here for the `lima` variant (docs/image-variants.md): `limactl start` boots the
# guest and then does everything else over ssh, so a VM somebody actually works in needs a
# server before it needs anything else on Lima's list. Nothing else here wanted one — a
# machine reached over a serial console does not — so this is the first package whose
# reason is somebody else's requirements document.
#
# There is no second candidate. Dropbear and tinyssh are the alternatives and neither is
# close: Lima writes OpenSSH configuration verbatim into its own ssh_config (multiplexing
# through ControlMaster/ControlPath, reverse forwards, a pile of `-o` settings), the
# reverse-sshfs mount is an OpenSSH client talking to an OpenSSH server, and every
# distribution's `ssh` is this one. It is C, and it links only libraries the image already
# ships: libcrypto from openssl, libz from zlib, libpam from pam and libcrypt from
# libxcrypt.
#
# It ships no interpreted helper either (constraint 5): the one shell script in the
# tarball is contrib/ssh-copy-id, which `make install` does not install.
#
# The OpenSSL coupling curl's env.sh describes applies here too and for the same reason —
# this compiles against sid's libssl-dev headers and asks libcrypto.so.3 for its symbols
# at runtime, which packages/openssl answers only while it stays on a 3.x release.
VERSION="10.5p1"
PACKAGE="openssh-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
URL="https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/${TARBALL}"
SHA256="d44d28a839ea9daf969cc69150fde59910b2b39361dad81a3bd6cbd19218db11"
# Read off the tarball's LICENCE, which enumerates them rather than naming one: the
# OpenSSH licence proper for Tatu Ylonen's original code (1 and 2), ssh-keyscan's own
# terms (3), the public-domain Rijndael implementation (4), 3-clause BSD for the Berkeley
# code (5), 2-clause BSD for everything else (6), and 3-clause BSD, ISC and X11 across
# openbsd-compat (8). All of it is BSD-ish or freer — the file's own opening summary — and
# openssh has been in Debian main since there was a Debian main.
LICENSE="SSH-OpenSSH AND ssh-keyscan AND BSD-2-Clause AND BSD-3-Clause AND ISC AND X11 AND LicenseRef-PublicDomain"
# Portable OpenSSH numbers itself <upstream>p<portable>, so the version is 10.5p1 and not
# 10.5. tools/upstream.sh understands that suffix; nothing else here has one, which is why
# the pattern in that script had to learn it.
