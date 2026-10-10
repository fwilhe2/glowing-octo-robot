#!/usr/bin/env bash
# Boot the image with systemd as PID 1 and run a machine in it with nspawn, so that a
# systemd build without nspawn or machined, a kernel missing an nf_tables expression, or
# an nspawn that cannot reach a registry fails CI instead of being discovered by hand.
#
#     ./test/nspawn.sh [rootfs.ext4] [bzImage]
#
# Overrides:
#   TIMEOUT    seconds to wait   (default 900 — a pull and a machine start under TCG,
#                                 which is what CI has, are slow)
#   MEM/CPUS   guest size        (default 2048 / 2)
#   LOG        console transcript (default output/nspawn-test.log)
#   IMAGE      what to run       (default this repository's published OCI image)
#
# **Driven over ssh, not the serial console**, unlike the tests before it. qemu_ssh_setup
# hands the guest an ephemeral key at boot, and from then on each step is a command with
# an exit status and its own output, rather than something typed at a console and a
# marker waited for in the transcript. test/ssh.sh is what proves that path works; this
# test assumes it, so a broken sshd fails both, and test/ssh.sh says why.
#
# The image is ours, from ghcr.io: public, multi-arch, and not Docker Hub, whose
# anonymous pull limit is per address and shared by every GitHub runner behind it. It is
# an "app" to nspawn (no systemd inside), so it runs under nspawn's stub init, which is
# the cheaper of its two kinds of machine and needs no boot inside the boot.
#
# What follows the image is appended to its entrypoint, as with docker, and this image's
# entrypoint is /bin/bash (image/build-rootfs.sh). So the commands below are bash's
# arguments, `-c '...'`, not a program: `-- echo hi` would run `bash echo hi`, and bash
# would refuse /usr/bin/echo as a script with "cannot execute binary file", exit 126.
#
# Three rounds, each assuming the one before:
#
#   1. machined is there: `nspawn ps` reaches the nspawn service by bus activation, and
#      the service reaches systemd-machined. The failure this catches is systemd built
#      with -Dmachined=false, which is how it was before nspawn.
#   2. a machine runs: `nspawn run --rm` pulls the image, assembles it, starts it under
#      systemd-nspawn, and returns the program's exit status and output. The image is
#      the same userspace as the host, so /etc/os-release cannot tell them apart; the
#      hostname can — inside a machine it is the machine's name.
#   3. the machine has a network: curl inside it reaches an HTTPS site, which goes over
#      the nspawn0 bridge, through nft's masquerade (NFT_NAT, NFT_MASQ, NFT_CT and
#      NFT_FIB_IPV4 in packages/kernel), out of the guest's NIC and back. Needs internet
#      on the machine running the test, like test/network.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
TIMEOUT="${TIMEOUT:-900}"
MEM="${MEM:-2048}"
source test/qemu-lib.sh

ROOTFS="${1:-${ROOTFS:-output/rootfs.ext4}}"
KERNEL="${2:-${KERNEL:-rootfs/boot/bzImage}}"
INIT="${INIT:-/usr/lib/systemd/systemd}"
LOG="${LOG:-output/nspawn-test.log}"
IMAGE="${IMAGE:-ghcr.io/fwilhe2/glowing-octo-robot/flfs:latest}"
TEST_NAME=nspawn

command -v ssh >/dev/null || { echo "error: ssh not found (install an openssh client)" >&2; exit 1; }

qemu_setup
qemu_preflight
SSH_DIR=$(mktemp -d)
qemu_ssh_setup
qemu_boot

guest() { SSH_DIR="$SSH_DIR" tools/ssh.sh -o ConnectTimeout=10 "$@"; }

# What the guest says about nspawn, machined and the bridge, printed before giving up.
# Over ssh when it is up, so it lands in the CI log rather than in the console
# transcript qemu-lib's fail() tails.
diagnose() {
    guest 'systemctl --no-pager status nspawn.service systemd-machined.service; \
journalctl --no-pager -n 80 -u nspawn.service -u systemd-machined.service -u "systemd-nspawn@*"; \
journalctl --no-pager --namespace=nspawn -n 40; \
nft list ruleset; ip -br addr' 2>&1 || true
}
die() { diagnose; fail "$1"; }

echo ">> waiting for ssh"
until guest true 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || fail "ssh never came up (see test/ssh.sh)"
    grep -qaE "$QEMU_DIED" "$LOG" && fail "the guest died"
    kill -0 "$qemu_pid" 2>/dev/null || fail "qemu exited"
    sleep 5
done

echo ">> round 1: the nspawn service, and machined behind it"
guest 'nspawn ps' || die "nspawn could not list machines (is systemd-machined built?)"

echo ">> round 2: run $IMAGE as a machine"
out=$(guest "timeout $((deadline - SECONDS)) nspawn run --rm --name smoke $IMAGE -- -c 'echo \"host=\$HOSTNAME\"; . /etc/os-release; echo \"id=\$ID\"'" 2>&1) \
    || die "nspawn run failed: $out"
printf '%s\n' "$out" | tail -5
[[ $out == *"id=flfs"* && $out == *"host=smoke"* ]] \
    || die "the machine ran, but not as a machine named smoke from $IMAGE"

echo ">> round 3: the machine reaches the internet over the bridge"
out=$(guest "timeout $((deadline - SECONDS)) nspawn run --rm $IMAGE -- -c 'curl -sS -o /dev/null -w http=%{http_code} https://example.com'" 2>&1) \
    || die "curl inside the machine failed: $out"
printf '%s\n' "$out" | tail -2
[[ $out == *"http=200"* ]] || die "the machine's HTTPS request did not come back 200"

echo ">> nspawn OK: machined answers, a machine runs, and it has a network"
