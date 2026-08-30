#!/bin/bash
set -euo pipefail

set -x

# Many images come out of the same staging tree, and the two arguments say which:
#
#     build-rootfs.sh <variant> <platform>
#
# A **variant** is a feature set — which packages are in the image and the /etc that goes
# with them, declared in image/variants/<name>.conf. A **platform** is what the assembled
# tree is turned into and what that target physically cannot use,
# image/platforms/<name>.conf. An image is one of each, per architecture. See
# docs/image-variants.md, which this script is the implementation of.
#
# It is one script rather than one per output because everything that is hard-won here —
# the merged-/usr skeleton, the loader path, the trim, ldconfig — is identical for all of
# them, and the two things that are not (mkfs.ext4 and a hand-assembled OCI layout) have
# nothing in common with each other either. So `format` in a platform file selects a
# branch at the bottom of this file, and there is no plugin mechanism: there will be
# three or four platforms ever, and an abstraction layer for two implementations is how
# a build system becomes unreadable.
#
# The rule the whole design rests on: **the package build stage never learns about
# variants.** Every package is compiled once per architecture into the same staging tree,
# exactly as before. A variant is a selection *from* that tree, resolved here.
VARIANT_DIR="${VARIANT_DIR:-/variants}"
PLATFORM_DIR="${PLATFORM_DIR:-/platforms}"
source "${VARIANT_LIB:-/usr/local/bin/variant-lib.sh}"

# The staging tree is an input, not the image. Everything below — the /etc we ship, the
# stripping, the pruning — happens on a copy in the container's own filesystem, so that
# rootfs/ stays exactly what the package builds put there. It has to: rootfs/ is also
# the sysroot the *next* package compiles against, and that needs the headers, static
# libraries and .pc files this script is about to throw away.
STAGE=/usr/local/src
IMAGE=/usr/local/image

# What `package *` means here. Not "every packages/<pkg>/env.sh" — that directory is not
# mounted into this container and, more to the point, would be the wrong answer: an image
# is selected from the tree that was actually staged, so the manifests are the list.
#
# The pipe is what keeps `set -e` out of it: a bare `$(cd … && ls)` that fails because the
# directory is not there is a failed assignment and an exit before the message below.
ALL_PACKAGES=$( (cd "$STAGE/usr/share/flfs/manifests" && ls) 2>/dev/null | tr '\n' ' ')
[ -n "$ALL_PACKAGES" ] || {
    echo "error: no per-package manifests in usr/share/flfs/manifests" >&2
    echo "       builder/build-package.sh writes one per package as it installs; a tree" >&2
    echo "       without them predates that and cannot be selected from. Delete rootfs/" >&2
    echo "       and rebuild." >&2
    exit 1
}

# Arguments. Two of them, except for the one back-compatible shorthand worth keeping:
# a single argument naming a *platform* is the default variant on that platform, which is
# what `build-rootfs.sh ext4` and `build-rootfs.sh oci` have always meant.
usage() {
    echo "usage: ${0##*/} <variant> <platform>" >&2
    echo "       ${0##*/} <platform>            # the default variant, $(default_variant)" >&2
    echo "  variants:  $(variant_list  | tr '\n' ' ')" >&2
    echo "  platforms: $(platform_list | tr '\n' ' ')" >&2
    exit 2
}

case $# in
    0) variant=$(default_variant); platform=ext4 ;;
    1) if [ -f "$PLATFORM_DIR/$1.conf" ]; then
           variant=$(default_variant); platform=$1
       else
           echo "error: '$1' is not a platform, so it needs one naming which image to build" >&2
           usage
       fi ;;
    2) variant=$1; platform=$2 ;;
    *) usage ;;
esac

# The variant first, then the platform on top of it — which is the resolution order, and
# it has to be this way round: a platform's omit/drop/keep are physical constraints of
# the target and a variant may not override them.
variant_load "$variant" || exit 1
description=$V_DESCRIPTION
packages=$V_PACKAGES
keep_globs=$V_KEEP
drop_globs=$V_DROP
files_overlays=$V_FILES
is_default=$V_DEFAULT
set_has "$V_PLATFORMS" "$platform" || {
    echo "error: variant $variant does not declare the $platform platform (it has: $V_PLATFORMS)" >&2
    echo "       That is a decision in image/variants/$variant.conf, not an oversight here:" >&2
    echo "       a variant that makes no sense as a container simply does not list it." >&2
    exit 1
}

platform_load "$platform" || exit 1
packages=$(_set_del "$packages" $V_OMIT)
keep_globs=$(_set_add "$keep_globs" $V_KEEP)
drop_globs=$(_set_add "$drop_globs" $V_DROP)
files_overlays="$files_overlays $V_FILES"
format=$V_FORMAT

# The name every output of this run is filed under. The default variant keeps the
# unsuffixed names this repository had before variants existed — output/rootfs.ext4,
# output/flfs-oci.tar, output/sbom-ext4.json — so docs/release.md, the boot tests and
# every published tag still mean what they always meant.
# IMAGE_ID rather than `id`, and the case is the point: the SBOM's relationship loop
# further down builds an SPDX element id per package in a variable of its own, and the
# first version of this called both of them `id`. Every image then wrote its size report
# and its SBOM to output/…-SPDXRef-Package-zstd.… — the last package alphabetically —
# so six images produced one report and one document, each describing whichever ran last.
IMAGE_ID=$(image_id "$variant" "$platform")
if [ "$is_default" = yes ]; then
    ext4_out=/usr/local/output/rootfs.ext4
    oci_out=/usr/local/output/flfs-oci.tar
    oci_name=flfs
else
    ext4_out=/usr/local/output/rootfs-$variant.ext4
    oci_out=/usr/local/output/flfs-$variant-oci.tar
    # The repository name a container image loads and publishes as. Per variant and not
    # per tag: `flfs:latest` and `flfs:<commit>` already have consumers and go on meaning
    # the default variant, so anything else gets a repository of its own rather than a
    # tag inside that one. tools/publish-oci.sh pushes to the matching name.
    oci_name=flfs-$variant
fi

set +x
echo "=== building $variant/$platform ($IMAGE_ID): $description"
echo "    packages: $packages"
set -x

# This runs natively inside the same-arch podman build as the packages it is assembling
# — never cross-arch — so the host's own uname tells us which ELF interpreter and
# multiarch library directory the toolchain baked into the binaries it just produced.
case "$(uname -m)" in
    x86_64)  ld_so=ld-linux-x86-64.so.2  ; multiarch=x86_64-linux-gnu  ; oci_arch=amd64 ;;
    aarch64) ld_so=ld-linux-aarch64.so.1 ; multiarch=aarch64-linux-gnu ; oci_arch=arm64 ;;
    *) echo "error: unsupported build architecture: $(uname -m) (expected x86_64 or aarch64)" >&2
       exit 1 ;;
esac

rm -rf "$IMAGE"
mkdir -p "$IMAGE"
cp -a "$STAGE"/. "$IMAGE"/
cd "$IMAGE"

# ---------------------------------------------------------------------------------
# Selection: which packages are in this image.
#
# Expressed as a deletion from the copy rather than a copy of what was chosen, and that
# is the whole reason rule 6 of the resolution order works — "everything not in any
# manifest is present regardless". The directory skeleton, image/files, ld.so.cache, the
# journal catalog database and the SBOM are not any package's files, so a selection
# cannot lose them by forgetting to name them. Selection is about compiled software, not
# about the tree's bones.
#
# It runs first, before the skeleton and before the trim, so that everything downstream —
# 800 strip invocations, the readelf sweep for the SBOM, ldconfig — walks the smaller
# tree. It runs before image/files is copied in too, which is why the `drop` globs are a
# second pass further down: those name paths in the /etc we ship, which does not exist yet.
work=$(mktemp -d)
manifests="$IMAGE/usr/share/flfs/manifests"

