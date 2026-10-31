#!/usr/bin/env bash
# Log into the guest tools/boot-qemu.sh (or boot-firecracker.sh, boot-vz.sh) is running,
# as `user`, without a password:
#
#     ./tools/ssh.sh                      # interactive shell
#     ./tools/ssh.sh podman ps            # one command
#     ./tools/ssh.sh --root               # as root
#     ./tools/ssh.sh --root journalctl -b # ... and one command as root
#     ./tools/ssh.sh -L 8080:localhost:80 # any ssh option, as long as it comes before a command
#
# The key, the port and every option are in the ssh_config qemu_ssh_setup (test/qemu-lib.sh)
# wrote for this VMM session, so this is `ssh -F $SSH_DIR/config flfs` and nothing more — scp,
# sftp and rsync -e take the same -F. The guest reuses this credential across an in-place
# reboot; launching a new VMM creates a fresh key pair.
#
# `user` by default, because the unprivileged account is the one to work in, and because
# a login of its own — a logind session, /run/user/1000 and a user manager — is what
# rootless podman needs and what `su user` from a root session never gives it: su keeps
# root's $XDG_RUNTIME_DIR, and pam_systemd will not open a session inside one. The key is
# the same one either way; image/files/etc/tmpfiles.d/flfs-home.conf copies it into
# user's authorized_keys. --root, which has to come first, logs in as root instead.
#
# Overrides:
#   SSH_DIR   where the boot script put the key and config   (default output/ssh)
#   SSH_BIN   the client executable                        (default ssh)
set -euo pipefail

cd "$(dirname "$0")/.."

SSH_DIR="${SSH_DIR:-output/ssh}"
if [ ! -f "$SSH_DIR/config" ]; then
    echo "error: no $SSH_DIR/config — is a guest running? Start one with ./boot.sh (or a tools/boot-*.sh script)" >&2
    exit 1
fi

login=user
if [ "${1:-}" = --root ]; then
    login=root
    shift
fi

error_file=$(mktemp)
trap 'rm -f "$error_file"' EXIT
attempt=0
ssh_bin="${SSH_BIN:-ssh}"
while :; do
    if "$ssh_bin" -F "$SSH_DIR/config" -l "$login" flfs "$@" 2>"$error_file"; then
        cat "$error_file" >&2
        exit 0
    else
        status=$?
    fi
    if [ "$status" -eq 255 ] && [ "$attempt" -lt 15 ] &&
       grep -qE 'kex_exchange_identification:.*(Connection reset|Connection closed)' "$error_file"; then
        if [ "$attempt" -eq 0 ]; then
            echo "ssh: guest is rebooting; waiting for sshd to return" >&2
        fi
        attempt=$((attempt + 1))
        sleep 2
        continue
    fi
    cat "$error_file" >&2
    exit "$status"
done
