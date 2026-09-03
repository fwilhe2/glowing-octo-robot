# openssh is the first package here that arrives with a *service*: a daemon to start, an
# account to run its privilege separation as, and a PAM stack to authenticate through.
# All three are written into DESTDIR at the bottom of this file rather than added to
# image/files, and that placement is the one decision in here worth reading twice.
#
# The reason is selection (docs/image-variants.md). image/files is copied into every
# image; a manifest belongs to one package. A unit in /etc that names an ExecStart the
# image does not contain is a failed unit and a `degraded` boot — which is exactly what
# `minimal` and `net` would ship if sshd.service came from image/files, since neither
# selects openssh. Installed from here, the whole apparatus is claimed by openssh's
# manifest and goes away with the package, for free, in every variant that does not ask
# for it. The pam.d stack and sshd_config follow the units for consistency rather than
# necessity: those two are inert without a daemon, but splitting one package's
# configuration across two mechanisms would be worse than either.
#
# --sysconfdir=/etc/ssh rather than the /usr/etc/ssh that --prefix=/usr would give, which
# is where sshd, ssh and ssh-keygen all look, and what every other system means by it.
#
# --with-pam is what buys a real session: pam_systemd.so registers the login with
# systemd-logind, the same way image/files/etc/pam.d/login does for the serial console.
# Without it sshd checks /etc/shadow itself and logind never sees the session.
#
# --with-sandbox=seccomp_filter names the sandbox the privilege-separated child runs in
# rather than letting configure pick. It would pick this anyway on Linux, and that is the
# point: a header that stopped being found would silently downgrade the child to the
# `rlimit` sandbox, which is a security property changing without a diff. It needs no
# library — openssh builds the filter with raw seccomp(2), not libseccomp, so this is one
# sandbox that costs nothing here (crun's --disable-seccomp is about the library).
#
# --with-default-path/--with-superuser-path are the PATH a non-login session gets, i.e.
# `ssh flfs uptime` rather than `ssh flfs`. image/files/etc/profile pins the same value
# for login shells; without these two the compiled-in default names /usr/sbin and /sbin,
# which on a merged-/usr image are the same directory twice.
#
# The --without/--disable block below is the deps.txt discipline (CLAUDE.md): none of
# these libraries are in the builder image, so configure would not find them today — but
# a line added to deps.txt for some other package would silently put a new .so into
# sshd's NEEDED, and naming them makes that impossible rather than unlikely. selinux and
# audit have no userspace here at all; libedit is line editing for sftp; ldns is a DNSSEC
# resolver, which is systemd-resolved's job (constraint 4); wtmpdb is a login database
# nothing here reads.
#
# --disable-security-key and --disable-pkcs11 are the other kind: both are dlopen
# interfaces to a provider — libfido2 for FIDO tokens, a PKCS#11 .so for smartcards —
# that this image will never contain, and a VM has no USB to plug one into (constraint 2).
#
# The login-record switches are last because they are the least obvious. utmp, wtmp and
# lastlog are files something has to create and something has to read, and this image has
# neither end: systemd stopped maintaining utmp/wtmp in v257, nothing creates
# /var/log/lastlog, and util-linux is already built --disable-last --disable-lslogins.
# Leaving the code in would have sshd writing login records into files that do not exist,
# which fails silently and is the definition of dead weight.
#
# --disable-strip leaves the binaries with their symbols in the staging tree, which is
# where a CI failure gets debugged from; image/build-rootfs.sh strips every ELF object in
# the image anyway, so this changes what is shipped not at all.
./configure \
    --prefix=/usr \
    --sysconfdir=/etc/ssh \
    --libexecdir=/usr/libexec \
    --with-pid-dir=/run \
    --with-privsep-path=/var/empty \
    --with-privsep-user=sshd \
    --with-default-path=/usr/local/bin:/usr/bin \
    --with-superuser-path=/usr/local/bin:/usr/bin \
    --with-pam \
    --with-zlib \
    --with-sandbox=seccomp_filter \
    --without-selinux \
    --without-audit \
    --without-libedit \
    --without-ldns \
    --without-wtmpdb \
    --without-kerberos5 \
    --without-ssl-engine \
    --without-security-key-builtin \
    --disable-security-key \
    --disable-pkcs11 \
    --disable-lastlog \
    --disable-utmp \
    --disable-utmpx \
    --disable-wtmp \
    --disable-wtmpx \
    --disable-strip

