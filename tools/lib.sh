# shellcheck shell=bash
# The few things build.sh, tools/ and test/ all need, in one place rather than one copy
# per script — these had drifted into seven copies of the architecture switch, eight of
# "list every package" and three different ways of keeping one env.sh from leaking into
# the next.
#
#     source tools/lib.sh      # after cd-ing to the repository root
#
# Sourcing it defines functions, one array and one constant, and does nothing else. Paths
# are relative to the repository root, like everything else here.

# The one timestamp every build here uses in place of "now" (2026-01-01T00:00:00Z), handed
# to every package build by build.sh and to image assembly by tools/build-image.sh as
# SOURCE_DATE_EPOCH — the reproducible-builds.org convention that compilers, the kernel,
# systemd's tools, mkfs.erofs and image/build-rootfs.sh all honour. A constant rather than
# the commit's date on purpose: the date would make two builds of the same tree from
# different commits differ in every timestamp, and nothing here means "when" by it. It
# is not a version and does not need to move.
FLFS_SOURCE_DATE_EPOCH=1767225600

# normalize_arch [arch] — amd64 or arm64, from either spelling; the host's when empty.
normalize_arch() {
    case "${1:-$(uname -m)}" in
        x86_64|amd64)  echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        *) echo "error: unsupported architecture: $1 (expected amd64 or arm64)" >&2
           return 1 ;;
    esac
}

# all_packages — every package name, one per line, in directory order.
all_packages() {
    local e
    for e in packages/*/env.sh; do
        e="${e%/env.sh}"
        printf '%s\n' "${e#packages/}"
    done
}

# package_name <arg> — the package an argument names, accepting the path a shell
# tab-completes to (packages/coreutils/) as well as the bare name. Fails for an unknown one.
package_name() {
    local p="${1%/}"
    p="${p#packages/}"
    if [ -z "$p" ] || [ ! -f "packages/$p/env.sh" ]; then
        echo "error: unknown package '$p' (no packages/$p/env.sh)" >&2
        return 1
    fi
    printf '%s\n' "$p"
}

# load_env <pkg> — source the package's env.sh into the current shell, with $PKG set,
# since env.sh may use it in its URL. Nothing is unset first: a script that loads more
# than one package does it in a subshell, or uses env_get.
load_env() {
    PKG="$1"
    # shellcheck disable=SC1090
    source "packages/$1/env.sh"
}

# env_get <pkg> <VAR>... — print each variable from the package's env.sh on its own
# line (empty when unset), without touching the caller's shell.
env_get() (
    load_env "$1"
    shift
    for var; do printf '%s\n' "${!var:-}"; done
)

# Downloading a tarball: follow redirects, fail on HTTP errors, and retry the 5xx a mirror
# serves while it syncs.
CURL_DOWNLOAD=(curl --location --fail --silent --show-error
               --retry 5 --retry-all-errors --retry-delay 2)

# fetch <curl args>... — an API or index request: short, retried, bounded.
fetch() {
    curl -fsSL --max-time 60 --retry 2 --retry-delay 2 "$@"
}

# gh_api <url> — fetch with a GitHub token when there is one (GH_TOKEN, GITHUB_TOKEN or
# `gh auth token`), which lifts the anonymous rate limit.
gh_api() {
    local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    if [ -z "$token" ] && command -v gh >/dev/null; then
        token=$(gh auth token 2>/dev/null || true)
    fi
    if [ -n "$token" ]; then
        fetch -H "Authorization: Bearer $token" -H 'Accept: application/vnd.github+json' "$1"
    else
        fetch -H 'Accept: application/vnd.github+json' "$1"
    fi
}

# mib <bytes> — "12.3", rounded to the nearest tenth, in integer arithmetic.
mib() {
    local tenths=$(( ($1 * 10 + 524288) / 1048576 ))
    printf '%d.%d' $(( tenths / 10 )) $(( tenths % 10 ))
}

# extract_vmlinux <bzImage> <out> — the uncompressed kernel inside an x86 bzImage, which is
# what Firecracker loads there (through its PVH entry point; it does not take a bzImage).
# The payload is the first gzip stream after the setup code — packages/kernel/build.sh
# leaves the compression at defconfig's gzip — and gzip stops at the end of it, ignoring
# the trailer the bzImage carries after. arm64's Image is already uncompressed and needs
# none of this. Used by tools/boot-firecracker.sh and test/vmm.sh.
extract_vmlinux() {
    local off
    off=$(grep -abo $'\x1f\x8b\x08' "$1" | head -1 | cut -d: -f1)
    [ -n "$off" ] || { echo "error: no gzip payload in $1" >&2; return 1; }
    tail -c "+$((off + 1))" "$1" | gzip -dc 2>/dev/null > "$2" || true
    [ "$(head -c 4 "$2")" = $'\x7fELF' ] || { echo "error: $1 did not unpack to an ELF" >&2; return 1; }
}
