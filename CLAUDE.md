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
                  (or src/, for the few whose source is ours rather than upstream's)
builder/          how a package is compiled: the one builder image, deps.txt (its
                  entire contents), and the entrypoint that sets up the sysroot
image/            how the staging tree becomes an image, disk or OCI: Containerfile,
                  build-rootfs.sh, and files/ — the /etc the image ships
test/             everything CI runs to verify a build, plus known-missing-libs.txt
tools/            local conveniences and maintenance, not part of a build
docs/             design notes for work not done yet — proposals, not descriptions
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
./test/kernel-caps.sh rootfs            # kernel config vs what a container needs
./tools/check-updates.sh [pkg...] # what upstream has released since the pinned VERSION
./test/boot.sh output/rootfs.ext4 rootfs/boot/bzImage   # headless boot smoke test
./test/systemd.sh output/rootfs.ext4 rootfs/boot/bzImage  # no failed units
./test/network.sh output/rootfs.ext4 rootfs/boot/bzImage  # DHCP + DNS + outbound TCP
./test/container.sh output/rootfs.ext4 rootfs/boot/bzImage  # crun starts a container
./test/oci.sh output/flfs-oci.tar # load and run the container image (no qemu)
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

A package is normally exactly two files, `packages/<pkg>/env.sh` (version, tarball,
checksum) and `packages/<pkg>/build.sh` (configure/compile/install only) — plus an entry in
the `build` matrix in `.github/workflows/ci.yml`. Everything else is shared and should stay
that way:

- `builder/Containerfile` + `builder/deps.txt` → the one builder image every package is
  compiled in. `deps.txt` is its entire contents, one apt package per line; there is no
  `apt build-dep` any more, and an `env.sh` says nothing about dependencies.
- `tools/prep.sh` → the only step that touches the network: pull-or-build the builder and
  sources images (content-hash tags from `tools/image-tags.sh`), then unpack the tarballs.
- `build.sh` (root) → the only driver: prep, extract, assemble podman mounts, run.
- `builder/build-package.sh` → container entrypoint: merged-`/usr` staging, sysroot flags,
  then `source /package-build.sh`.

**The compile runs `--network=none`.** Prep has already fetched every tarball (verified
against the `SHA256` in its `env.sh`) and got the builder image, so a build that reaches
for the internet is a bug — and the container cannot. `docs/build-container.md` is the
design note, including the phase not done yet.

Adding a library to `builder/deps.txt` to make a build work is almost always the wrong
fix: it is exactly how `test/known-missing-libs.txt` got its backlog. The bottom of
`deps.txt` lists what is deliberately absent and why. Configure the dependency out
instead.

`packages/<pkg>/build.sh` is bind-mounted, not copied into the image, and is *sourced* with the
unpacked source tree as the working directory. Install with `DESTDIR=/usr/local/rootfs`
and `--prefix=/usr`.

Everything is derived from `VERSION` in `env.sh`, and the weekly update workflow bumps
that single line. Never hardcode a version anywhere else.

### Packages whose source is in this repository

Not every package has to come from a tarball. `LOCAL_SOURCE=1` in `env.sh` means the
source is tracked in git at `packages/<pkg>/src/`, and the package has no `TARBALL`, `URL`
or `SHA256` at all. `packages/flfsfetch/` is the worked example — a small neofetch-alike
in one C file. Everything downstream of the source is unchanged: the same builder image,
the same sysroot flags, the same `DESTDIR=/usr/local/rootfs`, the same entry in the `build`
matrix, the same artifact.

What the flag changes, in the four places that assume a tarball exists:

| file | behaviour |
| --- | --- |
| `build.sh` | mounts `packages/<pkg>/src` as `/usr/local/src` instead of fetching and extracting |
| `tools/fetch-sources.sh` | nothing to download or verify |
| `tools/prep.sh` | nothing to vendor into the sources image |
| `tools/image-tags.sh` | excluded from the `sources` tag, so bumping one does not invalidate a hash that describes tarballs |
| `tools/check-updates.sh` | no upstream to compare against — `VERSION` is ours and means only what we say |

**The source directory is bind-mounted read-only**, which is the one real constraint. For
every other package `/usr/local/src` is a gitignored tree unpacked from a tarball and a
build may scatter object files through it; here it is the working tree, and a build that
wrote into it would turn a successful build into a dirty checkout. So the package's
`build.sh` has to compile straight to `DESTDIR` — for one C file that is a single `gcc`
invocation with no intermediate `.o` anywhere. Anything needing a real build directory
should use one under `/tmp`, not the source tree.

**The CI cache key has to include the source.** `.github/actions/build-package` hashes
`env.sh` and `build.sh`, which is sufficient for an upstream package because a source
change there means a new `VERSION` and so a new `env.sh`. A local package breaks that
assumption: the source can change with both files untouched, and the cache would then
serve the previous build's binary. The key hashes `$PKG/src` for exactly this reason.

Nothing has to be done to get the binary into the image — `image/build-rootfs.sh` copies
the whole staging tree and the trim removes nothing from `usr/bin`.

### Packages that compile nothing

`packages/iana-etc/` is the worked example: upstream generates `/etc/services` and
`/etc/protocols` from IANA's registries, so the tarball ships both files ready to install
and `build.sh` is two `install` commands with no `configure` or `make` anywhere. Nothing
about the machinery needs telling — the same builder image, the same
`DESTDIR=/usr/local/rootfs`, the same matrix entry.

The one thing it does differently is install outside `--prefix=/usr`. That is not a
liberty: glibc hardcodes these paths (`_PATH_SERVICES` is `"/etc/services"`), which is why
glibc's own install puts `/etc/rpc` there too. It is safe because `image/build-rootfs.sh`
copies the staging tree in *before* it overlays `image/files`, so a name appearing in both
would be won by `image/files` — and neither of these does.

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
credentials from `image/files/etc/shadow` — `root`/`root` and `user`/`user`, the latter
uid 1000 with its home created by `build-rootfs.sh` because nothing in the image would
make one on first login), `/sbin/init` → systemd, the trim (below),
`ld.so.conf` + `ldconfig`, permission fixups, `mkfs.ext4 -d`. Changes to the shipped `/etc` go
in `image/files/`, not into
`rootfs/` — and `image/files` is `COPY`ed into the builder image rather than bind-mounted, so
editing it means `podman build -f image/Containerfile` again before `podman run`, or the
image is assembled from the old copy.

