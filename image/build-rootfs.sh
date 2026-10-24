#!/bin/bash
set -euo pipefail

set -x

# Two things come out of the same staging tree, and the argument says which:
#
#   erofs  a bootable, read-only disk for qemu — output/rootfs.erofs, the real output of
#          this repo. Nothing on it can be changed; an update is a new image.
#   oci    a container image — output/flfs-oci.tar, the same userspace with the parts
#          that only mean something to a machine that boots taken back out
#
# They are one script rather than two because everything that is hard-won here — the
# merged-/usr skeleton, the loader path, the trim, ldconfig — is identical for both.
# The container flavour is expressed as *subtractions* from the disk image, in one
# block below, the same way vm.config is expressed as subtractions from defconfig.
flavour=${1:-erofs}
case "$flavour" in
    erofs|oci) ;;
    *) echo "usage: ${0##*/} [erofs|oci]" >&2; exit 2 ;;
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
# No var/log/journal, which used to be the switch for a persistent journal: journald's
# Storage=auto writes to /var/log/journal only if the directory exists, and the disk
# image's /var is a tmpfs now, so there is nowhere persistent for it to point. The
# journal lives in /run, which is the same RAM by another name.
install -d -m 0750 root
# The unprivileged account's home. Nothing in the image would create it on first login —
# pam_mkhomedir is not in image/files/etc/pam.d and there is no shadow-utils here — so a
# missing directory means bash starts in a working directory that does not exist. This is
# the container's copy; the disk image mounts a tmpfs over /home, and
# image/files/etc/tmpfiles.d/flfs-home.conf makes it there at every boot. The
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

if [ "$flavour" = erofs ]; then
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
# Every tar here is written the same way, so that the same tree makes the same bytes:
# --sort so directory order does not leak in, numeric owners, and every mtime clamped to
# SOURCE_DATE_EPOCH — the tree was just copied, stripped and generated, so its own
# timestamps are this run's. The pax options are the subtle half: GNU tar's pax format
# records atime and ctime per file, and names each extended header `PaxHeaders.<pid>`, so
# without them no two archives would ever match whatever went into them. Two of them:
# the OCI layer below, and the stream the disk image is made from (see mkfs.erofs).
repro_tar() {
    tar --create --format=pax --sort=name --numeric-owner \
        --mtime="@${SOURCE_DATE_EPOCH:-$(date +%s)}" --clamp-mtime \
        --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime "$@"
}