make -j"$(nproc)"

# install-nokeys, not install. The default target also runs `host-key`, which generates
# host keys, and `check-config`, which executes the sshd just built against the config
# just installed.
#
# Neither would do damage as things stand — the Makefile guards host-key with `if [ -z
# "$(DESTDIR)" ]`, and check-config is prefixed with `-` so its failure is ignored — but
# both are the wrong thing to depend on. Private host keys baked into an image built from
# a public repository would be the same key on every machine that ever boots it, which is
# a real compromise and one upstream refactor away from happening by accident; and a build
# step whose failure is ignored is a build step not worth having. The keys are generated
# on first boot instead, by the unit further down.
make install-nokeys DESTDIR=/usr/local/rootfs

# Three helpers `make install` puts in libexec that this image has no use for. Removed
# rather than left to ship, and the loop insists each one is really there first: a bare
# `rm -f` of a name upstream has renamed removes nothing, says nothing, and ships the
# binary — the same idiom and the same reasoning as packages/util-linux/build.sh.
#
#   ssh-keysign            installed setuid root (mode 4711), and used by exactly one
#                          thing: HostbasedAuthentication, which is off. Nothing in this
#                          image is setuid today and this is not the file to start with —
#                          see the ping note in CLAUDE.md for how carefully that has been
#                          avoided elsewhere.
#   ssh-pkcs11-helper      the two features disabled above still build and install their
#   ssh-sk-helper          helper as a stub, because the Makefile's install list is not
#                          conditional. They are execed only when a provider is
#                          configured, which the compiled-out code can never be.
for helper in ssh-keysign ssh-pkcs11-helper ssh-sk-helper; do
    if [ ! -e "/usr/local/rootfs/usr/libexec/$helper" ]; then
        echo "openssh: $helper is not installed — this removal list is stale" >&2
        exit 1
    fi
    rm -f "/usr/local/rootfs/usr/libexec/$helper"
done

