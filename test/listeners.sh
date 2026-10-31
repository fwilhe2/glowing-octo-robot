#!/usr/bin/env bash
# Boot the image and require that what listens on the network is exactly what we expect,
# so a version bump that opens a new port (an LLMNR or mDNS responder in resolved, a
# debug endpoint in a daemon) fails CI rather than shipping. test/image-files/ holds the
# files to a list; this holds the sockets to one.
#
#     ./test/listeners.sh [rootfs.erofs] [bzImage]
#
# One boot per round: the base image, then with each extension that starts a daemon at
# boot attached (SYSEXTS, test/qemu-lib.sh): kubernetes, for CRI-O. podman's starts
# nothing at boot, so a round of its own would boot the base again. ROUNDS picks.
# kubelet runs only once kubeadm has configured it, so its :10250 is test/k8s.sh's.
#
# Overrides:
#   ROUNDS     which rounds          (default: base kubernetes)
#   TIMEOUT    seconds to wait       (default 300)
#   MEM/CPUS   guest size            (default 1024 / 2)
#   LOG        console transcript    (default listeners-test.log, -<round> after it)
#
# Only sockets another machine could reach count: loopback addresses are dropped (that
# is resolved's stub on 127.0.0.53/54, among others), and so are unix and vsock sockets,
# which `ss -ntu` does not list. From Flatcar's cl.network.listeners and LinuxKit's
# test that a default image opens no ports.
set -euo pipefail

cd "$(dirname "$0")/.."
source test/qemu-lib.sh

ROOTFS="${1:-${ROOTFS:-output/rootfs.erofs}}"
KERNEL="${2:-${KERNEL:-rootfs/boot/bzImage}}"
INIT="${INIT:-/usr/lib/systemd/systemd}"
ROUNDS="${ROUNDS:-base kubernetes}"
BASE_LOG="${LOG:-output/listeners-test.log}"

# What each round must listen on, as "proto address:port process", one per line. A round
# lists only what it adds to the base. sshd, on both families, is all the base has; CRI-O's
# streaming server is on loopback.
expected_base='tcp 0.0.0.0:22 sshd
tcp [::]:22 sshd'
expected_kubernetes=''

# -H no header, -l listening (for udp: bound and unconnected), -n numeric, -p the process.
DONE="LISTENERS-DONE"
LIST="systemctl is-system-running --wait >/dev/null; while IFS= read -r l; do echo \"LSN> \$l\"; done < <(ss -Hlntup); echo LISTENERS'-DONE'"

# ss's columns are netid, state, recv-q, send-q, local, peer, process; the process is
# users:(("name",pid=…,fd=…),…), of which the first name is enough.
reduce() {
    sed -n 's/^LSN> //p' | while read -r proto _ _ _ local _ users; do
        case "$local" in
            127.*|'[::1]'*|'[::ffff:127.'*) continue ;;
        esac
        # IPv6's any address is [::] through sock_diag and * when ss falls back to
        # /proc/net (amd64's kernel has no INET_DIAG, arm64's defconfig turns it on).
        local=${local/#\*:/[::]:}
        name=$(sed -n 's/^users:(("\([^"]*\)".*/\1/p' <<<"$users")
        echo "$proto $local ${name:-?}"
    done | sort -u
}

round() { # name
    local name="$1" want got mark
    TEST_NAME="listeners-$name"
    LOG="${BASE_LOG%.log}-$name.log"
    SYSEXTS=
    [ "$name" = base ] || SYSEXTS="$name"
    want=$(printf '%s\n%s\n' "$expected_base" "$(eval "echo \"\$expected_$name\"")" | sed '/^$/d' | sort -u)

    qemu_setup
    qemu_preflight
    qemu_boot
    console_login
    mark=$(console_mark)
    console_send "$LIST"
    await "$DONE" "$((deadline - SECONDS))" "$mark" || fail "ss never finished"
    got=$(tail -c "+$((mark + 1))" "$LOG" | tr -d '\r' | reduce)

    echo ">> $name listens on:"
    printf '%s\n' "${got:-<nothing>}" | sed 's/^/   /'
    local extra missing
    extra=$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed '/^$/d')
    missing=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed '/^$/d')
    [ -z "$extra" ] || fail "$name listens on what nobody expected (extra: $(echo $extra)) — close it, or add it to expected_$name in $0"
    [ -z "$missing" ] || fail "$name does not listen on $(echo $missing)"
    cleanup
    trap - EXIT
    echo ">> listeners OK: $name"
}

for r in $ROUNDS; do round "$r"; done