`build-rootfs.sh` takes the output as its argument, `ext4` (the default) or `oci`, and the
same run of the same script produces `output/flfs-oci.tar` for the second. **The container
flavour is written as subtractions from the disk image, in one block**, for the same reason
`vm.config` is written as subtractions from defconfig: two scripts would drift, and the
skeleton, loader path, trim and `ldconfig` are identical either way. What it subtracts is
the kernel and systemd — the two things a container gets from the host and the runtime —
which means systemd's unit tree, udev, its drop-in directories, its PAM and NSS modules,
and every binary whose `NEEDED` names the private `libsystemd-shared` (derived by running
`readelf`, so a version bump that adds another tool needs no edit), plus the `/etc` only a
booted machine reads. `libsystemd.so.0` and `libudev.so.1` **stay**: they are the client
libraries other packages link against, and `dbus-daemon` is one of them. In the three
directories systemd shares with software we might ship later (`/etc/profile.d`, `/etc/ssh`,
`/etc/xdg`) the block deletes dangling symlinks and then the directory only if that emptied
it, rather than removing a future openssh package's config along with systemd's drop-in.

The OCI archive is assembled by hand — a gzipped layer, a config and a manifest as blobs
named after their own sha256, plus `index.json` and `oci-layout` — because that is the
entire format and `tar`/`gzip`/`sha256sum` are already in the container. Do not add buildah
or skopeo to `image/Containerfile` for this. `test/oci.sh` is the check: `podman load`
proves the layout is well formed and running it proves the userspace starts, in a second,
without qemu. It is *not* a substitute for the boot tests — the container runs on the
host's kernel, so nothing about `packages/kernel` is exercised.

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

