#!/bin/bash
# Turn a directory tree into a system or configuration extension image for this image
# (docs/sysext.md). Runs in the image-assembly container, like build-rootfs.sh, so that
# an extension is laid out by the same mkfs.erofs with the same reproducibility flags as
# the root it is merged over:
#
#     build-extension.sh sysext <name>    /usr/local/src → /usr/local/output/extensions/<name>.raw
#     build-extension.sh confext <name>   /usr/local/src → /usr/local/output/confexts/<name>.raw
#
# The output directories are named after where the images go in a guest,
# /var/lib/extensions and /var/lib/confexts, and the file name is the extension's name:
# systemd-sysext only merges an image whose extension-release.<name> matches its file
# name. Nothing in /usr/local/src is written to.
#
# The extension-release file is written here, not taken from the tree, because what it
# says is a promise about this image and not about the extension:
#
#   ID=flfs                      only this OS merges it
#   SYSEXT_LEVEL= / CONFEXT_LEVEL=  the level image/files/etc/os-release declares, which
#                                is the ABI an extension built today may rely on. LEVEL
#                                overrides it, which only a test refusing a wrong one wants.
#   ARCHITECTURE=                sysexts only: they carry binaries, so one built here only
#                                runs on this architecture. A confext is text.
#   EXTENSION_RELOAD_MANAGER=1   the merge reloads PID 1, so the units an extension ships
#                                exist as soon as it is merged — at boot that is during
#                                sysinit, and an Upholds= drop-in is what starts them.
#
# Not verity-protected: systemd sets that up through libcryptsetup, which the image does
# not have yet (#191).
set -euo pipefail

class="${1:?usage: build-extension.sh sysext|confext <name>}"
name="${2:?usage: build-extension.sh sysext|confext <name>}"
src=/usr/local/src

case "$class" in
    sysext)  release=usr/lib/extension-release.d key=SYSEXT_LEVEL  out=extensions allowed='usr opt' ;;
    confext) release=etc/extension-release.d     key=CONFEXT_LEVEL out=confexts   allowed='etc' ;;
    *) echo "error: class '$class' (expected sysext or confext)" >&2; exit 2 ;;
esac
[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "error: '$name' is not a usable extension name" >&2; exit 2; }

# A sysext merges /usr and /opt and nothing else; anything beside them would be silently
# ignored in the guest, which is worse than refusing it here.
for top in "$src"/* "$src"/.[!.]*; do
    [ -e "$top" ] || continue
    [[ " $allowed " == *" $(basename "$top") "* ]] || {
        echo "error: a $class carries only $allowed, not /$(basename "$top")" >&2; exit 1; }
done

level="${LEVEL:-$(sed -n "s/^$key=//p" /files/etc/os-release)}"
[ -n "$level" ] || { echo "error: image/files/etc/os-release declares no $key" >&2; exit 1; }

tree=/tmp/extension
rm -rf "$tree"
cp -a "$src" "$tree"
mkdir -p "$tree/$release"
{
    echo "ID=flfs"
    echo "$key=$level"
    if [ "$class" = sysext ]; then
        case "$(uname -m)" in
            x86_64)  echo "ARCHITECTURE=x86-64" ;;
            aarch64) echo "ARCHITECTURE=arm64" ;;
        esac
    fi
    echo "EXTENSION_RELOAD_MANAGER=1"
} > "$tree/$release/extension-release.$name"

# The same construction as the root image (build-rootfs.sh): from a tar stream, so that
# no xattr the host put on the files — an SELinux label above all — reaches the image,
# with every owner root and every time clamped.
erofs_repro=()
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
    erofs_repro=(-T "$SOURCE_DATE_EPOCH" --all-time -U 00000000-0000-0000-0000-000000000000)
fi
mkdir -p "/usr/local/output/$out"
tar --create --format=pax --sort=name --numeric-owner --owner=0 --group=0 \
    --mtime="@${SOURCE_DATE_EPOCH:-$(date +%s)}" --clamp-mtime \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    --directory "$tree" . > /tmp/extension.tar
rm -f "/usr/local/output/$out/$name.raw"
mkfs.erofs --quiet -zzstd,15 -C131072 -Eztailpacking,fragments --tar=f "${erofs_repro[@]}" \
    "/usr/local/output/$out/$name.raw" /tmp/extension.tar
rm -rf "$tree" /tmp/extension.tar
echo "$out/$name.raw: $class, $key=$level"
