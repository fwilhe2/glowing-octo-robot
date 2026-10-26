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
# One script, because the skeleton, the trim and ldconfig are the same for both; the
# container flavour is one block of subtractions from the disk image.
flavour=${1:-erofs}
case "$flavour" in
    erofs|oci) ;;
    *) echo "usage: ${0##*/} [erofs|oci]" >&2; exit 2 ;;
esac

# rootfs/ is mounted read-only and everything happens on a copy: the same rootfs/ is the
# input to the next assembly, and to the other flavour.
STAGE=/usr/local/src
IMAGE=/usr/local/image

# Native, never cross-arch, so uname names the loader the binaries were linked for.
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
install -d -m 0750 root
# `user`'s home, for the container: nothing would create it on login. The disk image
# mounts a tmpfs over /home and tmpfiles.d/flfs-home.conf makes it there. Numeric, since
# 1000 is a name only in the /etc being shipped.
install -d -m 0700 home/user
chown 1000:1000 home/user
install -d -m 1777 tmp
mkdir -p usr/{lib,share}

# systemd taints the system ("unmerged-bin", "var-run-bad") when usr/sbin or var/run is
# a directory rather than a symlink.
if [ -d usr/sbin ] && [ ! -L usr/sbin ]; then
    find usr/sbin -mindepth 1 -maxdepth 1 -exec mv -t usr/bin/ {} +
    rmdir usr/sbin
fi
ln -sfn bin usr/sbin

if [ -d var/run ] && [ ! -L var/run ]; then
    rm -rf var/run
fi
ln -sfn ../run var/run

