# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A **pragmatic, automated Linux From Scratch**: source tarballs in, a bootable
`output/rootfs.ext4` and a container image out. `README.md` is the user-facing
documentation; this file covers what is easy to get wrong when changing things.

## What this is, and what it is not

The goal is a **minimal but genuinely useful general-purpose Linux stack**, built from
source, automatically, and kept current. Minimal is a means here, not the point: the
image should be small because nothing unnecessary was added, not because something useful
was removed.

**Pragmatic** is the load-bearing word, and it separates this from LFS proper:

- **No self-hosted toolchain.** Real LFS bootstraps gcc and binutils through several
  passes to escape the host. That is a step too far for what this is for. The Debian
  builder image is the toolchain, deliberately and permanently — it is a solid, current,
  well-maintained choice, and *not* a stepping stone to something else. The one place
  the host is escaped is glibc, because a version skew there silently produces binaries
  that cannot start; everything else links against Debian's and that is fine.
- **Modern and established, both.** Every technology choice should be one a competent
  engineer would defend in 2026 — neither the crusty option that a decade of inertia
  chose, nor whatever appeared on GitHub last month. This is not an exercise in
  recreating Debian oldstable, and it is not a place to chase novelty.
- **Useful, not merely bootable.** An eventual target is running as a node in a
  Kubernetes cluster, but that is *an* aim, not *the* aim — the image should be a
  reasonable general-purpose Linux, and features are judged on whether they serve that.

## Project constraints

These are fixed decisions, not preferences. Do not propose or implement changes that
violate them, even when a request asks for simplification — if a simplification would
require breaking one, say so and offer an alternative that keeps it.

1. **The stack is systemd + glibc + GNU coreutils + bash.** Never swap in musl, busybox,
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
   a kernel that has the drivers. And it has to be *usable* from inside the guest, which
   is a separate claim and was false for a long time: `ip`, `ping` and `curl` (with TLS
   and a trust store behind it) are what make the difference between a machine that has a
   network and one somebody can debug.
5. **No new interpreters in the image.** `bash` is the one it has, and that is the budget.
   A package that would put perl, python, lua or a JavaScript runtime into `rootfs/`
   needs an argument that it is unavoidable, not merely convenient — and "we could write
   this bit in python" is never that argument. What the *builder* needs is unconstrained:
   perl is already in `builder/deps.txt`, and a package whose `configure` is perl or
   python is fine. The rule is about what ships. Watch `make install`, which is where an
   interpreted helper script sneaks into `DESTDIR` — iproute2's `routel` is python and
   OpenSSL's `c_rehash`/`CA.pl`/`tsget` are perl. Each package's `build.sh` deletes its
   own. `#!/bin/sh` is *not* one of these cases: `packages/bash/build.sh` links
   `/usr/bin/sh` at bash, so a shell script runs here. A wrapper is still deleted when
   what it wraps is missing — curl's `curl-config` describes headers the trim removes —
   but that is a judgement about the wrapper, not about the shebang.
6. **Every package is DFSG-free, and says so.** `LICENSE=` in `env.sh`, as an SPDX
   expression, checked by `test/check-licenses.sh` against `test/dfsg-licenses.txt` in its
   own workflow. Debian's guidelines are the bar because Debian has already argued every
   one of these to a conclusion. A license that only exists in `non-free` means the
   package does not belong here, however good it is.

## Adding a package: the questions to ask first

Packaging is the easy part. Choosing is where the mistakes are, so before writing an
`env.sh`, answer these — in the pull request, where they can be disagreed with:

- **Is it still maintained, or is it just old?** A last release in 2011 is a red flag, not
  a sign of stability. Check what the distributions actually ship today.
- **Is it established?** Something Debian, Fedora and Alpine all ship has been through
  more scrutiny than this project can apply. A GitHub project with forty stars and one
  contributor has not, whatever its README claims.
- **Is there a more modern option that is equally established?** Both halves matter. The
  default answer to "what does everyone use" is often right and sometimes a decade stale;
  the answer to "what is newest" is almost always wrong.
- **What does it drag in?** A dependency is a decision about the image, not an
  implementation detail — see `test/known-missing-libs.txt` for what happens when that
  goes unasked. Size is a real cost too, and `test/size-budget.txt` will say so.
