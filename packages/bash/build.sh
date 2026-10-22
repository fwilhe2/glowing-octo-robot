./configure --prefix=/usr
make
make install DESTDIR=$ROOTFS

# /bin/sh, which upstream does not install: which shell answers to that name is the
# distribution's decision, not bash's. This one had not made it, so the image had no
# /bin/sh at all — a stranger position than it sounds, since every `#!/bin/sh` script in
# the world is then a file it cannot start. That is not hypothetical: it is `crun spec`'s
# default `"args": ["sh"]`, a container entrypoint, a systemd unit that shells out, and
# the wrapper scripts several of these packages install. bash is the only interpreter
# here (constraint 5) so it is the only candidate, and Fedora and Arch both point
# /usr/bin/sh at it exactly like this.
#
# Invoked under this name bash follows sh's startup-file behaviour on its own, which is
# what the name is a promise about. It is not full POSIX mode — that needs --posix or
# POSIXLY_CORRECT — so a script relying on bashisms still works, and one that does not is
# none the wiser. The cost is a symlink.
#
# -f because rootfs/ is cumulative: a rebuild would otherwise meet the previous one's.
ln -sf bash $ROOTFS/usr/bin/sh

# Two things `make install` adds that a booted image cannot use. The loadable builtins in
# usr/lib/bash (0.6 MiB) are bash's examples directory compiled: `enable -f` can load
# them, but most duplicate a coreutils program already in the image — sleep, rm,
# cut, mkdir, stat — and Debian ships them as bash-builtins, separately, for that reason.
# And bashbug mails a bug report through a sendmail the image does not have.
[ -d $ROOTFS/usr/lib/bash ] || { echo "bash: usr/lib/bash is not installed — stale removal" >&2; exit 1; }
rm -rf $ROOTFS/usr/lib/bash
drop_installed bashbug