cp -r /files/* .

# os-release(5): the file in /usr/lib, /etc/os-release a symlink to it.
install -D -m 644 etc/os-release usr/lib/os-release
ln -sfn ../usr/lib/os-release etc/os-release

# The fields only a build knows. FLFS_VERSION is for a release (docs/release.md; nothing
# sets it yet), FLFS_BUILD is the commit. Unset, the file is exactly as it is in git.
# PRETTY_NAME is rewritten in place: not every parser takes the last of two assignments.
if [ -n "${FLFS_VERSION:-}" ]; then
    sed -i "s/^PRETTY_NAME=\"\(.*\)\"\$/PRETTY_NAME=\"\1 $FLFS_VERSION\"/" usr/lib/os-release
    printf 'VERSION="%s"\nVERSION_ID="%s"\n' "$FLFS_VERSION" "$FLFS_VERSION" >> usr/lib/os-release
fi

if [ -n "${FLFS_BUILD:-}" ]; then
    printf 'BUILD_ID="%s"\n' "$FLFS_BUILD" >> usr/lib/os-release
fi

if [ "$flavour" = erofs ]; then
    # systemd's osc-context drop-in wraps every prompt in OSC 3008 sequences, and the
    # serial console is what the boot tests parse; enabling it is a change to those
    # tests. Masking the tmpfiles snippet stops it coming back at boot, the rm removes
    # the staged copy.
    mkdir -p etc/tmpfiles.d
    ln -sfn /dev/null etc/tmpfiles.d/20-systemd-osc-context.conf
    rm -f etc/profile.d/80-systemd-osc-context.sh

    mkdir -p etc/systemd/system
    ln -sf /usr/lib/systemd/system/multi-user.target etc/systemd/system/default.target

    # The kernel execs /sbin/init; point it at systemd.
    ln -sf /usr/lib/systemd/systemd sbin/init
fi

# The ELF interpreter path baked into every binary. Merged-/usr resolves it already;
# this only acts if glibc put the loader somewhere unexpected.
if [ ! -e "lib64/$ld_so" ]; then
    loader=$(find . -name "$ld_so" -not -path './lib64/*' -not -path './lib/*' | head -n1)
    if [ -n "$loader" ]; then
        mkdir -p lib64
        ln -sf "/${loader#./}" "lib64/$ld_so"
    fi
fi

# ---------------------------------------------------------------------------------
# Every tar here goes through this, so the same tree makes the same bytes. The pax options
# matter: GNU tar's pax format otherwise records atime and ctime and names each extended
# header after the pid.
repro_tar() {
    tar --create --format=pax --sort=name --numeric-owner \
        --mtime="@${SOURCE_DATE_EPOCH:-$(date +%s)}" --clamp-mtime \
        --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime "$@"
}

# ---------------------------------------------------------------------------------
# The container flavour, as subtractions: a container gets its kernel from the host and
# its PID 1 from the runtime. Before the trim, so the strip has less to walk.
if [ "$flavour" = oci ]; then
    # The kernel, and /usr/lib/modules, which only links to its config.
    rm -rf boot usr/lib/modules

    # systemd: its tree, udev, its drop-in directories, its PAM and NSS modules. glibc
    # skips an nsswitch.conf source whose module is missing.
    rm -rf usr/lib/systemd usr/lib/udev usr/share/factory usr/share/user-tmpfiles.d
    rm -rf usr/lib/sysusers.d usr/lib/tmpfiles.d usr/lib/environment.d usr/lib/binfmt.d
    # sysctls, ours included: in a container the runtime decides them.
    rm -rf usr/lib/sysctl.d etc/sysctl.d
    rm -rf usr/lib/credstore etc/credstore etc/credstore.encrypted usr/lib/pam.d
    rm -rf etc/systemd etc/udev etc/tmpfiles.d etc/user-tmpfiles.d
    rm -f  usr/lib/security/pam_systemd.so usr/lib/security/pam_systemd_loadkey.so
    rm -f  usr/lib/libnss_systemd.so.2 usr/lib/libnss_resolve.so.2 \
           usr/lib/libnss_myhostname.so.2

    # libsystemd.so.0 stays: crun and libmount need it.
    # systemd's tools are whatever links the private libsystemd-shared, found rather
    # than listed so a new one needs no edit here.
    while IFS= read -r bin; do
        if readelf -d "$bin" 2>/dev/null | grep -q 'libsystemd-\(shared\|core\)'; then
            rm -f "$bin"
        fi
    done < <(find usr/bin -maxdepth 1 -type f)

    # PAM, and whatever links it. Without /etc/pam.d libpam aborts rather than falls
    # back (`su` answers "Critical error - immediate abort"), so it is broken here
    # anyway. `grep -a` is required: without it GNU grep discards a match inside an ELF
    # .dynstr. `if` rather than `&&`, which would be the loop's exit status under set -e.
    rm -rf usr/lib/security etc/security
    rm -f  usr/lib/libpam*
    while IFS= read -r bin; do
        if grep -qa 'libpam\.so' "$bin" 2>/dev/null; then
            rm -f "$bin"
        fi
    done < <(find usr/bin -maxdepth 1 -type f)

    # A serial getty, with no serial line.
    rm -f usr/bin/agetty

    # sshd and everything only it uses; the client stays. sshd-session and sshd-auth
    # link libpam but are in usr/libexec, which the sweep above does not walk.
    rm -f  usr/bin/sshd usr/libexec/sshd-session usr/libexec/sshd-auth \
           usr/libexec/sftp-server etc/ssh/sshd_config
    rm -rf usr/share/empty.sshd

    # The engines' half of the base (conmon, /etc/containers, subordinate IDs). crun
    # stays.
    rm -rf usr/bin/conmon etc/containers etc/subuid etc/subgid

    # The two libraries only conmon linked, checked so a new consumer fails the build
    # rather than somebody's container. Excluded by prefix to skip their own .la files.
    consumers=$(find usr -type f -perm -u+x ! -name 'libglib-2.0.*' ! -name 'libpcre2-8.*' \
                    -exec grep -laE 'libglib-2\.0\.so|libpcre2-8\.so' {} + 2>/dev/null || true)
    if [ -n "$consumers" ]; then
        echo "error: the container image still needs glib or pcre2, which this deletes:" >&2
        echo "$consumers" >&2
        exit 1
    fi
    rm -f usr/lib/libglib-2.0.* usr/lib/libpcre2-8.*

    # kmod: the kernel has no modules. The disk image keeps it for systemd and udev. Its
    # symlinks are collected by the dangling-link sweep below.
    rm -rf etc/depmod.d etc/modprobe.d etc/modules-load.d
    rm -f  usr/bin/kmod usr/lib/libkmod.so*

    # libudev has no consumer once udev and udevadm are gone. grep rather than readelf,
    # so a dlopen by name counts too.
    consumers=$(find usr -type f -perm -u+x ! -name 'libudev.so*' -exec grep -la 'libudev\.so' {} + 2>/dev/null || true)
    if [ -n "$consumers" ]; then
        echo "error: the container image still needs libudev, which this deletes:" >&2
        echo "$consumers" >&2
        echo "       Keep the library — drop the rm below — or configure udev out of" >&2
        echo "       whatever package started asking for it." >&2
        exit 1
    fi
    rm -f usr/lib/libudev.so*

    # Symlinks left dangling by all of that, and the three /etc directories systemd
    # shares with openssh and others, removed only if that emptied them. Resolved
    # against the tree, not with readlink -f (which would use the container's root).
    # Twice, for chains.
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

    # The /etc only a booted machine reads; the runtime supplies hostname and
    # resolv.conf. /etc/hosts stays: --network=none mounts none over it.
    rm -f etc/fstab etc/shadow etc/hostname etc/resolv.conf
    rm -rf etc/pam.d
fi

# ---------------------------------------------------------------------------------
# Nothing in the image is setuid or setgid; a privilege it grants is a file capability
# (below). Build the package without the bit.
setid=$(find . -xdev -type f -perm /6000 -printf '%m %p\n')
if [ -n "$setid" ]; then
    echo "error: setuid/setgid files in the image (build the package without them):" >&2
    echo "$setid" >&2
    exit 1
fi

# The account files carry no comments, because buildah parses /etc/passwd itself and
# stops at the first malformed line, so `USER user` in a Containerfile FROM flfs fails.
# Their reasons, here instead:
#   passwd   `user` is uid 1000, above the 999 systemd-sysusers allocates up to.
#   group    `user`'s group only; sysusers allocates the rest (wheel, systemd-journal).
#   shadow   no passwords. Logins are per-machine credentials on the kernel command line
#            (ssh.authorized_keys.root, login.noauth; see test/qemu-lib.sh).
for f in etc/passwd etc/group etc/shadow; do
    [ -e "$f" ] || continue
    if grep -nE '^[[:space:]]*(#|$)' "$f" >&2; then
        echo "error: $f has comment or blank lines (above); keep the reasons in build-rootfs.sh" >&2
        exit 1
    fi
done

# A hash in a public image is a password everyone has. `*` and `!…` match nothing.
if [ -e etc/shadow ]; then
    hashed=$(awk -F: '$2 != "*" && $2 !~ /^!/ { print $1 }' etc/shadow)
    if [ -n "$hashed" ]; then
        echo "error: accounts with a password in /etc/shadow: $hashed" >&2
        exit 1
    fi
fi

# Strip debug symbols, from ELF files only and failing loudly: strip on a text file
# exits nonzero, and silencing that once hid a partly stripped image. One file at a time,
# so a crash names its file. The magic test is bash's read, not a process per file, and
# tracing is off for the loops.
elf_list=$(mktemp)
set +x
while IFS= read -r -d '' f; do
    LC_ALL=C read -r -N 4 magic < "$f" 2>/dev/null || continue
    if [ "$magic" = $'\177ELF' ]; then printf '%s\0' "$f"; fi
done < <(find usr -type f -print0) > "$elf_list"
set -x
echo "stripping $(tr -cd '\0' < "$elf_list" | wc -c) ELF objects"

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

# The trim: what `make install` puts there and nothing in the image can reach — the
# bar is unreachable, not unlikely to be used. First, link-time files: there is no
# compiler.
find usr \( -name '*.a' -o -name '*.la' \) -delete
find usr/lib usr/lib64 -maxdepth 1 -name '*.o' -delete 2>/dev/null || true
rm -rf usr/include usr/src
rm -rf usr/lib/pkgconfig usr/lib64/pkgconfig usr/share/pkgconfig
rm -rf usr/share/aclocal usr/share/gtk-doc
# e2fsprogs' compile_et/mk_cmds templates, used to generate C at build time.
rm -rf usr/share/et usr/share/ss

# Documentation: no man, no info.
rm -rf usr/share/man usr/share/doc usr/share/info usr/share/xml

# Translations and locale sources: the image is C-locale only.
rm -rf usr/share/locale usr/share/i18n usr/share/gettext

# glibc's gconv modules, a tenth of the image. UTF-8, ASCII, Latin-1 and UCS are built
# into libc; the modules only serve iconv(1) with an unusual charset. Keep what a text
# file in the wild might be in (Latin, Cyrillic, Greek, Windows and DOS code pages, the
# Unicode transforms); drop CJK, EBCDIC and the obsolete. gconv-modules stays whole, for
# the aliases, so `iconv -l` lists more than it can do.
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

# systemd's translated catalogues; the English systemd.catalog stays.
find usr/lib/systemd/catalog -name 'systemd.*.catalog' -delete 2>/dev/null || true

# Completions (no bash-completion), polkit rules (no polkitd), X11.
rm -rf usr/share/bash-completion usr/share/zsh usr/share/fish etc/bash_completion.d
rm -rf usr/share/polkit-1 usr/share/X11 etc/X11

# D-Bus introspection XML: documentation; a running service answers introspection itself.
rm -rf usr/share/dbus-1/interfaces

# CMake package files: link-time metadata, like pkg-config.
rm -rf usr/lib/cmake

# PAM modules no file in pam.d names (with or without `.so`), and helpers only they use.
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

# NSS modules nsswitch.conf does not name (compat, db, hesiod).
nss_conf=$(grep -v '^[[:space:]]*#' etc/nsswitch.conf)
for module in usr/lib/libnss_*.so.2; do
    [ -e "$module" ] || continue
    name=${module##*/libnss_}
    name=${name%.so.2}
    grep -Eq "[[:space:]]$name([[:space:]]|\$)" <<<"$nss_conf" || rm -f "$module"
