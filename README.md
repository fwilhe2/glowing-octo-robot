# glowing-octo-robot

A **pragmatic, automated Linux From Scratch**, targeting virtual machines: source
tarballs in, a bootable disk image and a container image out, rebuilt and version-checked
by CI rather than by hand.

## What this is

A **minimal but genuinely useful general-purpose Linux stack**, built from source and kept
current. Minimal is the means, not the point — the image is small because nothing
unnecessary was added, not because something useful was taken away.

*Pragmatic* is what separates it from LFS proper:

* **No self-hosted toolchain.** Real LFS bootstraps gcc and binutils through several
  passes to escape the host. That is a step further than this needs to go. The Debian
  builder image *is* the toolchain — deliberately and permanently, not as a stepping
  stone. The single exception is glibc, which is built here and compiled against, because
  a version skew there silently produces binaries that cannot start.
* **Modern and established, both.** Every choice should be one a competent engineer would
  defend today: not the crusty option a decade of inertia settled on, and not whatever
  turned up on GitHub last month. This is neither a re-creation of Debian oldstable nor a
  showcase for new things.
* **Opinionated where it matters.** systemd, glibc, GNU coreutils and bash are fixed.
  `bash` is the only interpreter the image contains and is meant to stay that way.
  Everything is DFSG-free and says which license it is under.

Running as a node in a Kubernetes cluster is an eventual target — *an* aim rather than
*the* aim. It should be a reasonable general-purpose Linux first.

Non-goals, so they do not have to be re-argued: real hardware (virtual machines only —
qemu today, rust-vmm/Firecracker-style VMMs next), a self-hosted toolchain, and any
substitute for the four components above.

## Layout

```
build.sh          the only build entry point — ./build.sh <package>
packages/<pkg>/   env.sh + build.sh per package, and the tree its tarball unpacks into
builder/          how a package is compiled: the one builder image, deps.txt (its
                  entire contents), and the entrypoint that sets up the sysroot
image/            how the staging tree becomes an image — a bootable disk or an OCI
                  image: Containerfile, build-rootfs.sh, files/ (the /etc it ships), and
                  variants/ + platforms/, which declare the images there are
test/             everything CI runs to verify a build
tools/            local conveniences and maintenance, not part of a build
docs/             design notes for work not done yet — proposals, not descriptions
downloads/        source tarballs (gitignored)
rootfs/           shared staging tree every package installs into (gitignored)
output/           built images, fetched CI artifacts, test console logs (gitignored)
```

Scripts under `test/` and `tools/` `cd` to the repository root themselves, so they run
correctly from any directory.

## Building

Each package is built in a throwaway podman container and installed into the shared
`rootfs/` staging tree:

```sh
./build.sh glibc
./build.sh coreutils
```

glibc comes first because everything else is compiled against it: `rootfs/` is
bind-mounted into the builder read-only and handed to gcc as `--sysroot`, so the
binaries we ship require the symbol versions *our* glibc defines rather than whatever
the Debian builder image happens to have installed. `SYSROOT_DIR` points that mount at
another tree — CI stages a glibc-only one, which keeps each package's artifact to its
own files. Packages that have no libc to build against (`glibc`, `kernel`) set
`NO_SYSROOT=1` in their `env.sh`.

The container also *runs* on our glibc: every file its own `libc6` owns is bind-mounted
over with ours. Builds run what they just compiled — `help2man` asks a fresh `ptx` for
its `--help`, ncurses runs its own `tic` — and sid's older loader can't start a binary
linked against a newer glibc. glibc stays backwards compatible, so the image's Debian
binaries keep working on ours.

Everything else a package links against still comes from the builder image, so this is
not the staged LFS toolchain — it is the one library where a version skew silently
produces binaries that can't start.