Two things in the image are *generated* rather than installed, and both are silent when
they are missing. `ldconfig` is the known one. The other is systemd's message catalogue:
`usr/lib/systemd/catalog/*.catalog` is only the source form, and what `journalctl -x`
opens is a compiled `/var/lib/systemd/catalog/database` that nothing was building — every
`MESSAGE_ID` lookup answered *Failed to find catalog entry*. `build-rootfs.sh` runs
`journalctl --root="$IMAGE" --update-catalog`, and it has to be **our** journalctl: the
image container has no systemd, and a Debian one would write a database for a different
version to read. Ours is compiled against our glibc and its RUNPATH is an absolute
`/usr/lib/systemd` that resolves to the *container's* copy, so the invocation calls our
loader by hand with `--library-path "$IMAGE/usr/lib:$IMAGE/usr/lib/systemd"` —
`--library-path` is searched ahead of `DT_RUNPATH`, which is what makes the override
take. The sixteen translated catalogs are trimmed for the same reason as `share/locale`:
a C-locale image can never select one. It runs for the `ext4` flavour only — the
subtractions have taken both the catalog sources and journalctl itself by then — which is
the general rule for **anything added below the subtractions block: it runs against a
tree systemd has been removed from, so it has to say which flavour it is for.** The
failure does not look like one. Invoked explicitly, `ld.so` reports a program it cannot
open with the same *cannot open shared object file* it uses for libraries, so a deleted
`journalctl` reads as a missing library of journalctl's.

Persistent logging is one `mkdir`: journald's `Storage=auto` keeps the journal in `/run`
unless `/var/log/journal` exists, and systemd's tmpfiles snippet for it is `z`, which
adjusts a directory that is already there rather than creating one. Mode and group are
left to tmpfiles at boot — the `systemd-journal` group does not exist yet while the image
is being assembled, and `systemd-sysusers` is ordered before `systemd-tmpfiles-setup`.

The kernel is a normal package (`packages/kernel/`, `defconfig` + `kvm_guest.config` +
`container.config` + `vm.config`) staged at `rootfs/boot/bzImage`, so a CI run is self-contained. `test/boot.sh` runs `/bin/bash` as
PID 1 by default, not systemd: it isolates "the kernel booted and the loader resolved a
real binary" from everything systemd does on top. `test/systemd.sh`, `test/network.sh` and
`test/container.sh` boot systemd for real (they reach `multi-user.target` and a login
prompt). `test/systemd.sh` is the cheap catch-all: it asserts `systemctl is-system-running`
says `running`, which is `degraded` if and only if some unit failed — the failure mode a
package gets for free by installing a unit whose binary needs a library we don't ship. It also
asserts the `Tainted` property is empty.

All three drive a real serial login, and their `await` only matches console output that
arrived *after* the point the caller passes in. That is load-bearing rather than tidy:
matching the whole transcript once made the password get typed into the username prompt,
because systemd (built `-Dmode=release`, so status lines are unit *descriptions* — see
`status-unit-format-default` in its `meson.build`) prints "Query the User Interactively
for a Password" long before login asks for one. The symptom is `Login incorrect` with
perfectly correct credentials, so when a test cannot log in, suspect the handshake before
suspecting `image/files/etc/shadow`.

The system bus is the reference `dbus-daemon` (`dbus`, which needs `expat`). Anything with
a D-Bus API needs it — systemd-logind exits with *Failed to connect to system bus* and
crash-loops without one — and it enables itself through `.target.wants` symlinks in its own
unit directory, so nothing in `image/files` enables it. Sessions on top of that need
`pam_systemd.so`, which is why systemd is built `-Dpam=enabled` and why
`image/files/etc/pam.d/login` references it.