done

# terminfo: keep the TERM values that can appear on a serial console or over ssh.
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

# Local additions from extra/ (tools/build-image.sh; absent in CI): after the trim, which
# does not get to decide about them, and before ldconfig. Not in the SBOM.
if [ -d /extra ] && [ -n "$(ls -A /extra)" ]; then
    echo "extra: overlaying $(find /extra -type f | wc -l) file(s) from extra/"
    cp -a /extra/. .
fi

# Last step that touches libraries: ld.so.cache indexes what is there now.
cat > etc/ld.so.conf <<EOF
/usr/lib
/usr/local/lib
/lib64
/usr/lib/$multiarch
EOF
ldconfig -r "$IMAGE" || true

# ---------------------------------------------------------------------------------
# First boot, done here: /etc is read-only on EROFS, and the units that would write it
# are ConditionNeedsUpdate=/etc and skip. A missed step shows as "Read-only file system"
# in the journal, which test/systemd.sh fails on.
#
# With our systemd, through our loader: --library-path outranks its absolute RUNPATH,
# which would resolve inside this container. A binary it cannot open is reported as
# "cannot open shared object file", like a missing library. Disk flavour only.
if [ "$flavour" = erofs ]; then
    ours_ld="$IMAGE/lib64/$ld_so"
    [ -x "$ours_ld" ] || ours_ld="$IMAGE/usr/lib/$ld_so"
    ours() {
        local bin=$1; shift
        "$ours_ld" --library-path "$IMAGE/usr/lib:$IMAGE/usr/lib/systemd" "$IMAGE/usr/bin/$bin" "$@"
    }

    # Every account a sysusers.d snippet asks for, appended to image/files' passwd.
    ours systemd-sysusers --root="$IMAGE"

    # The /etc half of tmpfiles.d; the rest is tmpfs, made at boot.
    ours systemd-tmpfiles --root="$IMAGE" --create --boot --prefix=/etc
    # The mask above has to survive a tmpfiles run whose /dev/null is inside $IMAGE.
    test ! -e etc/profile.d/80-systemd-osc-context.sh

    # Presets: PID 1 applies them on first boot by writing /etc, and that is the only
    # thing enabling networkd and resolved. Missed, the boot is `running` with no network.
    ours systemctl preset-all --root="$IMAGE"
    test -L etc/systemd/system/multi-user.target.wants/systemd-networkd.service

    # / at the 0555 tmpfiles.d/root.conf would otherwise fail to fchmod at every boot.
    chmod 555 "$IMAGE"

    # File capabilities, declared by a package in usr/share/flfs/capabilities/<pkg> as
    # "<path> <caps>" lines, since package tars carry no xattrs. image/build-extension.sh
    # does the same for extensions.
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

    # Empty, for PID 1 to bind-mount a per-boot id over. Not "uninitialized", which asks
    # for it to be persisted.
    : > etc/machine-id
    chmod 444 etc/machine-id

    # /var as a unit, not an fstab line, so a VM can override it: a `systemd.mount-extra=`
    # on the command line makes the fstab generator write a var.mount that outranks this
    # one. Not systemd.volatile=state, whose tmpfs is capped at a quarter of RAM.
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

    # Anything under the mount points would be invisible; tmpfiles makes what is needed.
    find var home root -mindepth 1 -delete