# ---------------------------------------------------------------------------------
# The container flavour, as subtractions. A container gets its kernel from the host and
# its PID 1 from the runtime, so both of ours are dead weight — and worse than dead,
# because a systemd that cannot run is still a systemd someone will try to run. This
# runs before the trim so the strip pass below has less to walk.
if [ "$flavour" = oci ]; then
    # The kernel. The host's is the one the container will be running on. Its
    # /usr/lib/modules/<release> holds nothing but a link to boot/config.
    rm -rf boot usr/lib/modules

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

    # libsystemd.so.0 stays: it is the public client library, and ten binaries this
    # image keeps have it in NEEDED — crun and libmount.so.1 among them, which is the
    # container runtime and `mount`. What is gone is systemd the system, not its API.

    # Its command-line tools, found rather than listed: systemctl, journalctl, udevadm,
    # loginctl and the forty-odd systemd-* binaries all link the private
    # libsystemd-shared we just deleted, and nothing else in the tree does. Deriving
    # the list means a version bump that adds another one needs no edit here.
    while IFS= read -r bin; do
        if readelf -d "$bin" 2>/dev/null | grep -q 'libsystemd-\(shared\|core\)'; then
            rm -f "$bin"
        fi
    done < <(find usr/bin -maxdepth 1 -type f)

    # PAM, all of it, and this is not the usual "a container rarely needs that": it is
    # already broken in one. /etc/pam.d went with systemd's /etc above, and libpam with
    # no configuration for a service does not fall back to something permissive, it
    # aborts — `su -c ... root` in the published image answers "su: Critical error -
    # immediate abort", and runuser the same. /etc/shadow is gone too, so there would be
    # nothing to authenticate against even with a config. What that leaves is a megabyte
    # of modules nothing can load and a handful of helpers that cannot start.
    #
    # The consumers are derived for the same reason the systemd tools are: a util-linux
    # that grows another PAM-linked helper would otherwise ship it here, pointed at a
    # library this deleted.
    #
    # `grep -a`, and it is not optional. Without it GNU grep decides the file is binary,
    # and a match on a "line" carrying NUL bytes and invalid UTF-8 — which is every line
    # of an ELF .dynstr — is discarded rather than reported: `grep -q libpam.so
    # usr/bin/su` exits 1 on a binary that plainly needs libpam.so.0. `-l` happens to
    # short-circuit before that check and answers correctly, which is the sort of
    # difference that makes this silent. `if` rather than `grep && rm` for a duller
    # reason: a failing `&&` list at the end of a loop body is the script's exit status
    # under `set -e`.
    rm -rf usr/lib/security etc/security
    rm -f  usr/lib/libpam*
    while IFS= read -r bin; do
        if grep -qa 'libpam\.so' "$bin" 2>/dev/null; then
            rm -f "$bin"
        fi
    done < <(find usr/bin -maxdepth 1 -type f)

    # A serial getty, in a container that has no serial line and no PID 1 to start one.
    rm -f usr/bin/agetty

    # openssh's server half, which the PAM sweep above cannot see: sshd-session and
    # sshd-auth are the two binaries in the package that link libpam — configure puts
    # -lpam in SSHDLIBS rather than LIBS, so the clients and even the listener do not —
    # and they live in usr/libexec, which that loop does not walk. Named instead, so
    # the -f is the one place a rename would go unnoticed; a release that moved them
    # into usr/bin would be collected by the sweep, and one that kept them here under a
    # new name would ship a binary whose NEEDED names a deleted libpam, which is what
    # test/check-rootfs-deps.sh is for.
    #
    # The rest of the package stays, and that is the line this draws: an ssh *client*
    # in a container is ordinary, an ssh *server* in one has no PID 1 to be started by,
    # no /etc/pam.d to authenticate through and no host key anything would generate. So
    # the listener goes with its helpers, and so do the files that exist only to serve
    # it — the sftp subsystem sshd execs, the config only sshd reads, and the privilege
    # separation chroot only sshd enters. Its unit and sysusers.d snippet went with
    # usr/lib/systemd above.
    rm -f  usr/bin/sshd usr/libexec/sshd-session usr/libexec/sshd-auth \
           usr/libexec/sftp-server etc/ssh/sshd_config
    rm -rf usr/share/empty.sshd

    # What is left of the container stack in the base once the engines are extensions
    # (podman, kubernetes; docs/sysext.md): conmon and the containers/image configuration,
    # which in a container are a niche (podman-in-podman) rather than the point, and the
    # subordinate ID ranges only the podman extension's newuidmap reads. crun stays: it
    # is a few hundred KB, it is what test/container.sh-style bundles run on, and it was in
    # this image before podman was.
    rm -rf usr/bin/conmon etc/containers etc/subuid etc/subgid

    # ...and the two libraries only conmon linked. Checked the same way libudev is below,
    # and for the same reason: a package that started linking glib would look complete in
    # the staging tree and fail at exec in somebody's container once this deleted it.
    # The libraries' own files are excluded by prefix rather than by .so, because libtool
    # installs a .la beside each that names it — executable, and deleted only by the trim
    # further down, which runs after this.
    consumers=$(find usr -type f -perm -u+x ! -name 'libglib-2.0.*' ! -name 'libpcre2-8.*' \
                    -exec grep -laE 'libglib-2\.0\.so|libpcre2-8\.so' {} + 2>/dev/null || true)
    if [ -n "$consumers" ]; then
        echo "error: the container image still needs glib or pcre2, which this deletes:" >&2
        echo "$consumers" >&2
        exit 1
    fi
    rm -f usr/lib/libglib-2.0.* usr/lib/libpcre2-8.*

    # kmod, dead here for a reason that has nothing to do with containers: packages/kernel
    # builds with CONFIG_MODULES off, so there is no module to insert into anything. The
    # disk image keeps it anyway — systemd-modules-load and udev reach libkmod, and a
    # missing library there is a failed unit rather than a smaller image. The six tools
    # are symlinks to kmod and the loop below collects them once this deletes the target.
    rm -rf etc/depmod.d etc/modprobe.d etc/modules-load.d
    rm -f  usr/bin/kmod usr/lib/libkmod.so*

    # libudev.so.1 is the half of the sentence above that is not true of it: with udev
    # and udevadm gone, nothing in the container names the library at all, so it was
    # 1.6 MB of client library with no client. It has to come after that loop rather than
    # next to the comment it belongs to — udevadm is a consumer right up until the line
    # above deletes it. The disk image is where udev runs, and keeps it.
    #
    # Checked rather than asserted, because the failure is silent here and loud in
    # somebody else's container: a package that started linking libudev would look
    # complete in the staging tree test/check-rootfs-deps.sh reads and fail at exec once
    # this deleted the library underneath it. grep rather than readelf, so a dlopen by
    # name is caught alongside a DT_NEEDED — udev's API is reached both ways.
    consumers=$(find usr -type f -perm -u+x ! -name 'libudev.so*' -exec grep -la 'libudev\.so' {} + 2>/dev/null || true)
    if [ -n "$consumers" ]; then
        echo "error: the container image still needs libudev, which this deletes:" >&2
        echo "$consumers" >&2
        echo "       Keep the library — drop the rm below — or configure udev out of" >&2
        echo "       whatever package started asking for it." >&2
        exit 1
    fi
    rm -f usr/lib/libudev.so*

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
# Nothing in the image is setuid or setgid, as a rule rather than an accident: ping works
# through a sysctl, sudo is not here, and util-linux and openssh are built not to install
# the bit. A file that arrives with one fails the build, because the bit's survival used
# to depend on how the packages were unpacked — CI's unprivileged untar dropped it and a
# local copy kept it — and a privilege the image grants should not be a coin toss.
setid=$(find . -xdev -type f -perm /6000 -printf '%m %p\n')
if [ -n "$setid" ]; then
    echo "error: setuid/setgid files in the image (build the package without them):" >&2
    echo "$setid" >&2
    exit 1
