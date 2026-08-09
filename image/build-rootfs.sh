#!/bin/bash
set -euo pipefail

set -x

# Two things come out of the same staging tree, and the argument says which:
#
#   ext4  a bootable disk for qemu — output/rootfs.ext4, the real output of this repo
#   oci   a container image — output/flfs-oci.tar, the same userspace with the parts
#         that only mean something to a machine that boots taken back out
#
# They are one script rather than two because everything that is hard-won here — the
# merged-/usr skeleton, the loader path, the trim, ldconfig — is identical for both.
# The container flavour is expressed as *subtractions* from the disk image, in one
# block below, the same way vm.config is expressed as subtractions from defconfig.
flavour=${1:-ext4}
case "$flavour" in
    ext4|oci) ;;
    *) echo "usage: ${0##*/} [ext4|oci]" >&2; exit 2 ;;
esac

# The staging tree is an input, not the image. Everything below — the /etc we ship, the
# stripping, the pruning — happens on a copy in the container's own filesystem, so that
# rootfs/ stays exactly what the package builds put there. It has to: rootfs/ is also
# the sysroot the *next* package compiles against, and that needs the headers, static
# libraries and .pc files this script is about to throw away.
STAGE=/usr/local/src
IMAGE=/usr/local/image

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

if [ "$flavour" = ext4 ]; then
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
# The container flavour, as subtractions. A container gets its kernel from the host and
# its PID 1 from the runtime, so both of ours are dead weight — and worse than dead,
# because a systemd that cannot run is still a systemd someone will try to run. This
# runs before the trim so the strip pass below has less to walk.
if [ "$flavour" = oci ]; then
    # The kernel. The host's is the one the container will be running on.
    rm -rf boot

    # systemd, in the four places it installs itself: its own tree (36 MB of units,
    # generators, the executor and the private libsystemd-shared/-core), udev, the
    # drop-in directories it owns, and its PAM/NSS modules. nsswitch.conf here lists
    # only `files` and `dns`, so its NSS modules were never loaded even in the disk
    # image; they would simply dangle now that libsystemd-shared is gone.
    rm -rf usr/lib/systemd usr/lib/udev usr/share/factory usr/share/user-tmpfiles.d
    rm -rf usr/lib/sysusers.d usr/lib/tmpfiles.d usr/lib/environment.d usr/lib/binfmt.d
    # sysctl.d is systemd-sysctl's, and a container has no business setting kernel
    # parameters — the ones it can see belong to the host or to its own namespace, and
    # nothing in here would apply them either way. That covers ours as well as systemd's:
    # image/files/etc/sysctl.d/50-ping-group-range.conf is the guest's opt-in to
    # unprivileged ICMP sockets, and a runtime decides that for a container.
    rm -rf usr/lib/sysctl.d etc/sysctl.d
    rm -rf usr/lib/credstore etc/credstore etc/credstore.encrypted usr/lib/pam.d
    rm -rf etc/systemd etc/udev etc/tmpfiles.d etc/user-tmpfiles.d
    rm -f  usr/lib/security/pam_systemd.so usr/lib/security/pam_systemd_loadkey.so
    rm -f  usr/lib/libnss_systemd.so.2 usr/lib/libnss_resolve.so.2 \
           usr/lib/libnss_myhostname.so.2

    # libsystemd.so.0 and libudev.so.1 stay: they are the public client libraries other
    # packages link against — dbus-daemon has libsystemd.so.0 in its NEEDED — and
    # removing them would break binaries we are keeping. What is gone is systemd the
    # system, not its API.

    # Its command-line tools, found rather than listed: systemctl, journalctl, udevadm,
    # loginctl and the forty-odd systemd-* binaries all link the private
    # libsystemd-shared we just deleted, and nothing else in the tree does. Deriving
    # the list means a version bump that adds another one needs no edit here.
    while IFS= read -r bin; do
        if readelf -d "$bin" 2>/dev/null | grep -q 'libsystemd-\(shared\|core\)'; then
            rm -f "$bin"
        fi
    done < <(find usr/bin -maxdepth 1 -type f)

    # And the symlinks that pointed into all of that: /sbin/init, halt, poweroff,
    # reboot, shutdown, resolvconf, run0, the mount.* helpers — plus, in the three
    # directories systemd shares with software we do not ship *yet*, its shell
    # integration snippets (/etc/profile.d), its ssh proxy drop-in (/etc/ssh) and its
    # user-unit directory (/etc/xdg). Those three hold nothing else today, but deleting
    # them outright is how a future openssh package loses its config; dropping the links
    # that now point at nothing, and then the directory if that emptied it, doesn't.
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

    # The /etc that only a booted machine reads: a root filesystem to mount, a password
    # to type at a login prompt that isn't there, a NIC for networkd to configure. The
    # runtime supplies hostname and resolv.conf — ours pointed into resolved's /run stub,
    # which nothing will ever create here.
    #
    # /etc/hosts stays. A runtime bind-mounts its own over it, so it is not what the
    # container will read, but a static localhost mapping is correct either way and a
    # missing file is not — `podman run --network=none` mounts nothing.
    rm -f etc/fstab etc/shadow etc/hostname etc/resolv.conf
    rm -rf etc/pam.d
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
# Disk flavour only, and this is one of the two places where "the trim is identical for
# both" stops being true. The subtractions block above has already deleted
# usr/lib/systemd — the .catalog source files with it — and every binary linking
# libsystemd-shared, which is exactly how journalctl goes. So there is nothing to
# compile, nothing left to read the result, and the loader invocation below fails with
# a message that names neither: run explicitly, ld.so reports a program it cannot open
# through the same "cannot open shared object file" it uses for libraries, so a missing
# journalctl reads as a missing library of journalctl's.
if [ "$flavour" = ext4 ]; then
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

