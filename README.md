# glowing-octo-robot
my experimental linux from scratch (lfs) build, targeting qemu

## Building

Each package is built in a throwaway podman container and installed into the shared
`rootfs/` staging tree:

```sh
./build.sh coreutils
```

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
libraries. It runs `/bin/bash` as PID 1, not systemd, because systemd can't reach a
target yet; point `INIT` at systemd once it can. `./boot-qemu.sh` is still the way to
poke at an image interactively.

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

No secret to set up, but one wrinkle worth knowing about: GitHub deliberately starts no
workflow run for a push made with the built-in `GITHUB_TOKEN`, so the pull request would
otherwise sit there with no CI. `workflow_dispatch` is the one event that token *is*
allowed to trigger, so the workflow asks for the run itself with `gh workflow run ci.yml
--ref <branch>`. That run belongs to the branch rather than to the pull request, so it
is not listed under the pull request's checks — the workflow posts a comment linking to
it instead.
