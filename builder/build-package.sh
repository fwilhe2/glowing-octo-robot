#!/bin/bash
# Container entrypoint for every package build: set up the compiler flags and helpers,
# then source the package's build.sh.
#
# Bind mounts set up by ../build.sh:
#   /usr/local/src      unpacked source tree (working directory)
#   /package-build.sh   the package's build.sh
#   /usr/local/rootfs   this package's staging tree, empty at the start (DESTDIR)
#   /usr/local/sysroot  our glibc, compiled against as $SYSROOT
set -euo pipefail

ROOTFS=/usr/local/rootfs

# Merged /usr, with sbin merged into bin, in place before anything installs: systemd
# taints the system ("unmerged-usr", "unmerged-bin") otherwise.
install -d "$ROOTFS"/usr/{bin,lib}
ln -sfn bin      "$ROOTFS/usr/sbin"
ln -sfn usr/bin  "$ROOTFS/bin"
ln -sfn usr/sbin "$ROOTFS/sbin"
ln -sfn usr/lib  "$ROOTFS/lib"
ln -sfn usr/lib  "$ROOTFS/lib64"

# Compile and link against our glibc rather than the builder's, so binaries do not ask
# for symbol versions only sid has. --sysroot points the default paths at ours, and the
# builder's directories are appended after it (-idirafter, trailing -L) so every other
# header and library is still Debian's. docs/guides/linking.md has the long version.
if [ -n "${SYSROOT:-}" ]; then
    multiarch=$(gcc -print-multiarch)

    sysroot_cppflags="--sysroot=$SYSROOT"
    sysroot_cppflags+=" -idirafter /usr/include/$multiarch -idirafter /usr/include"

    # Ours named first, explicitly: a -L outranks the sysroot's defaults, so appending
    # Debian's alone would hand -lc back to sid. -B for the crt files, which gcc finds
    # relative to itself rather than the sysroot. -rpath-link resolves the libraries'
    # own dependencies at link time only.
    sysroot_ldflags="--sysroot=$SYSROOT"
    for dir in /usr/lib64 /usr/lib; do
        [ -d "$SYSROOT$dir" ] || continue
        sysroot_ldflags+=" -B$SYSROOT$dir -L$SYSROOT$dir -Wl,-rpath-link,$SYSROOT$dir"
    done
    sysroot_ldflags+=" -L/usr/lib/$multiarch -L/usr/lib"
    # -rpath-link for Debian's too: a library's own dependencies (libpam needing
    # libaudit) are otherwise looked up in the sysrooted defaults.
    sysroot_ldflags+=" -Wl,-rpath-link,/usr/lib/$multiarch -Wl,-rpath-link,/usr/lib"

    export CPPFLAGS="$sysroot_cppflags${CPPFLAGS:+ $CPPFLAGS}"
    export LDFLAGS="$sysroot_ldflags${LDFLAGS:+ $LDFLAGS}"

    # -O2 has to be said: autoconf only defaults to it when CFLAGS is unset, and setting
    # it is what the line above does, so everything was silently -O0. No -g, since the
    # image is stripped. SYSROOT_CFLAGS is the same without -O2, for meson, whose c_args
    # come after its buildtype's optimization (see meson_install).
    export SYSROOT_CFLAGS="$sysroot_cppflags"
    export CFLAGS="$sysroot_cppflags -O2${CFLAGS:+ $CFLAGS}"
    export CXXFLAGS="$sysroot_cppflags -O2${CXXFLAGS:+ $CXXFLAGS}"
fi

# Go and Rust read none of the above, so they get the sysroot their own way, are pinned
# offline (the build has no network), and keep paths out of the binary (reproducible).
export GOTOOLCHAIN=local GOPROXY=off GOFLAGS="-mod=vendor -trimpath -buildvcs=false"
export GOPATH=/tmp/go GOCACHE=/tmp/go-cache CGO_ENABLED=1
export CGO_CFLAGS="${CFLAGS:-}" CGO_LDFLAGS="${LDFLAGS:-}"
# Rust: one -C link-arg per flag, because cargo splits RUSTFLAGS on whitespace and rustc
# rejects a bare -B.
export CARGO_HOME=/tmp/cargo CARGO_NET_OFFLINE=true
RUSTFLAGS="--remap-path-prefix=/usr/local/src=."
for flag in ${LDFLAGS:-}; do RUSTFLAGS+=" -C link-arg=$flag"; done
export RUSTFLAGS