if [ "$flavour" = ext4 ]; then
    chmod 755 etc/systemd/system etc/systemd/network etc/pam.d \
              etc/systemd/system/dbus.service.d
    chmod 644 etc/fstab etc/hostname etc/pam.d/* \
              etc/systemd/network/*.network \
              etc/systemd/system/dbus.service.d/*.conf
    # Password hashes must not be world-readable. Only reachable for this flavour: the
    # subtractions above delete etc/shadow outright, a container having no login to
    # authenticate.
    chmod 600 etc/shadow
fi

du -sh "$IMAGE"

# ---------------------------------------------------------------------------------
# What the image weighs, written down. This is the only place the *assembled* tree
# exists — rootfs/ is the input, still carrying the headers and static libraries the
# trim above removed — so if the number is not taken here it cannot be taken at all.
# test/rootfs-size.sh is what reads this back, compares the total against the budget in
# test/size-budget.txt and prints the breakdown.
#
# One report per flavour, and the flavour is in the filename: the two images share every
# line of this script up to here and are nothing like the same size, so a single path
# would mean whichever ran last describing both.
#
# Apparent bytes rather than blocks: it measures what the tree contains instead of what
# one filesystem's rounding makes of it, which keeps the number comparable across the two
# architectures, across a change to mkfs, and between a disk and a tar. What each flavour
# then costs in its own container — `disk` for the ext4, `archive` for the OCI — is
# appended below, once the thing that answers it has run.
report=/usr/local/output/rootfs-size-$flavour.txt
{
    echo "# assembled $flavour image tree, sizes in bytes. Written by image/build-rootfs.sh."
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

if [ "$flavour" = ext4 ]; then
    /sbin/mkfs.ext4 -L root -d "$IMAGE" /usr/local/output/rootfs.ext4 1G

    # What that came to once the filesystem's own metadata, journal and block rounding are
    # counted: the number that says whether 1G is still the right size for the disk.
    fs=$(/sbin/dumpe2fs -h /usr/local/output/rootfs.ext4 2>/dev/null)
    block_count=$(echo "$fs" | grep '^Block count:'  | tr -dc '0-9')
    block_free=$( echo "$fs" | grep '^Free blocks:'  | tr -dc '0-9')
    block_size=$( echo "$fs" | grep '^Block size:'   | tr -dc '0-9')
    echo "disk $(( (block_count - block_free) * block_size ))" >> "$report"
    echo "capacity $(( block_count * block_size ))" >> "$report"

    cat "$report"
    exit 0
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
      "org.opencontainers.image.title": "flfs",
      "org.opencontainers.image.description": "Florian's Linux From Scratch, without the kernel and systemd"
    }
  },
  "rootfs": {
    "type": "layers",
    "diff_ids": ["sha256:$diff_id"]
  },
  "history": [
    {
      "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
      "created_by": "image/build-rootfs.sh oci"
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

# ref.name is the tag `podman load` gives what it reads: localhost/flfs:latest.
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
      "annotations": { "org.opencontainers.image.ref.name": "flfs:latest" }
    }
  ]
}
EOF
echo '{"imageLayoutVersion": "1.0.0"}' > "$layout/oci-layout"

tar --create --directory "$layout" oci-layout index.json blobs \
    > /usr/local/output/flfs-oci.tar
ls -l /usr/local/output/flfs-oci.tar

# The container flavour's answer to `disk`: what a registry stores and a `podman pull`
# moves is the gzipped layer, not the tree. Appended here rather than above for the same
# reason `disk` is appended after mkfs — the number does not exist until the thing that
# produces it has run.
echo "archive $(stat -c %s /usr/local/output/flfs-oci.tar)" >> "$report"

cat "$report"