fi

# The account files image/files ships are data only, and their reasons are kept here,
# because a comment line in them is not harmless. glibc skips one, but not every reader
# of /etc/passwd is glibc: buildah parses it itself to resolve a Containerfile's
# `USER user`, gives up at the first line without seven fields, and reports *unknown
# user* — so an image built FROM flfs could not name its own account.
#
#   passwd   `user` is uid 1000 deliberately: systemd allocates system users from below
#            SYSTEM_UID_MAX, which is 999 when there is no /etc/login.defs to say
#            otherwise, so nothing systemd-sysusers creates can collide with it. Its home
#            is made above for the container and by tmpfiles.d/flfs-home.conf at boot.
#   group    the user's own group, and only that. The groups worth joining —
#            systemd-journal, wheel, adm — are `g <name> - -` in systemd's sysusers.d, so
#            sysusers allocates their GIDs below, after this file is copied in; naming
#            one here would mean guessing a number sysusers is entitled to choose.
#   shadow   no account has a password, and `*` is not a hash any password can match.
#            Logins are handed in per machine as systemd credentials on the kernel
#            command line: ssh.authorized_keys.root for sshd, and login.noauth for the
#            serial console, which util-linux's login reads and test/qemu-lib.sh passes.
#            Whoever controls the VMM already owns the guest; nobody else has a password
#            to try.
for f in etc/passwd etc/group etc/shadow; do
    [ -e "$f" ] || continue
    if grep -nE '^[[:space:]]*(#|$)' "$f" >&2; then
        echo "error: $f has comment or blank lines (above); keep the reasons in build-rootfs.sh" >&2
        exit 1
    fi
done

# Nor does any account have a password. Access is handed to each machine as a credential
# (see above), and a hash in a public image is a password everyone has.
# `*` and `!…` are the only shapes that match nothing; sysusers writes `!*`.
if [ -e etc/shadow ]; then
    hashed=$(awk -F: '$2 != "*" && $2 !~ /^!/ { print $1 }' etc/shadow)
    if [ -n "$hashed" ]; then
        echo "error: accounts with a password in /etc/shadow: $hashed" >&2
        exit 1
    fi
fi

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

# D-Bus introspection XML, 0.6 MiB of it, installed by systemd for each of its services.
# It is documentation for people writing a client: `busctl introspect` and every other
# caller ask the running service, which answers from its own vtable, and dbus-daemon
# reads only the policy files in share/dbus-1/system.d and the activation files beside
# them, never interfaces/.
rm -rf usr/share/dbus-1/interfaces

# CMake package files, which are the same link-time metadata as the pkg-config above in
# another build system's dialect. OpenSSL installs them.
rm -rf usr/lib/cmake

