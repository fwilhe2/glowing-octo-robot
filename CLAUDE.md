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

## Layout

Everything in the root is either an entry point or a directory; nothing else belongs
there.

```
build.sh          the only build entry point — ./build.sh <package>
packages/<pkg>/   env.sh + build.sh per package, and the tree its tarball unpacks into
builder/          how a package is compiled: base + per-package images, and the
                  container entrypoint that sets up the sysroot
image/            how the staging tree becomes a disk: Containerfile, build-rootfs.sh,
                  and files/ — the /etc the image ships
test/             everything CI runs to verify a build, plus known-missing-libs.txt
tools/            local conveniences and maintenance, not part of a build
downloads/        source tarballs (gitignored)
rootfs/           shared, cumulative staging tree every package installs into (gitignored)
output/           built images, fetched CI artifacts, test console logs (gitignored)
```

Paths in scripts are relative to the repository root, and the ones under `test/` and
`tools/` `cd` there themselves, so they work from any directory. `artifacts/` is CI's
scratch directory for downloaded artifacts — it deliberately does not collide with
`packages/` or `image/`.

## Commands

```sh
./build.sh glibc            # must come first — everything else compiles against it
./build.sh <package>        # one package into the shared rootfs/ staging tree
./test/check-rootfs-deps.sh rootfs      # unresolved NEEDED entries
./test/check-symbol-versions.sh rootfs  # symbol versions no shipped library defines
./tools/check-updates.sh [pkg...] # what upstream has released since the pinned VERSION
./test/boot.sh output/rootfs.ext4 rootfs/boot/bzImage   # headless boot smoke test
./test/systemd.sh output/rootfs.ext4 rootfs/boot/bzImage  # no failed units
./test/network.sh output/rootfs.ext4 rootfs/boot/bzImage  # DHCP + DNS + outbound TCP
./test/container.sh output/rootfs.ext4 rootfs/boot/bzImage  # crun starts a container
./tools/boot-qemu.sh              # interactive boot (Ctrl-a x to exit)
```

There is no test suite and no linter — the checks above plus a real boot are the
verification story. Builds are slow (glibc, systemd and the kernel are tens of minutes);
run them in the background rather than blocking on a foreground call.

`build.sh` skips the download when the tarball is already in downloads/ and skips the
extract when `packages/<pkg>/<PACKAGE>/` already exists, so a rebuild after editing only
`packages/<pkg>/build.sh` re-runs just the compile.

`rootfs/` is a *shared, cumulative* staging tree (gitignored) — every package installs
into the same directory and nothing removes stale files, so after a version bump or a
build that partially succeeded, delete `rootfs/` and rebuild from glibc when the tree
stops making sense.

## How a package build works

A package is exactly two files, `packages/<pkg>/env.sh` (version/tarball/apt knobs) and
`packages/<pkg>/build.sh` (configure/compile/install only) — plus an entry in the `build` matrix
in `.github/workflows/ci.yml`. Everything else is shared and should stay that way:

- `builder/base.Containerfile` → `abstract-lfs-builder`, the Debian sid base with a generic toolchain.
- `builder/package.Containerfile` → per-package builder, `apt build-dep $BUILD_DEP` + `$EXTRA_DEPS`.
- `build.sh` (root) → the only driver: download, extract, assemble podman mounts, run.
- `builder/build-package.sh` → container entrypoint: merged-`/usr` staging, sysroot flags,
  then `source /package-build.sh`.

`packages/<pkg>/build.sh` is bind-mounted, not copied into the image, and is *sourced* with the
unpacked source tree as the working directory. Install with `DESTDIR=/usr/local/rootfs`
and `--prefix=/usr`.

Everything is derived from `VERSION` in `env.sh`, and the weekly update workflow bumps
that single line. Never hardcode a version anywhere else.

## The two things that break silently

**1. Compiling against the wrong glibc.** `builder/build-package.sh` exports
`CPPFLAGS`/`CFLAGS`/`CXXFLAGS`/`LDFLAGS` pointing gcc at our staged glibc via
`--sysroot`, with the builder image's own paths appended (`-idirafter`, trailing `-L`) so
non-glibc dependencies still resolve to Debian's. A build system that *replaces* rather
than appends to those variables silently drops the sysroot — see `packages/systemd/build.sh`,
where `-Dc_args` has to carry `$CFLAGS` over by hand. `test/check-symbol-versions.sh` is what
catches this; it is why that script exists.