# cargo_vendored <cargo args>...
#
# cargo build --release, offline and --locked, against ./vendor (from VENDOR_TARBALL).
# LTO with one codegen unit, which drops most of the dependency tree from the binary.
cargo_vendored() {
    install -d "$CARGO_HOME"
    cat > "$CARGO_HOME/config.toml" <<CARGO
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$PWD/vendor"

[profile.release]
lto = true
codegen-units = 1
CARGO
    cargo build --release --offline --locked "$@"
}

# The helpers every packages/<pkg>/build.sh can use; it is sourced, so they are in scope.

# A plain `make` is parallel.
export MAKEFLAGS="-j$(nproc)"

# drop_installed <name-in-usr/bin | path/under/rootfs>...
#
# Delete what `make install` put there, and fail if one was not installed: a removal that
# silently does nothing after an upstream rename is how an interpreter script ships.
drop_installed() {
    local prog f
    for prog in "$@"; do
        case "$prog" in
            */*) f="$ROOTFS/$prog" ;;
            *)   f="$ROOTFS/usr/bin/$prog" ;;
        esac
        if [ ! -e "$f" ] && [ ! -L "$f" ]; then
            echo "error: $prog is not installed — this removal list is stale" >&2
            return 1
        fi
        rm -rf "$f"
    done
}

# assert_not_linked <library-substring> <path-under-rootfs>...
#
# Fail if an installed binary has the library in DT_NEEDED: for a dependency configured
# out that could come back without a word.
assert_not_linked() {
    local lib="$1" bin
    shift
    for bin in "$@"; do
        if readelf -d "$ROOTFS/$bin" | grep -q "NEEDED.*$lib"; then
            echo "error: $bin is linked against $lib, which this package configures out" >&2
            return 1
        fi
    done
}

# meson_install [meson setup options]...
#
# setup, compile and install. --buildtype=release because meson's default is -O0, and
# CFLAGS without the -O2 so the buildtype decides. -Dlibdir=lib, not the multiarch path.
meson_install() {
    CFLAGS="${SYSROOT_CFLAGS:-}" CXXFLAGS="${SYSROOT_CFLAGS:-}" \
        meson setup --prefix /usr --buildtype=release -Dlibdir=lib "$@" build
    meson compile -C build
    meson install -C build --destdir "$ROOTFS"
}

cd /usr/local/src
source /package-build.sh

# The license texts, into usr/share/licenses/<pkg>/ under the path each has in the
# source: `make install` puts almost none of them anywhere, and the few it does land in
# usr/share/doc, which the image trims. Upstream's own (top level, doc/, any LICENSES/
# directory as REUSE and the kernel lay them out, debian/copyright for Debian's tarballs)
# and every vendored dependency's, since MIT and Apache-2.0 code linked into a Go or Rust
# binary ships its notice with it. packages/<pkg>/licenses/ is for a source that has no
# text to copy. Identical files are hardlinked, so a hundred copies of Apache-2.0 cost
# one. A package with no license text at all fails here rather than ship without one.
if [ -n "${FLFS_PKG:-}" ]; then
    licenses=$ROOTFS/usr/share/licenses/$FLFS_PKG
    name=( \( -iname 'copying*' -o -iname 'licen[cs]e*' -o -iname 'notice*' -o -iname 'copyright*'
              -o -iname 'unlicense*' \) )
    code=( \( -name '*.[ch]' -o -name '*.go' -o -name '*.rs' -o -name '*.py' -o -name '*.json'
              -o -name '*.toml' -o -name '*.y*ml' -o -name '*.in' -o -name '*.am' -o -name '*.sh'
              -o -name '*.pl' -o -name '*.html' -o -name '*.xml' \) )
    found=$(cd /usr/local/src && find . -xtype f \( \
            \( ! -path './*/*' "${name[@]}" \) \
            -o \( \( -path './doc/*' -o -path './docs/*' \) ! -path './*/*/*' "${name[@]}" \) \
            -o -path '*/LICENSES/*' -o -path '*/licenses/*' \
            -o -path './debian/copyright' \
            -o \( -path './vendor/*' "${name[@]}" \) \
        \) ! "${code[@]}" \
        ! -path '*/test/*' ! -path '*/tests/*' ! -path '*/testdata/*' ! -path '*/testsuite/*' \
        | LC_ALL=C sort)
    if [ -n "$found" ]; then
        install -d "$licenses"
        (cd /usr/local/src && xargs -d '\n' cp -L --parents -t "$licenses" <<< "$found")
    fi
    if [ -d /usr/local/licenses ]; then
        install -d "$licenses"
        cp -L -r /usr/local/licenses/. "$licenses"/
    fi
    if [ ! -d "$licenses" ] || [ -z "$(find "$licenses" -type f)" ]; then
        echo "error: $FLFS_PKG ships no license text: none in its source, and no" >&2
        echo "       packages/$FLFS_PKG/licenses/ to stand in for one" >&2
        exit 1
    fi
    chmod -R u=rwX,go=rX "$licenses"
    find "$licenses" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum \
        | awk 'seen[$1]++ { print first[$1] "\t" substr($0, 67); next } { first[$1] = substr($0, 67) }' \
        | while IFS=$'\t' read -r keep dup; do ln -f "$keep" "$dup"; done
fi

# The component record image/build-rootfs.sh turns into the SBOM: the pins ../build.sh
# passes as FLFS_*. After the build, so only a package that installed gets one.
if [ -n "${FLFS_PKG:-}" ]; then
    components=$ROOTFS/usr/share/flfs/components
    install -d "$components"
    {
        printf 'name=%s\n'    "$FLFS_PKG"
        printf 'version=%s\n' "${FLFS_VERSION:-}"
        printf 'license=%s\n' "${FLFS_LICENSE:-NOASSERTION}"
        printf 'origin=%s\n'  "${FLFS_ORIGIN:-tarball}"
        printf 'builder=%s\n' "${FLFS_BUILDER:-}"
        # `if`, not `&&`: a false && list would fail the group under set -e.
        if [ -n "${FLFS_URL:-}" ];    then printf 'url=%s\n'    "$FLFS_URL";    fi
        if [ -n "${FLFS_SHA256:-}" ]; then printf 'sha256=%s\n' "$FLFS_SHA256"; fi
        if [ -n "${FLFS_CPE:-}" ];    then printf 'cpe=%s\n'    "$FLFS_CPE";    fi
    } > "$components/$FLFS_PKG"
    # Vendored dependencies are a component of their own, with their own checksum.
    if [ -n "${FLFS_VENDOR_URL:-}" ]; then
        {
            printf 'name=%s\n'    "$FLFS_PKG-vendor"
            printf 'version=%s\n' "${FLFS_VERSION:-}"
            printf 'license=%s\n' "${FLFS_LICENSE:-NOASSERTION}"
            printf 'origin=tarball\n'
            printf 'builder=%s\n' "${FLFS_BUILDER:-}"
            printf 'url=%s\n'     "$FLFS_VENDOR_URL"
            printf 'sha256=%s\n'  "${FLFS_VENDOR_SHA256:-}"
        } > "$components/$FLFS_PKG-vendor"
    fi

    # What a Go or Rust program compiled in, as purls, one per line in
    # usr/share/flfs/modules/<pkg>: the SBOM lists each as a package its program
    # CONTAINS, which is what a vulnerability scanner matches advisories against — most of
    # them, for this image, are about a module or crate rather than a program.
    #   Go: each binary's build info (`go version -m`, which reads it without running
    #   anything), its modules after replacements, and its toolchain as stdlib.
    #   Rust: what the build links, from `cargo tree` over the normal dependency edges —
    #   not Cargo.lock, which also lists build and dev dependencies that never ship.
    modules=$(
        find "$ROOTFS" -type f -perm -u+x -print0 | xargs -0 -r -n1 go version -m 2>/dev/null |
            awk -F'\t' '
                # "<file>: go1.25.3" heads each binary; a "=>" line replaces the dep above it.
                /^[^\t].*: go[0-9]/ { flush(); sub(/.*: go/, ""); print "pkg:golang/stdlib@" $0; next }
                $2 == "dep" { flush(); dep = $3 "@" $4; next }
                $2 == "=>"  { dep = $3 "@" $4; next }
                function flush() { if (dep != "") print "pkg:golang/" dep; dep = "" }
                END { flush() }'
        if [ -f "$CARGO_HOME/config.toml" ]; then
            (cd /usr/local/src && cargo tree --offline --locked -e normal --prefix none --format '{p}' 2>/dev/null) |
                awk '$2 ~ /^v[0-9]/ && $3 !~ /^\(\// { print "pkg:cargo/" $1 "@" substr($2, 2) }'
        fi
    )
    if [ -n "$modules" ]; then
        install -d "$ROOTFS/usr/share/flfs/modules"
        LC_ALL=C sort -u <<< "$modules" > "$ROOTFS/usr/share/flfs/modules/$FLFS_PKG"
    fi
fi
