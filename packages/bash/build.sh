./configure --prefix=/usr
make
make install DESTDIR=/usr/local/rootfs

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
ln -sf bash /usr/local/rootfs/usr/bin/sh
