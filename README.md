# glowing-octo-robot
my experimental linux from scratch (lfs) build, targeting qemu

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

`rootfs.Containerfile` / `build-rootfs.sh` then turn `rootfs/` into `output/rootfs.ext4`
(see the `rootfs` job in `.github/workflows/ci.yml`), which `./boot-qemu.sh` boots.

## Adding a package

Create a directory named after the package with two files in it, and add it to the CI
matrix in `.github/workflows/ci.yml`:

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
  | `UPSTREAM_*` | where to look for new releases, when the directory `URL` points into isn't it — see `lib/upstream.sh` |

  Everything is derived from `VERSION`, so bumping that one line is a complete update —
  which is what the update workflow below relies on.

* `build.sh` — only the configure/compile/install commands. It is sourced inside the
  container by `lib/build-package.sh` with the unpacked source tree as the working
  directory; install with `DESTDIR=/usr/local/rootfs`.

Everything else — the base image (`Containerfile`), the per-package builder image
(`package.Containerfile`), the download/unpack/run dance (`build.sh`) and the
merged-`/usr` staging (`lib/build-package.sh`) — is shared.

## Checking runtime dependencies

Packages compile inside a Debian builder image, so `configure` will happily link
against an optional library that exists only in that container. The build succeeds,
the library is never staged, and nothing notices until the binary is exec'd in qemu —
which is how `bash` ended up needing `libtinfo.so.6` with no `ncurses` package.

```sh
./check-rootfs-deps.sh rootfs
```

reports every `NEEDED` entry the tree can't resolve, and runs in the `rootfs` CI job.
Libraries listed in `known-missing-libs.txt` are reported but don't fail the run, so
new regressions stand out from the existing backlog; that file explains what wants
each one and how to resolve it.

When a package pulls in something unwanted, prefer configuring it out (e.g.
`--without-selinux`) over adding a package to satisfy the reference.

A library that *is* present can still be the wrong one — a binary compiled against a
newer glibc than the image ships links fine in the builder and then dies at exec time
with ``version `GLIBC_2.44' not found``. So:

```sh
./check-symbol-versions.sh rootfs
```

compares every versioned symbol the tree's binaries ask for against what the tree's own
libraries define, and also runs in the `rootfs` CI job. It is what keeps the sysroot
above honest: a package whose build system quietly drops the exported `CFLAGS`/`LDFLAGS`
shows up here.

## Booting

The kernel is a package like any other (`kernel/`), built with `defconfig` plus
`kvm_guest.config` and staged at `rootfs/boot/bzImage`, so a CI run produces an image
that can boot on its own. The `boot` job does exactly that:

```sh
./boot-test.sh output/rootfs.ext4 rootfs/boot/bzImage
```

boots the image in qemu with nobody at the console, types a command at PID 1 over the
serial port and waits for the output to come back — proof that the kernel mounted the
root filesystem, exec'd userspace and that the dynamic loader resolved a real binary's
libraries. It runs `/bin/bash` as PID 1 rather than systemd, which keeps that failure
apart from anything systemd does on top; the network test below is the one that boots
systemd for real. `./boot-qemu.sh` is still the way to poke at an image interactively.

## Networking

The guest gets one virtio-net NIC on qemu's user-mode network, and everything above it
is systemd: `_files/etc/systemd/network/20-wired.network` puts systemd-networkd on
DHCP for anything named `en*` or `eth*`, networkd hands the lease's DNS servers to
systemd-resolved, and `/etc/resolv.conf` is a symlink to resolved's stub. Nothing else
is involved — there is no DHCP client, no resolver library and no init script of our
own to go wrong.

Interfaces a container runtime creates (`veth*`, `docker0`, `cni*`, `podman*`) do not
match that file on purpose: whatever brings them up configures them.

```sh
./network-test.sh output/rootfs.ext4 rootfs/boot/bzImage
```

is the check, and it runs in the `boot` CI job. It boots the image with systemd as PID
1 — networkd and resolved are the things under test, so a raw shell would prove nothing
— logs in at the serial getty and asserts three layers in order: the link is
`routable` (DHCP answered), `getent hosts example.com` resolves (the resolved stub
answers), and a TCP connection to it is accepted (routing and the VMM's NAT work). The
last two need the machine running the test to have internet access.

The in-guest checks use bash builtins, `networkctl` and `getent` only: the image ships
no `grep`, `sed` or `awk` yet.

## Keeping packages up to date

```sh
./check-updates.sh              # every package
./check-updates.sh bash glibc   # only these
```

reports what each package is pinned to and what upstream has released since. Where to
look is declared per package in `env.sh` (see `lib/upstream.sh` for the knobs); nothing
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