**`image/files/etc/pam.d/other` is `pam_deny`, so a PAM service with no file of its own is
denied rather than defaulted.** That is the right policy and an easy trap: the service
that needs one is not always obvious from the package that installs it. `user@.service`
carries `PAMName=systemd-user`, so a missing `pam.d/systemd-user` fails every login's user
manager and leaves the system `degraded`; util-linux's `su` and `runuser` each want their
own. `other` runs `pam_warn` before `pam_deny` so the next one says which service it was in
the journal instead of failing mutely.

`/etc/profile` exists to source `/etc/profile.d`, not for its own sake — systemd installs
shell drop-ins there and `systemd-tmpfiles` recreates the symlinks at every boot from
`/usr/lib/tmpfiles.d/20-systemd-*.conf`, so deleting one from the image does not stick.
Masking the tmpfiles snippet with a symlink to `/dev/null` is what switches one off, and
`build-rootfs.sh` does that for `80-systemd-osc-context.sh`. Both halves are needed — the
mask stops tmpfiles restoring it, the `rm` removes the copy already staged. The reason is
no longer that it shells out to `sed` on every prompt, which was true before `sed` was a
package; it is that the drop-in wraps every prompt in OSC 3008 sequences, and the serial
console is not a terminal here but the input `test/systemd.sh`, `test/network.sh` and
`test/container.sh` parse. Unmasking it is a change to what those tests read, so it wants
its own commit rather than a ride inside another one.

`nsswitch.conf` may only name modules that are actually in the image as
`libnss_<name>.so.2`; a name with no module silently loses that source. glibc installs
`files`/`dns`, systemd installs `systemd`/`myhostname`/`resolve`. `hosts` uses
`resolve [!UNAVAIL=return] files myhostname dns`, where the `[!UNAVAIL=return]` is
load-bearing: a NOTFOUND from resolved is final, but resolved not running has to fall
through to `/etc/hosts`. `services` and `protocols` name `files` and nothing else, which
is the whole answer now that `iana-etc` ships both; `ethers` and `networks` name a file
neither glibc nor any package installs, and nothing in the image asks them.

Networking is systemd end to end: `image/files/etc/systemd/network/20-wired.network` (DHCP on
`en*`/`eth*`), networkd handing the lease to resolved, and `image/files/etc/resolv.conf` as a
symlink into resolved's `/run` stub. The qemu scripts pass `-nic user,model=virtio-net-pci`;
the NIC shows up as `ens3`, so match on the naming scheme rather than a fixed name.
`test/network.sh` is the check — it boots systemd for real and logs in at the serial
getty (`root`/`root`, from `image/files/etc/shadow`). Its in-guest commands are bash builtins,
`networkctl` and `getent` only. That was forced when the image had no `grep`, `sed` or
`awk`; those are packages now, but the tests still stick to builtins so a failure in the
handshake means what it says.

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
Note what that costs on arm64: kconfig resolves an explicitly-set `=m` to `y`, not `n`,
and arm64's defconfig is far more modular than `x86_64_defconfig`, so turning modules off
builds most of a distro kernel *in*. That is why `vm.config` has to name subtractions
(media, wireless, MTD/MMC/SPI/regulator, Bluetooth, CAN) that amd64 never needed.

The largest of those by far is arm64's SoC platform support. `arch/arm64/Kconfig.platforms`
is a multi-platform config — 48 `ARCH_<vendor>` symbols, each pulling in that SoC's
pinctrl, clocks, PHYs, regulators, MMC, SPI and RTC — and clearing all of them removes
**1594 built-in symbols**, 43% of the arm64 kernel. Nothing is lost: qemu's `virt` board
has no `ARCH_*` symbol of its own because it is described entirely by the device tree qemu
passes in and driven by generic drivers (GICv3, the PL011 UART, the architected timer,
PSCI, virtio). The arm64 kernel still has ~40% more built in than amd64's; the rest is
crypto implementations and generic subsystems, and trimming further has a worse
risk-to-reward ratio than what is already gone. **`SERIAL_8250` must never be added to
`vm.config`** however tempting it looks on arm64 — the fragment is shared, and it is
amd64's console.

