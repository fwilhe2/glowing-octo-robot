# shellcheck shell=bash
# The few things build.sh, tools/ and test/ all need, in one place rather than one copy
# per script — these had drifted into seven copies of the architecture switch, eight of
# "list every package" and three different ways of keeping one env.sh from leaking into
# the next.
#
#     source tools/lib.sh      # after cd-ing to the repository root
#
# Sourcing it defines functions and one array and does nothing else. Paths are relative
# to the repository root, like everything else here.

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

# cargo_lock <tarball> — the Cargo.lock at the top of a package's source tarball, on
# stdout. Top level only (--no-wildcards-match-slash): a workspace can carry lockfiles
# for its examples or vendored sub-crates further down, and those describe nothing that
# gets built.
cargo_lock() {
    tar -xOf "$1" --wildcards --no-wildcards-match-slash '*/Cargo.lock'
}

# cargo_lock_crates — read a Cargo.lock on stdin and print "name version sha256" for
# every crate it pins, one per line. These are what a CARGO_CRATES package needs in
# downloads/crates, and the checksum is the one Cargo.lock records, so every crate is
# verified against a hash that came out of a tarball which was itself verified.
#
# Fails on anything that is not from crates.io — a git dependency has no checksum in the
# lock and no stable download URL, so it cannot be pinned the way everything else here
# is. The workspace's own packages have no `source` and are skipped.
#
# builder/build-package.sh has a copy of this reader (cargo_install), because tools/ is
# not mounted into the builder. Keep the two in step.
cargo_lock_crates() {
    awk -F' = ' '
        function flush() {
            if (src == "") return
            if (src != "\"registry+https://github.com/rust-lang/crates.io-index\"" || sum == "") {
                print "error: crate " name " " ver " is from " src ", not crates.io" > "/dev/stderr"
                bad = 1
                return
            }
            gsub(/"/, "", name); gsub(/"/, "", ver); gsub(/"/, "", sum)
            print name, ver, sum
        }
        /^\[\[package\]\]/ { flush(); name = ver = src = sum = "" }
        $1 == "name"     { name = $2 }
        $1 == "version"  { ver = $2 }
        $1 == "source"   { src = $2 }
        $1 == "checksum" { sum = $2 }
        END { flush(); exit bad }'
}
