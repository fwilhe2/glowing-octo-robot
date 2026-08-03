#!/usr/bin/env bash
# Boot the image with systemd as PID 1 and actually start a container in the guest, so
# a kernel config or a crun build that cannot run one fails CI instead of being
# discovered by hand.
#
#     ./test/container.sh [rootfs.ext4] [bzImage]
#
# Overrides:
#   TIMEOUT    seconds to wait   (default 300 — qemu falls back to TCG in CI, where
#                                 there is no KVM, and that is slow)
#   MEM/CPUS   guest size        (default 1024 / 2)
#   LOG        console transcript (default container-test.log)
#   LOGIN_USER/LOGIN_PASSWORD    serial console credentials (default root / root)
#
# Like test/network.sh this boots systemd rather than a raw shell: crun asks systemd
# over sd-bus to create the cgroup v2 scope, so PID 1 is part of what is under test.
#
# The checks are layered so a failure says where it broke:
#   1. cgroup v2 is mounted and the controllers the kernel fragment adds are delegated
#   2. crun runs and reports the features it was built with
#   3. a container actually starts, and from inside it the pid, uts and mount
#      namespaces are demonstrably not the host's
#
# The bundle is built by hand. `crun spec` writes a complete, valid config.json, and
# the only edits needed are patched in with bash parameter expansion — the image ships
# no grep, sed, awk or jq, and none of them are needed for this.
set -euo pipefail

cd "$(dirname "$0")/.."

ROOTFS="${1:-${ROOTFS:-output/rootfs.ext4}}"
KERNEL="${2:-${KERNEL:-rootfs/boot/bzImage}}"
INIT="${INIT:-/usr/lib/systemd/systemd}"
TIMEOUT="${TIMEOUT:-300}"
MEM="${MEM:-1024}"
CPUS="${CPUS:-2}"
LOG="${LOG:-output/container-test.log}"
LOGIN_USER="${LOGIN_USER:-root}"
LOGIN_PASSWORD="${LOGIN_PASSWORD:-root}"

# Same trick as test/network.sh: the guest echoes back everything typed at the console,
# so a marker must not appear in the command that produces it or we would match our own
# input. The guest's shell strips the quotes; the patterns below are the joined string.
READY="SHELL-IS-UP"
QUIET="stty -echo; PS1="
PROBE="echo SHELL-IS'-UP'"

CGROUP_OK="CGROUP2-OK"
BUNDLE_OK="BUNDLE-OK"
RUN_OK="CONTAINER-OK"

# cgroup v2, and specifically the controllers that were not in defconfig: memory is
# MEMCG, and without it a bundle asking for a memory limit fails. cgroup.controllers is
# the delegated set at the root, which is what a container runtime gets to work with.
CGROUP_CHECK="c=\$(</sys/fs/cgroup/cgroup.controllers); echo \"controllers: \$c\"; \
[[ \$c == *memory* && \$c == *pids* && \$c == *cpu* ]] && echo CGROUP2'-OK'"

# What runs inside the container. Two things constrain how this is written:
#
#   - it ends up as a JSON string in config.json, so it must contain no double quotes
#     and no backslashes, and it is spliced in through a single-quoted shell variable
#     so it must contain no single quotes either;
#   - it is the *replacement* half of a bash ${var/pat/repl}, where an unescaped & is a
#     backreference to the whole match — `&&` would silently expand to `"sh""sh"`. Hence
#     the nested ifs instead of the `&&` chain the other checks in this repo use.
#
# $$ is 1 only in a pid namespace, and bash sets $HOSTNAME from gethostname(2) at
# startup, so it reads `crun` (the hostname the generated spec sets) only in a uts
# namespace. Both are the host's values if crun quietly did nothing.
IN_CTR="echo ctr-pid=\$\$; echo ctr-host=\$HOSTNAME; \
if [[ \$\$ == 1 ]]; then if [[ \$HOSTNAME == crun ]]; then echo CONTAINER-OK; fi; fi"

# Bind-mount the guest's own root as the container rootfs: crun needs to pivot_root onto
# a mount point, and this gives the container a populated /usr without any image tooling.
# --bind rather than --rbind on purpose, so the guest's /proc, /sys and /run do not come
# along and the container gets the fresh ones its config.json asks for.
#
# The two patches to the generated spec: terminal false, because there is no console
# socket on this serial line, and args replaced with the assertions above. Both target
# strings occur exactly once in what `crun spec` writes.
# The umount is not tidiness, it is a guard: rm -rf crosses mount points, so removing
# /run/ct while /run/ct/rootfs is still a bind mount of / would delete the guest's root
# filesystem through it. A fresh boot has no /run/ct (it is on tmpfs), but this has to
# be safe to run twice in one boot.
BUNDLE="umount /run/ct/rootfs 2>/dev/null; rm -rf /run/ct && \
mkdir -p /run/ct/rootfs && cd /run/ct && crun spec && \
mount --bind / /run/ct/rootfs && \
c=\$(</run/ct/config.json); \
r='\"/bin/bash\", \"-c\", \"$IN_CTR\"'; \
c=\${c/'\"terminal\": true'/'\"terminal\": false'}; \
c=\${c/'\"sh\"'/\$r}; \
printf '%s' \"\$c\" > /run/ct/config.json && echo BUNDLE'-OK'"