`glibc` and `kernel` set `NO_SYSROOT=1` (nothing to build against). The builder container
also *runs* on our glibc: root `build.sh` bind-mounts every file the image's `libc6` owns
over with ours, because builds execute what they just compiled.

**2. Linking against a library only the builder image has.** `configure` finds an
optional dev package inside the Debian container, links against it, and the missing `.so`
is only discovered when the binary is exec'd in qemu. Prefer configuring the dependency
out (`--without-selinux`, `-Dx11_autolaunch=disabled`) over adding a package to satisfy it.
`test/check-rootfs-deps.sh` reports all of them at once; `test/known-missing-libs.txt` allowlists
the accepted backlog so new regressions stand out. Run it before booting.

## Image assembly and boot

`image/Containerfile` + `image/build-rootfs.sh` turn `rootfs/` into `output/rootfs.ext4`:
directory skeleton, `image/files/etc` copied in as the shipped `/etc` (hostname `flfs`,
credentials from `image/files/etc/shadow`), `/sbin/init` → systemd, the trim (below),
`ld.so.conf` + `ldconfig`, permission fixups, `mkfs.ext4 -d`. Changes to the shipped `/etc` go
in `image/files/`, not into
`rootfs/` — and `image/files` is `COPY`ed into the builder image rather than bind-mounted, so
editing it means `podman build -f image/Containerfile` again before `podman run`, or the
image is assembled from the old copy.

All of that happens on a *copy* at `/usr/local/image` inside the container, not on the
bind-mounted staging tree. It has to: `rootfs/` is simultaneously the image's input and the
sysroot the next package compiles against, so the headers, `*.a` and `*.pc` files the trim
deletes are still needed there. Nothing in the image build may write to `/usr/local/src`.