for p in $packages; do
    [ -f "$manifests/$p" ] || {
        echo "error: variant $variant selects '$p', which is not in this staging tree." >&2
        echo "       Staged packages: $ALL_PACKAGES" >&2
        echo "       Either the name is wrong in image/variants/, or that package's build" >&2
        echo "       did not run — builder/build-package.sh writes a manifest only after a" >&2
        echo "       successful install." >&2
        exit 1
    }
done

cat "$manifests"/*        | LC_ALL=C sort -u > "$work/owned"
for p in $packages; do cat "$manifests/$p"; done | LC_ALL=C sort -u > "$work/selected"
LC_ALL=C comm -23 "$work/owned" "$work/selected" > "$work/unselected"

# `keep` globs win over both `omit` and `drop`, which is the only precedence rule anybody
# has to remember. This is the half of it that rescues a file from an omitted package —
# libsystemd.so.0 out of a systemd the oci platform otherwise deletes entirely.
#
# Tracing off: this loop is thousands of iterations and `set -x` over it would be longer
# than the rest of the build log put together. Same reason as the strip scan below.
set +x
: > "$work/delete"
: > "$work/rescued"
while IFS= read -r path; do
    [ -n "$path" ] || continue
    rescued=
    for g in $keep_globs; do
        case "$path" in $g) rescued=1; break ;; esac
    done
    if [ -n "$rescued" ]; then
        printf '%s\n' "$path" >> "$work/rescued"
    else
        printf '%s\n' "$path" >> "$work/delete"
    fi
done < "$work/unselected"

# Files and symlinks by name; directories only afterwards and only if what was removed
# from inside them left them empty. A directory in a manifest is usually one a package
# created and shares with three others — `rm -rf` on it would take the neighbours' files
# with it, which is precisely the class of mistake a manifest exists to prevent.
#
# Reverse lexicographic order is depth-first for paths: usr/lib/systemd/system sorts
# after usr/lib/systemd, so children are attempted before their parents.
gone=0
while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -L "$path" ] || [ ! -d "$path" ]; then
        rm -f "$path"
        gone=$(( gone + 1 ))
    fi
done < "$work/delete"
while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -d "$path" ] && [ ! -L "$path" ] && rmdir "$path" 2>/dev/null; then
        gone=$(( gone + 1 ))
    fi
done < <(LC_ALL=C sort -r "$work/delete")
set -x
echo "selection: kept $(wc -l < "$work/selected") paths from $(echo $packages | wc -w) packages, removed $gone, rescued $(wc -l < "$work/rescued") by keep"

mkdir -p usr/bin bin sbin boot
mkdir -p {dev,etc,home,lib}
mkdir -p {mnt,opt,proc,srv,sys}
mkdir -p var/{lib,lock,log,spool}
# journald's Storage=auto keeps the journal in /run — volatile, gone at reboot — unless
# /var/log/journal exists, and creating it is the entire switch. Nothing else does:
# systemd's tmpfiles snippet for it is `z`, which adjusts a directory that is already
# there rather than creating one. The mode and group are left alone here because the
# systemd-journal group does not exist yet in this container; systemd-tmpfiles fixes
# both at boot, after systemd-sysusers has created it.
mkdir -p var/log/journal
install -d -m 0750 root
# The unprivileged account's home. Nothing in the image would create it on first login —
# pam_mkhomedir is not in image/files/etc/pam.d and there is no shadow-utils here — so a
# missing directory means bash starts in a working directory that does not exist. The
# ownership is numeric because the names do not exist in *this* container, only in the
# /etc being shipped; 1000:1000 is what image/files/etc/passwd says.
install -d -m 0700 home/user
chown 1000:1000 home/user
install -d -m 1777 tmp
mkdir -p usr/{lib,share}

# systemd checks both of these at startup and tags the system "unmerged-bin" and
# "var-run-bad" in `systemctl show -p Taint` when they are real directories rather than
# symlinks. builder/build-package.sh already stages /usr/sbin as a link, but assert it
# here too: this script is what defines the shipped image, and it should not depend on
# the state the staging tree happened to arrive in.
if [ -d usr/sbin ] && [ ! -L usr/sbin ]; then
    find usr/sbin -mindepth 1 -maxdepth 1 -exec mv -t usr/bin/ {} +
    rmdir usr/sbin
fi
ln -sfn bin usr/sbin

# systemd's own tmpfiles ship `L /var/run - - - - ../run`, but tmpfiles will not replace
# a directory that already exists — so pre-creating var/run above was the only reason the
# link never appeared. Anything staged under it is meaningless anyway: /run is a tmpfs at
# runtime.
if [ -d var/run ] && [ ! -L var/run ]; then
    rm -rf var/run
fi
ln -sfn ../run var/run

cp -r /files/* .

# os-release(5) says the file belongs in /usr/lib, with /etc/os-release as a symlink to
# it: /usr/lib is the vendor's copy that ships with the OS, and /etc is where an
# administrator would override it. Keeping the real file under /usr also means it
# survives on a system booted with an empty /etc, which is the direction stateless
# images go. image/files/etc/os-release stays the source of truth in the repository —
# this just puts it where the spec says at assembly time. Both flavours: a container
# image is asked what it is at least as often as a disk is.
install -D -m 644 etc/os-release usr/lib/os-release
ln -sfn ../usr/lib/os-release etc/os-release

# The three fields image/files/etc/os-release cannot carry, because only a build knows
# them. That file explains at length why it ships none of them rather than inventing
# values — "consumers can tell 'not versioned' from 'version 1', but not from a number
# that means nothing" — and this does not change that bargain: with neither variable set,
# which is what a local `podman run` does, the file comes out exactly as it is in git.
#
#   FLFS_VERSION   a release, and only a release: the CalVer yyyy-mm-dd that
#                  .github/workflows/release.yml cuts. Absent on every ordinary build,
#                  because an untagged build of main is not a version of anything.
#   FLFS_BUILD     the commit. Every CI build has one, released or not, and BUILD_ID is
#                  precisely os-release(5)'s field for "which build is this" as distinct
#                  from "which release is this".
#
# PRETTY_NAME is rewritten rather than appended to, because a second PRETTY_NAME= would
# work only for parsers that take the last assignment — true of a shell and of systemd,
# not guaranteed of anything else. os-release(5) has no ordering rule to lean on, so the
# file is left with one of each key.
#
# Before the flavour split, deliberately: a container image is asked what version it is
# at least as often as a disk is.
if [ -n "${FLFS_VERSION:-}" ]; then
    sed -i "s/^PRETTY_NAME=\"\(.*\)\"\$/PRETTY_NAME=\"\1 $FLFS_VERSION\"/" usr/lib/os-release
    printf 'VERSION="%s"\nVERSION_ID="%s"\n' "$FLFS_VERSION" "$FLFS_VERSION" >> usr/lib/os-release
fi

if [ -n "${FLFS_BUILD:-}" ]; then
    printf 'BUILD_ID="%s"\n' "$FLFS_BUILD" >> usr/lib/os-release
fi

# A variant's own /etc, laid over the one image/files ships. No variant uses this yet —
# it is what `k8s-node` becomes a list of packages plus, rather than a fork of the image
# build — so the directory is expected to be absent and naming one that is not there is
# an error rather than a silent nothing.
for dir in $files_overlays; do
    overlay="${OVERLAY_DIR:-/overlays}/$dir"
    [ -d "$overlay" ] || {
        echo "error: $variant/$platform names files '$dir', which is not at $overlay" >&2
        echo "       image/Containerfile has to COPY it in before a variant can use it." >&2
        exit 1
    }
    cp -r "$overlay"/* .
done

# ---------------------------------------------------------------------------------
# `drop`, the second half of selection. These name paths regardless of which package
# owns them — or of whether any package does, which is why this runs here rather than
# with the manifest pass above: most of what the oci platform drops is the /etc we ship,
# copied in three lines ago.
#
# `keep` wins over `drop` as it wins over `omit`, and the check is the same one.
set +x
shopt -s nullglob dotglob
for g in $drop_globs; do
    for match in $g; do
        rescued=
        for k in $keep_globs; do
            case "$match" in $k) rescued=1; break ;; esac
        done
        if [ -n "$rescued" ]; then continue; fi
        # `nullglob` only silences a *pattern* that matched nothing; a literal path like
        # `etc/hostname` survives expansion whether or not it exists. Asking keeps the log
        # honest about what was actually there — and a drop line that never matches
        # anything in any image is a line worth noticing has gone stale.
        if [ -e "$match" ] || [ -L "$match" ]; then
            rm -rf "$match"
            echo "drop: $match"
        fi
    done
done
shopt -u nullglob dotglob
set -x

# ---------------------------------------------------------------------------------
# What selection left pointing at nothing.
#
# Scoped rather than tree-wide, and deliberately: /etc/resolv.conf is a symlink into
# resolved's /run stub that nothing will ever create at assembly time, and a sweep over
# the whole image would decide it was dangling and delete the file constraint 4 depends
# on. usr/bin is where a removed package leaves links behind, and the three /etc
# directories below are the ones systemd shares with software we might ship later —
# deleting those outright is how a future openssh package loses its config; dropping the
# links that now point at nothing, and then the directory if that emptied it, doesn't.
#
# Targets are resolved against the tree rather than with `readlink -f`, which would
# resolve an absolute one against the *builder container's* root and conclude that
# /usr/lib/systemd/systemd still exists. Twice, because these come in chains
# (systemd-umount → systemd-mount).
shared="etc/profile.d etc/ssh etc/xdg"
for _ in 1 2; do
    while IFS= read -r link; do
        target=$(readlink "$link")
        case "$target" in
            /*) target=".$target" ;;
            *)  target="$(dirname "$link")/$target" ;;
        esac
        [ -e "$target" ] || rm -f "$link"
    done < <(find usr/bin $shared -type l 2>/dev/null)
done
find $shared -depth -type d -empty -delete 2>/dev/null || true

# ---------------------------------------------------------------------------------
# Everything from here to the trim is about a machine that *boots*, so it is conditional
# on there being a systemd in the image to boot rather than on the platform being ext4.
# That is not the same question — a future platform could ship a self-booting disk of the
# same tree — and asking the tree is the honest version of it.
if [ -e usr/lib/systemd/systemd ]; then
    # systemd ships two shell drop-ins and systemd-tmpfiles symlinks both into
    # /etc/profile.d at every boot, so /etc/profile now sources them. One stays masked.
    #
    # It used to be masked out of necessity: 80-systemd-osc-context.sh shells out to
    # `sed` to escape $PWD on every single prompt, and there was no sed in the image, so
    # the console would have printed "command not found" between every command. #66
    # packaged sed, so that reason is gone and this is now a choice — the remaining one
    # being that the drop-in wraps every prompt in OSC 3008 context sequences, and the
    # serial console they land on is not a terminal here, it is the input the boot tests
    # parse. Turning it on changes what test/systemd.sh, network.sh and container.sh
    # read, which is a change to be judged on its own rather than to arrive inside
    # something else. (The console-handshake note further down in CLAUDE.md is what that
    # fragility has already cost once.)
    #
    # Removing the symlink is not enough, because tmpfiles would put it back; masking the
    # tmpfiles snippet with a symlink to /dev/null is the documented way to switch one
    # off, and the snippet's own header says so. Both halves are needed: the mask stops it
    # coming back, the rm takes out the copy already staged. The oci flavour needs neither
    # — the subtractions below delete etc/tmpfiles.d and systemd's drop-ins outright.
    mkdir -p etc/tmpfiles.d
    ln -sfn /dev/null etc/tmpfiles.d/20-systemd-osc-context.conf
    rm -f etc/profile.d/80-systemd-osc-context.sh

    mkdir -p etc/systemd/system
    ln -sf /usr/lib/systemd/system/multi-user.target etc/systemd/system/default.target

    # The kernel execs /sbin/init; point it at systemd.
    ln -sf /usr/lib/systemd/systemd sbin/init
fi

# Binaries carry an ELF interpreter path baked in by the toolchain — /lib64/ld-linux-
# x86-64.so.2 on amd64, /lib/ld-linux-aarch64.so.1 on arm64. With merged-/usr, lib64 and
# lib both already point at usr/lib, so this resolves either way; only add a symlink if
# it doesn't (e.g. glibc landed the loader somewhere unexpected).
if [ ! -e "lib64/$ld_so" ]; then
    loader=$(find . -name "$ld_so" -not -path './lib64/*' -not -path './lib/*' | head -n1)
    if [ -n "$loader" ]; then
        mkdir -p lib64
        ln -sf "/${loader#./}" "lib64/$ld_so"
    fi
fi

# ---------------------------------------------------------------------------------
# Trim. Everything from here to ldconfig removes things that exist only because a
# package's `make install` puts them there, not because anything in a booted image
# reads them. None of it is a judgement call about what a user might want later: the
# image has no compiler, no man/info reader and no locale support, so these files are
# unreachable, not merely unused. Build-time consumers get them from rootfs/, which
# this script no longer touches.

# Debug symbols. glibc, systemd and util-linux are compiled with -g and nothing strips
# them, so about half of what would be shipped is DWARF that only a debugger we do not
# have could read — libc.so.6 alone is 11 MB unstripped and 2 MB stripped. /boot is
# excluded because the kernel is not one.
#
# This used to be `find usr -type f -print0 | xargs ... strip 2>/dev/null || true`, on the
# belief that strip "refuses to touch anything that is not an ELF object and leaves it
# alone". Half true: it leaves the file unmodified, but it also writes "file format not
# recognized" and exits nonzero, once per text file in the tree. That is what the
# `2>/dev/null` was for, and between them the two silencers hid a real failure:
#
#   - `xargs -P` stops dispatching when a child is killed or exits 255, so one strip that
#     dies takes the whole remainder of the file list with it,
#   - and `|| true` then discarded xargs' status, so the build carried on and shipped a
#     tree that was only *partly* stripped — which part depending on find's order.
#
# Not hypothetical. On arm64 the oci flavour shipped a 10 MB unstripped libc.so.6 while
# the ext4 flavour in the same job stripped it to 1.6 MB, reproducibly, and the only thing
# that noticed was test/size-budget.txt. That file already records a smaller version of
# this and reads it as batching noise: "two trees differing only in files that were
# deleted from one produced ~0.9 MiB of difference in directories neither touched".
#
# So: hand strip only ELF objects, and let it fail the build if it fails. The magic test
# is bash's `read -N 4` rather than file(1), which debian:sid does not have without
# another line in image/Containerfile, or readelf, which would be a process per file.
# bash drops NUL bytes as it reads, which is harmless here — \x7fELF contains none, so a
# file whose first bytes are NUL simply fails to match and is skipped, as it should be.
#
# The scan runs with tracing off: `set -x` over twenty thousand iterations would be longer
# than the rest of the build log put together.
elf_list=$(mktemp)
set +x
while IFS= read -r -d '' f; do
    LC_ALL=C read -r -N 4 magic < "$f" 2>/dev/null || continue
    if [ "$magic" = $'\177ELF' ]; then printf '%s\0' "$f"; fi
done < <(find usr -type f -print0) > "$elf_list"
set -x
echo "stripping $(tr -cd '\0' < "$elf_list" | wc -c) ELF objects"

# Serial, one file per invocation, and the file named if it fails. That is a deliberate
# retreat from `xargs -P "$(nproc)" -n 50`, on two grounds.
#
# The parallelism is no longer buying anything. It was there because this pass used to
# walk the whole tree — twenty thousand files, almost all of them not ELF and each one an
# error. The filter above takes it to eight hundred, and eight hundred strips cost seconds.
#
# And the parallelism is what made the failure unreadable. strip dies with SIGBUS on this
# tree; batched fifty at a time across four workers, all xargs can say is "strip:
# terminated by signal 7", the other forty-nine files in that batch are silently skipped,
# and every file xargs had not yet dispatched is skipped too. One at a time, a crash names
# its file, and nothing else is skipped because there is nothing else in flight.
set +x
stripped=0
while IFS= read -r -d '' f; do
    strip --strip-unneeded "$f" || {
        set -x
        echo "error: strip failed on $f (after $stripped objects)" >&2
        exit 1
    }
    stripped=$((stripped + 1))
done < "$elf_list"
set -x
echo "stripped $stripped ELF objects"
rm -f "$elf_list"

# Link-time-only files: static archives, libtool descriptors, the crt*.o startup objects
# glibc installs next to them, headers and pkg-config metadata. The loader never opens
# any of it — a running binary uses the .so — and there is no compiler here to link with.
find usr \( -name '*.a' -o -name '*.la' \) -delete
find usr/lib usr/lib64 -maxdepth 1 -name '*.o' -delete 2>/dev/null || true
rm -rf usr/include usr/src
rm -rf usr/lib/pkgconfig usr/lib64/pkgconfig usr/share/pkgconfig
rm -rf usr/share/aclocal usr/share/gtk-doc
# e2fsprogs' compile_et/mk_cmds templates, used to generate C at build time.
rm -rf usr/share/et usr/share/ss

# Documentation, for readers this image does not ship: there is no man, no info, and
# nothing that renders the html and xml under share/doc.
rm -rf usr/share/man usr/share/doc usr/share/info usr/share/xml

# Translations and locale definitions. The image runs in the C locale — no
# locale-archive is generated and nothing sets LANG — so the .mo catalogues can never be
# loaded, and share/i18n is the *source* form that localedef would compile if it were.
rm -rf usr/share/locale usr/share/i18n usr/share/gettext

# glibc's gconv modules, which are the same C-locale argument one level further down and
# by far the largest thing left that nothing here can reach: 253 shared objects, 7.7 MiB,
# about a tenth of the image. debian-slim carries the same set, so this is not why we are
# larger than it — it is simply the biggest dead weight in the tree.
#
# What can reach them is exactly one program. glibc compiles the important conversions
# *into* libc — ASCII, ISO-8859-1, UTF-8, UCS-2/4 and INTERNAL are in gconv_builtin.h and
# need no module at all — so the directory only matters to a caller of iconv_open with an
# unusual charset, and readelf across the image finds one such caller: /usr/bin/iconv.
# (glibc's gencat was the other, and packages/glibc/build.sh no longer installs it.)
#
# So this is not "delete what nothing uses" but "decide what iconv should still be able
# to do", which is a smaller claim and worth stating: the Latin, Cyrillic and Greek
# single-byte encodings a text file in the wild might be in, the Windows and DOS code
# pages, and the Unicode transforms that are not builtins. What goes is CJK (the
# multi-byte tables, which are most of the bytes — libCNS alone is 473 KB), EBCDIC in all
# sixteen national flavours, and a long tail of standards that were obsolete before this
# repository existed.
#
# The gconv-modules configuration is deliberately left whole. It is text, it is small,
# and it is what resolves charset *aliases* for the modules that remain — pruning it by
# hand to match would risk breaking a name that still works. The visible cost is that
# `iconv -l` still advertises everything; asking for one of the missing ones fails at
# module load rather than at lookup.
#
# usr/lib64 on amd64 and usr/lib on arm64, hence the loop rather than a fixed path.
gconv_keep="ANSI_X3.110 CP1250 CP1251 CP1252 CP1253 CP1254 CP1255 CP1256 CP1257 CP1258
            IBM437 IBM850 ISO8859-1 ISO8859-2 ISO8859-3 ISO8859-4 ISO8859-5 ISO8859-6
            ISO8859-7 ISO8859-8 ISO8859-9 ISO8859-9E ISO8859-10 ISO8859-11 ISO8859-13
            ISO8859-14 ISO8859-15 ISO8859-16 KOI8-R KOI8-RU KOI8-T KOI8-U MACINTOSH
            UNICODE UTF-16 UTF-32 UTF-7"
for gconvdir in usr/lib/gconv usr/lib64/gconv; do
    [ -d "$gconvdir" ] || continue
    for module in "$gconvdir"/*.so; do
        [ -e "$module" ] || continue
        name=${module##*/}
        case " $(echo $gconv_keep) " in
            *" ${name%.so} "*) continue ;;
        esac
        rm -f "$module"
    done