- **Does it need an interpreter at runtime?** See constraint 5. This is the one that most
  often disqualifies an otherwise reasonable choice.

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
                  and size-budget.txt
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
./test/check-licenses.sh                # every package declares a DFSG-free license
./tools/check-updates.sh [pkg...] # what upstream has released since the pinned VERSION
./test/boot.sh output/rootfs.ext4 rootfs/boot/bzImage   # headless boot smoke test
./test/systemd.sh output/rootfs.ext4 rootfs/boot/bzImage  # no failed units
./test/network.sh output/rootfs.ext4 rootfs/boot/bzImage  # DHCP + DNS + outbound TCP
./test/container.sh output/rootfs.ext4 rootfs/boot/bzImage  # crun starts a container
./test/oci.sh output/flfs-oci.tar # load and run the container image (no qemu)
./test/rootfs-size.sh [ext4|oci]  # image size vs test/size-budget.txt, and where it went
./tools/boot-qemu.sh              # interactive boot (Ctrl-a x to exit)
```

There is no test suite and no linter — the checks above plus a real boot are the
verification story. Builds are slow (glibc, systemd and the kernel are tens of minutes);
run them in the background rather than blocking on a foreground call.

`build.sh` skips the download when the tarball is already in downloads/ and skips the
extract when `packages/<pkg>/<PACKAGE>/` already exists, so a rebuild after editing only
`packages/<pkg>/build.sh` re-runs just the compile. The extraction is
`--strip-components=1` into a directory `build.sh` names, rather than into whatever
directory the tarball happens to contain: `$PACKAGE` is derived from `$VERSION`, so the
unpacked tree is versioned even when upstream's is not. Debian's `ca-certificates` unpacks
to a bare `ca-certificates/`, and without this a version bump would find the previous
snapshot already sitting there and quietly skip the extraction.

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

That rule is about *libraries a package links against*, and it is worth being clear about
what it is not: **a build-time interpreter is fine, an interpreter in the shipped image is
not.** The builder image's size is not a consideration — perl is already in `deps.txt`
because glibc and the kernel need it, and a package whose `configure` is perl or python is
admissible on those grounds alone. What the image must never gain is a perl or python
*script*; today it has none, not even glibc's `mtrace`, which lands here as the POSIX-shell
variant, and `bash` is the only interpreter it ships. So the thing to check when packaging
something like OpenSSL is not what built it but what its `make install` leaves in
`DESTDIR` — helper scripts land there and ship as dead files unless `build.sh` or the trim
removes them.

`packages/<pkg>/build.sh` is bind-mounted, not copied into the image, and is *sourced* with the
unpacked source tree as the working directory. Install with `DESTDIR=/usr/local/rootfs`
and `--prefix=/usr`.

`PACKAGE`, `TARBALL` and `URL` are all derived from `VERSION` in `env.sh`. Never hardcode
a version anywhere else.

**`SHA256` is the exception, and it is a sharp one.** It cannot be derived — it is a hash
of bytes that exist only upstream — so a version bump is *two* lines, and
`tools/bump-version.sh <pkg> <version>` is what writes both: it rewrites `VERSION`, fetches
the tarball the new `URL` names, pins what it actually received, and reads the result back
through `fetch-sources.sh` to prove the pin describes the file. Use it rather than editing
`VERSION` by hand.

A bump that changes `VERSION` alone leaves the previous release's checksum in place and
`fetch-sources.sh` refuses the new tarball — correctly, since a name and a hash that
disagree is exactly what it exists to catch. The failure is in the `sources` job, before
anything is built, and it reads as *CHECKSUM MISMATCH* rather than as anything about the
version. `.github/workflows/update-packages.yml` opened one such pull request per package
before it was taught to call the script; the checksum only became part of `env.sh` when the
vendored sources image arrived, which is why the workflow's one-line `sed` was right when
it was written and silently wrong afterwards.

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

## The three things that break silently

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

**3. A meson package with no `--buildtype`.** Autotools packages get `-g -O2` from
`configure`'s own default, so nothing has to say so; **meson's default buildtype is
`debug`, which is `-O0`**, and it says nothing about it. The result compiles, links,
passes every check here and boots — it is simply two to thirteen times the code it should
be. Every `meson setup` in `packages/` therefore passes `--buildtype=release`
explicitly. systemd's `-Dmode=release` is *not* that: it is a systemd option about
logging and status-line format (see the `status-unit-format-default` note in the image
section) and has nothing to do with the optimizer, which is what made this easy to miss
for as long as it was.

The blast radius is mostly systemd, because it is the only large one: comparing the
published `flfs` container image against `debian:bookworm-slim`, `libudev.so.1`'s `.text`
was 13× Debian's and `libsystemd.so.0`'s was 4×, against 1.35× for bash — the autotools
control. Those two libraries alone accounted for essentially the whole 4 MB by which the
container image exceeded debian-slim's, and the disk image carries much more of it
(`libsystemd-shared`, `libsystemd-core`, `pam_systemd` and the three NSS modules are all
the same build). `test/size-budget.txt` is the check that *would* have caught this, if the
ceilings had ever been set against an optimized build rather than around what was measured.

Note that meson's `release` is `-O3`, not the `-O2` a distribution would use;
`--buildtype=debugoptimized` or `-Doptimization=2` is the closer match if `-O3` ever
proves to cost more in size than it returns.

**And the version of that which the check cannot catch: a library that is already on the
allowlist.** `known-missing-libs.txt` says "these are accepted", not "these are accepted
for glibc's nscd" — so a *new* package picking up an allowlisted library is reported as
part of the backlog and the build passes. iproute2 is the worked example: `libselinux-dev`
is in deps.txt's deliberately-absent list, but `libblkid-dev` pulls it into the image
anyway, and iproute2's configure links `ip` and `ss` against it with no `--without-selinux`
to pass. Since `libselinux.so.1` is already allowlisted for nscd, the first sign would
have been `ip` not starting in qemu. The fix is in `packages/iproute2/build.sh`: hide the
library from `$PKG_CONFIG`, then `readelf` the installed binary and fail the build if it
came back. **When packaging something that might reach for an allowlisted library, check
the binary rather than the check.**

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
host's kernel, so nothing about `packages/kernel` is exercised. `tools/publish-oci.sh`
pushes both architectures to ghcr.io as one manifest list; see the CI section.

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

Having that file is only half of it: **`pam.d/systemd-user` has to include
`pam_systemd.so`**, however much it looks like the one module that cannot belong there.
`systemd --user` exits immediately unless `$XDG_RUNTIME_DIR` is set and nothing in
`user@.service` sets it, so that module — which puts `/run/user/UID` into the PAM
environment — is the only thing standing between a login and a failed `user@0.service`.
It does not ask logind for a session that logind is waiting on, because `pam_systemd`
special-cases `PAM_SERVICE=systemd-user` and registers the class `manager` instead. The
symptom of leaving it out is `degraded` with *Trying to run as user instance, but
$XDG_RUNTIME_DIR is not set* in the journal, which names neither PAM nor the file.

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
getty (`root`/`root`, from `image/files/etc/shadow`) — and it runs **two rounds**, which is
the thing to preserve when adding to it. The first asks whether the system has a network
and uses bash builtins, `networkctl` and `getent` only. That was forced when the image had
no `grep`, `sed` or `awk`; those are packages now, but the round still sticks to builtins
so a failure in the handshake means what it says. The second asks whether someone logged
in could use it — `ip` for the address and route, `ping`, and `curl` over TLS — and is the
one place that rule is deliberately broken, because those tools are what it is testing.
Keeping them apart is what separates "the network is broken" from "the tools are broken".

`ping` goes to `127.0.0.1` there, not to a real host. qemu's user-mode networking only
forwards ICMP when the *host* kernel lets an unprivileged process open a datagram ICMP
socket, which is a property of the machine running the test rather than of the image — so
an outbound ping is a flaky check of something the TCP and TLS probes either side of it
already cover. In the guest, `image/files/etc/sysctl.d/50-ping-group-range.conf` is what
lets a non-root account ping at all: nothing here is setuid, and a `CAP_NET_RAW` file
capability would have to survive both `mkfs.ext4 -d` and the OCI layer tar.

`ip` and friends come from `iproute2`, which wants `libmnl` — without it its configure
sets `HAVE_MNL:=n` and silently drops half the tool set. Its `make install` puts a python
`routel` next to `ip`; `packages/iproute2/build.sh` deletes it (constraint 5).

TLS is `openssl` (3.5 LTS), `curl` built `--with-openssl`, and `ca-certificates` — Debian's
snapshot of Mozilla's roots, concatenated into `/etc/ssl/certs/ca-certificates.crt` with
`/etc/ssl/cert.pem` symlinked to it, which is the bundle curl is compiled to look for and
OpenSSL's own default. There is no hashed `CApath`, deliberately: building one is what
`c_rehash` is for, and `c_rehash` is perl. **The OpenSSL version is coupled to the builder
image's**, and this is the sharp edge: curl compiles against sid's `libssl-dev` and asks
for `libcrypto.so.3`/`libssl.so.3` at runtime, which ours answers only while it stays on a
3.x release. `packages/openssl/env.sh` holds `tools/check-updates.sh` to the 3.5 series
for that reason, and `test/check-symbol-versions.sh` is what would catch the other
direction — a curl that wanted a symbol version our older OpenSSL does not define.

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
`rootfs` → `boot` → `publish-oci`. Each package job uses `.github/actions/build-package`,
which stages a glibc-only sysroot via `SYSROOT_DIR=sysroot` so each package artifact
contains only its own files, and caches on a hash that deliberately includes
`glibc/env.sh` — a glibc bump must rebuild everything.

`publish-oci` is the only job that writes anything the world can see, and the only one
**gated to `main`** (`if: github.ref == 'refs/heads/main'`), which has a consequence worth
knowing before touching it: a pull request cannot exercise it. Green CI on a branch says
nothing about whether publishing works, so changes to it or to `tools/publish-oci.sh` want
verifying by hand — the script runs anywhere, `REGISTRY=` points it at a local registry,
and the artifacts it reads are downloadable from any run.

It pushes `flfs:<commit>-<arch>` for each architecture and then a manifest list at
`flfs:<commit>` and `flfs:latest`. One job rather than a push step per `rootfs` matrix leg,
because the list can only be assembled once both architectures exist; a single amd64 runner
is enough, since loading and pushing a foreign-arch image never runs it. It needs `boot`
rather than `rootfs`: the OCI and ext4 images are the same userspace from the same staging
tree, so a disk that fails to boot is not a container to publish, whatever `test/oci.sh`
made of it in isolation. The gate on `main` is about `latest` — the commit tags would be
harmless from a branch, but `latest` has one holder.

Both archives carry the same `ref.name` annotation and so both `podman load` as
`localhost/flfs:latest`; the script tags and pushes each before loading the next, which is
the only thing keeping the list from being one architecture twice.