The trim is that whole middle section of `build-rootfs.sh` — `strip`, then removing what a
booted system cannot reach: static libraries and `crt*.o`, `usr/include`, pkg-config data,
man/info/doc, `share/locale` and `share/i18n` (the image is C-locale only), all but a dozen
terminfo entries, shell completions, polkit rules. `strip` needs `binutils` in
`image/Containerfile`, ignores non-ELF files, and runs before `ldconfig` so the cache
indexes the final libraries. The bar for adding to that list is that *nothing in the image
can reach the file*, not that it looks unlikely to be used — and the rest of the trim
happens at build time, in `packages/systemd/build.sh` (some fifty components off) and the
`vm.config` fragment in `packages/kernel/build.sh` (defconfig's hardware taken back out).
Because `rootfs/` is cumulative, a component that stops being built stays staged locally
until the tree is deleted; only CI starts clean.

The kernel is a normal package (`packages/kernel/`, `defconfig` + `kvm_guest.config` +
`container.config` + `vm.config`) staged at `rootfs/boot/bzImage`, so a CI run is self-contained. `test/boot.sh` runs `/bin/bash` as
PID 1 by default, not systemd: it isolates "the kernel booted and the loader resolved a
real binary" from everything systemd does on top. `test/systemd.sh`, `test/network.sh` and
`test/container.sh` boot systemd for real (they reach `multi-user.target` and a login
prompt). `test/systemd.sh` is the cheap catch-all: it asserts `systemctl is-system-running`
says `running`, which is `degraded` if and only if some unit failed — the failure mode a
package gets for free by installing a unit whose binary needs a library we don't ship. It also
asserts the `Tainted` property is empty.

The system bus is the reference `dbus-daemon` (`dbus`, which needs `expat`). Anything with
a D-Bus API needs it — systemd-logind exits with *Failed to connect to system bus* and
crash-loops without one — and it enables itself through `.target.wants` symlinks in its own
unit directory, so nothing in `image/files` enables it. Sessions on top of that need
`pam_systemd.so`, which is why systemd is built `-Dpam=enabled` and why
`image/files/etc/pam.d/login` references it.

Networking is systemd end to end: `image/files/etc/systemd/network/20-wired.network` (DHCP on
`en*`/`eth*`), networkd handing the lease to resolved, and `image/files/etc/resolv.conf` as a
symlink into resolved's `/run` stub. The qemu scripts pass `-nic user,model=virtio-net-pci`;
the NIC shows up as `ens3`, so match on the naming scheme rather than a fixed name.
`test/network.sh` is the check — it boots systemd for real and logs in at the serial
getty (`root`/`root`, from `image/files/etc/shadow`). Its in-guest commands are bash builtins,
`networkctl` and `getent` only: there is no `grep`, `sed` or `awk` in the image.

The OCI runtime is `crun` (constraint 3), plus `json-c` for `config.json`. crun is the
only runtime written in C; runc (Go) and youki (Rust) would each mean a second toolchain
in the builder image and binaries that bypass the sysroot machinery, so don't propose
swapping to them. It is built `--disable-seccomp --disable-criu`, so a bundle's seccomp
profile is accepted and ignored rather than enforced — packaging `libseccomp` is what
fixes that (and would let systemd stop being built `-Dseccomp=disabled`). Do **not** add
`--disable-bpf` to that list: on cgroup v2 the device controller is a BPF program, so
crun fails with *eBPF not supported* on any bundle carrying device rules — which the
default `crun spec` output does. eBPF costs nothing here, being a raw syscall plus
`linux/bpf.h` with no library to ship. There is no image tooling: skopeo/umoci/podman
are all Go, so bundles are made by hand with `crun spec`.

The container kernel options are a `container.config` fragment written out by
`packages/kernel/build.sh` as a heredoc and merged with `make container.config` — a *file* next
to `build.sh` would not work, because `build.sh` is the only thing in `packages/kernel/` that is
bind-mounted into the builder. `x86_64_defconfig` has `CGROUPS`, the pid/net/ipc/uts
namespaces and `SECCOMP_FILTER` and nothing else that matters here, so the fragment is
load-bearing: `USER_NS`, `MEMCG` (without it `memory.max` does not exist and any bundle
with a memory limit fails), `OVERLAY_FS`, `VETH`/`BRIDGE`/`TUN`, `BPF_SYSCALL` +
`CGROUP_BPF`, and nftables — which is invisible until `NETFILTER_ADVANCED=y`.

`vm.config` is the same mechanism pointed the other way, and is merged *after*
`container.config` so the subtractions are what olddefconfig sees last — nothing in it may
take back a symbol the container fragment turned on. It clears the hardware
`x86_64_defconfig` assumes and a virtio guest never has: DRM (i915 *and* virtio-gpu — every
qemu invocation here is `-nographic` on `console=ttyS0`), sound, USB, HID, SATA/PATA,
`CONFIG_ETHERNET` (the menu holding every vendor NIC driver; `VIRTIO_NET` lives outside it,
which is what makes that safe), IOMMU, PCMCIA, RAID/device-mapper, NFS/FAT/ISO9660, quotas,
hibernation and cpufreq — plus SELinux and audit, which have no userspace here, and
defconfig's debug options. It also turns `CONFIG_MODULES` off: everything is built in and
`make modules_install` is never run, so a symbol that resolves to `=m` is silently missing
from the image — with modules off, kconfig has to resolve every tristate to `y` or `n`.

systemd's own BPF sandboxing is a separate axis from crun's. crun reaches the cgroup v2
device controller through raw `bpf(2)` and needs no library; systemd loads its compiled-in
programs through **libbpf**, which is why `libbpf` and `elfutils` (for `libelf.so.1`) are
packages. systemd is already built `-Dbpf-framework` enabled — the programs are compiled
by clang inside the builder and embedded as skeletons — so not shipping the library was
enough to disable `IPAddressAllow`/`Deny`, `RestrictNetworkInterfaces` and `SocketBind*`
silently, with one warning at boot.

The LSM half needs four more kernel symbols, all in the fragment: `BPF_JIT` (which
`BPF_LSM` depends on and defconfig leaves off), `BPF_LSM` itself, `SECURITYFS` — systemd
decides whether bpf-lsm is available by reading `/sys/kernel/security/lsm`, so without
securityfs the answer is no however the kernel is built — and `DEBUG_INFO_BTF`, because
an LSM program names the kernel function it hooks and resolving that name needs
`/sys/kernel/btf/vmlinux`. `CONFIG_LSM` already lists `bpf`. The BTF option is the
expensive one: it compiles the kernel with debug info and runs pahole over `vmlinux`.

`tools/fetch-image.sh` / `tools/boot-qemu.sh` are for poking at CI artifacts locally. The `rootfs-dir`
CI artifact is lossy (`upload-artifact` dereferences symlinks); never rebuild a bootable
image from it — `output/rootfs.ext4` is the real output.

## CI

`.github/workflows/ci.yml`: `base` → `glibc` (and `kernel` in parallel) → `build` matrix →
`rootfs` → `boot`. Each package job uses `.github/actions/build-package`, which stages a
glibc-only sysroot via `SYSROOT_DIR=sysroot` so each package artifact contains only its
own files, and caches on a hash that deliberately includes `glibc/env.sh` — a glibc bump
must rebuild everything.