done

# systemd's message catalogue, same reasoning one level down. It ships seventeen
# .catalog files and sixteen of them are translations, selected by locale — which in a
# C-locale image can never be the selected one. Dropping them leaves systemd.catalog,
# the English source, which `journalctl -x` can and does reach. Matching on the
# language infix rather than a list of languages, so a new translation upstream is
# dropped too instead of quietly reappearing.
find usr/lib/systemd/catalog -name 'systemd.*.catalog' -delete 2>/dev/null || true

# Shell completions for shells that are not in the image (bash's own live in
# share/bash-completion, which is only read by the bash-completion package we do not
# ship), and polkit rules with no polkitd to enforce them.
rm -rf usr/share/bash-completion usr/share/zsh usr/share/fish etc/bash_completion.d
rm -rf usr/share/polkit-1 usr/share/X11 etc/X11

# terminfo is 12 MB describing some 2500 terminals. The console here is a serial line,
# so keep the handful of TERM values that can actually appear on it and drop the rest.
# Matching by name rather than by first-letter directory: ncurses can be built with
# hashed directories instead.
if [ -d usr/share/terminfo ]; then
    for t in ansi dumb linux screen screen-256color tmux tmux-256color \
             vt100 vt102 vt220 xterm xterm-256color xterm-color; do
        entry=$(find usr/share/terminfo -mindepth 2 -maxdepth 2 -name "$t" -print -quit)
        [ -n "$entry" ] || continue
        install -D -m 644 "$entry" "usr/share/terminfo.keep/${entry#usr/share/terminfo/}"
    done
    rm -rf usr/share/terminfo
    if [ -d usr/share/terminfo.keep ]; then
        mv usr/share/terminfo.keep usr/share/terminfo
    fi
