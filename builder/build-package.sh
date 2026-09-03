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

# merged-/usr staging: /bin /sbin /lib /lib64 become symlinks into /usr, and /usr/sbin
# into /usr/bin — the bin/sbin merge. Both halves are load-bearing: systemd checks them
# at startup and tags the system "unmerged-usr" / "unmerged-bin" in its taint string when
# either is a real directory. Packages install into /usr/sbin freely; with the symlink in
# place before any of them runs, those files land in /usr/bin.
install -d /usr/local/rootfs/usr/{bin,lib}

# rootfs/ is cumulative, so this can meet a tree staged before the bin/sbin merge, with a
# real /usr/sbin that has files in it. Move them across first: `ln -sfn` against an
# existing *directory* creates a link inside it rather than replacing it, so the result
# would silently be /usr/sbin/bin and the taint would stay.
if [ -d /usr/local/rootfs/usr/sbin ] && [ ! -L /usr/local/rootfs/usr/sbin ]; then
    find /usr/local/rootfs/usr/sbin -mindepth 1 -maxdepth 1 \
        -exec mv -t /usr/local/rootfs/usr/bin/ {} +
    rmdir /usr/local/rootfs/usr/sbin
fi

ln -sfn bin      /usr/local/rootfs/usr/sbin
ln -sfn usr/bin  /usr/local/rootfs/bin
ln -sfn usr/sbin /usr/local/rootfs/sbin
ln -sfn usr/lib  /usr/local/rootfs/lib
ln -sfn usr/lib  /usr/local/rootfs/lib64

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
    export CFLAGS="$sysroot_cppflags${CFLAGS:+ $CFLAGS}"
    export CXXFLAGS="$sysroot_cppflags${CXXFLAGS:+ $CXXFLAGS}"
    export LDFLAGS="$sysroot_ldflags${LDFLAGS:+ $LDFLAGS}"
fi

# What this package is about to add to the tree, so that image/build-rootfs.sh can later
# be asked for a *subset* of it. Selection by package needs a mapping from package to
# files and there was never one: rootfs/ is a merged blob and usr/share/flfs/components
# records the pin, not the paths. See docs/image-variants.md.
#
# It has to be a before-and-after diff rather than "everything under DESTDIR is mine",
# because rootfs/ is cumulative — thirty-five packages have already installed into it.
#
# Size and mtime are in the key alongside the path, not just the path, so that a package
# which *overwrites* another's file claims it too. Ownership of an overwritten path is
# genuinely ambiguous, and claiming it in both manifests is the safe direction: a file in
# either package's manifest is kept when either package is selected.
#
# usr/share/flfs is pruned because it is where the manifests and the component records
# themselves live. They are the intermediate form — build-rootfs.sh consumes and deletes
# both — and a manifest that listed itself would be a package claiming its own bookkeeping.
#
# LC_ALL=C on both sorts and the comm between them: three commands that have to agree
# about collation, and a locale that reordered one of them would silently produce a
# manifest of everything.
manifest_snapshot() {  # <output file>
    ( cd /usr/local/rootfs 2>/dev/null &&
      find . \( -path ./usr/share/flfs -prune \) -o -printf '%y %s %T@ %P\n' ) \
        | LC_ALL=C sort > "$1"
}

manifest_snapshot /tmp/flfs-tree-before

cd /usr/local/src
source /package-build.sh

if [ -n "${FLFS_PKG:-}" ]; then
    manifest_snapshot /tmp/flfs-tree-after
    manifests=/usr/local/rootfs/usr/share/flfs/manifests
    install -d "$manifests"
    # cut -f4- rather than -f4: the path is the rest of the line, so a filename with a
    # space in it survives.
    LC_ALL=C comm -13 /tmp/flfs-tree-before /tmp/flfs-tree-after \
        | cut -d' ' -f4- > "$manifests/$FLFS_PKG"
    echo "manifest: $FLFS_PKG claims $(wc -l < "$manifests/$FLFS_PKG") paths"
fi

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
    components=/usr/local/rootfs/usr/share/flfs/components
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
fi
