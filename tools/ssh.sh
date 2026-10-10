#!/usr/bin/env bash
# Log into the guest tools/boot-qemu.sh is running, as root, without a password:
#
#     ./tools/ssh.sh                      # interactive shell
#     ./tools/ssh.sh uname -a             # one command
#     ./tools/ssh.sh -L 8080:localhost:80 # any ssh option, as long as it comes before a command
#
# The key, the port and every option are in the ssh_config qemu_ssh_setup (test/qemu-lib.sh)
# wrote for this boot, so this is `ssh -F $SSH_DIR/config flfs` and nothing more — scp,
# sftp and rsync -e take the same -F. The key exists only while that guest runs; there is
# nothing to set up and nothing left behind.
#
# Overrides:
#   SSH_DIR   where boot-qemu.sh put the key and config   (default output/ssh)
set -euo pipefail

cd "$(dirname "$0")/.."

SSH_DIR="${SSH_DIR:-output/ssh}"
if [ ! -f "$SSH_DIR/config" ]; then
    echo "error: no $SSH_DIR/config — is a guest running? Start one with ./tools/boot-qemu.sh" >&2
    exit 1
fi

exec ssh -F "$SSH_DIR/config" flfs "$@"