# PAM modules no PAM configuration names. Linux-PAM builds and installs all forty of its
# modules; a module is only ever loaded because a line in /etc/pam.d or /usr/lib/pam.d
# names it, both are read-only here, and the image's services name nine between them.
# Derived from the files rather than listed, so that a service gaining a module keeps it
# without an edit here. The match takes the name with or without `.so`, since both
# spellings appear (openssh's file writes `pam_unix`). Helpers whose only caller is a
# module that has just gone go with it. A no-op on the container flavour, which the
# subtractions have already taken PAM away from.
if [ -d usr/lib/security ]; then
    pam_conf=$(cat etc/pam.d/* usr/lib/pam.d/* 2>/dev/null | grep -v '^[[:space:]]*#')
    for module in usr/lib/security/pam_*.so; do
        name=$(basename "$module" .so)
        if ! grep -Eq "(^|[[:space:]/])$name(\\.so)?([[:space:]]|\$)" <<<"$pam_conf"; then
            rm -f "$module"
            case $name in
                pam_filter)    rm -rf usr/lib/security/pam_filter ;;
                pam_faillock)  rm -f usr/bin/faillock ;;
                pam_pwhistory) rm -f usr/bin/pwhistory_helper ;;
                pam_mkhomedir) rm -f usr/bin/mkhomedir_helper ;;
                pam_timestamp) rm -f usr/bin/pam_timestamp_check ;;
            esac
        fi
    done
fi

# NSS modules nsswitch.conf does not name, by the same argument: glibc loads
# libnss_<name>.so.2 only for a <name> in that file, which is read-only. That is glibc's
# compat (the NIS `+user` syntax), db (Berkeley DB maps) and hesiod (DNS TXT records),
# all three legacy directory services nothing here is configured for. Both flavours.
nss_conf=$(grep -v '^[[:space:]]*#' etc/nsswitch.conf)
for module in usr/lib/libnss_*.so.2; do
    [ -e "$module" ] || continue
    name=${module##*/libnss_}
    name=${name%.so.2}
    grep -Eq "[[:space:]]$name([[:space:]]|\$)" <<<"$nss_conf" || rm -f "$module"
done

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

# Local additions: whatever is in /extra (bind-mounted from the host's extra/ directory by
# tools/build-image.sh, absent in CI) is laid over the assembled tree, for both flavours.
# Deliberately *after* the trim and the subtractions -- a debugging tool you asked for is not
# something the trim gets to decide about -- and *before* ldconfig, so a library that comes
# with one is in ld.so.cache. Not in the SBOM: it is generated from the component records
# packages leave, and these are not packages.
if [ -d /extra ] && [ -n "$(ls -A /extra)" ]; then
    echo "extra: overlaying $(find /extra -type f | wc -l) file(s) from extra/"
    cp -a /extra/. .
fi

# Build the shared-library search path and cache so the loader finds our libs. This is
# the last step that touches libraries: ld.so.cache indexes what is there when it runs.
cat > etc/ld.so.conf <<EOF
/usr/lib
/usr/local/lib
/lib64
/usr/lib/$multiarch
EOF
ldconfig -r "$IMAGE" || true

