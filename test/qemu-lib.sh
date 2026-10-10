#!/usr/bin/env bash
# The qemu plumbing shared by the boot tests and tools/boot-qemu.sh.
#
# Sourced, never executed. Six scripts in test/ and one in tools/ all have to launch the
# same guest — same machine type, same console device, same accel flags, same kernel
# command line — and four of them then have to drive a serial login. Written out per
# script that was ~470 lines of identical text, and the failure mode of letting it drift
# is nasty in a specific way: tools/boot-qemu.sh is what somebody reaches for to debug a
# boot CI just failed, so a divergence there means debugging a different machine than the
# one that broke.
#
# The caller sets ROOTFS/KERNEL/INIT and whatever else it needs, then:
#
#   qemu_setup       normalize $ARCH; pick the binary, console device and accel flags
#   qemu_preflight   refuse now if the binary or the images are missing
#   qemu_ssh_setup   optional: an ephemeral key, a port forward to the guest's sshd and
#                    the credential that authorizes the one over the other (see below)
#   qemu_argv        build the common command line into $QEMU_ARGV
#   qemu_boot        run it in the background on a fifo, logging to $LOG
#
# ...and then drives the console with console_send / console_mark / await /
# console_login. tools/boot-qemu.sh stops after qemu_argv and execs it instead, handing
# the console to the terminal.

source tools/lib.sh   # normalize_arch

# Defaults every caller shares. ROOTFS, KERNEL and INIT are deliberately not among them:
# they differ per script and a wrong default there boots the wrong thing quietly.
TIMEOUT="${TIMEOUT:-300}"   # qemu falls back to TCG in CI, where there is no KVM, and
MEM="${MEM:-1024}"          # that is slow
CPUS="${CPUS:-2}"
LOGIN_USER="${LOGIN_USER:-root}"
LOGIN_PASSWORD="${LOGIN_PASSWORD:-root}"

# What a guest looks like on its way out. Matched by await and by test/boot.sh's own loop.
QEMU_DIED='Kernel panic|Attempted to kill init|Requesting system (poweroff|reboot)'

# Defaults to the host's own architecture — CI runs these on a matching amd64 or arm64
# runner, so it never has to be told. Override with ARCH=amd64|arm64 to point at the other
# qemu binary and machine type explicitly. Both uname's spelling (x86_64/aarch64) and this
# repo's (amd64/arm64) are accepted.
qemu_setup() {
    ARCH=$(normalize_arch "${ARCH:-}")

    # amd64's "pc" machine and default cpu need no flags at all; arm64 has no implicit
    # machine type, so qemu-system-aarch64 refuses to start without one. ttyS0 is the 8250
    # UART kvm_guest.config/vm.config build in on amd64; arm64's virt board exposes a
    # PL011 instead, at ttyAMA0 — see packages/kernel/build.sh.
    #
    # Use KVM acceleration when available. On arm64 that means naming the machine type and
    # accel together (-machine virt,accel=kvm) rather than as a separate flag, since virt
    # isn't optional there the way amd64's implicit pc machine is.
    accel=()
    machine=()
    if [ "$ARCH" = arm64 ]; then
        QEMU=qemu-system-aarch64
        CONSOLE=ttyAMA0
        if [ -w /dev/kvm ]; then
            machine=(-machine virt,accel=kvm -cpu host)
        else
            echo "note: /dev/kvm not available, emulating (slow)"
            machine=(-machine virt -cpu max)
        fi
    else
        QEMU=qemu-system-x86_64
        CONSOLE=ttyS0
        if [ -w /dev/kvm ]; then
            accel=(-enable-kvm -cpu host)
        else
            echo "note: /dev/kvm not available, emulating (slow)"
        fi
    fi
}

# $QEMU_HINT is appended to a missing-image message: tools/boot-qemu.sh boots what
# tools/fetch-image.sh downloaded, and naming the command that produces the file is the
# whole difference between a useful error and a true one.
qemu_preflight() {
    command -v "$QEMU" >/dev/null || { echo "error: $QEMU not found" >&2; exit 1; }
    [ -f "$KERNEL" ] || { echo "error: missing kernel: $KERNEL${QEMU_HINT:+ $QEMU_HINT}" >&2; exit 1; }
    [ -f "$ROOTFS" ] || { echo "error: missing rootfs: $ROOTFS${QEMU_HINT:+ $QEMU_HINT}" >&2; exit 1; }
}

