#!/bin/bash
set -euo pipefail

set -x

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
    x86_64)  ld_so=ld-linux-x86-64.so.2  ; multiarch=x86_64-linux-gnu  ;;
    aarch64) ld_so=ld-linux-aarch64.so.1 ; multiarch=aarch64-linux-gnu ;;
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

mkdir -p etc/systemd/system
ln -sf /usr/lib/systemd/system/multi-user.target etc/systemd/system/default.target

# The kernel execs /sbin/init; point it at systemd.
ln -sf /usr/lib/systemd/systemd sbin/init

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
# have could read — libc.so.6 alone is 11 MB unstripped and 2 MB stripped. strip refuses
# to touch anything that is not an ELF object and leaves it alone, which is what makes
# it safe to point at the whole tree; /boot is excluded because the kernel is not one.
find usr -type f -print0 \
    | xargs -0 -r -P "$(nproc)" -n 50 strip --strip-unneeded 2>/dev/null || true

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

chown -R root:root etc

chmod 755 etc/systemd/system etc/systemd/network etc/pam.d \
          etc/systemd/system/dbus.service.d
chmod 644 etc/passwd etc/group etc/fstab etc/os-release \
          etc/nsswitch.conf etc/hostname etc/ld.so.conf etc/pam.d/* \
          etc/systemd/network/*.network \
          etc/systemd/system/dbus.service.d/*.conf
# Password hashes must not be world-readable.
chmod 600 etc/shadow

du -sh "$IMAGE"
/sbin/mkfs.ext4 -L root -d "$IMAGE" /usr/local/output/rootfs.ext4 1G
