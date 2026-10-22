#!/bin/bash
# Container entrypoint shared by every package builder. Prepares the rootfs staging
# tree, then runs the package's own build commands.
#
# Bind mounts set up by ../build.sh:
#   /usr/local/src      unpacked source tree (working directory)
#   /package-build.sh   the package's build.sh
#   /usr/local/rootfs   staging tree all packages install into (DESTDIR)
#   /usr/local/sysroot  tree with our glibc in it, compiled against as $SYSROOT
set -euo pipefail

# The DESTDIR every package installs into, named once. packages/<pkg>/build.sh files use
# $ROOTFS too.
ROOTFS=/usr/local/rootfs

# merged-/usr staging: /bin /sbin /lib /lib64 become symlinks into /usr, and /usr/sbin
# into /usr/bin — the bin/sbin merge. Both halves are load-bearing: systemd checks them
# at startup and tags the system "unmerged-usr" / "unmerged-bin" in its taint string when
# either is a real directory. Packages install into /usr/sbin freely; with the symlink in
# place before any of them runs, those files land in /usr/bin.
install -d "$ROOTFS"/usr/{bin,lib}

# rootfs/ is cumulative, so this can meet a tree staged before the bin/sbin merge, with a
# real /usr/sbin that has files in it. Move them across first: `ln -sfn` against an
# existing *directory* creates a link inside it rather than replacing it, so the result
# would silently be /usr/sbin/bin and the taint would stay.
if [ -d "$ROOTFS/usr/sbin" ] && [ ! -L "$ROOTFS/usr/sbin" ]; then
    find "$ROOTFS/usr/sbin" -mindepth 1 -maxdepth 1 \
        -exec mv -t "$ROOTFS/usr/bin/" {} +
    rmdir "$ROOTFS/usr/sbin"
fi

ln -sfn bin      "$ROOTFS/usr/sbin"
ln -sfn usr/bin  "$ROOTFS/bin"
ln -sfn usr/sbin "$ROOTFS/sbin"
ln -sfn usr/lib  "$ROOTFS/lib"
ln -sfn usr/lib  "$ROOTFS/lib64"

# Compile and link against our own glibc instead of the builder image's (issue #33).
# Without this the shipped binaries carry GLIBC_x.y symbol requirements from whatever
# glibc sid happens to have today, while the image ships ours — it only works as long
# as the two stay close enough, and breaks silently when they drift apart.
#
# This is the interim fix, not a staged LFS toolchain: --sysroot redirects the *default*
# header and library paths at our glibc, and the builder image's own directories are put
# back afterwards (-idirafter, trailing -L) so everything else a package needs to link
# against — kernel headers, and the optional libraries we haven't packaged yet — is
# still found there. So glibc comes from us, the rest is still Debian's.
if [ -n "${SYSROOT:-}" ]; then
    multiarch=$(gcc -print-multiarch)

    sysroot_cppflags="--sysroot=$SYSROOT"
    sysroot_cppflags+=" -idirafter /usr/include/$multiarch -idirafter /usr/include"

    # glibc splits itself across two directories: the shared objects go to slibdir
    # (/lib64, which the merged-/usr staging above points at /usr/lib) and the files
    # only the linker ever reads — libc.so, crt1.o and friends — go to libdir,
    # /usr/lib64. Both have to be named explicitly, and ahead of the builder image's
    # directories at the end: an explicit -L outranks the sysroot's own defaults, so
    # putting Debian's back without naming ours first hands -lc straight back to sid.
    #
    # -B, not just -L, for the crt files: gcc looks for those in its own startfile
    # directories, which are relative to where gcc is installed and so never sysrooted.
    # Without it a package links Debian's Scrt1.o against our libc. -rpath-link is
    # link-time only — it resolves the dependencies of the libraries being linked
    # against without baking a builder path into the binary.
    sysroot_ldflags="--sysroot=$SYSROOT"
    for dir in /usr/lib64 /usr/lib; do
        [ -d "$SYSROOT$dir" ] || continue
        sysroot_ldflags+=" -B$SYSROOT$dir -L$SYSROOT$dir -Wl,-rpath-link,$SYSROOT$dir"
    done
    sysroot_ldflags+=" -L/usr/lib/$multiarch -L/usr/lib"
    # ...and -rpath-link for them as well, not just -L. A -L only resolves libraries the
    # link names itself; the libraries those in turn need — libpam.so needing
    # libaudit.so.1 — are looked up in the linker's default directories, which --sysroot
    # has just moved into our tree, where Debian's dependencies aren't.
    sysroot_ldflags+=" -Wl,-rpath-link,/usr/lib/$multiarch -Wl,-rpath-link,/usr/lib"

    export CPPFLAGS="$sysroot_cppflags${CPPFLAGS:+ $CPPFLAGS}"
    export LDFLAGS="$sysroot_ldflags${LDFLAGS:+ $LDFLAGS}"

    # -O2 has to be said here, because the line above it is what takes it away. Autoconf
    # only picks its default of `-g -O2` when CFLAGS is *unset*; exporting the sysroot
    # flags in CFLAGS makes it set, so every configure-based package compiled at -O0 —
    # and so did any plain-make package whose Makefile only sets -O2 when CFLAGS is empty.
    # It is the autotools twin of the meson buildtype trap in CLAUDE.md, and just as
    # silent: nothing fails, the code is merely bigger and slower than it should be
    # (sed's .text was 17% smaller once it was fixed).
    #
    # -O2 and not autoconf's `-g -O2`: the image is stripped, so debug info would only
    # make every package artifact and the staging tree larger for nothing that ships.
    #
    # The sysroot-only form is kept as SYSROOT_CFLAGS for meson, which takes its
    # optimization from --buildtype and must not have this -O2 appended after it —
    # meson_install below passes it instead, and systemd's -Dc_args names it. cmake's
    # Release flags come after CMAKE_C_FLAGS, so json-c keeps its own -O3 either way.
    export SYSROOT_CFLAGS="$sysroot_cppflags"
    export CFLAGS="$sysroot_cppflags -O2${CFLAGS:+ $CFLAGS}"
    export CXXFLAGS="$sysroot_cppflags -O2${CXXFLAGS:+ $CXXFLAGS}"