fi
# ---------------------------------------------------------------------------------

# Build the shared-library search path and cache so the loader finds our libs. This is
# the last step that touches libraries: ld.so.cache indexes what is there when it runs.
cat > etc/ld.so.conf <<EOF
/usr/lib
/usr/local/lib
/lib64
/usr/lib/$multiarch
EOF
ldconfig -r "$IMAGE" || true

# The other index the image needs generated rather than installed. The .catalog files
# above are the source form; what journalctl actually opens is a compiled database at
# /var/lib/systemd/catalog/database, and nothing was building it — so any `journalctl
# -x`, and anything else resolving a MESSAGE_ID, answered "Failed to find catalog
# entry" for every message in the image.
#
# It has to be *our* journalctl: this container has no systemd of its own, and a
# Debian one would be writing a database for a different version to read. That binary
# is compiled against our glibc, and its RUNPATH is an absolute /usr/lib/systemd, which
# resolves inside this container to the container's copy — so invoke our loader by hand
# and hand it the image's library directories. --library-path is searched ahead of
# DT_RUNPATH, which is exactly what makes the override take. Same-arch only, which this
# script already assumes.
#
# Not tolerant of failure the way ldconfig above is: an empty catalog is the state this
# is fixing, and it should not be able to come back silently.
#
# Conditional on journalctl being in the image rather than on the flavour, and this is
# the general rule for **anything added below the selection block: it runs against a tree
# packages have been removed from, so it has to say which images it is for.** An image
# without systemd has neither the .catalog sources nor anything left to read the result,
# and the loader invocation below would fail with a message that names neither: run
# explicitly, ld.so reports a program it cannot open through the same "cannot open shared
# object file" it uses for libraries, so a missing journalctl reads as a missing library
# of journalctl's.
#
# Not tolerant of failure once it does run: an empty catalog is the state this is fixing.
if [ -x usr/bin/journalctl ]; then
    catalog_ld="$IMAGE/lib64/$ld_so"
    [ -x "$catalog_ld" ] || catalog_ld="$IMAGE/usr/lib/$ld_so"
    "$catalog_ld" --library-path "$IMAGE/usr/lib:$IMAGE/usr/lib/systemd" \
        "$IMAGE/usr/bin/journalctl" --root="$IMAGE" --update-catalog
    test -s "$IMAGE/var/lib/systemd/catalog/database"