fi

rm -rf usr/share/flfs/capabilities

chown -R root:root etc

chmod 644 etc/passwd etc/group etc/hosts etc/profile etc/nsswitch.conf etc/ld.so.conf

if [ "$flavour" = erofs ]; then
    chmod 755 etc/systemd/system etc/systemd/network etc/pam.d \
              etc/systemd/system/dbus.service.d etc/systemd/journald.conf.d \
              etc/systemd/system-preset
    chmod 644 etc/fstab etc/hostname etc/subuid etc/subgid etc/pam.d/* etc/tmpfiles.d/flfs-home.conf \
              etc/systemd/network/*.network \
              etc/systemd/system/dbus.service.d/*.conf etc/systemd/journald.conf.d/*.conf \
              etc/systemd/system-preset/*.preset
    chmod 600 etc/shadow
fi

du -sh "$IMAGE"

# ---------------------------------------------------------------------------------
# The SBOM, SPDX 2.3, generated from the component records builder/build-package.sh
# leaves rather than scanned (there is no package database). From the assembled tree,
# since the two flavours differ. Hand-written JSON; test/check-sbom.sh parses it.
sbom="$IMAGE/usr/share/flfs/sbom.json"
components="$IMAGE/usr/share/flfs/components"

if [ ! -d "$components" ] || [ -z "$(ls -A "$components" 2>/dev/null)" ]; then
    echo "error: no component records in usr/share/flfs/components" >&2
    echo "       builder/build-package.sh stages one per package; a tree without them" >&2
    echo "       predates that and cannot be described. Delete rootfs/ and rebuild." >&2
    exit 1
fi

created=$(date -u -d "@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y-%m-%dT%H:%M:%SZ)

# JSON string escaping, applied to every value.
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
    # Unique per document, and derived rather than random so it is reproducible.
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
        name= version= license= origin= url= sha256=
        while IFS='=' read -r key value; do
            case "$key" in
                name) name=$value ;; version) version=$value ;; license) license=$value ;;
                origin) origin=$value ;;
                url) url=$value ;; sha256) sha256=$value ;;
            esac
        done < "$record"
        [ -n "$name" ] || continue

        printf ',\n    {\n'
        printf '      "SPDXID": "SPDXRef-Package-%s",\n' "$(spdxid "$name")"
        printf '      "name": "%s",\n' "$(jstr "$name")"
        printf '      "versionInfo": "%s",\n' "$(jstr "$version")"
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

    # The builder image, the one build input env.sh does not describe.
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

    # Libraries a shipped binary needs and the image lacks: DEPENDS_ON without CONTAINS.
    # The same construction as test/check-rootfs-deps.sh, over the assembled tree. A
    # library is a file plus its SONAME symlink, so both count as provided.
    provided=$(
        { find "$IMAGE" -name '*.so*' \( -type f -o -type l \) -print0 2>/dev/null |
          xargs -0 -r -n40 sh -c '
              for f in "$@"; do
                  basename "$f"
                  readelf -d "$f" 2>/dev/null | sed -n "s/.*SONAME.*\[\(.*\)\].*/\1/p"
              done' _ || true; } | sort -u
    )
    # readelf fails on every non-ELF file; the braces let `|| true` cover only it.
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