# ---------------------------------------------------------------------------------
# The server's configuration, replacing the one install-sysconf wrote. Upstream ships a
# file whose every line is commented out — it documents the compiled-in defaults rather
# than setting anything — so the four lines that are not defaults are the whole policy
# this image has about being logged into.
#
# The Include comes first because in sshd_config the *first* setting of an option wins,
# which makes a drop-in directory an override only if it is read before the file that
# would otherwise decide. That is what lets a variant — `lima`, next — change policy
# without rewriting this file.
#
# UsePAM yes: see --with-pam above. The compiled default is no.
#
# PermitRootLogin prohibit-password is the compiled default, written down because it is
# load-bearing here: image/files/etc/shadow ships root with the password `root`, which is
# fine for a serial console on a development VM and is not fine over a network. Keys
# still work; passwords do not.
#
# KbdInteractiveAuthentication no closes the hole upstream's own comment warns about —
# with PAM enabled, keyboard-interactive is a second path to password authentication, and
# it is not the path PermitRootLogin inspects. Password authentication for ordinary
# accounts stays on, through PasswordAuthentication, which is what makes `user`/`user`
# work from outside the way it already does on the console.
cat > /usr/local/rootfs/etc/ssh/sshd_config <<'EOF'
# Drop-ins first: in sshd_config the first setting of an option wins, so a file included
# here overrides what follows. Nothing ships one; a variant may.
Include /etc/ssh/sshd_config.d/*.conf

# Authenticate through PAM, which is what registers the session with systemd-logind
# (/etc/pam.d/sshd, and pam_systemd.so inside it). The compiled default is no.
UsePAM yes

# root over the network by key only, never by password: /etc/shadow in this image ships a
# throwaway password for root and a network is not a serial console.
PermitRootLogin prohibit-password
PasswordAuthentication yes
KbdInteractiveAuthentication no

Subsystem sftp /usr/libexec/sftp-server
EOF

# ---------------------------------------------------------------------------------
# The unit, and the unit that gives it something to present.
#
# Type=exec rather than notify: sshd has no sd_notify support upstream — the systemd
# integration distributions ship is a patch — so the most systemd can be told is that the
# binary was successfully execed. Type=simple would not even claim that much.
#
# KillMode=process is the one line here that is not boilerplate: without it, restarting
# sshd kills the sessions it has forked, which includes the session of whoever typed
# `systemctl restart sshd`.
install -d /usr/local/rootfs/usr/lib/systemd/system
cat > /usr/local/rootfs/usr/lib/systemd/system/sshd.service <<'EOF'
[Unit]
Description=OpenSSH server daemon
Documentation=man:sshd(8) man:sshd_config(5)
After=network.target sshd-keygen.service
Wants=sshd-keygen.service

[Service]
Type=exec
ExecStart=/usr/bin/sshd -D -e
ExecReload=/usr/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Host keys are generated on the machine, at its first boot, and never in the image: an
# image built from a public repository that carried a private host key would put the same
# key on every machine that ever booted it, and any of them could then impersonate the
# rest. `ssh-keygen -A` is upstream's own answer to "make whatever is missing", so a new
# key type in a later release needs no edit here.
#
# The conditions are OR'd (the `|` prefix), so the unit runs when *any* of the three is
# absent — which is what makes it a no-op on every boot after the first, and what makes it
# do the right thing if one key is deleted. It writes to /etc, which is on the root
# filesystem and mounted rw; the disk carries it across reboots.
cat > /usr/local/rootfs/usr/lib/systemd/system/sshd-keygen.service <<'EOF'
[Unit]
Description=Generate the OpenSSH host keys that are missing
Documentation=man:ssh-keygen(1)
ConditionPathExists=|!/etc/ssh/ssh_host_rsa_key
ConditionPathExists=|!/etc/ssh/ssh_host_ecdsa_key
ConditionPathExists=|!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/ssh-keygen -A
EOF

# Enabled by shipping the .wants symlink itself, the way packages/dbus's meson install
# does: there is no `systemctl enable` step anywhere in this build, and image/files does
# not enable units it does not own. An sshd nobody starts is untested code — test/ssh.sh
# and the systemd/network boot tests all reach it through this symlink.
install -d /usr/local/rootfs/usr/lib/systemd/system/multi-user.target.wants
ln -sfn ../sshd.service \
    /usr/local/rootfs/usr/lib/systemd/system/multi-user.target.wants/sshd.service

# ---------------------------------------------------------------------------------
# The privilege separation account, created at first boot by systemd-sysusers because
# there is no shadow-utils in this image and nothing else could create it. sshd refuses to
# start without it: the unprivileged child that talks to the network runs as this user and
# chroots into /var/empty, which `make install` created above as root-owned 0755 — the
# ownership and mode sshd checks before it will use it.
#
# The `-` fields are the uid (any, allocated below SYSTEM_UID_MAX at first boot) and the
# shell (systemd's default for a system user, /usr/sbin/nologin, which util-linux ships
# and merged-/usr resolves into /usr/bin).
install -d /usr/local/rootfs/usr/lib/sysusers.d
cat > /usr/local/rootfs/usr/lib/sysusers.d/sshd.conf <<'EOF'
u sshd - "OpenSSH privilege separation" /var/empty -
EOF

# ---------------------------------------------------------------------------------
# And the PAM stack, which is not optional: image/files/etc/pam.d/other is pam_deny, so a
# service with no file of its own is refused rather than defaulted — see the long note in
# CLAUDE.md about what that has already cost. The same four modules as pam.d/login, for
# the same reasons, including pam_systemd.so being `optional` so a broken module costs the
# session registration rather than the ability to log in.
install -d /usr/local/rootfs/etc/pam.d
cat > /usr/local/rootfs/etc/pam.d/sshd <<'EOF'
auth       required   pam_unix.so
account    required   pam_unix.so
session    required   pam_unix.so
# Registers the login with systemd-logind. Optional, as in pam.d/login: a missing or
# broken pam_systemd.so should cost the session tracking, not the login.
session    optional   pam_systemd.so
password   required   pam_unix.so
EOF