# Passwordless ssh into the guest, the way Vagrant and Lima do it: a key pair generated on
# the host for this boot only, its public half handed to the guest as it boots, a host
# port forwarded to the guest's 22, and an ssh_config tying the three together, so that
# `ssh -F $SSH_DIR/config flfs` — which is all tools/ssh.sh is — needs nothing else.
#
# Nothing about it is in the image. The key reaches the guest as the systemd credential
# ssh.authorized_keys.root on the kernel command line (systemd.set_credential_binary=,
# base64 because a public key has spaces in it). That is systemd's own interface for
# exactly this, and it works the same on both architectures, which SMBIOS — the other way
# qemu passes credentials — does not: arm64's virt board has no SMBIOS without UEFI
# firmware, and this boots the kernel directly. The command line is world-readable inside
# the guest, which is fine for a *public* key and is the reason nothing else goes this
# way. packages/openssh/build.sh has sshd read the credential where PID 1 put it, so a
# disk that was booted before with another key still accepts this one.
#
# Ephemeral in the sense that matters: generated per call, never written into the image,
# and deleted with $SSH_DIR when the guest goes away — by qemu_boot's cleanup, or by the
# caller's when it launches qemu itself. A private key that outlives its guest is one more
# file to keep track of for no gain; the next boot makes a new one in milliseconds.
#
# The forward binds 127.0.0.1 only. SSH_PORT picks the port; by default it is the first
# from 2222 that nothing on this host is listening on, which is racy in theory and lets
# two guests run side by side in practice.
qemu_ssh_setup() {
    command -v ssh-keygen >/dev/null || { echo "error: ssh-keygen not found (install an openssh client)" >&2; exit 1; }
    SSH_DIR="${SSH_DIR:-output/ssh}"
    if [ -z "${SSH_PORT:-}" ]; then
        SSH_PORT=2222
        while (exec 9<>"/dev/tcp/127.0.0.1/$SSH_PORT") 2>/dev/null; do
            SSH_PORT=$((SSH_PORT + 1))
        done
    fi

    rm -rf "$SSH_DIR"
    mkdir -p -m 700 "$SSH_DIR"
    ssh-keygen -q -t ed25519 -N '' -C "flfs-ephemeral@$(hostname)" -f "$SSH_DIR/id_ed25519"

    # StrictHostKeyChecking/UserKnownHostsFile because the guest generates its host keys at
    # its own first boot (sshd-keygen.service), so a rebuilt image is a new host on the
    # same port and recording it would only buy a MITM warning next time. This is a
    # loopback forward to a VM this shell just started, which is the one case where that
    # trade is right; Lima and Vagrant make it too. IdentitiesOnly keeps an agent full of
    # other keys from using up MaxAuthTries before this one is offered, and BatchMode
    # turns "the key was refused" into an error rather than a password prompt root could
    # never pass (PermitRootLogin prohibit-password).
    cat > "$SSH_DIR/config" <<EOF
Host flfs
    HostName 127.0.0.1
    Port $SSH_PORT
    User root
    IdentityFile $(realpath "$SSH_DIR/id_ed25519")
    IdentitiesOnly yes
    BatchMode yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF

    QEMU_NIC_EXTRA=",hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
    QEMU_APPEND_EXTRA=" systemd.set_credential_binary=ssh.authorized_keys.root:$(base64 -w0 < "$SSH_DIR/id_ed25519.pub")"
    QEMU_SSH_DIR="$SSH_DIR"
}

qemu_argv() {
    QEMU_ARGV=(
        "${accel[@]}" "${machine[@]}"
        -m "$MEM" -smp "$CPUS"
        -kernel "$KERNEL"
        -drive file="$ROOTFS",format=raw,if=virtio
        -nic "user,model=virtio-net-pci${QEMU_NIC_EXTRA:-}"
        -append "root=/dev/vda rw console=$CONSOLE init=$INIT${QEMU_APPEND_EXTRA:-}"
        -nographic
        -no-reboot
    )
}