fi

chown -R root:root etc

# os-release is not in this list: it is a symlink now, and the install -m 644 above
# already set the mode on the real file under /usr/lib.
chmod 644 etc/passwd etc/group etc/hosts etc/profile etc/nsswitch.conf etc/ld.so.conf

# Per file rather than per flavour, for the same reason as the catalog above: which of
# these exist is now a question about what this image selected, and a `chmod` on a path a
# platform dropped is a failed build rather than a smaller image.
#
# `if` rather than `[ … ] && chmod …`, and not as a style preference: under `set -e` a
# top-level `A && B` whose A is false is a non-zero status for the whole list, so the
# idiom would fail the build on precisely the images these tests exist to skip.
if [ -d etc/systemd ]; then
    chmod 755 etc/systemd/system etc/systemd/network etc/systemd/system/dbus.service.d
    chmod 644 etc/systemd/network/*.network etc/systemd/system/dbus.service.d/*.conf
fi
if [ -d etc/pam.d ]; then
    chmod 755 etc/pam.d
    chmod 644 etc/pam.d/*
fi
if [ -f etc/fstab ];    then chmod 644 etc/fstab;    fi
if [ -f etc/hostname ]; then chmod 644 etc/hostname; fi
# Password hashes must not be world-readable. Absent from a container image, which has no
# login to authenticate.
if [ -f etc/shadow ];   then chmod 600 etc/shadow;   fi

du -sh "$IMAGE"

# ---------------------------------------------------------------------------------
# What this image asks for and does not have.
#
# Selection introduces a failure mode the old two-flavour build could not have: an image
# missing a library some binary in it needs. The superset always resolves — that is what
# test/check-rootfs-deps.sh proves about rootfs/ — but a subset need not, and a variant
# that drops libmnl and keeps `ip` is broken in a way nothing over the staging tree can
# see. The first sign would be `ip` not starting in qemu, which is the same shape as the
# allowlisted-library trap CLAUDE.md already records.
#
# The computation is not new: it is what the SBOM's "unresolved" entries have always
# been, with deliberately the same construction as test/check-rootfs-deps.sh — two
# different answers to "what does this tree fail to resolve" is exactly the drift that
# script's allowlist exists to prevent. What changes is the verdict. Today the number is
# written into a document; here it fails the build.
#
# Both halves of `provided` matter, and getting either wrong is silent. A library is
# usually shipped as a real file plus a SONAME symlink pointing at it — libcurl.so.4 ->
# libcurl.so.4.8.0 — so `-type f` alone misses every name a binary actually asks for. The
# first version of this reported 29 shipped libraries as missing for that reason. The
# SONAME read out of the file covers the other direction, where the link is absent and
# ld.so.conf resolves by name.
provided=$(
    { find "$IMAGE" -name '*.so*' \( -type f -o -type l \) -print0 2>/dev/null |
      xargs -0 -r -n40 sh -c '
          for f in "$@"; do
              basename "$f"
              readelf -d "$f" 2>/dev/null | sed -n "s/.*SONAME.*\[\(.*\)\].*/\1/p"
          done' _ || true; } | sort -u
)
# The braces and the `|| true` are load-bearing: this hands readelf every file in the
# tree, most of which are not ELF at all, and readelf exits non-zero on each one it
# cannot parse. xargs turns that into 123, and `set -o pipefail` at the top of this
# script turns *that* into a failed image build. Grouping is what lets `|| true` apply to
# the producer rather than to `sed`.
needed=$(
    { find "$IMAGE" -type f -print0 2>/dev/null |
      xargs -0 -r -n40 readelf -dW 2>/dev/null || true; } |
    sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p' | sort -u
)
missing=$(comm -23 <(printf '%s\n' "$needed") <(printf '%s\n' "$provided"))

# test/known-missing-libs.txt is the accepted backlog for the superset, and a variant's
# check runs against the same list: a library that is accepted-missing for everybody
# stays accepted-missing here. Same caveat CLAUDE.md already records — an allowlist hides
# new arrivals as well as old ones.
allowlist=${ALLOWLIST:-/known-missing-libs.txt}
unexpected=$(
    comm -23 <(printf '%s\n' "$missing" | grep -v '^$' | sort -u) \
             <(grep -v '^[[:space:]]*\(#\|$\)' "$allowlist" | sort -u)
)