fi

# Go and Rust, which read none of the variables above. Without these a Go or Rust
# package would link the builder image's glibc — the first silent breakage in CLAUDE.md
# — and reach for the network, which --network=none turns into a failed build.
#
# Go: cgo compiles and links through gcc with CGO_CFLAGS/CGO_LDFLAGS, so those carry the
# sysroot. GOFLAGS=-mod=vendor builds from the vendor/ directory every Go release tarball
# here ships, GOPROXY=off and GOTOOLCHAIN=local make "download a module" or "download a
# newer go" an error rather than an attempt, and -trimpath with -buildvcs=false keep the
# build directory and the (absent) git state out of the binary — test/reproducible.sh
# compares to the byte.
export GOTOOLCHAIN=local GOPROXY=off GOFLAGS="-mod=vendor -trimpath -buildvcs=false"
export GOPATH=/tmp/go GOCACHE=/tmp/go-cache CGO_ENABLED=1
export CGO_CFLAGS="${CFLAGS:-}" CGO_LDFLAGS="${LDFLAGS:-}"
#
# Rust: rustc links through gcc as well, and -C link-arg is how the sysroot reaches it;
# C compiled by build scripts (the cc crate) reads CFLAGS on its own. One -C link-arg per
# flag, not one -C link-args for all of them: cargo splits RUSTFLAGS on whitespace, so the
# plural form hands every flag after the first to rustc itself, which rejects -B. The
# remap keeps the source path out of panic messages and debug info for the same
# reproducibility reason. Crates come from the package's vendor/ directory — see
# cargo_vendored below.
export CARGO_HOME=/tmp/cargo CARGO_NET_OFFLINE=true
RUSTFLAGS="--remap-path-prefix=/usr/local/src=."
for flag in ${LDFLAGS:-}; do RUSTFLAGS+=" -C link-arg=$flag"; done
export RUSTFLAGS

# cargo_vendored <cargo args>...
#
# cargo build --release, offline, against the crates in ./vendor (unpacked there by root
# build.sh from VENDOR_TARBALL) rather than crates.io. --locked so that a Cargo.lock that
# disagrees with the vendored crates is an error instead of a re-resolution. The source
# replacement goes in $CARGO_HOME rather than the source tree, which stays as unpacked.
#
# So does the release profile, which a crate's own Cargo.toml would otherwise decide and
# neither netavark's nor aardvark-dns's does: cargo's default is no LTO and sixteen
# codegen units, which buys parallel compile time and pays for it in every copy of every
# generic the dependency tree instantiates. One unit with LTO is what lets the linker see
# that most of tokio, hickory and serde are never called. It is not opt-level "s": these
# are small programs whose speed nobody notices either way, but -O3 is what upstream
# tests.
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

