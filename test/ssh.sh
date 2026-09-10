#!/usr/bin/env bash
# Boot the image with systemd as PID 1 and log into it over ssh, so that a change which
# leaves the image with a daemon that will not start, no host key or a PAM stack that
# refuses fails CI instead of being discovered by somebody trying to use the machine.
#
#     ./test/ssh.sh [rootfs.ext4] [bzImage]
#
# Overrides:
#   TIMEOUT    seconds to wait                 (default 300 — qemu falls back to TCG in
#                                              CI, where there is no KVM, and that is slow)
#   MEM/CPUS   guest size                      (default 1024 / 2)
#   LOG        console transcript              (default ssh-test.log)
#   LOGIN_USER/LOGIN_PASSWORD  serial console credentials (default root / root)
#
# **The guest connects to itself.** That is the deliberate part of the design, and it is
# what keeps this test from needing anything the other four do not: no port forward in
# test/qemu-lib.sh, no ssh client on the runner, no key material moving across the
# boundary. Everything that could be wrong about sshd in this image is inside the guest —
# the unit, the host key, the privilege separation account, the seccomp sandbox, the PAM
# stack — and 127.0.0.1 exercises all of it. What it does not exercise is reaching the
# guest from outside, which is a property of the VMM's networking rather than of the
# image, and which the `lima` platform will have to answer for itself.
#
# Two rounds, layered so a failure says where it broke, the same way test/network.sh is:
#
# The first asks whether the *daemon* is there — the unit is active, sshd-keygen.service
# left a host key behind, and something is accepting connections on port 22. It uses
# nothing but systemctl and bash builtins, so a failure means what it says.
#
# The second asks whether anyone could actually log in: a key is generated in the guest,
# authorized, and used. That is the round that goes through sshd's privilege separation,
# /etc/pam.d/sshd and pam_systemd — which is why it also checks $XDG_SESSION_ID, the one
# cheap piece of evidence that the session was registered with logind rather than merely
# authenticated.
set -euo pipefail

cd "$(dirname "$0")/.."
source test/qemu-lib.sh

ROOTFS="${1:-${ROOTFS:-output/rootfs.ext4}}"
KERNEL="${2:-${KERNEL:-rootfs/boot/bzImage}}"
INIT="${INIT:-/usr/lib/systemd/systemd}"
LOG="${LOG:-output/ssh-test.log}"
TEST_NAME=ssh

# Same marker trick as test/qemu-lib.sh and test/network.sh: the guest echoes back what is
# typed at the console until `stty -echo` has taken effect, so a marker must not appear
# verbatim in the command that produces it. The guest's shell strips the quotes.
DAEMON_MARKER="SSHD-IS-UP"
LOGIN_MARKER="SSH-LOGIN-OK"

# Round one. /dev/tcp is bash's own, so this needs no netcat and no ss — and asking the
# socket rather than trusting `is-active` is the difference between "systemd started
# something" and "something is listening".
DAEMON_CHECK="[[ \$(systemctl is-active sshd.service) == active ]] \
&& [[ -s /etc/ssh/ssh_host_ed25519_key ]] \
&& (exec 3<>/dev/tcp/127.0.0.1/22) \
&& echo SSHD-IS'-UP'"

# Round two. Idempotent, because the loop below retries it: ssh-keygen refuses to
# overwrite an existing key, so generate one only if there is none.
#
# root by key is exactly what the shipped sshd_config allows and image/files/etc/shadow's
# throwaway password is not — `PermitRootLogin prohibit-password` — so this doubles as the
# check that that line means what it says.
#
# BatchMode=yes so a failed key is an error rather than a password prompt this console
# would sit at until the deadline. StrictHostKeyChecking=no and a /dev/null known-hosts
# file because the host key was generated on this boot and nothing has seen it before.
#
# XDG_SESSION_ID is set by pam_systemd.so out of /etc/pam.d/sshd, and by nothing else in
# a non-interactive ssh command. An empty one means the session never reached logind,
# which is a broken PAM stack wearing a working login as a disguise.
#
# Tested for being non-empty rather than for looking like a session id, and that is not
# laziness: the ids here are `c1`, `c2`, `c3` and not `1`, `2`, `3`. logind derives a
# numeric id from the kernel's audit session id when there is one, and
# packages/kernel/build.sh turns CONFIG_AUDIT off (there is no audit userspace here), so
# it falls back to generating its own with a `c` prefix. Asserting a shape would be
# asserting the kernel config from the wrong end of the machine.
SSH_CHECK="install -d -m 700 /root/.ssh \
&& { [[ -f /root/.ssh/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519; } \
&& install -m 600 /root/.ssh/id_ed25519.pub /root/.ssh/authorized_keys \
&& [[ \$(ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes root@127.0.0.1 id -un) == root ]] \
&& [[ -n \$(ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes root@127.0.0.1 'echo \$XDG_SESSION_ID') ]] \
&& echo SSH-LOGIN'-OK'"

DIAGNOSE="systemctl --no-pager --full status sshd.service sshd-keygen.service
journalctl --no-pager -n 60 -u sshd.service -u sshd-keygen.service
ls -l /etc/ssh; getent passwd sshd; ls -ld /var/empty"

qemu_setup
qemu_preflight
qemu_boot
console_login

echo ">> logged in, checking that sshd is up"

# Retried, for the same reason test/network.sh retries its first round: sshd-keygen has an
# RSA key to generate on this first boot and multi-user.target is reached without waiting
# for it. Re-asking costs nothing.
until grep -qaF "$DAEMON_MARKER" "$LOG"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "sshd is not running, has no host key, or is not listening"
    grep -qaE "$QEMU_DIED" "$LOG" && fail "the guest died"
    kill -0 "$qemu_pid" 2>/dev/null || fail "qemu exited"
    console_send "$DAEMON_CHECK"
    sleep 5
done

echo ">> sshd OK: unit active, host key present, port 22 accepting connections"
echo ">> logging in over ssh, as the machine, to itself"

until grep -qaF "$LOGIN_MARKER" "$LOG"; do
    [ "$SECONDS" -lt "$deadline" ] || \
        fail "ssh could not log in (the daemon is up — see the console below)"
    grep -qaE "$QEMU_DIED" "$LOG" && fail "the guest died"
    kill -0 "$qemu_pid" 2>/dev/null || fail "qemu exited"
    console_send "$SSH_CHECK"
    sleep 5
done

echo ">> ssh OK: key authentication accepted for root, and logind registered the session"