if [ -n "$unexpected" ]; then
    set +x
    echo "error: $variant/$platform is missing libraries that binaries in it need:" >&2
    for lib in $unexpected; do
        # The error names the fix, which is the whole reason the manifests exist: "this
        # variant needs libmnl.so.0, which libmnl provides; add it to net.conf" is a
        # thirty-second fix and "unresolved: libmnl.so.0" is a twenty-minute one.
        # `|| true` on both of these: grep exits non-zero when it matches nothing, and
        # under `set -o pipefail` that is a failed assignment and an exit in the middle of
        # an error message. `sed -n 1,4p` rather than `head -4` for the neighbouring
        # reason — head closing the pipe early is a SIGPIPE the same pipefail would take
        # for a build failure.
        owners=$( { (cd "$manifests" && grep -lF "/$lib" ./*) 2>/dev/null || true; } |
                  sed 's|^\./||' | tr '\n' ' ')
        consumers=$( { find "$IMAGE" -type f -print0 |
                       xargs -0 -r -n40 grep -laF "$lib" 2>/dev/null || true; } |
                     sed -e "s|^$IMAGE/||" -e '4q' | tr '\n' ' ')
        printf '  %s\n' "$lib" >&2
        if [ -n "$owners" ]; then
            printf '      provided by: %s — add it to image/variants/%s.conf\n' "$owners" "$variant" >&2
        else
            printf '      no package here provides it; it came from the Debian builder image.\n' >&2
            printf '      Configure the dependency out, or allowlist it in %s.\n' "$(basename "$allowlist")" >&2
        fi
        printf '      needed by: %s\n' "$consumers" >&2
    done
    exit 1
fi

# The other direction, and the one DT_NEEDED cannot see: a library selection removed
# whose name is still referenced by something that survived. This is the general form of
# the libudev guard the old subtractions block carried by hand — grep rather than readelf
# precisely so a dlopen by name is caught alongside a NEEDED, which is how udev's and
# kmod's APIs are both reached.
#
# Only names selection actually removed and nothing else provides: a library that moved
# or is shipped twice is not gone.
set +x
: > "$work/gone-libs.all"
while IFS= read -r p; do
    case "${p##*/}" in *.so|*.so.*) printf '%s\n' "${p##*/}" >> "$work/gone-libs.all" ;; esac
done < "$work/delete"
LC_ALL=C sort -u -o "$work/gone-libs.all" "$work/gone-libs.all"
# Both sides re-sorted in the same collation: `provided` above was built with the
# container's default locale and gone-libs.all with LC_ALL=C, and comm compares byte
# order rather than trusting either.
printf '%s\n' "$provided" | LC_ALL=C sort -u > "$work/provided"
comm -23 "$work/gone-libs.all" "$work/provided" > "$work/gone-libs.gross"

# ...minus every name that is a *prefix* of one the image still provides, which is the
# rule this check needs and did not have on its first outing. `usr/lib/libsystemd.so` is
# the unversioned development symlink: the oci platform's `keep usr/lib/libsystemd.so.0*`
# does not match it, so selection removes it, and by bare name it looks gone. It is not,
# in any sense a consumer cares about — `libsystemd.so.0` is right there — and because
# `grep -F` matches substrings, hunting for "libsystemd.so" finds every binary that
# references `libsystemd.so.0`. That is exactly what happened: crun, logger, dbus-daemon,
# libmount, libdbus-1 and libsystemd.so.0 itself were reported as referencing a library
# that had not gone anywhere.
#
# A name that is a prefix of a provided one is therefore not a removal, and the same rule
# covers every other `libX.so` dev symlink the trim leaves behind.
set +x
: > "$work/gone-libs"
while IFS= read -r lib; do
    [ -n "$lib" ] || continue
    shadowed=
    while IFS= read -r have; do
        case "$have" in "$lib"*) shadowed=1; break ;; esac
    done < "$work/provided"
    if [ -z "$shadowed" ]; then printf '%s\n' "$lib" >> "$work/gone-libs"; fi
done < "$work/gone-libs.gross"
set -x

if [ -s "$work/gone-libs" ]; then
    # `grep -o` per file so the message names the library as well as the file. Without it
    # the report is a list of paths and no clue which of forty removed libraries any of
    # them wanted, which is a twenty-minute fix pretending to be a thirty-second one.
    # Two passes: one `grep -l` over the whole tree to find the files at all, then `grep
    # -o` on just those. A `grep -o` per executable would be two thousand invocations for
    # an answer that is almost always "none of them".
    candidates=$(find usr -type f -perm -u+x -exec grep -laF -f "$work/gone-libs" {} + 2>/dev/null || true)
    set +x
    : > "$work/gone-refs"
    for f in $candidates; do
        for lib in $(grep -oaF -f "$work/gone-libs" "$f" 2>/dev/null | sort -u); do
            printf '%s %s\n' "$lib" "$f" >> "$work/gone-refs"
        done
    done
    set -x
    if [ -s "$work/gone-refs" ]; then
        set +x
        echo "error: $variant/$platform still references libraries selection removed:" >&2
        sort -u "$work/gone-refs" | sed 's/^/  /' >&2
        echo "       Either select the package that provides it, rescue the library with a" >&2
        echo "       'keep' line, or drop whatever started asking for it." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------------
# The component records for packages this image does not contain.
#
# A record exists for every package that was staged; an image is a selection from that,
# so the SBOM has to be too. Presence is decided by asking the tree rather than by
# reading the package list, which is the difference that matters for a `keep`: the oci
# platform omits systemd and rescues libsystemd.so.0, and systemd is genuinely still an
# ingredient of that image.
components="$IMAGE/usr/share/flfs/components"
set +x
for record in "$components"/*; do
    [ -e "$record" ] || continue
    pkg=${record##*/}
    [ -f "$manifests/$pkg" ] || continue
    survives=
    while IFS= read -r path; do
        if [ -e "$IMAGE/$path" ] || [ -L "$IMAGE/$path" ]; then survives=1; break; fi
    done < "$manifests/$pkg"
    if [ -z "$survives" ]; then rm -f "$record"; fi
done
set -x
echo "components: $(ls "$components" | wc -l) packages contributed files to this image"

# The manifests have done their work — selection, the dependency hint above and the
# component pruning just now. They are the intermediate form, like the component records
# and the .catalog sources, and the assembled image should have one answer to "what is in
# me": usr/share/flfs/sbom.json, below.
rm -rf "$manifests"

# ---------------------------------------------------------------------------------
# What is in the image, written down: an SPDX 2.3 document, one per image (issue #75).
#
# Generated, not scanned. A scanner infers packages from a package manager's database and
# there is none here — nothing in this image was installed, everything was compiled — so a
# scanner would find almost nothing and be confident about it. Every ingredient is already
# pinned and hashed in packages/<pkg>/env.sh; builder/build-package.sh stages those pins
# into usr/share/flfs/components as each package installs, and this reads them back.
#
# Reading them from the *assembled* tree rather than from packages/ is the whole point,
# and it is why this lives here rather than in a script over the repository. Every image
# has genuinely different contents — this one is whatever `$variant` selected, minus what
# `$platform` cannot use — so a document generated from env.sh would describe none of
# them. The records left in usr/share/flfs/components after the pruning above are the
# packages that actually contributed a file to *this* image.
#
# Written by hand, for the same reason the OCI archive below is: this is a JSON object
# with fields we control, and the alternative is putting jq or python into
# image/Containerfile to serialise thirty string fields. The values are package names,
# versions, URLs and hex digests — but "we control them" is a claim worth checking rather
# than asserting, so test/check-sbom.sh parses the result on the runner, where there *is*
# a JSON parser, and CI fails when it will not parse or comes up short.
sbom="$IMAGE/usr/share/flfs/sbom.json"
components="$IMAGE/usr/share/flfs/components"

if [ ! -d "$components" ] || [ -z "$(ls -A "$components" 2>/dev/null)" ]; then
    echo "error: no component records in usr/share/flfs/components" >&2
    echo "       builder/build-package.sh stages one per package; a tree without them" >&2
    echo "       predates that and cannot be described. Delete rootfs/ and rebuild." >&2
    exit 1
fi

# SOURCE_DATE_EPOCH when it is set, so that the same tree produces the same document.
# SPDX requires a creation timestamp and an unconditional `date` would be the only thing
# in the image that changes between two identical builds.
created=$(date -u -d "@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y-%m-%dT%H:%M:%SZ)

# JSON string escaping, for the four characters that can appear in anything read from a
# file: backslash, quote, tab, and any control character. Applied to every value below
# rather than only the ones that look risky — the cost is nothing and the alternative is
# deciding, per field, whether upstream could ever put a quote in a version string.
jstr() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g'
}

# SPDX identifiers may only contain letters, digits, '.' and '-'.
spdxid() { printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '-'; }

image_name="flfs-$IMAGE_ID-$oci_arch"

{
    printf '{\n'
    printf '  "spdxVersion": "SPDX-2.3",\n'
    printf '  "dataLicense": "CC0-1.0",\n'
    printf '  "SPDXID": "SPDXRef-DOCUMENT",\n'
    printf '  "name": "%s",\n' "$(jstr "$image_name")"
    # The namespace has to be unique per document. Deriving it from the component records
    # rather than from a UUID keeps two builds of the same tree identical, which is the
    # same reason SOURCE_DATE_EPOCH is honoured above.
    printf '  "documentNamespace": "https://github.com/fwilhe2/glowing-octo-robot/spdx/%s-%s",\n' \
        "$(jstr "$image_name")" "$(cat "$components"/* | sha256sum | cut -c1-16)"
    printf '  "creationInfo": {\n'
    printf '    "created": "%s",\n' "$created"
    printf '    "creators": [ "Tool: flfs-build-rootfs", "Organization: github.com/fwilhe2/glowing-octo-robot" ]\n'
    printf '  },\n'
    printf '  "documentDescribes": [ "SPDXRef-Image" ],\n'
    printf '  "packages": [\n'

    # The image itself, which everything else is CONTAINED_BY or a DEPENDS_ON of.
    printf '    {\n'
    printf '      "SPDXID": "SPDXRef-Image",\n'
    printf '      "name": "%s",\n' "$(jstr "$image_name")"
    printf '      "downloadLocation": "NOASSERTION",\n'
    printf '      "filesAnalyzed": false,\n'
    printf '      "licenseConcluded": "NOASSERTION",\n'
    printf '      "licenseDeclared": "NOASSERTION",\n'
    printf '      "copyrightText": "NOASSERTION",\n'
    printf '      "primaryPackagePurpose": "OPERATING_SYSTEM"\n'
    printf '    }'

    for record in "$components"/*; do
        name= version= license= origin= builder= url= sha256=
        while IFS='=' read -r key value; do
            case "$key" in
                name) name=$value ;; version) version=$value ;; license) license=$value ;;
                origin) origin=$value ;; builder) builder=$value ;;
                url) url=$value ;; sha256) sha256=$value ;;
            esac
        done < "$record"
        [ -n "$name" ] || continue

        printf ',\n    {\n'
        printf '      "SPDXID": "SPDXRef-Package-%s",\n' "$(spdxid "$name")"
        printf '      "name": "%s",\n' "$(jstr "$name")"
        printf '      "versionInfo": "%s",\n' "$(jstr "$version")"
        # A local-source package has no tarball to point at, so the repository is the
        # download location and there is no checksum — the honest answer in both cases,
        # and NOASSERTION would be a worse one.
        if [ "$origin" = local ]; then
            printf '      "downloadLocation": "git+https://github.com/fwilhe2/glowing-octo-robot",\n'
        else
            printf '      "downloadLocation": "%s",\n' "$(jstr "$url")"
        fi
        printf '      "filesAnalyzed": false,\n'
        if [ -n "$sha256" ]; then
            printf '      "checksums": [ { "algorithm": "SHA256", "checksumValue": "%s" } ],\n' "$(jstr "$sha256")"
        fi
        printf '      "externalRefs": [ { "referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": "pkg:generic/%s@%s" } ],\n' \
            "$(jstr "$name")" "$(jstr "$version")"
        printf '      "licenseConcluded": "NOASSERTION",\n'
        printf '      "licenseDeclared": "%s",\n' "$(jstr "${license:-NOASSERTION}")"
        printf '      "copyrightText": "NOASSERTION"\n'
        printf '    }'
    done

    # The toolchain. Same package and same source compiled by a different compiler is a
    # different artifact, and this is the one build input env.sh has never described.
    # One entry per distinct reference, which is normally one.
    builders=$(awk -F= '$1 == "builder" && $2 != "" { print $2 }' "$components"/* | sort -u)
    for b in $builders; do
        printf ',\n    {\n'
        printf '      "SPDXID": "SPDXRef-Builder-%s",\n' "$(spdxid "$b")"
        printf '      "name": "%s",\n' "$(jstr "${b%%:*}")"
        printf '      "versionInfo": "%s",\n' "$(jstr "${b##*:}")"
        printf '      "downloadLocation": "%s",\n' "$(jstr "$b")"
        printf '      "filesAnalyzed": false,\n'
        printf '      "licenseConcluded": "NOASSERTION",\n'
        printf '      "licenseDeclared": "NOASSERTION",\n'
        printf '      "copyrightText": "NOASSERTION"\n'
        printf '    }'
    done

    # And the libraries the image asks for and does not have. An SBOM listing only what
    # we built would describe something other than what runs: these are real runtime
    # dependencies of shipped binaries, resolved by nothing.
    #
    # $missing was computed above, where it is also what fails the build when it names
    # something test/known-missing-libs.txt has not accepted. One computation, two
    # consumers: a document that disagreed with the check beside it would be worse than
    # either alone.
    #
    # They appear as packages the image DEPENDS_ON without a matching CONTAINS below,
    # which is precisely what SPDX's two relationships are for and reads correctly in a
    # consumer: needed, not present.
    for lib in $missing; do
        [ -n "$lib" ] || continue
        printf ',\n    {\n'
        printf '      "SPDXID": "SPDXRef-Unresolved-%s",\n' "$(spdxid "$lib")"
        printf '      "name": "%s",\n' "$(jstr "$lib")"
        printf '      "versionInfo": "NOASSERTION",\n'
        printf '      "downloadLocation": "NOASSERTION",\n'
        printf '      "filesAnalyzed": false,\n'
        printf '      "licenseConcluded": "NOASSERTION",\n'
        printf '      "licenseDeclared": "NOASSERTION",\n'
        printf '      "copyrightText": "NOASSERTION",\n'
        printf '      "comment": "Referenced by a shipped binary through DT_NEEDED but not present in this image."\n'
        printf '    }'
    done

    printf '\n  ],\n'
    printf '  "relationships": [\n'
    printf '    { "spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-Image" }'

    for record in "$components"/*; do
        name=$(awk -F= '$1 == "name" { print $2 }' "$record")
        [ -n "$name" ] || continue
        pkg_spdxid="SPDXRef-Package-$(spdxid "$name")"
        printf ',\n    { "spdxElementId": "SPDXRef-Image", "relationshipType": "CONTAINS", "relatedSpdxElement": "%s" }' "$pkg_spdxid"
        b=$(awk -F= '$1 == "builder" { print $2 }' "$record")
        if [ -n "$b" ]; then
            printf ',\n    { "spdxElementId": "SPDXRef-Builder-%s", "relationshipType": "BUILD_TOOL_OF", "relatedSpdxElement": "%s" }' \
                "$(spdxid "$b")" "$pkg_spdxid"
        fi
    done

    for lib in $missing; do
        [ -n "$lib" ] || continue
        printf ',\n    { "spdxElementId": "SPDXRef-Image", "relationshipType": "DEPENDS_ON", "relatedSpdxElement": "SPDXRef-Unresolved-%s" }' "$(spdxid "$lib")"
    done

    printf '\n  ]\n'
    printf '}\n'
} > "$sbom"

# The records were the intermediate form; the document supersedes them, the same way the
# .catalog sources are superseded by the compiled database. Removing them also keeps the
# SBOM the single answer to "what is in this image" rather than one of two that could
# disagree.
rm -rf "$components"

cp "$sbom" "/usr/local/output/sbom-$IMAGE_ID.json"
echo "sbom: $(wc -c < "$sbom") bytes, $(grep -c '"SPDXID"' "$sbom") elements"

# ---------------------------------------------------------------------------------
# What the image weighs, written down. This is the only place the *assembled* tree
# exists — rootfs/ is the input, still carrying the headers and static libraries the
# trim above removed — so if the number is not taken here it cannot be taken at all.
# test/rootfs-size.sh is what reads this back, compares the total against the budget in
# test/size-budget.txt and prints the breakdown.
#
# One report per image, and the image id is in the filename: every variant and platform
# shares every line of this script up to the selection block and none of them are the
# same size, so a single path would mean whichever ran last describing all of them. The
# default variant's reports keep the bare rootfs-size-ext4.txt / rootfs-size-oci.txt
# names, which is what test/vs-debian-slim.sh and test/size-history.sh read.
#
# Apparent bytes rather than blocks: it measures what the tree contains instead of what
# one filesystem's rounding makes of it, which keeps the number comparable across the two
# architectures, across a change to mkfs, and between a disk and a tar. What each flavour
# then costs in its own container — `disk` for the ext4, `archive` for the OCI — is
# appended below, once the thing that answers it has run.
report=/usr/local/output/rootfs-size-$IMAGE_ID.txt
{
    echo "# assembled $IMAGE_ID image tree, sizes in bytes. Written by image/build-rootfs.sh."
    echo "total $(du -sb "$IMAGE" | cut -f1)"

    # Two depths: enough to separate usr/lib from usr/share from usr/bin, which is where
    # growth actually shows up, without listing every subdirectory of usr/share. The
    # empty directories of the skeleton are noise at this resolution, hence the floor.
    #
    # Both loops read from a process substitution rather than a pipeline on purpose:
    # `find | sort | head` under `set -o pipefail` fails the script with 141, because
    # head exits at line 25 and sort dies of SIGPIPE writing line 26. Inside <(...) that
    # status is nobody's business.
    while read -r bytes path; do
        [ "$path" = "$IMAGE" ] && continue
        [ "$bytes" -ge 65536 ] || continue
        echo "dir $bytes ${path#"$IMAGE"/}"
    done < <(du -b --max-depth=2 "$IMAGE" | sort -rn)

    # And the individual files, because one new 20 MB binary and 20 MB spread over a
    # thousand files are the same total and completely different problems.
    while read -r bytes path; do
        echo "file $bytes ${path#"$IMAGE"/}"
    done < <(find "$IMAGE" -type f -printf '%s %p\n' | sort -rn | head -n 25)
} > "$report"

# ---------------------------------------------------------------------------------
# What the tree is turned into, selected by the platform's `format`: one branch per
# format and no plugin mechanism, deliberately. `mkfs.ext4 -d` and a hand-assembled OCI
# layout have nothing in common, there will be three or four formats ever, and an
# abstraction layer over two implementations is how a build system acquires one nobody
# can read. A fourth branch is what a `lima` or `firecracker` platform would add.
if [ "$format" = ext4 ]; then
    /sbin/mkfs.ext4 -L root -d "$IMAGE" "$ext4_out" 1G

    # What that came to once the filesystem's own metadata, journal and block rounding are
    # counted: the number that says whether 1G is still the right size for the disk.
    fs=$(/sbin/dumpe2fs -h "$ext4_out" 2>/dev/null)
    block_count=$(echo "$fs" | grep '^Block count:'  | tr -dc '0-9')
    block_free=$( echo "$fs" | grep '^Free blocks:'  | tr -dc '0-9')
    block_size=$( echo "$fs" | grep '^Block size:'   | tr -dc '0-9')
    echo "disk $(( (block_count - block_free) * block_size ))" >> "$report"
    echo "capacity $(( block_count * block_size ))" >> "$report"

    ls -l "$ext4_out"
    cat "$report"
    exit 0
fi

if [ "$format" != oci ]; then
    echo "error: image/platforms/$platform.conf names format '$format', which nothing here builds" >&2
    echo "       Add a branch to image/build-rootfs.sh, next to ext4 and oci." >&2
    exit 1
fi

# ---------------------------------------------------------------------------------
# The OCI image, written out by hand. An oci-archive is a tar of a directory holding
# five things: the layer, the config and the manifest as blobs named after their own
# sha256, an index.json naming the manifest, and an `oci-layout` version marker. That
# is the entire format, which is why nothing here needs buildah, skopeo or a podman
# inside the container — `podman load -i` and `skopeo copy oci-archive:...` read what
# this writes. (The image itself still ships no such tooling: see docs/container-runtime.md.)
layout=/tmp/oci
rm -rf "$layout" /tmp/layer.tar
mkdir -p "$layout/blobs/sha256"

blob() {  # <file> <extension-less name it should have> → prints "<digest> <size>"
    local src=$1 digest size
    digest=$(sha256sum "$src" | cut -d' ' -f1)
    size=$(stat -c %s "$src")
    mv "$src" "$layout/blobs/sha256/$digest"
    echo "$digest $size"
}

# One layer, holding the whole tree. --sort and a forced uid/gid keep the bytes from
# depending on directory order or on whether podman ran rootless; every file in the
# image is root-owned either way. The descriptor names the *compressed* blob while
# rootfs.diff_ids in the config names the uncompressed one, so both get hashed.
tar --create --format=pax --sort=name --numeric-owner --owner=0 --group=0 \
    --directory "$IMAGE" . > /tmp/layer.tar
diff_id=$(sha256sum /tmp/layer.tar | cut -d' ' -f1)
gzip -9n < /tmp/layer.tar > /tmp/layer.tar.gz
rm -f /tmp/layer.tar
read -r layer_digest layer_size < <(blob /tmp/layer.tar.gz)

# Entrypoint bash, no Cmd: `podman run -it flfs` is a shell, and anything after the
# image name is passed to it (`podman run flfs -c uptime`). PATH has to be spelled out
# — with no /etc/profile read and no shell login, an empty one in the config leaves the
# runtime's default, which lists directories a merged-/usr image does not have.
cat > /tmp/config.json <<EOF
{
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "architecture": "$oci_arch",
  "os": "linux",
  "config": {
    "Env": ["PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/root"],
    "Entrypoint": ["/bin/bash"],
    "WorkingDir": "/root",
    "Labels": {
      "org.opencontainers.image.title": "$oci_name",
      "org.opencontainers.image.description": "$description (variant $variant), without the kernel and systemd"
    }
  },
  "rootfs": {
    "type": "layers",
    "diff_ids": ["sha256:$diff_id"]
  },
  "history": [
    {
      "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
      "created_by": "image/build-rootfs.sh $variant $platform"
    }
  ]
}
EOF
read -r config_digest config_size < <(blob /tmp/config.json)

cat > /tmp/manifest.json <<EOF
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:$config_digest",
    "size": $config_size
  },
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:$layer_digest",
      "size": $layer_size
    }
  ]
}
EOF
read -r manifest_digest manifest_size < <(blob /tmp/manifest.json)

# ref.name is the tag `podman load` gives what it reads: localhost/flfs:latest for the
# default variant, localhost/flfs-<variant>:latest for the others. Distinct per variant
# and not decoration: test/oci.sh and tools/publish-oci.sh both read the tag back out of
# what podman printed, and two archives annotated the same name would have the second
# load silently move that tag off the first image.
cat > "$layout/index.json" <<EOF
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:$manifest_digest",
      "size": $manifest_size,
      "platform": { "architecture": "$oci_arch", "os": "linux" },
      "annotations": { "org.opencontainers.image.ref.name": "$oci_name:latest" }
    }
  ]
}
EOF
echo '{"imageLayoutVersion": "1.0.0"}' > "$layout/oci-layout"

tar --create --directory "$layout" oci-layout index.json blobs > "$oci_out"
ls -l "$oci_out"

# The container flavour's answer to `disk`: what a registry stores and a `podman pull`
# moves is the gzipped layer, not the tree. Appended here rather than above for the same
# reason `disk` is appended after mkfs — the number does not exist until the thing that
# produces it has run.
echo "archive $(stat -c %s "$oci_out")" >> "$report"

cat "$report"