systemd's own BPF sandboxing is a separate axis from crun's. crun reaches the cgroup v2
device controller through raw `bpf(2)` and needs no library; systemd loads its compiled-in
programs through **libbpf**, which is why `libbpf` and `elfutils` (for `libelf.so.1`) are
packages. systemd is already built `-Dbpf-framework` enabled — the programs are compiled
by clang inside the builder and embedded as skeletons — so not shipping the library was
enough to disable `IPAddressAllow`/`Deny`, `RestrictNetworkInterfaces` and `SocketBind*`
silently, with one warning at boot.

The LSM half needs more kernel symbols, all in the fragment: `BPF_JIT` (which `BPF_LSM`
depends on and defconfig leaves off), `FTRACE` (`BPF_LSM` also depends on `BPF_EVENTS`,
which is not a knob — it is `default y` behind the probe event types, and those live
inside the FTRACE menu, which `x86_64_defconfig` leaves on and arm64's defconfig
explicitly switches off), `BPF_LSM` itself, `SECURITYFS` — systemd decides whether
bpf-lsm is available by reading `/sys/kernel/security/lsm`, so without securityfs the
answer is no however the kernel is built — and `DEBUG_INFO_BTF`, because an LSM program
names the kernel function it hooks and resolving that name needs
`/sys/kernel/btf/vmlinux`. `CONFIG_LSM` already lists `bpf`. The BTF option is the
expensive one: it compiles the kernel with debug info and runs pahole over `vmlinux`. It
also cannot be asked for on its own — it lives inside `if DEBUG_INFO`, and `DEBUG_INFO`
is itself only ever *selected*, by the "Debug information" choice that `x86_64_defconfig`
leaves at None and arm64's defconfig sets to REDUCED, so the fragment has to settle that
choice (`DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT`, `# DEBUG_INFO_REDUCED is not set`) before
the BTF line means anything.

**A fragment line that cannot be applied is dropped in silence, so `build.sh` checks.**
`merge_config.sh` only verifies its own work when it is the thing that runs the config
command; `make <name>.config` passes it `-m` and re-runs `olddefconfig` as a separate
step, and a symbol whose dependencies are unmet disappears between the two without a
word. Every silent kernel-config failure this repo has had went that way — `BPF_LSM`
asked for with no `BPF_EVENTS` under it, `DEBUG_INFO_BTF` asked for inside an `if
DEBUG_INFO` that was off, `WIRELESS`/`FAT_FS`/`CPU_FREQ`/`I2C` cleared and immediately
`select`ed back by `WLAN`/`VFAT_FS`/`SCHED_MC_PRIO`/`MEDIA_SUBDRV_AUTOSELECT`. The check
after `make vm.config` fails the build instead: everything `container.config` turns on
has to be `=y`, and nothing either fragment clears may come back `=y`. `vm.config` is
still allowed to name symbols that do not exist on this architecture — that is how the
x86-only lines behave on arm64 — it just may not name one that exists and stayed on.
When adding to `vm.config`, expect to clear the symbol that *selects* the one you want
gone, not only the one you want gone.

`tools/fetch-image.sh` / `tools/boot-qemu.sh` are for poking at CI artifacts locally. The `rootfs-dir`
CI artifact is lossy (`upload-artifact` dereferences symlinks); never rebuild a bootable
image from it — `output/rootfs.ext4` is the real output.

## CI

`.github/workflows/ci.yml`: `base` → `glibc` (and `kernel` in parallel) → `build` matrix →
`rootfs` → `boot`. Each package job uses `.github/actions/build-package`, which stages a
glibc-only sysroot via `SYSROOT_DIR=sysroot` so each package artifact contains only its
own files, and caches on a hash that deliberately includes `glibc/env.sh` — a glibc bump
must rebuild everything.
