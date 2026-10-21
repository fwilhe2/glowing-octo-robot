#!/usr/bin/env bash
# Log into the guest tools/boot-qemu.sh (or boot-firecracker.sh, boot-vz.sh) is running,
# as root, without a password:
#
#     ./tools/ssh.sh                      # interactive shell
#     ./tools/ssh.sh uname -a             # one command
#     ./tools/ssh.sh --user               # as the unprivileged account, uid 1000
#     ./tools/ssh.sh --user podman ps     # ... and one command as it
#     ./tools/ssh.sh -L 8080:localhost:80 # any ssh option, as long as it comes before a command
#
# The key, the port and every option are in the ssh_config qemu_ssh_setup (test/qemu-lib.sh)
# wrote for this boot, so this is `ssh -F $SSH_DIR/config flfs` and nothing more — scp,
# sftp and rsync -e take the same -F. The key exists only while that guest runs; there is
# nothing to set up and nothing left behind.
#
# --user, which has to come first, logs in as `user` with the same key
# (image/files/etc/tmpfiles.d/flfs-home.conf puts it in that account's authorized_keys).
# It is a login of its own, with a logind session, /run/user/1000 and a user manager —
# which is what rootless podman needs and what `su user` from root's session never gives
# it: su keeps root's $XDG_RUNTIME_DIR, and pam_systemd will not open a session inside one.
#
# Overrides:
#   SSH_DIR   where the boot script put the key and config   (default output/ssh)
set -euo pipefail

cd "$(dirname "$0")/.."

SSH_DIR="${SSH_DIR:-output/ssh}"
if [ ! -f "$SSH_DIR/config" ]; then
    echo "error: no $SSH_DIR/config — is a guest running? Start one with ./tools/boot-qemu.sh (or boot-firecracker.sh, boot-vz.sh)" >&2
    exit 1
fi

login=()
if [ "${1:-}" = --user ]; then
    login=(-l user)
    shift
fi

exec ssh -F "$SSH_DIR/config" ${login[@]+"${login[@]}"} flfs "$@"
