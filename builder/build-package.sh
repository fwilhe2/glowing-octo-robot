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
# header and library is still Debian's. docs/linking.md has the long version.
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
fi