`image/Containerfile` / `image/build-rootfs.sh` then turn `rootfs/` into `output/rootfs.ext4`
(see the `rootfs` job in `.github/workflows/ci.yml`), which `./tools/boot-qemu.sh` boots.
The same script also writes `output/flfs-oci.tar`, the same userspace as a container image
— see [The OCI image](#the-oci-image) — and a smaller disk and container for each of the
other declared variants; see [Image variants](#image-variants).

## Adding a package

Packaging is the easy part; choosing is where the mistakes are. Before writing any of the
below, answer these in the pull request, where they can be argued with:

* **Is it maintained, or just old?** A last release in 2011 is a red flag, not a sign of
  stability. Check what distributions ship today.
* **Is it established?** Something Debian, Fedora and Alpine all carry has had more
  scrutiny than this project can apply. Forty GitHub stars and one contributor has not.
* **Is there a more modern option that is equally established?** Both halves matter — the
  answer to "what does everyone use" is sometimes a decade stale, and the answer to "what
  is newest" almost always wrong.
* **What does it drag in?** A dependency is a decision about the image; see
  [Checking runtime dependencies](#checking-runtime-dependencies) for what happens when it
  goes unasked, and `test/size-budget.txt` for what it costs.
* **Does it need an interpreter at runtime?** `bash` is the only one the image has. A
  package that would add perl, python or a JavaScript runtime needs a case that it is
  unavoidable. What the *builder* needs is unconstrained — perl is already in
  `builder/deps.txt` — so the thing to check is what `make install` leaves in `DESTDIR`.
* **Is it DFSG-free?** Every package declares `LICENSE=` and CI rejects anything not on
  the list; see [Licensing](#licensing).

Then create a directory under `packages/` named after the package with two files in it,
and add it to the CI matrix in `.github/workflows/ci.yml`:

* `env.sh` — the source tarball, plus optional knobs:

  | variable | meaning |
  | --- | --- |
  | `VERSION` | upstream version |
  | `PACKAGE` | directory the tarball unpacks into |
  | `TARBALL` | tarball file name |
  | `URL` | where to download it (may use `$PKG`, the package directory name) |
  | `SHA256` | checksum of the tarball; nothing is ever used without matching it |
  | `LICENSE` | SPDX expression for what the tarball ships; must be DFSG-free — see [Licensing](#licensing) |
  | `MIRRORS` | optional extra URLs, tried in order when `URL` is unreachable |
  | `NO_SYSROOT` | set to `1` for packages that aren't compiled against our glibc |
  | `LOCAL_SOURCE` | set to `1` when the source is in this repository rather than upstream — see below |
  | `UPSTREAM_*` | where to look for new releases, when the directory `URL` points into isn't it — see `tools/upstream.sh` |

  `PACKAGE`, `TARBALL` and `URL` are all derived from `VERSION`. `SHA256` is not — it is
  a hash of bytes only upstream has — so an update is those two lines, and
  `./tools/bump-version.sh <package> <version>` writes both: it rewrites `VERSION`,
  fetches the new tarball from `URL` and pins what it actually got. That is what the
  update workflow below uses.

* `build.sh` — only the configure/compile/install commands. It is sourced inside the
  container by `builder/build-package.sh` with the unpacked source tree as the working
  directory; install with `DESTDIR=/usr/local/rootfs`.

A package says nothing about its build dependencies. There is one builder image for all of
them and `builder/deps.txt` is the whole list of what it contains, one apt package per
line. If a build wants something that isn't in there, prefer configuring the dependency
out — the bottom of `deps.txt` says what is deliberately absent and why, and
`test/known-missing-libs.txt` is what the opposite habit already cost.

Everything else — the builder image (`builder/Containerfile`), prep (`tools/prep.sh`),
the fetch/extract/run dance (`build.sh`) and the merged-`/usr` staging
(`builder/build-package.sh`) — is shared.

### ...whose source is ours

A package does not have to come from a tarball. `LOCAL_SOURCE=1` in `env.sh` means the
source is tracked in this repository at `packages/<pkg>/src/`, so there is no `TARBALL`,
`URL` or `SHA256`, nothing to download or vendor, and no upstream to check for releases.
`packages/flfsfetch/` — a small neofetch-alike in one C file — is the worked example.

Everything after the source is identical: the same builder image, the same sysroot flags,
the same `DESTDIR`, the same CI matrix entry and artifact. The one constraint is that
`packages/<pkg>/src` is mounted **read-only**, because it is a tracked working tree rather
than a gitignored unpacked tarball — so `build.sh` compiles straight to `DESTDIR` instead
of leaving object files behind.

## Licensing

Every package declares what it is under, as an SPDX expression in its `env.sh`:

```sh
LICENSE="BSD-3-Clause OR GPL-2.0-only"              # upstream offers a choice
LICENSE="LGPL-2.1-or-later AND GPL-2.0-or-later"    # library and tools differ
```

```sh
./test/check-licenses.sh
```

checks that every package declares one and that every identifier is on
`test/dfsg-licenses.txt`. It runs in its own workflow rather than inside the build,
because it needs nothing compiled — an unacceptable license should be answered in seconds
on the branch that adds it, not after forty minutes of building.

**The bar is the Debian Free Software Guidelines**, because Debian has already argued
every one of these to a conclusion. A license Debian ships in `main` can be added to the
list; one that exists only in `non-free` means the package does not belong here. That
rules out the non-commercial, field-of-use-restricted and "shall be used for Good, not
Evil" varieties without further discussion.

What the check proves is that a declaration exists and is free. It does **not** prove the
declaration is true — nothing opens the tarball. Reading the license off `COPYING` is a
packaging step, done once, and worth redoing when a version bump crosses a relicensing.

## Checking runtime dependencies

Packages compile inside a Debian builder image, so `configure` will happily link
against an optional library that exists only in that container. The build succeeds,
the library is never staged, and nothing notices until the binary is exec'd in qemu —
which is how `bash` ended up needing `libtinfo.so.6` with no `ncurses` package.

```sh
./test/check-rootfs-deps.sh rootfs
```

reports every `NEEDED` entry the tree can't resolve, and runs in the `rootfs` CI job.
Libraries listed in `test/known-missing-libs.txt` are reported but don't fail the run, so
new regressions stand out from the existing backlog; that file explains what wants
each one and how to resolve it.

When a package pulls in something unwanted, prefer configuring it out (e.g.
`--without-selinux`) over adding a package to satisfy the reference.

A library that *is* present can still be the wrong one — a binary compiled against a
newer glibc than the image ships links fine in the builder and then dies at exec time
with ``version `GLIBC_2.44' not found``. So:

```sh
./test/check-symbol-versions.sh rootfs
```

compares every versioned symbol the tree's binaries ask for against what the tree's own
libraries define, and also runs in the `rootfs` CI job. It is what keeps the sysroot
above honest: a package whose build system quietly drops the exported `CFLAGS`/`LDFLAGS`
shows up here.

## Booting

The kernel is a package like any other (`packages/kernel/`), built with `defconfig` plus
`kvm_guest.config`, a `container.config` fragment that adds what containers need (see
[Containers](#containers)) and a `vm.config` fragment that takes away what a virtual
machine does not have (see [What the image leaves out](#what-the-image-leaves-out)), and
staged at `rootfs/boot/bzImage`, so a CI run produces an image that can boot on its own.
The `boot` job does exactly that:

```sh
./test/boot.sh output/rootfs.ext4 rootfs/boot/bzImage
```

boots the image in qemu with nobody at the console, types a command at PID 1 over the
serial port and waits for the output to come back — proof that the kernel mounted the
root filesystem, exec'd userspace and that the dynamic loader resolved a real binary's
libraries. It runs `/bin/bash` as PID 1 rather than systemd, which keeps that failure
apart from anything systemd does on top; the tests below are the ones that boot systemd
for real. `./tools/boot-qemu.sh` is still the way to poke at an image interactively.

```sh
./test/systemd.sh output/rootfs.ext4 rootfs/boot/bzImage
```

is the next layer up, and it also runs in the `boot` job. It boots systemd, logs in at
the serial getty and asserts that `systemctl is-system-running` reports `running` —
which it does if and only if no unit failed. That catches the class of problem nothing
else here looks for: a package installing a unit it cannot actually run, which costs
nothing at build time and leaves every boot `degraded`. When it fails it prints
`systemctl --failed` and the boot's error-priority journal, so the failing unit and its
reason land in the CI log. It also asserts systemd's `Tainted` property is
empty, which catches image-assembly mistakes no unit ever fails over — an unmerged
`/usr/sbin`, a `/var/run` that is a real directory.

## The OCI image

The same staging tree also comes out as a container image. Every commit on `main` that
gets through the boot tests is published to ghcr.io, for both architectures under one
name:

```sh
podman run --rm -it ghcr.io/fwilhe2/glowing-octo-robot/flfs:latest
```

`latest` is a manifest list, so that pulls the amd64 or arm64 image to match the machine
it runs on. Every commit also keeps a tag of its own — `flfs:<commit>`, and
`flfs:<commit>-amd64` / `flfs:<commit>-arm64` to ask for one architecture on purpose.

To build it instead of pulling it, `output/flfs-oci.tar`:

```sh
podman run --volume "$PWD"/rootfs:/usr/local/src --volume "$PWD"/output:/usr/local/output \
    rootfs-builder /usr/local/bin/build-rootfs.sh oci
podman load -i output/flfs-oci.tar
podman run --rm -it localhost/flfs:latest
```

The `rootfs` CI job also uploads it as `oci-image-<arch>` next to `rootfs.ext4-<arch>`,
which is what the `publish-oci` job pushes: it waits for `boot`, because the two images
are the same userspace and a disk that will not boot is not a container worth publishing.
`tools/publish-oci.sh` is the whole of it, and runs by hand against any registry —
`REGISTRY=` to point it elsewhere, `TAG=` to name it something other than the commit.

It is the disk image minus the two things a container gets from somewhere else: the
kernel, which is the host's, and systemd, which the runtime replaces. `/bin/bash` is the
entrypoint, so `podman run -it` is a shell and anything after the image name is passed to
it (`podman run flfs -c 'flfsfetch'`). Everything else is the same userspace, assembled by
the same script from the same tree — `oci` is a *platform*, thirteen lines of
`image/platforms/oci.conf` expressing the container as subtractions, so the two cannot
drift apart the way two scripts would. Omitting systemd takes its unit tree, udev, its
drop-in directories, its PAM and NSS modules and every one of its command-line tools with
it, because those are all systemd's files and the per-package manifests know that;
`libsystemd.so.0` is rescued by a `keep` line, being the public client library that `crun`
and `libmount.so.1` link. `libudev.so.1` is not: with udevadm gone nothing names it. Also
gone is the `/etc` only a booted machine reads: `fstab`, `shadow`, the networkd
configuration, `resolv.conf`. A runtime provides hostname, hosts and resolv.conf itself.

Nothing new is needed to write it. An OCI archive is a tar of five files — a layer, a
config and a manifest, each named after its own sha256, plus an `index.json` and a version
marker — so `build-rootfs.sh` writes them with `tar`, `gzip` and `sha256sum` rather than
pulling buildah or skopeo into the build container.

```sh
./test/oci.sh output/flfs-oci.tar
```

loads it and runs it, which is the cheapest verification in this repo — no qemu, no boot.
That is also its limit: a container runs on the *host's* kernel, so this says nothing
about `packages/kernel` and does not replace the boot tests. It is a check on the image
we produce; [Containers](#containers) below is the unrelated question of the runtime the
*disk* image ships.

## Image variants

There is more than one image, and which ones there are is *data* rather than code. An
image is a **variant** on a **platform**:

* a **variant** is a feature set — which packages are in it and the `/etc` that goes with
  them — declared in `image/variants/<name>.conf`;
* a **platform** is what the assembled tree is turned into, and what that target
  physically cannot use, in `image/platforms/<name>.conf`.

| variant | what it is for | platforms |
| --- | --- | --- |
| `minimal` | boots to a login shell on the serial console and nothing else | `ext4`, `oci` |
| `net` | minimal, plus a network somebody can debug: addressing, DNS, TLS, `ip`/`ping`/`curl` | `ext4`, `oci` |
| `full` | everything this repository builds — the image published as `flfs:latest` | `ext4`, `oci` |

`full` is the **default variant**, which means it keeps the unsuffixed names: it is
`output/rootfs.ext4`, `output/flfs-oci.tar`, `sbom-ext4.json` and the `flfs:latest` tag.
The others are `output/rootfs-minimal.ext4`, `output/flfs-net-oci.tar` and so on.

```sh
./tools/variants.sh list          # every (variant, platform) pair CI builds
./tools/variants.sh show net oci  # what net resolves to on that platform
podman run --volume "$PWD"/rootfs:/usr/local/src --volume "$PWD"/output:/usr/local/output \
    rootfs-builder /usr/local/bin/build-rootfs.sh minimal ext4
```

The rule the whole thing rests on: **the package build never learns about variants.**
Every package is compiled once per architecture into the same staging tree, exactly as
before, and a variant is a *selection from* that tree resolved at assembly time. That is
what keeps 36 packages × 2 architectures from becoming 36 × 2 × N build jobs — a new
variant costs only an image and a boot.

What makes selection by package possible is a primitive that did not exist before:
`builder/build-package.sh` diffs the staging tree around each package's install and writes
the paths it added to `usr/share/flfs/manifests/<pkg>`. That also answers "which package
shipped this file", which is the first question of every size investigation and which
nothing here could answer before.

And what makes it *safe* is that a subset need not resolve even though the superset always
does. `image/build-rootfs.sh` therefore fails an image whose binaries need a library it
does not ship, against the same `test/known-missing-libs.txt` allowlist
`test/check-rootfs-deps.sh` holds the staging tree to — and the error names the package
that provides it, because the manifests know. Each variant also declares which of the boot
tests apply to it, and CI boots every variant: a subset booting is precisely the claim
being tested, and `full` passing says nothing about `minimal`.

Selection is deliberately **not** transitive: nothing in this repository declares a
dependency graph, so closing over one would mean deriving it from `DT_NEEDED`, which is a
guess that is right often enough to be dangerous. Explicit lists plus a check that names
the missing package is the same trade this project made when it replaced `apt build-dep`
with a reviewed `deps.txt`.

`docs/image-variants.md` is the design, including the `lima` and `firecracker` platforms
that are not built yet.

## What the image leaves out

The staging tree and the disk image are not the same thing. `rootfs/` is what the
package builds produce *and* the sysroot the next package compiles against, so it keeps
its headers, static libraries and `.pc` files; `image/build-rootfs.sh` copies it and
assembles the disk from the copy, dropping everything a booted system cannot reach:

* **debug symbols** — nothing is stripped at install time, so roughly half the tree is
  DWARF for a debugger the image does not ship (`libc.so.6` alone is 11 MB unstripped
  and 2 MB stripped)
* **link-time-only files** — `*.a`, `*.la`, the `crt*.o` startup objects, `usr/include`
  and pkg-config metadata: there is no compiler here
* **documentation** — `share/man`, `share/info`, `share/doc`, with no reader for any of it
* **locale data** — `share/locale` message catalogues and the `share/i18n` source
  definitions. The image runs in the C locale: no locale archive is built and nothing
  sets `LANG`
* **terminfo** — 2500 terminal descriptions cut down to the dozen `TERM` values that can
  appear on a serial console
* **shell completions and polkit rules** — for shells and a `polkitd` that are not here

That is the mechanical half. The other half is not building things in the first place:
`packages/systemd/build.sh` turns off some fifty components (the EFI/bootloader half of
the tree, `machined`/`nspawn`/`importd`, `portabled`, `repart`, `homed`, `oomd`,
`coredump`, the remote journal transports, backlight/rfkill/hibernate/quotas, the 22 MB
hardware database) and `packages/kernel/build.sh` extends its `vm.config` fragment to
subtract the hardware `x86_64_defconfig` assumes — the DRM stack, sound, USB, HID, SATA
and PATA, every ethernet vendor driver, IOMMU, PCMCIA, RAID/device-mapper, NFS, FAT and
ISO9660, SELinux, audit, and the loadable-module machinery itself, since every symbol
here is built in and `make modules_install` is never run.

Both halves follow the same rule, which is worth keeping when adding to them: something
is removed because *nothing in the image can reach it*, never because it seems unlikely
to be used. A VM's devices are virtio and the console is a serial line — that is what
makes the driver list above dead code rather than a bet.

Rebuilding only the image after changing one of the build-time options is not enough
locally: `rootfs/` is cumulative and nothing removes stale files from it, so a component
that is no longer built stays staged until the tree is deleted and rebuilt.

## The shell, and `/bin/sh`

`bash` is the only interpreter in the image and `/usr/bin/sh` is a symlink to it, made by
`packages/bash/build.sh` because upstream installs no such name — which shell answers to
it is the distribution's decision. This one had not made it, so for a long time there was
no `/bin/sh` here at all, which is a stranger position than it sounds: every `#!/bin/sh`
script in the world is then a file the image cannot start. That is not hypothetical. It
is `crun spec`'s default `"args": ["sh"]`, a container entrypoint, a systemd unit that
shells out, and the wrapper scripts several of these packages install.

Invoked under that name bash follows sh's startup-file behaviour on its own. It is not
full POSIX mode, which needs `--posix` or `POSIXLY_CORRECT`, so nothing that relies on a
bashism breaks and nothing that does not is any the wiser. Fedora and Arch point
`/usr/bin/sh` at bash the same way. The cost is one symlink.

What this does *not* change is the no-new-interpreters rule. The image gained no
interpreter — bash was already here — and perl, python and the rest are as unwelcome as
they were. What it changes is which deletions in a `build.sh` are about the shebang,
which is now none of them.

## The system bus

The image ships the reference `dbus-daemon` (the `dbus` package, which needs `expat`).
It is not optional furniture: systemd-logind connects to the system bus at startup, and
without one it exits with *Failed to connect to system bus* and is restarted until it
hits its start limit. dbus enables itself — the `.target.wants` symlinks live in its own
unit directory — and creates its `messagebus` user through the `sysusers.d` snippet it
installs, so nothing in `image/files` has to enable or provision it.

Logging in registers a session with logind because systemd is built `-Dpam=enabled` and
`image/files/etc/pam.d/login` calls `pam_systemd.so`; `loginctl list-sessions` shows the
serial console session.

## Networking

The guest gets one virtio-net NIC on qemu's user-mode network, and everything above it
is systemd: `image/files/etc/systemd/network/20-wired.network` puts systemd-networkd on
DHCP for anything named `en*` or `eth*`, networkd hands the lease's DNS servers to
systemd-resolved, and `/etc/resolv.conf` is a symlink to resolved's stub. Nothing else
is involved — there is no DHCP client, no resolver library and no init script of our
own to go wrong.

Interfaces a container runtime creates (`veth*`, `docker0`, `cni*`, `podman*`) do not
match that file on purpose: whatever brings them up configures them.

Configuring the network is one thing; being able to look at it from inside the guest is
another, and for a long time the image could not. `iproute2` is what fixed that —
`ip addr`, `ip route`, `ip link`, plus `ss`, `bridge` and `tc` — because `networkctl`
only reports what networkd was asked to do and cannot read a route out of the kernel or
create a link. The alternative is net-tools, and it is not a close call: `ifconfig`
predates most of what rtnetlink can express and cannot see multiple addresses on an
interface, policy routing or namespaces. `iputils` supplies `ping`, `arping` and
`tracepath`, and `image/files/etc/sysctl.d/50-ping-group-range.conf` opens the datagram
ICMP socket to unprivileged users so `ping` works for the `user` account without being
setuid.

```sh
./test/network.sh output/rootfs.ext4 rootfs/boot/bzImage
```

is the check, and it runs in the `boot` CI job. It boots the image with systemd as PID
1 — networkd and resolved are the things under test, so a raw shell would prove nothing
— logs in at the serial getty and asserts two rounds of checks.

The first round asks whether the *system* has a network: the link is `routable` (DHCP
answered), `getent hosts example.com` resolves (the resolved stub answers), and a TCP
connection to it is accepted (routing and the VMM's NAT work). The second asks whether
someone logged in could use it: `ip` shows a global address and a default route, `ping`
opens an ICMP socket, and `curl https://example.com` verifies a certificate chain and
makes a request. Splitting them keeps "the network is broken" and "the tools are broken"
apart. Everything past the first check needs the machine running the test to have
internet access.

The first round uses bash builtins, `networkctl` and `getent` only. That began as a
constraint and is now a choice: `grep`, `sed` and `awk` are in the image, but a serial
console handshake is better off not depending on a package it is not testing. The second
round is where that rule is deliberately broken, since those tools are the thing under
test — it still parses their output with `[[ ]]`.

## TLS and the trust store

`curl` is the HTTP client, `openssl` is what it speaks TLS with, and `ca-certificates` is
the list of roots it verifies against. All three arrived together, because none of them
is useful alone.

The TLS backend was an open question — `docs/container-runtime.md` preferred mbedTLS on
size, at roughly 1.5 MB against OpenSSL's 5. It is settled on OpenSSL, on the *modern and
established* test at the top of this file. mbedTLS is established in embedded firmware;
OpenSSL is what a general-purpose Linux has, and the next thing here to want TLS will
look for `libcrypto` and expect to find it. Carrying two TLS libraries is the outcome
worth avoiding, so the one to carry is the one that scales. Its `Configure` being perl was
never a disqualification: a build-time interpreter is fine, and what the rule forbids is
an interpreter *in the image* — which is why `packages/openssl/build.sh` deletes
`c_rehash`, `CA.pl` and `tsget` from `DESTDIR`, all three being perl with no perl here to
run them. `packages/curl/build.sh` deletes `curl-config` alongside them for a different
reason: it is a shell script, and shell scripts run here, but what it describes is where
libcurl's headers live and the trim has removed them.

The roots come from Debian's `ca-certificates`, which is a snapshot of Mozilla's
`certdata.txt` plus the python that turns it into PEM — the same source Buildroot,
OpenWrt, Void and Gentoo build their bundles from. The python runs in the builder and
what ships is a text file: `/etc/ssl/certs/ca-certificates.crt`, one concatenated bundle
rather than a hashed `CApath` directory, since building that directory is what `c_rehash`
was for. `/etc/ssl/cert.pem` is a symlink to it, so OpenSSL's own default finds it too.

`openssl` is pinned to the 3.5 LTS branch and `packages/openssl/env.sh` says why at
length. The short version: curl is compiled against the builder image's OpenSSL headers,
so it asks for `libcrypto.so.3` at runtime and ours has to be the library that answers —
which makes a major-version bump something to do deliberately rather than automatically.

## Remote access

`openssh` is the ssh server and client, and it is the first thing this image has ever
*listened* on — which is a change of what the image is, not another line in the package
list. Everything before it was reached over a serial console; this is reached over a
network, by somebody who is not already at the machine.

It is here for the `lima` variant. Lima starts the VM and then does everything else over
ssh — provisioning, mounting the host's filesystem back into the guest, running commands
— so a VM somebody actually works in needs a server before it needs anything else on
Lima's list. There is no second candidate: Lima writes OpenSSH configuration verbatim,
`sshfs` is an OpenSSH client talking to an OpenSSH server, and every distribution's `ssh`
is this one. It links only what the image already had — `libcrypto` from openssl, `libz`,
`libpam`, `libcrypt` — and ships no interpreted helper.

Three things about how it is set up are decisions rather than defaults.

**Host keys are generated on the machine, at its first boot**, by `sshd-keygen.service`
running `ssh-keygen -A`, and never in the image. A private host key baked into an image
built from a public repository would be the same key on every machine that ever booted
it, and any of them could then impersonate the rest. `packages/openssh/build.sh` runs
`make install-nokeys` for the same reason, even though upstream's key-generating install
step is already a no-op under `DESTDIR`.

**Root can log in by key and not by password.** `PermitRootLogin prohibit-password`, plus
`KbdInteractiveAuthentication no` to close the second path to a password that PAM's
keyboard-interactive method would otherwise open. `image/files/etc/shadow` ships
`root`/`root` and `user`/`user`, which are throwaway credentials for a development VM
reached over a serial console and are not credentials to expose to a network.

**The daemon brings its own scaffolding, from the package rather than from
`image/files`.** The unit, the symlink that enables it, the `sysusers.d` snippet for the
privilege separation account, `sshd_config` and `/etc/pam.d/sshd` are all installed by
`packages/openssh/build.sh` into `DESTDIR`. That is what makes them disappear in the
variants that do not select openssh: `image/files` is copied into every image, but a
package's manifest belongs to one package, and a unit whose `ExecStart` names a binary
that is not there is a failed unit and a `degraded` boot.

```sh
./test/ssh.sh output/rootfs.ext4 rootfs/boot/bzImage
```

is the check, and it has the guest connect to itself on `127.0.0.1` — which
means no port forward, no ssh client on the runner and no key material crossing the
boundary. Everything that can be wrong about sshd in this image is inside the guest: the
unit, the host key, the privilege separation account, the seccomp sandbox and the PAM
stack. Reaching the guest from *outside* is a property of the VMM rather than of the
image, and it is the `lima` platform's problem when that arrives.

## Archives

`tar` and `gzip` are GNU tar and GNU gzip. The image had `xz` and `zstd` — and `zlib`,
which is a library with no command-line tool on top of it — so it could read the two
formats almost nothing arrives in and neither of the two it does. `tar+gzip` is what an
OCI layer is, and it is what everything else that ships a tarball is too.

tar is built with ACL and extended-attribute support on, which is the half that matters
for `docs/container-runtime.md`: an image layer carries file capabilities as
`security.capability` xattrs, and `tar --xattrs --acls` is what carries them through an
unpack. Both are autodetected, and neither `--with-posix-acls` nor `--with-xattrs` fails
a configure that cannot have them — they check for the headers and quietly turn
themselves back off — so `packages/tar/build.sh` asserts on `config.h` instead. `readelf`
would not do: the ACL half links `libacl`, but the xattr calls are glibc's, so a tar with
no xattr support has exactly the same `NEEDED` as one with it and differs only in
unpacking layers wrong. What is *not* built is `rmt`, the remote-tape server tar reaches
for over rsh — there is no rsh here, and no tape drive for it to reach.

gzip installs a dozen wrapper scripts around the binary, and none of them ship. Most wrap
a tool that is not here: `zdiff` and `zcmp` want diffutils, `znew` wants `compress`,
`zless` wants `less`. That leaves `zgrep` and a couple of others, and shipping four of
twelve because those four happen to work is a worse story than shipping none.

`gunzip` and `zcat` are the exception, being names too much of the world calls to simply
not have — and they are better as symlinks than as wrappers regardless, a symlink costing
neither a fork nor a shell. gzip's `main()` has always been able to answer to them by
looking at `argv[0]`; that code sits behind `#if !GNU_STANDARD`, whose default is why
upstream ships wrappers at all, so `packages/gzip/build.sh` compiles with
`-DGNU_STANDARD=0` and symlinks both names at the binary. It then compresses a string and
reads it back through the installed `zcat`, because the failure mode is silent and
backwards: a `gunzip` that did not get the macro compresses.

## Containers

The OCI runtime is `crun`, chosen because it is the only one written in C — runc is Go
and youki is Rust, and either would mean a second language toolchain in the builder
image producing binaries that never pass through the `--sysroot` machinery that keeps
everything else on our glibc. It brings one dependency with it, `json-c`, which is what
it parses `config.json` with. crun used to bundle yajl and could be built
`--enable-embedded-yajl`; that option is gone, so the JSON library is a package now.

crun is built without seccomp and CRIU (see the comments in `crun/build.sh`), so a
bundle's seccomp profile is accepted and ignored rather than enforced. Adding a
`libseccomp` package would fix that and would also let systemd stop being built
`-Dseccomp=disabled`. eBPF stays enabled even though it reads like an optional feature:
on cgroup v2 the device controller *is* a BPF program, and a crun built `--disable-bpf`
fails outright on any bundle with device rules — which is every bundle `crun spec`
writes.

`x86_64_defconfig` enables almost none of what a container needs — it has `CGROUPS`, the
pid/net/ipc/uts namespaces and `SECCOMP_FILTER`, and stops there. `kernel/build.sh`
writes out a `container.config` fragment and merges it with `make container.config`:
`USER_NS` and `MEMCG`, `OVERLAY_FS` for image layers, `VETH`/`BRIDGE`/`TUN` for
container networking, `BPF_SYSCALL`/`CGROUP_BPF` for the cgroup v2 device controller,
and nftables, which is hidden behind `NETFILTER_ADVANCED` that defconfig leaves off. The
fragment is a heredoc rather than a file next to `build.sh` because only `build.sh` is
bind-mounted into the builder.

## systemd's BPF sandboxing

Separate from crun's use of BPF above. crun talks to the cgroup v2 device controller
through raw `bpf(2)` calls and needs no library; systemd loads its own programs —
`IPAddressAllow=`/`Deny=`, `RestrictNetworkInterfaces=`, `SocketBind*=`,
`RestrictFileSystems=` — through **libbpf**. systemd is built with `-Dbpf-framework`
enabled, so those programs are compiled by clang inside the builder image and embedded
as skeletons; it then `dlopen`s `libbpf.so.1` at runtime to load them. Not shipping the
library disabled all of it with a single line in the journal, which is why `libbpf` and
`elfutils` (for `libelf.so.1`, which libbpf parses ELF objects with) are packages.

The LSM-based ones — `RestrictFileSystems=` and the user-namespace lockdown
`systemd-nsresourced` does — need the kernel side too, and the `container.config`
fragment carries all four symbols:

| symbol | why |
| --- | --- |
| `BPF_JIT` | `BPF_LSM` depends on it; defconfig leaves it off |
| `BPF_LSM` | the hook type itself. `CONFIG_LSM` already lists `bpf` |
| `SECURITYFS` | systemd decides bpf-lsm is available by reading `/sys/kernel/security/lsm`, so without securityfs the answer is no however the kernel is built |
| `DEBUG_INFO_BTF` | an LSM program names the kernel function it hooks, and resolving that name needs `/sys/kernel/btf/vmlinux` |

`DEBUG_INFO_BTF` is the one with a real price: it compiles the kernel with debug info
and runs pahole over `vmlinux`, so the kernel job gets noticeably slower. `dwarves` is
already in `builder/deps.txt`.

Nothing pulls images yet: `crun` runs an OCI *bundle*, and the tooling that turns a
registry reference into one (skopeo, umoci, podman) is all Go. `crun spec` writes a
valid `config.json` from nothing, so a directory plus that file is enough to start a
container by hand.

```sh
./test/container.sh output/rootfs.ext4 rootfs/boot/bzImage
```

is the check, and it runs in the `boot` CI job alongside the network test. It boots
systemd for real — crun asks systemd over sd-bus for the cgroup v2 scope, so PID 1 is
part of what is under test — logs in at the serial getty and then asserts three layers:
`cgroup.controllers` lists `memory`, `pids` and `cpu` (the fragment's `MEMCG` and
friends actually took), `crun spec` plus a bind mount produces a bundle, and `crun run`
starts a container whose `$$` is 1 and whose `$HOSTNAME` is the one the spec set — pid
and uts namespaces that are demonstrably not the host's.

The bundle is assembled with bash parameter expansion. The image ships no `jq`, and a
JSON edit is not a job for `sed` either. Two traps are worth knowing if you edit those
checks: the
command spliced into `config.json` can contain no quotes of any kind, and `&` in the
replacement half of `${var/pat/repl}` is a backreference to the whole match, so an `&&`
chain silently corrupts the JSON.

## Keeping packages up to date

```sh
./tools/check-updates.sh              # every package
./tools/check-updates.sh bash glibc   # only these
```

reports what each package is pinned to and what upstream has released since. Where to
look is declared per package in `env.sh` (see `tools/upstream.sh` for the knobs); nothing
needs declaring when the download URL points into a directory that holds every release,
which covers the GNU mirrors, savannah and kernel.org. Projects that publish on GitHub
set `UPSTREAM_GITHUB="owner/repo"`. Only plain numeric versions are considered, so
release candidates are never proposed, and a candidate is reported only once its
tarball has been confirmed to exist at the URL `env.sh` would fetch it from.

`.github/workflows/update-packages.yml` runs that check every Monday and opens one pull
request per outdated package, each bumping a single `VERSION` line. CI then builds the
package, checks the assembled rootfs for unresolved libraries and boots the image, so
an update that breaks something says so before it reaches `main`. Closing a pull
request unmerged stops that version from being proposed again; the next release still
gets its own.

No secret to set up, but one repository setting: *Settings → Actions → General → Workflow
permissions* → **Allow GitHub Actions to create and approve pull requests**. Without it
the workflow pushes its branch and then dies on `gh pr create` with *GitHub Actions is
not permitted to create or approve pull requests*.

One more wrinkle worth knowing about: GitHub deliberately starts no
workflow run for a push made with the built-in `GITHUB_TOKEN`, so the pull request would
otherwise sit there with no CI. `workflow_dispatch` is the one event that token *is*
allowed to trigger, so the workflow asks for the run itself with `gh workflow run ci.yml
--ref <branch>`. That run belongs to the branch rather than to the pull request, so it
is not listed under the pull request's checks — the workflow posts a comment linking to
it instead.