# Launch it in the background with its console on a fifo we hold open, and its output in
# $LOG. Sets $qemu_pid and $deadline, installs the cleanup trap, and opens fd 3 as the way
# to type at the guest.
qemu_boot() {
    qemu_argv

    work=$(mktemp -d)
    console="$work/console-in"
    mkfifo "$console"
    mkdir -p "$(dirname "$LOG")"
    : > "$LOG"

    "$QEMU" "${QEMU_ARGV[@]}" < "$console" > "$LOG" 2>&1 &
    qemu_pid=$!

    cleanup() {
        exec 3>&- 2>/dev/null || true
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        rm -rf "$work"
        [ -z "${QEMU_SSH_DIR:-}" ] || rm -rf "$QEMU_SSH_DIR"
    }
    trap cleanup EXIT

    # Read-write, so opening never blocks on qemu having got as far as its stdin.
    exec 3<> "$console"

    deadline=$((SECONDS + TIMEOUT))
    echo ">> booting $ROOTFS with $KERNEL (init=$INIT), waiting up to ${TIMEOUT}s"
}

console_send() { printf '%s\n' "$1" >&3; }

# How much console output there is so far, as a byte offset into the log — the caller takes
# one of these before it types something and passes it to await, so that only the guest's
# answer can satisfy the wait. See console_login below for why that matters.
console_mark() { wc -c < "$LOG"; }

# $TEST_NAME names the test in the failure line; $DIAGNOSE, when set, is typed at the guest
# first so its answer lands in the transcript below. If the guest never got as far as a
# shell that just scrolls past, and the console log is what there is to go on.
fail() {
    echo ">> ${TEST_NAME:-boot} test FAILED: $1" >&2
    [ -n "${DIAGNOSE:-}" ] && { console_send "$DIAGNOSE" 2>/dev/null || true; sleep 5; }
    echo ">> last 80 lines of the console:" >&2
    tail -80 "$LOG" >&2
    exit 1
}

# Wait for a pattern to show up on the console, keeping an eye on the guest being alive and
# on the overall deadline. Returns 1 on the local timeout so the caller can retry. With a
# third argument, output before that offset is ignored.
await() { # pattern seconds [since]
    local until=$((SECONDS + $2)) since="${3:-0}"
    while [ "$SECONDS" -lt "$until" ]; do
        tail -c "+$((since + 1))" "$LOG" | grep -qaE "$1" && return 0
        grep -qaE "$QEMU_DIED" "$LOG" && fail "the guest died"
        kill -0 "$qemu_pid" 2>/dev/null || fail "qemu exited"
        [ "$SECONDS" -lt "$deadline" ] || fail "timed out waiting for: $1"
        sleep 2
    done
    return 1
}

# The guest echoes back everything typed at the console until `stty -echo` takes effect, so
# a marker must not appear verbatim in the command that produces it or we would match our
# own input. The guest's shell strips the quotes; READY is the joined string.
READY="SHELL-IS-UP"
PROBE="echo SHELL-IS'-UP'"
# With the terminal echo off the console log holds the guest's output and nothing else,
# which keeps a long command line from being redrawn all over the transcript.
# SYSTEMD_COLORS=0 because every failure path here is read as text, in a CI log or an
# output/*.log, and systemctl/networkctl/resolvectl wrap each field in escapes.
QUIET="stty -echo; PS1=; export SYSTEMD_COLORS=0"

# Log in at the serial getty and leave a quiet shell behind on fd 3.
#
# agetty reprints the prompt after a failed or mistimed attempt, so the login is worth
# retrying: typing into it while it is still setting the line up loses characters.
#
# The password waits on output typed *after* the username, not on "Password" appearing
# anywhere in the log. systemd's own status lines contain "Query the User Interactively for
# a Password" a few seconds into the boot, so matching the whole log satisfies the wait
# before login has asked anything: the password goes into the username prompt, the next
# command typed becomes the password, and every attempt is rejected with the credentials
# perfectly correct. The same applies to a previous failed attempt's prompt.
console_login() {
    await 'login:' "$TIMEOUT" || fail "no login prompt"
    echo ">> got a login prompt, logging in as $LOGIN_USER"

    until grep -qaF "$READY" "$LOG"; do
        [ "$SECONDS" -lt "$deadline" ] || fail "could not get a shell (login rejected?)"
        local prompt
        prompt=$(console_mark)
        console_send "$LOGIN_USER"
        await 'Password' 15 "$prompt" || continue
        console_send "$LOGIN_PASSWORD"
        sleep 3
        console_send "$QUIET"
        console_send "$PROBE"
        await "$READY" 10 || true
    done
}