RUN="cd /run/ct && crun run ct-smoke; echo \"crun exit: \$?\""

FEATURES="crun --version; echo '--- features ---'; crun features"
DIAGNOSE="crun list; echo '--- cgroup ---'; cat /sys/fs/cgroup/cgroup.controllers; \
echo '--- config ---'; cat /run/ct/config.json; echo '--- dmesg ---'; dmesg | tail -40"

command -v qemu-system-x86_64 >/dev/null || { echo "error: qemu-system-x86_64 not found" >&2; exit 1; }
[ -f "$KERNEL" ] || { echo "error: missing kernel: $KERNEL" >&2; exit 1; }
[ -f "$ROOTFS" ] || { echo "error: missing rootfs: $ROOTFS" >&2; exit 1; }

accel=()
if [ -w /dev/kvm ]; then
    accel=(-enable-kvm -cpu host)
else
    echo "note: /dev/kvm not available, emulating (slow)"
fi

work=$(mktemp -d)
console="$work/console-in"
mkfifo "$console"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"

qemu-system-x86_64 \
    "${accel[@]}" \
    -m "$MEM" -smp "$CPUS" \
    -kernel "$KERNEL" \
    -drive file="$ROOTFS",format=raw,if=virtio \
    -nic user,model=virtio-net-pci \
    -append "root=/dev/vda rw console=ttyS0 init=$INIT" \
    -nographic \
    -no-reboot \
    < "$console" > "$LOG" 2>&1 &
qemu_pid=$!

cleanup() {
    exec 3>&- 2>/dev/null || true
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

# Read-write, so opening never blocks on qemu having got as far as its stdin.
exec 3<> "$console"

echo ">> booting $ROOTFS with $KERNEL (init=$INIT), waiting up to ${TIMEOUT}s"

deadline=$((SECONDS + TIMEOUT))
DIED='Kernel panic|Attempted to kill init|Requesting system (poweroff|reboot)'

fail() {
    echo ">> container test FAILED: $1" >&2
    printf '%s\n' "$DIAGNOSE" >&3 2>/dev/null || true
    sleep 8
    echo ">> last 80 lines of the console:" >&2
    tail -80 "$LOG" >&2
    exit 1
}

# How much console output there is so far, as a byte offset into the log — the caller
# takes one of these before it types something and passes it to await, so that only the
# guest's answer can satisfy the wait. See the login handshake below for why that
# matters.
console_mark() { wc -c < "$LOG"; }

# With a third argument, output before that offset is ignored.
await() { # pattern seconds [since]
    local until=$((SECONDS + $2)) since="${3:-0}"
    while [ "$SECONDS" -lt "$until" ]; do
        tail -c "+$((since + 1))" "$LOG" | grep -qaE "$1" && return 0
        grep -qaE "$DIED" "$LOG" && fail "the guest died"
        kill -0 "$qemu_pid" 2>/dev/null || fail "qemu exited"
        [ "$SECONDS" -lt "$deadline" ] || fail "timed out waiting for: $1"
        sleep 2
    done
    return 1
}

await 'login:' "$TIMEOUT" || fail "no login prompt"
echo ">> got a login prompt, logging in as $LOGIN_USER"

# The password waits on output typed *after* the username, not on "Password" appearing
# anywhere in the log: systemd's status lines contain "Query the User Interactively for
# a Password" a few seconds into the boot, and matching that types the password into the
# username prompt. test/systemd.sh has the long version.
until grep -qaF "$READY" "$LOG"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "could not get a shell (login rejected?)"
    prompt=$(console_mark)
    printf '%s\n' "$LOGIN_USER" >&3
    await 'Password' 15 "$prompt" || continue
    printf '%s\n' "$LOGIN_PASSWORD" >&3
    sleep 3
    printf '%s\n' "$QUIET" >&3
    printf '%s\n' "$PROBE" >&3
    await "$READY" 10 || true
done

echo ">> logged in, checking cgroup v2"

printf '%s\n' "$CGROUP_CHECK" >&3
await "$CGROUP_OK" 30 || fail "cgroup v2 missing a controller the fragment should have added"
echo ">> cgroup v2 OK: memory, pids and cpu are delegated"

# Recorded for the transcript rather than asserted on: what crun was built with is the
# first thing worth knowing when a bundle behaves unexpectedly.
printf '%s\n' "$FEATURES" >&3
sleep 3

echo ">> building an OCI bundle"
printf '%s\n' "$BUNDLE" >&3
await "$BUNDLE_OK" 40 || fail "could not build a bundle (crun spec or the bind mount failed)"

echo ">> starting the container"
printf '%s\n' "$RUN" >&3
await "$RUN_OK" 60 || fail "the container did not start or its assertions did not pass"

echo ">> container OK: crun started it, PID 1 in its own pid namespace, /proc its own"
