# glowing-octo-robot
my experimental linux from scratch (lfs) build, targeting qemu

## Layout

```
build.sh          the only build entry point — ./build.sh <package>
packages/<pkg>/   env.sh + build.sh per package, and the tree its tarball unpacks into
builder/          how a package is compiled: the base and per-package builder images,
                  and the container entrypoint that sets up the sysroot
image/            how the staging tree becomes a disk image: Containerfile,
                  build-rootfs.sh, and files/ — the /etc the image ships
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

## Adding a package

Create a directory under `packages/` named after the package with two files in it, and
add it to the CI matrix in `.github/workflows/ci.yml`:

* `env.sh` — the source tarball, plus optional knobs:

  | variable | meaning |
  | --- | --- |
  | `VERSION` | upstream version |
  | `PACKAGE` | directory the tarball unpacks into |
  | `TARBALL` | tarball file name |
  | `URL` | where to download it (may use `$PKG`, the package directory name) |
  | `BUILD_DEP` | Debian source package to take build-dependencies from (default: `$PKG`; empty to skip `build-dep` entirely) |
  | `EXTRA_DEPS` | extra apt packages `build-dep` doesn't cover |
  | `NO_SYSROOT` | set to `1` for packages that aren't compiled against our glibc |
  | `UPSTREAM_*` | where to look for new releases, when the directory `URL` points into isn't it — see `tools/upstream.sh` |

  Everything is derived from `VERSION`, so bumping that one line is a complete update —
  which is what the update workflow below relies on.

* `build.sh` — only the configure/compile/install commands. It is sourced inside the
  container by `builder/build-package.sh` with the unpacked source tree as the working
  directory; install with `DESTDIR=/usr/local/rootfs`.

Everything else — the base image (`builder/base.Containerfile`), the per-package builder image
(`builder/package.Containerfile`), the download/unpack/run dance (`build.sh`) and the
merged-`/usr` staging (`builder/build-package.sh`) — is shared.

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

```sh
./test/network.sh output/rootfs.ext4 rootfs/boot/bzImage
```

is the check, and it runs in the `boot` CI job. It boots the image with systemd as PID
1 — networkd and resolved are the things under test, so a raw shell would prove nothing
— logs in at the serial getty and asserts three layers in order: the link is
`routable` (DHCP answered), `getent hosts example.com` resolves (the resolved stub
answers), and a TCP connection to it is accepted (routing and the VMM's NAT work). The
last two need the machine running the test to have internet access.

The in-guest checks use bash builtins, `networkctl` and `getent` only: the image ships
no `grep`, `sed` or `awk` yet.

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
already in the kernel package's `EXTRA_DEPS`.

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

The bundle is assembled with bash parameter expansion, because the image still ships no
`grep`, `sed`, `awk` or `jq`. Two traps are worth knowing if you edit those checks: the
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
