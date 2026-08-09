# -Dc_args=-Wno-error=override-init: systemd promotes -Werror=override-init specifically,
# which a blanket -Wno-error does NOT cancel; the errno aliases in the generated
# errno-to-name.inc trip it on this bleeding-edge sid toolchain.
# The disabled features drop optional runtime libs we don't ship (libselinux, libseccomp,
# libaudit, libcrypto); libcap, libpam and libcrypt(libxcrypt) are built as packages.
#
# -Dpam=enabled builds pam_systemd, which is what registers a login as a session with
# systemd-logind — without it logind runs but never sees a seat used, so `loginctl
# list-sessions` stays empty. It is referenced from _files/etc/pam.d/login.
# -Dlibdir=lib: meson defaults libdir to the Debian multiarch path
# (lib/x86_64-linux-gnu) on this builder, which the rest of the system doesn't search.
#
# -Dc_args replaces the CFLAGS environment variable rather than adding to it, so the
# sysroot flags lib/build-package.sh exports have to be carried over by hand or systemd
# would be the one package still compiled against the builder's glibc.
#
# The groups after that are the trim. systemd builds close to ninety components by
# default and a headless VM that runs containers needs a fraction of them: what is
# turned off below is either hardware we do not have, an install/deployment mechanism
# we do not use, or a daemon with no consumer in this image. Each one dropped is a
# binary, its units and its dbus policy gone — and one less thing that can leave a boot
# `degraded`.
# --buildtype=release: meson's default is `debug`, which is -O0. -Dmode=release below is
# a systemd option about logging and status format and does not touch it. See "the three
# things that break silently" in CLAUDE.md — this is by far the worst-affected package.
systemd_opts=(
    --prefix /usr
    --buildtype=release
    -Dlibdir=lib
    -Dmode=release
    -Dc_args="${CFLAGS:-} -Wno-error=override-init"

    -Dselinux=disabled -Dseccomp=disabled -Daudit=disabled
    -Dpam=enabled -Dopenssl=disabled -Dlibcryptsetup=disabled

    # No firmware boot path: qemu is handed the kernel with -kernel, so there is no ESP
    # to install a loader into and nothing to build a UKI for. Takes systemd-boot,
    # bootctl, ukify, kernel-install and the whole EFI half of the tree with it.
    -Dbootloader=disabled -Defi=false -Dkernel-install=false -Dukify=disabled
    -Dtpm=false -Dtpm2=disabled

    # Hardware that does not exist in a VM, or that only matters on a laptop: screen
    # backlight, radio kill switches, suspend-to-disk, disk quotas, the virtual console
    # (the console here is ttyS0), pstore crash dumps and binfmt_misc.
    -Dbacklight=false -Drfkill=false -Dhibernate=false -Dquotacheck=false
    -Dvconsole=false -Dpstore=false -Dbinfmt=false -Dxdg-autostart=false

    # The hardware database is 22 MB of PCI/USB/OUI vendor names and input-device
    # quirks, all of it describing devices a virtio guest never sees. udev's hwdb
    # builtin stays compiled in and simply finds no database, which it logs at debug.
    -Dhwdb=false

    # No locale data is shipped (see image/build-rootfs.sh), so localed would have
    # nothing to switch between and systemd's own translations nothing to translate.
    -Dlocaled=false -Dtranslations=false

    # Container and image machinery we do not use: crun is the runtime (constraint 3),
    # and there is no image tooling to feed nspawn/machined/importd a machine image.
    # nss-mymachines resolves container hostnames through machined, so it goes too.
    -Dmachined=false -Dnspawn=disabled -Dvmspawn=disabled -Dimportd=disabled
    -Dnss-mymachines=disabled -Dportabled=false -Dsysext=false

    # Deployment and provisioning: repartitioning the disk, A/B image updates, cloud
    # instance metadata, home-directory management, exporting block devices over NVMe.
    # firstboot goes with them — the image ships a complete /etc, which is why the
    # service used to be masked in image/build-rootfs.sh.
    -Drepart=disabled -Dsysupdate=disabled -Dsysinstall=false -Dfirstboot=false
    -Dimds=disabled -Dhomed=disabled -Dstoragetm=false -Doomd=false

    # Coredump handling needs elfutils to symbolize a backtrace, and the journal's
    # remote transports need libcurl/gnutls/microhttpd. We ship none of those to the
    # image (elfutils is packaged for libelf, which libbpf links against).
    -Dcoredump=false -Delfutils=disabled -Dremote=disabled

    # Optional dependencies the Debian builder image happens to have installed.
    # Autodetection would link against them and the missing .so would only turn up when
    # the binary is exec'd in qemu, so they are turned off by name rather than by luck.
    -Dlibcurl=disabled -Dgnutls=disabled -Dmicrohttpd=disabled -Dgcrypt=disabled
    -Dp11kit=disabled -Dlibfido2=disabled -Dqrencode=disabled -Dlibarchive=disabled
    -Dxkbcommon=disabled -Dpcre2=disabled -Dglib=disabled -Dxenctrl=disabled
    -Dlibiptc=disabled -Dpwquality=disabled -Dpasswdqc=disabled
    -Dbzip2=disabled -Dlz4=disabled -Didn=false -Dlibidn2=disabled

    # Access control with no userspace behind it: no polkitd, no SMACK/IMA/IPE/AppArmor.
    -Dpolkit=disabled -Dsmack=false -Dima=false -Dipe=false -Dapparmor=disabled

    -Dtests=false
)

meson setup "${systemd_opts[@]}" build
meson compile -C build
meson install -C build --destdir /usr/local/rootfs