# What every packages/<pkg>/build.sh can use. They are sourced, not executed, so anything
# defined here is in scope — which is what lets a rule live in one place instead of being
# a convention each package has to remember.

# Parallel by default. Before this, half the packages ran a serial `make` — glibc among
# them — for no reason other than that nobody had typed -j. cmake and meson pick their own
# parallelism; make picks this up from the environment, recursive makes included.
export MAKEFLAGS="-j$(nproc)"

# drop_installed <path-under-usr/bin>...
#
# Delete files a package's `make install` put in usr/bin that the image does not want —
# and fail the build if one of them was not there. A removal that silently does nothing
# after an upstream rename is exactly how a perl or python helper ends up shipping
# (CLAUDE.md, constraint 5), so a stale list is an error rather than a no-op. Symlinks
# count as installed: several of these are links to the real binary.
drop_installed() {
    local prog f
    for prog in "$@"; do
        f="$ROOTFS/usr/bin/$prog"
        if [ ! -e "$f" ] && [ ! -L "$f" ]; then
            echo "error: $prog is not installed — this removal list is stale" >&2
            return 1
        fi
        rm -f "$f"
    done
}

# assert_not_linked <library-substring> <path-under-rootfs>...
#
# Fail if an installed binary has the library in its DT_NEEDED. For dependencies that are
# configured out but can come back without a word — see "a library that is already on the
# allowlist" in CLAUDE.md: the rootfs checks cannot see these, the binary can.
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
# setup, compile and install, with the options every package here needs. The one that
# matters is --buildtype=release: meson's default is `debug`, which is -O0, and nothing
# complains — see "the three things that break silently" in CLAUDE.md. A wrapper makes
# that the default rather than something each package has to say. -Dlibdir=lib because
# meson otherwise defaults to the builder's multiarch path (lib/x86_64-linux-gnu), which
# nothing in the image searches.
meson_install() {
    # meson reads CFLAGS into c_args, which come after the buildtype's -O3 on the
    # command line, so the -O2 exported above would quietly win. Hand it the sysroot
    # flags alone; the buildtype decides the optimization.
    CFLAGS="${SYSROOT_CFLAGS:-}" CXXFLAGS="${SYSROOT_CFLAGS:-}" \
        meson setup --prefix /usr --buildtype=release -Dlibdir=lib "$@" build
    meson compile -C build
    meson install -C build --destdir "$ROOTFS"
}

cd /usr/local/src
source /package-build.sh

# What just got installed, written down where it was installed. ../build.sh passes the
# pins from env.sh across as FLFS_*; this stages one record per package into the tree
# beside the binaries, and image/build-rootfs.sh collects them into the SBOM from the
# assembled image rather than from packages/ — which matters, because the assembled tree
# is the only place that knows what actually ended up in an image (issue #75).
#
# Deliberately after `source`, not before: `set -e` means a failed build never reaches
# this line, so a record exists only for a package that installed something. The reverse
# would put a component in the SBOM that is not in the image.
#
# key=value rather than JSON because nothing in this container should have to escape a
# string, and there is exactly one place — build-rootfs.sh — that has to know the SBOM
# format. rootfs/ is cumulative, so the record is overwritten on a rebuild the same way
# the binaries are.
if [ -n "${FLFS_PKG:-}" ]; then
    components=$ROOTFS/usr/share/flfs/components
    install -d "$components"
    {
        printf 'name=%s\n'    "$FLFS_PKG"
        printf 'version=%s\n' "${FLFS_VERSION:-}"
        printf 'license=%s\n' "${FLFS_LICENSE:-NOASSERTION}"
        printf 'origin=%s\n'  "${FLFS_ORIGIN:-tarball}"
        printf 'builder=%s\n' "${FLFS_BUILDER:-}"
        # `if` rather than `[ ... ] && printf`: a local-source package has neither, and an
        # && list that ends false is a non-zero exit for the whole group, which `set -e`
        # at the top of this file would turn into a failed build.
        if [ -n "${FLFS_URL:-}" ];    then printf 'url=%s\n'    "$FLFS_URL";    fi
        if [ -n "${FLFS_SHA256:-}" ]; then printf 'sha256=%s\n' "$FLFS_SHA256"; fi
    } > "$components/$FLFS_PKG"
    # A package's vendored dependencies are a component of their own, with their own
    # download and checksum: the SBOM should say that netavark's crates came from a
    # tarball pinned separately from netavark's source, rather than fold one hash into
    # the other. The license is the package's, which is what its vendor tarball is
    # published under as a whole; the crates' own are in vendor/*/Cargo.toml.
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
