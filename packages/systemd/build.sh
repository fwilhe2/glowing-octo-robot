# meson_install supplies --buildtype=release; -Dmode=release is about log and status
# format, not optimization. -Dc_args replaces CFLAGS rather than adding to it, so the
# sysroot flags are passed by hand (SYSROOT_CFLAGS, without the -O2 that would override
# the buildtype). -Wno-error=override-init: systemd promotes that warning specifically,
# and sid's compiler trips it in generated code.
#
# seccomp is what makes SystemCallFilter= in systemd's own units do anything; pam builds
# pam_systemd, which registers logins with logind. The rest is the trim: each component
# off is a binary, its units and its D-Bus policy gone, and one less way to degrade a boot.
systemd_opts=(
    -Dmode=release
    -Dc_args="${SYSROOT_CFLAGS:-} -Wno-error=override-init"

    -Dselinux=disabled -Dseccomp=enabled -Daudit=disabled
    -Dpam=enabled -Dopenssl=disabled -Dlibcryptsetup=disabled

    # No firmware boot path: VMMs are handed the kernel, so no ESP, loader or UKI.
    -Dbootloader=disabled -Defi=false -Dkernel-install=false -Dukify=disabled
    -Dtpm=false -Dtpm2=disabled

    # Hardware a VM does not have, or that only matters on a laptop.
    -Dbacklight=false -Drfkill=false -Dhibernate=false -Dquotacheck=false
    -Dvconsole=false -Dpstore=false -Dbinfmt=false -Dxdg-autostart=false

    # 22 MB describing devices a virtio guest never sees.
    -Dhwdb=false

    # C-locale only.
    -Dlocaled=false -Dtranslations=false

    # systemd's own container and image machinery: crun and podman are the runtime, and
    # podman takes its ID ranges from /etc/subuid.
    -Dmachined=false -Dnspawn=disabled -Dvmspawn=disabled -Dimportd=disabled
    -Dnss-mymachines=disabled -Dportabled=false
    -Dmountfsd=false -Dnsresourced=false

    # How software is added to the immutable image (docs/sysext.md). Verity is set up by
    # the kernel (dm-init), so no libcryptsetup.
    -Dsysext=true

    # Deployment and provisioning. firstboot: the image ships a complete /etc. fdisk:
    # repart, sysupdate and homed were its only callers.
    -Drepart=disabled -Dsysupdate=disabled -Dsysinstall=false -Dfirstboot=false
    -Dimds=disabled -Dhomed=disabled -Dstoragetm=false -Doomd=false
    -Dfdisk=disabled

    # coredump and journal-remote need libraries the image does not ship.
    -Dcoredump=false -Delfutils=disabled -Dremote=disabled

    # Optional libraries the builder has and the image does not, off by name.
    -Dlibcurl=disabled -Dgnutls=disabled -Dmicrohttpd=disabled -Dgcrypt=disabled
    -Dp11kit=disabled -Dlibfido2=disabled -Dqrencode=disabled -Dlibarchive=disabled
    -Dxkbcommon=disabled -Dpcre2=disabled -Dglib=disabled -Dxenctrl=disabled
    -Dpwquality=disabled -Dpasswdqc=disabled
    -Dbzip2=disabled -Dlz4=disabled -Didn=false -Dlibidn2=disabled

    # Access control with no userspace behind it: no polkitd, no SMACK/IMA/IPE/AppArmor.
    -Dpolkit=disabled -Dsmack=false -Dima=false -Dipe=false -Dapparmor=disabled

    -Dtests=false
)

meson_install "${systemd_opts[@]}"
