# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

An experimental Linux From Scratch build targeting qemu: source tarballs in, a bootable
`output/rootfs.ext4` out. `README.md` is the user-facing documentation; this file covers
what is easy to get wrong when changing things.

## Project constraints

These are fixed decisions, not preferences. Do not propose or implement changes that
violate them, even when a request asks for simplification — if a simplification would
require breaking one, say so and offer an alternative that keeps it.

1. **The stack is systemd + glibc + GNU coreutils.** Never swap in musl, busybox,
   toybox, dinit/OpenRC/runit/s6, or any other substitute, and never drop a component to
   make something build or boot. If I ask for a simplification that implies dropping part
   of this stack, treat it as out of scope and push back.
2. **Virtual machines are the only target.** qemu today, rust-vmm/Firecracker-style VMMs
   next; real hardware is explicitly a non-goal. Kernel config, drivers and firmware
   should be trimmed to what a VM needs — do not add hardware support "just in case".
3. **It must be able to run containers.** Kernel features (namespaces, cgroup v2, overlayfs,
   netfilter/nftables, veth) and the userspace to go with them are in scope and must not be
   configured away.
4. **Networking has to work end to end.** A booted image needs working interfaces,
   addressing (systemd-networkd/systemd-resolved), DNS and outbound connectivity — not just
   a kernel that has the drivers.

## Commands

```sh
./build.sh glibc            # must come first — everything else compiles against it
./build.sh <package>        # one package into the shared rootfs/ staging tree
./check-rootfs-deps.sh rootfs      # unresolved NEEDED entries
./check-symbol-versions.sh rootfs  # symbol versions no shipped library defines
./check-updates.sh [pkg...] # what upstream has released since the pinned VERSION
./boot-test.sh output/rootfs.ext4 rootfs/boot/bzImage   # headless boot smoke test
./network-test.sh output/rootfs.ext4 rootfs/boot/bzImage  # DHCP + DNS + outbound TCP
./boot-qemu.sh              # interactive boot (Ctrl-a x to exit)
```

There is no test suite and no linter — the checks above plus a real boot are the
verification story. Builds are slow (glibc, systemd and the kernel are tens of minutes);
run them in the background rather than blocking on a foreground call.

`build.sh` skips the download when the tarball is already in the repo root and skips the
extract when `<pkg>/<PACKAGE>/` already exists, so a rebuild after editing only
`<pkg>/build.sh` re-runs just the compile.

`rootfs/` is a *shared, cumulative* staging tree (gitignored) — every package installs
into the same directory and nothing removes stale files, so after a version bump or a
build that partially succeeded, delete `rootfs/` and rebuild from glibc when the tree
stops making sense.

## How a package build works

A package is exactly two files, `<pkg>/env.sh` (version/tarball/apt knobs) and
`<pkg>/build.sh` (configure/compile/install only) — plus an entry in the `build` matrix
in `.github/workflows/ci.yml`. Everything else is shared and should stay that way:

- `Containerfile` → `abstract-lfs-builder`, the Debian sid base with a generic toolchain.
- `package.Containerfile` → per-package builder, `apt build-dep $BUILD_DEP` + `$EXTRA_DEPS`.
- `build.sh` (root) → the only driver: download, extract, assemble podman mounts, run.
- `lib/build-package.sh` → container entrypoint: merged-`/usr` staging, sysroot flags,
  then `source /package-build.sh`.

`<pkg>/build.sh` is bind-mounted, not copied into the image, and is *sourced* with the
unpacked source tree as the working directory. Install with `DESTDIR=/usr/local/rootfs`
and `--prefix=/usr`.

Everything is derived from `VERSION` in `env.sh`, and the weekly update workflow bumps
that single line. Never hardcode a version anywhere else.

## The two things that break silently

