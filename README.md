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
  | `BUILD_DEP` | Debian source package to take build-dependencies from (default: `$PKG`) |
  | `EXTRA_DEPS` | extra apt packages `build-dep` doesn't cover |

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