rm -rf "$components"

cp "$sbom" "/usr/local/output/sbom-$flavour.json"
echo "sbom: $(wc -c < "$sbom") bytes, $(grep -c '"SPDXID"' "$sbom") elements"

# ---------------------------------------------------------------------------------
# The size report test/rootfs-size.sh reads, taken here because this is the only place
# the assembled tree exists. Apparent bytes, so it compares across arches and formats.
report=/usr/local/output/rootfs-size-$flavour.txt
{
    echo "# assembled $flavour image tree, sizes in bytes. Written by image/build-rootfs.sh."
    echo "total $(du -sb "$IMAGE" | cut -f1)"

    # Process substitution, not a pipeline: `sort | head` dies of SIGPIPE under pipefail.
    while read -r bytes path; do
        [ "$path" = "$IMAGE" ] && continue
        [ "$bytes" -ge 65536 ] || continue
        echo "dir $bytes ${path#"$IMAGE"/}"
    done < <(du -b --max-depth=2 "$IMAGE" | sort -rn)

    while read -r bytes path; do
        echo "file $bytes ${path#"$IMAGE"/}"
    done < <(find "$IMAGE" -type f -printf '%s %p\n' | sort -rn | head -n 25)
} > "$report"

if [ "$flavour" = erofs ]; then
    # EROFS: no write path at all, compressed, sized to its contents. On one 160 MiB tree:
    #   -zlz4hc,12                                     95.6 MiB
    #   -zzstd,15  -C131072 -Eztailpacking,fragments   65.9 MiB   this
    #   -zlzma,6   -C131072                            61.4 MiB   ~10x slower to read
    # 128 KiB clusters matter most (the default is one 4 KiB block). Needs
    # CONFIG_EROFS_FS_ZIP_ZSTD (packages/kernel).
    erofs_repro=()
    if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
        erofs_repro=(-T "$SOURCE_DATE_EPOCH" --all-time -U 00000000-0000-0000-0000-000000000000)
    fi
    rm -f /usr/local/output/rootfs.erofs
    # From a tar, so the only xattr is security.capability: from a directory mkfs.erofs
    # records the host's SELinux labels too.
    repro_tar --xattrs --xattrs-include='security.capability' --directory "$IMAGE" . \
        > /tmp/rootfs.tar
    mkfs.erofs -L root -zzstd,15 -C131072 -Eztailpacking,fragments --tar=f "${erofs_repro[@]}" \
        /usr/local/output/rootfs.erofs /tmp/rootfs.tar
    rm -f /tmp/rootfs.tar

    # dm-verity, with the hash tree appended to the same file. No superblock: the kernel
    # is handed every parameter on its command line.
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

    # The command line that boots this image, and the only record of its root hash. The
    # table is `<start> <sectors> verity <version> <data dev> <hash dev> <data block>
    # <hash block> <data blocks> <hash start block> <algo> <root hash> <salt>`. /dev/vda
    # is the VMM's choice, and the one thing a consumer may have to rewrite.
    sectors=$(( data_size / 512 ))
    printf '%s\n' "root=/dev/dm-0 ro rootfstype=erofs dm-mod.waitfor=/dev/vda dm-mod.create=\"root,,,ro,0 $sectors verity 1 /dev/vda /dev/vda 4096 4096 $data_blocks $data_blocks sha256 $root_hash $salt\"" \
        > /usr/local/output/rootfs.cmdline
    cat /usr/local/output/rootfs.cmdline

    echo "disk $(stat -c %s "$erofs")" >> "$report"

    cat "$report"
    exit 0
fi

# ---------------------------------------------------------------------------------
# The OCI archive, by hand: a layer, config and manifest as blobs named by their sha256,
# plus index.json and oci-layout. That is the whole format.
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

# One layer. The manifest names the compressed blob, diff_ids the uncompressed tar.
repro_tar --owner=0 --group=0 --directory "$IMAGE" . > /tmp/layer.tar
diff_id=$(sha256sum /tmp/layer.tar | cut -d' ' -f1)
gzip -9n < /tmp/layer.tar > /tmp/layer.tar.gz
rm -f /tmp/layer.tar
read -r layer_digest layer_size < <(blob /tmp/layer.tar.gz)

# Entrypoint bash, no Cmd: `podman run flfs -c uptime` works. PATH is explicit because
# the runtime's default names directories a merged-/usr image does not have.
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

echo "archive $(stat -c %s /usr/local/output/flfs-oci.tar)" >> "$report"

cat "$report"
