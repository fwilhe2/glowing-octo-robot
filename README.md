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