**1. Compiling against the wrong glibc.** `lib/build-package.sh` exports
`CPPFLAGS`/`CFLAGS`/`CXXFLAGS`/`LDFLAGS` pointing gcc at our staged glibc via
`--sysroot`, with the builder image's own paths appended (`-idirafter`, trailing `-L`) so
non-glibc dependencies still resolve to Debian's. A build system that *replaces* rather
than appends to those variables silently drops the sysroot — see `systemd/build.sh`,
where `-Dc_args` has to carry `$CFLAGS` over by hand. `check-symbol-versions.sh` is what
catches this; it is why that script exists.

`glibc` and `kernel` set `NO_SYSROOT=1` (nothing to build against). The builder container
also *runs* on our glibc: root `build.sh` bind-mounts every file the image's `libc6` owns
over with ours, because builds execute what they just compiled.

**2. Linking against a library only the builder image has.** `configure` finds an
optional dev package inside the Debian container, links against it, and the missing `.so`
is only discovered when the binary is exec'd in qemu. Prefer configuring the dependency
out (`--without-selinux`, `-Dx11_autolaunch=disabled`) over adding a package to satisfy it.
`check-rootfs-deps.sh` reports all of them at once; `known-missing-libs.txt` allowlists
the accepted backlog so new regressions stand out. Run it before booting.

## Image assembly and boot

`rootfs.Containerfile` + `build-rootfs.sh` turn `rootfs/` into `output/rootfs.ext4`:
directory skeleton, `_files/etc` copied in as the shipped `/etc` (hostname `flfs`,
credentials from `_files/etc/shadow`), `/sbin/init` → systemd, `ld.so.conf` + `ldconfig`,
permission fixups, `mkfs.ext4 -d`. Changes to the shipped `/etc` go in `_files/`, not into
`rootfs/` — and `_files` is `COPY`ed into the builder image rather than bind-mounted, so
editing it means `podman build -f rootfs.Containerfile` again before `podman run`, or the
image is assembled from the old copy.

The kernel is a normal package (`kernel/`, `defconfig` + `kvm_guest.config`) staged at
`rootfs/boot/bzImage`, so a CI run is self-contained. `boot-test.sh` runs `/bin/bash` as
PID 1 by default, not systemd: it isolates "the kernel booted and the loader resolved a
real binary" from everything systemd does on top. `network-test.sh` is the one that boots
systemd for real (it reaches `multi-user.target` and a login prompt).

The system bus is the reference `dbus-daemon` (`dbus`, which needs `expat`). Anything with
a D-Bus API needs it — systemd-logind exits with *Failed to connect to system bus* and
crash-loops without one — and it enables itself through `.target.wants` symlinks in its own
unit directory, so nothing in `_files` enables it. Sessions on top of that need
`pam_systemd.so`, which is why systemd is built `-Dpam=enabled` and why
`_files/etc/pam.d/login` references it.

Networking is systemd end to end: `_files/etc/systemd/network/20-wired.network` (DHCP on
`en*`/`eth*`), networkd handing the lease to resolved, and `_files/etc/resolv.conf` as a
symlink into resolved's `/run` stub. The qemu scripts pass `-nic user,model=virtio-net-pci`;
the NIC shows up as `ens3`, so match on the naming scheme rather than a fixed name.
`network-test.sh` is the check — it boots systemd for real and logs in at the serial
getty (`root`/`root`, from `_files/etc/shadow`). Its in-guest commands are bash builtins,
`networkctl` and `getent` only: there is no `grep`, `sed` or `awk` in the image.

`fetch-image.sh` / `boot-qemu.sh` are for poking at CI artifacts locally. The `rootfs-dir`
CI artifact is lossy (`upload-artifact` dereferences symlinks); never rebuild a bootable
image from it — `output/rootfs.ext4` is the real output.

## CI

`.github/workflows/ci.yml`: `base` → `glibc` (and `kernel` in parallel) → `build` matrix →
`rootfs` → `boot`. Each package job uses `.github/actions/build-package`, which stages a
glibc-only sysroot via `SYSROOT_DIR=sysroot` so each package artifact contains only its
own files, and caches on a hash that deliberately includes `glibc/env.sh` — a glibc bump
must rebuild everything.