# ---------------------------------------------------------------------------------
# First boot, done here. The disk image's root is EROFS, so /etc cannot be written by
# anything that runs on it, and every unit that would normally fill /etc in on first boot
# has to have had its work done before mkfs. systemd already knows this shape: the
# units that write /etc are ConditionNeedsUpdate=/etc, which is false on a read-only
# /etc, so they skip rather than fail — but skipping only works if the result is already
# here. What is left over is a degraded boot at best and a silently incomplete one at
# worst (see the presets below), with a journal that says "Read-only file system" and
# nothing about which of these was missed. test/systemd.sh fails on that line.
#
# Each tool has to be *our* build: this container has no systemd of its own, and a Debian
# one would apply a different version's rules. Ours are compiled against our glibc with
# an absolute RUNPATH of /usr/lib/systemd, which resolves inside this container to the
# container's copy — so they are run through our loader by hand, with the image's library
# directories. --library-path is searched ahead of DT_RUNPATH, which is exactly what makes
# the override take. Same-arch only, which this script already assumes. Invoked this way,
# ld.so reports a program it cannot open with the same "cannot open shared object file"
# it uses for libraries, so a deleted binary reads as a missing library of its own.
#
# Disk flavour only: the subtractions block above has already deleted these binaries,
# their configuration and anything that would read the result from the container tree.
if [ "$flavour" = erofs ]; then
    ours_ld="$IMAGE/lib64/$ld_so"
    [ -x "$ours_ld" ] || ours_ld="$IMAGE/usr/lib/$ld_so"
    ours() {
        local bin=$1; shift
        "$ours_ld" --library-path "$IMAGE/usr/lib:$IMAGE/usr/lib/systemd" "$IMAGE/usr/bin/$bin" "$@"
    }

    # The accounts every sysusers.d snippet asks for — systemd's own groups, dbus'
    # messagebus, openssh's privilege separation user — appended to the passwd and group
    # image/files ships. systemd-sysusers.service would have done this at first boot.
    ours systemd-sysusers --root="$IMAGE"

    # The /etc half of tmpfiles.d: the profile.d and ssh_config.d symlinks, the credstore
    # directories, /etc/mtab. The rest of it — /var, /run, /home — is on a tmpfs at boot
    # and systemd-tmpfiles-setup.service makes it there, so --prefix keeps this to the
    # one tree that has to be right before the image is sealed. --boot because these are
    # first-boot lines in a world where every boot is the first.
    ours systemd-tmpfiles --root="$IMAGE" --create --boot --prefix=/etc
    # The osc-context drop-in is masked above with a symlink to /dev/null, and that has
    # to have survived a tmpfiles run whose /dev/null is inside $IMAGE.
    test ! -e etc/profile.d/80-systemd-osc-context.sh

    # Unit presets. On first boot — which with an empty machine-id is every boot — PID 1
    # applies systemd-preset files by writing enablement symlinks into /etc/systemd/system,
    # and that is how systemd-networkd, systemd-resolved and timesyncd get enabled at all:
    # nothing ships them with a .wants symlink of their own. On a read-only /etc the write
    # fails, PID 1 logs it and carries on, and the machine boots `running` with no network.
    # No failed unit, no degraded state — test/network.sh is what notices.
    ours systemctl preset-all --root="$IMAGE"
    test -L etc/systemd/system/multi-user.target.wants/systemd-networkd.service

    # / itself at 0555, which is what systemd's tmpfiles.d/root.conf (`z / 555`) sets at
    # every boot — and on EROFS the fchmod fails, once per boot, in the journal. Shipping
    # the mode it wants turns that into a no-op. It is the mode of the directory mkfs is
    # handed, so this is the one place it can be set.
    chmod 555 "$IMAGE"

    # File capabilities, which a package declares rather than sets: CI's package tars
    # carry no xattrs, so `setcap` in a package's build.sh would not survive the trip to
    # this tree. A package that needs one writes usr/share/flfs/capabilities/<pkg>, one
    # "<path> <capabilities>" per line, and whichever assembly takes its files applies it —
    # this one, or image/build-extension.sh for a package in a system extension. The
    # image's rule is that nothing is setuid, and a capability is what replaces it: newuidmap
    # and newgidmap (packages/shadow) get CAP_SETUID and CAP_SETGID for a rootless
    # container's ID maps, as Fedora ships them. They reach the disk image through the tar
    # mkfs.erofs is fed below, which carries security.capability and no other xattr. The
    # container flavour applies none: an OCI layer would not carry them either.
    apply_capabilities() { # tree
        local records="$1/usr/share/flfs/capabilities" path caps
        [ -d "$records" ] || return 0
        while read -r path caps; do
            [ -n "$path" ] || continue
            [ -f "$1/$path" ] || { echo "error: $records names $path, which is not a file" >&2; exit 1; }
            setcap "$caps" "$1/$path"
            getcap "$1/$path"
        done < <(cat "$records"/*)
    }
    apply_capabilities .

    # An empty /etc/machine-id, rather than none. On a read-only root PID 1 generates an
    # id at every boot and bind-mounts it over this file from /run; with no file to mount
    # over it can do neither, and dbus, journald and networkd's DHCP client id all read
    # it. Empty rather than "uninitialized", which would ask systemd-machine-id-commit to
    # persist it — there is nowhere to persist it to.
    : > etc/machine-id
    chmod 444 etc/machine-id

    # The journal catalogue is the one index this script used to compile and no longer
    # does: what `journalctl -x` opens is /var/lib/systemd/catalog/database, and /var is a
    # tmpfs, so a database written here would be hidden under it. The source files stay in
    # /usr/lib/systemd/catalog, and systemd-journal-catalog-update.service compiles them at
    # boot — it is ConditionNeedsUpdate=/var, and a /var that starts empty always needs
    # one. That is the hermetic-/usr arrangement working as designed rather than a gap.

    # /var's mount, as a unit rather than an fstab line, so that it is a default a VM can
    # override without editing anything in the image. systemd's unit search path puts
    # /run/systemd/generator ahead of /usr/lib/systemd/system, and that is where
    # systemd-fstab-generator writes the var.mount for a kernel command line's
    # `systemd.mount-extra=/dev/vdb:/var:ext4:x-systemd.makefs,x-systemd.growfs` — so a VM
    # given a disk for /var gets it, formatted on first boot and grown to fit, and a VM
    # given nothing gets this tmpfs. The .wants link names the unit, not the file, so it
    # pulls in whichever var.mount won.
    #
    # Not systemd.volatile=state, which is the same fallback built in: its tmpfs is capped
    # at a quarter of RAM, and /var/lib/containers is where podman keeps its images.
    cat > usr/lib/systemd/system/var.mount <<'UNIT'
[Unit]
Description=Variable state, in RAM (no persistent /var was given)
Documentation=man:systemd.mount(5)
DefaultDependencies=no
Conflicts=umount.target
Before=local-fs.target umount.target

[Mount]
What=tmpfs
Where=/var
Type=tmpfs
Options=mode=0755,nosuid,nodev
UNIT
    mkdir -p usr/lib/systemd/system/local-fs.target.wants
    ln -sfn ../var.mount usr/lib/systemd/system/local-fs.target.wants/var.mount

    # And the mount points themselves, emptied. /var, /home and /root are mounts (var.mount
    # above, image/files/etc/fstab), so anything staged under them would ship and be invisible
    # — including the /var/run symlink, which systemd's own var.conf recreates on the
    # tmpfs. An empty directory says that plainly; a populated one would be a lie that
    # costs bytes. The container keeps all of it: it has no fstab.
    find var home root -mindepth 1 -delete
fi

# The capability records are an intermediate form, like the component records, and in the
# container flavour they would name files the subtractions above have deleted.
rm -rf usr/share/flfs/capabilities

chown -R root:root etc

# os-release is not in this list: it is a symlink now, and the install -m 644 above
# already set the mode on the real file under /usr/lib.
chmod 644 etc/passwd etc/group etc/hosts etc/profile etc/nsswitch.conf etc/ld.so.conf

if [ "$flavour" = erofs ]; then
    chmod 755 etc/systemd/system etc/systemd/network etc/pam.d \
              etc/systemd/system/dbus.service.d etc/systemd/journald.conf.d \
              etc/systemd/system-preset
    chmod 644 etc/fstab etc/hostname etc/subuid etc/subgid etc/pam.d/* etc/tmpfiles.d/flfs-home.conf \
              etc/systemd/network/*.network \
              etc/systemd/system/dbus.service.d/*.conf etc/systemd/journald.conf.d/*.conf \
              etc/systemd/system-preset/*.preset
    # Password hashes must not be world-readable. Only reachable for this flavour: the
    # subtractions above delete etc/shadow outright, a container having no login to
    # authenticate.
    chmod 600 etc/shadow
fi

du -sh "$IMAGE"

# ---------------------------------------------------------------------------------
# What is in the image, written down: an SPDX 2.3 document, one per flavour (issue #75).
#
# Generated, not scanned. A scanner infers packages from a package manager's database and
# there is none here — nothing in this image was installed, everything was compiled — so a
# scanner would find almost nothing and be confident about it. Every ingredient is already
# pinned and hashed in packages/<pkg>/env.sh; builder/build-package.sh stages those pins
# into usr/share/flfs/components as each package installs, and this reads them back.
#
# Reading them from the *assembled* tree rather than from packages/ is the whole point,
# and it is why this lives here rather than in a script over the repository. The two
# flavours have genuinely different contents — the oci one has had systemd and the kernel
# subtracted — so a document generated from env.sh would describe neither image. What is
# in usr/share/flfs/components is what got staged into the tree that became this image.
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

image_name="flfs-$flavour-$oci_arch"

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
    # dependencies of shipped binaries, resolved by nothing. Computed from the assembled
    # tree rather than read from test/known-missing-libs.txt, because that file is an
    # allowlist of what has been *accepted* and this has to be what is actually true.
    #
    # They appear as packages the image DEPENDS_ON without a matching CONTAINS below,
    # which is precisely what SPDX's two relationships are for and reads correctly in a
    # consumer: needed, not present.
    # Deliberately the same construction as test/check-rootfs-deps.sh, which is the
    # authority on this question — two different answers to "what does this tree fail to
    # resolve" is exactly the drift that file's allowlist exists to prevent. It cannot
    # simply be reused: it runs over rootfs/, the staging tree, and this has to describe
    # the *assembled* image, which the trim and the oci subtractions have changed.
    #
    # Both halves of `provided` matter, and getting either wrong is silent. A library is
    # usually shipped as a real file plus a SONAME symlink pointing at it — libcurl.so.4
    # -> libcurl.so.4.8.0 — so `-type f` alone misses every name a binary actually asks
    # for. The first version of this reported 29 shipped libraries as missing for that
    # reason. The SONAME read out of the file covers the other direction, where the link
    # is absent and ld.so.conf resolves by name.
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
    # script turns *that* into a failed image build. Grouping is what lets `|| true`
    # apply to the producer rather than to `sed`.
    needed=$(
        { find "$IMAGE" -type f -print0 2>/dev/null |
          xargs -0 -r -n40 readelf -dW 2>/dev/null || true; } |
        sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p' | sort -u
    )
    missing=$(comm -23 <(printf '%s\n' "$needed") <(printf '%s\n' "$provided"))
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
        id="SPDXRef-Package-$(spdxid "$name")"
        printf ',\n    { "spdxElementId": "SPDXRef-Image", "relationshipType": "CONTAINS", "relatedSpdxElement": "%s" }' "$id"
        b=$(awk -F= '$1 == "builder" { print $2 }' "$record")
        if [ -n "$b" ]; then
            printf ',\n    { "spdxElementId": "SPDXRef-Builder-%s", "relationshipType": "BUILD_TOOL_OF", "relatedSpdxElement": "%s" }' \
                "$(spdxid "$b")" "$id"
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

cp "$sbom" "/usr/local/output/sbom-$flavour.json"
echo "sbom: $(wc -c < "$sbom") bytes, $(grep -c '"SPDXID"' "$sbom") elements"

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
# then costs in its own container — `disk` for the EROFS image, `archive` for the OCI — is
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

if [ "$flavour" = erofs ]; then
    # EROFS rather than ext4 with `ro` in fstab: a filesystem that has no write path at
    # all, so "nothing modifies the image" is a property of the format rather than of a
    # mount option somebody can remount away. It is also compressed and sized to its
    # contents — there is no free space to choose, and so no 1G to outgrow.
    #
    # The compression is where most of the disk image's size is decided, more than by
    # anything any package does. Measured on one amd64 tree of 160 MiB:
    #
    #   -zlz4hc,12                                     95.6 MiB   what this used to be
    #   -zlz4hc,12  -C65536 -Eztailpacking,fragments   80.1 MiB
    #   -zzstd,15  -C131072 -Eztailpacking,fragments   65.9 MiB   this
    #   -zzstd,19  -C131072 -Eztailpacking             64.1 MiB   at 3-4x the build time
    #   -zlzma,6   -C131072                            61.4 MiB
    #
    # -C is the bigger half of it. EROFS compresses each physical cluster on its own, and
    # the default cluster is one 4 KiB block, so lz4hc was compressing 4 KiB at a time with
    # no history to match against; 128 KiB is squashfs's default block for the same
    # reason. A read now decompresses up to that much to return one page, which for a
    # root filesystem that is read sequentially at boot and then cached costs nothing
    # anybody measures. ztailpacking puts a file's last partial block inline with its
    # inode instead of in a cluster of its own, and fragments compresses those tails
    # together, which is all there is to most of the unit files and /etc. zstd rather
    # than lzma: decompression an order of magnitude faster, for 4.5 MiB.
    # It needs CONFIG_EROFS_FS_ZIP_ZSTD, which packages/kernel's rootfs.config turns on
    # and test/kernel-caps.sh holds it to.
    #
    # The label is for people and blkid; nothing mounts by it (the root is the verity
    # device on top, /etc/fstab says why). With SOURCE_DATE_EPOCH set — the same switch
    # the SBOM honours below — every timestamp and the UUID are pinned, so the same tree
    # makes the same bytes.
    erofs_repro=()
    if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
        erofs_repro=(-T "$SOURCE_DATE_EPOCH" --all-time -U 00000000-0000-0000-0000-000000000000)
    fi
    rm -f /usr/local/output/rootfs.erofs
    #
    # From a tar stream rather than the directory, for the one extended attribute the image
    # has: the file capabilities packages declare, applied further up. mkfs.erofs given a
    # directory records every xattr it can read, and on an SELinux host that includes the
    # security.selinux label the *host* gives every file — which made a Fedora build differ
    # from CI's in nothing else, and which cannot be removed, the kernel reporting a label
    # on every file whether or not one is stored. Through tar, what goes in is exactly what
    # --xattrs-include names: security.capability, nothing else, on any host.
    repro_tar --xattrs --xattrs-include='security.capability' --directory "$IMAGE" . \
        > /tmp/rootfs.tar
    mkfs.erofs -L root -zzstd,15 -C131072 -Eztailpacking,fragments --tar=f "${erofs_repro[@]}" \
        /usr/local/output/rootfs.erofs /tmp/rootfs.tar
    rm -f /tmp/rootfs.tar

    # dm-verity, so the image is not only read-only but tamper-evident: the kernel checks
    # every block it reads against a hash tree, and the tree against a root hash on its own
    # command line. A changed byte anywhere in the filesystem is an I/O error on the block
    # that holds it, not a changed file.
    #
    # The tree is appended to the same file rather than shipped as a second disk, so an
    # image is still one file to attach; --hash-offset is where the filesystem ends, and
    # EROFS images are whole blocks, which is the alignment verity needs. No superblock:
    # it exists for veritysetup to read the parameters back at open time, and nothing
    # opens this with veritysetup — the kernel is handed every parameter instead.
    erofs=/usr/local/output/rootfs.erofs
    data_size=$(stat -c %s "$erofs")
    if [ $(( data_size % 4096 )) -ne 0 ]; then
        echo "error: $erofs is $data_size bytes, not a whole number of 4 KiB blocks" >&2
        exit 1
    fi
    data_blocks=$(( data_size / 4096 ))
    verity_salt=()
    if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
        verity_salt=(--salt="$(printf '%s' "$SOURCE_DATE_EPOCH" | sha256sum | cut -c1-64)")
    fi
    verity=$(veritysetup format --no-superblock --hash=sha256 \
        --data-block-size=4096 --hash-block-size=4096 \
        --data-blocks="$data_blocks" --hash-offset="$data_size" \
        "${verity_salt[@]}" "$erofs" "$erofs")
    echo "$verity"
    root_hash=$(sed -n 's/^Root hash:[[:space:]]*//p' <<< "$verity")
    salt=$(sed -n 's/^Salt:[[:space:]]*//p' <<< "$verity")
    [ -n "$root_hash" ] && [ -n "$salt" ] || {
        echo "error: could not read the root hash and salt back from veritysetup" >&2
        exit 1
    }

    # The kernel arguments that boot this image, and the only place its root hash is
    # written down: the image is half of a release and this is the other half, with the
    # kernel. dm-mod.create builds the verity device in the kernel itself (CONFIG_DM_INIT),
    # so there is still no initrd; the table is `<start> <sectors> verity <version> <data
    # dev> <hash dev> <data block> <hash block> <data blocks> <hash start block> <algo>
    # <root hash> <salt>`. dm-mod.waitfor holds it until virtio-blk has probed the disk.
    #
    # /dev/vda is a property of the VMM rather than of the image — virtio-blk's first disk,
    # under qemu and Firecracker both — and is the one assumption in here a consumer may
    # have to rewrite.
    sectors=$(( data_size / 512 ))
    printf '%s\n' "root=/dev/dm-0 ro rootfstype=erofs dm-mod.waitfor=/dev/vda dm-mod.create=\"root,,,ro,0 $sectors verity 1 /dev/vda /dev/vda 4096 4096 $data_blocks $data_blocks sha256 $root_hash $salt\"" \
        > /usr/local/output/rootfs.cmdline
    cat /usr/local/output/rootfs.cmdline

    # What that came to once the compression, the filesystem's own metadata and the hash
    # tree are counted. The file is the disk, with no slack, so its size is the answer.
    echo "disk $(stat -c %s "$erofs")" >> "$report"

    cat "$report"
    exit 0
fi

# ---------------------------------------------------------------------------------
# The OCI image, written out by hand. An oci-archive is a tar of a directory holding
# five things: the layer, the config and the manifest as blobs named after their own
# sha256, an index.json naming the manifest, and an `oci-layout` version marker. That
# is the entire format, which is why nothing here needs buildah, skopeo or a podman
# inside the container — `podman load -i` and `skopeo copy oci-archive:...` read what
# this writes. (The disk image ships podman, which could; the image container that runs
# this script does not, and does not need it.)
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

# One layer, holding the whole tree; every file in the image is root-owned. The
# descriptor names the *compressed* blob while rootfs.diff_ids in the config names the
# uncompressed one, so both get hashed. gzip -n leaves the name and time out of its header.
repro_tar --owner=0 --group=0 --directory "$IMAGE" . > /tmp/layer.tar
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
  "created": "$created",
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
      "created": "$created",
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

repro_tar --owner=0 --group=0 --directory "$layout" oci-layout index.json blobs \
    > /usr/local/output/flfs-oci.tar
ls -l /usr/local/output/flfs-oci.tar

# The container flavour's answer to `disk`: what a registry stores and a `podman pull`
# moves is the gzipped layer, not the tree. Appended here rather than above for the same
# reason `disk` is appended after mkfs — the number does not exist until the thing that
# produces it has run.
echo "archive $(stat -c %s /usr/local/output/flfs-oci.tar)" >> "$report"

cat "$report"
