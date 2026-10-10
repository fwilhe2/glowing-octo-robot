# How the build works

This document describes the system as it is. The other files in `docs/` are design notes
and proposals. `CLAUDE.md` gives the reasons behind each decision; this file gives the
mechanics, and lists the pitfalls in one place.

## Overview

```
 packages/<pkg>/env.sh ─┐
 builder/deps.txt ──────┼─► prep ──► builder image + sources image   (network allowed)
                        │
 packages/<pkg>/build.sh ─► build ──► rootfs/   (one package at a time, --network=none)
                                        │
 image/files/ ─────────────────────────►├─► build-rootfs.sh ext4 ──► output/rootfs.ext4
                                        └─► build-rootfs.sh oci  ──► output/flfs-oci.tar
                                                  │
                                    test/*.sh  ◄──┘   (static checks, then qemu boots)
```

There are three stages. **Prep** fetches everything. **Build** compiles each package
offline into a shared staging tree. **Assemble** copies that tree, trims it, and writes
the two images.

## 1. Prep: the only stage that uses the network

`tools/prep.sh` makes sure two images exist locally. Each is pulled from the registry if
it is there, and built otherwise.

| image | contents | tag |
| --- | --- | --- |
| builder | Debian sid at a pinned snapshot date, plus every apt package in `builder/deps.txt` | hash of `builder/Containerfile`, `deps.txt`, `build-package.sh`, plus the arch |
| sources | every pinned tarball, `FROM scratch` | hash of every package's `TARBALL` and `SHA256` |

Both tags are content hashes (`tools/image-tags.sh`), so the same checkout always names
the same image, locally and in CI. Changing an input changes the tag, and the next prep
builds a new image.

After pulling the sources image, prep copies its tarballs into `downloads/`.
`tools/fetch-sources.sh` then checks every tarball against the `SHA256` in its `env.sh`.
A tarball that is missing or wrong is downloaded from `URL`, then from each `MIRRORS`
entry, and is only accepted if the checksum matches.

The builder's apt sources point at `snapshot.debian.org` for the same date as the base
image. Without that, an old base image would install today's packages.

## 2. Build: one package

`./build.sh <pkg>` runs on the host, then starts one container.

### Host side (`build.sh`)

1. Loads `packages/<pkg>/env.sh` through `tools/lib.sh` (`load_env`), with `$PKG` set.
2. Runs prep.
3. Unpacks the tarball into `packages/<pkg>/$PACKAGE/` with `--strip-components=1`.
   It extracts into `.extracting` first and then renames, so an interrupted extract
   never looks finished. If the directory already exists, the extract is skipped.
   `LOCAL_SOURCE=1` packages skip this step and mount `packages/<pkg>/src` read-only.
4. Collects the mounts:

   | host | container | mode |
   | --- | --- | --- |
   | unpacked source | `/usr/local/src` | rw (ro for local source) |
   | `packages/<pkg>/build.sh` | `/package-build.sh` | ro |
   | `rootfs/` | `/usr/local/rootfs` | rw: the install target |
   | `$SYSROOT_DIR` (default `rootfs/`) | `/usr/local/sysroot` | ro: the glibc to compile against |
   | each file of Debian's `libc6`, replaced by ours | its own path | ro |

5. Passes the pins as `FLFS_*` environment variables, for the SBOM.
6. Runs the container with `--network=none`.

The `libc6` overlay matters. Builds *run* what they compile: help2man runs a freshly
built `ptx`, ncurses runs its own `tic`. Those binaries need our glibc, which is newer
than sid's, so the container has to run on our glibc as well. Bind mounts put every
file in place before the first process starts. glibc is backwards compatible, so
Debian's gcc, make and perl keep working.

### Container side (`builder/build-package.sh`)

1. **Merged `/usr`.** It makes `/bin`, `/sbin`, `/lib` and `/lib64` symlinks into
   `/usr`, and `/usr/sbin` a symlink to `bin`. If any of these is a real directory,
   systemd reports itself as tainted.
2. **Sysroot flags.** Unless the package sets `NO_SYSROOT`, it prepends to `CPPFLAGS`,
   `CFLAGS`, `CXXFLAGS` and `LDFLAGS`:
   - `--sysroot=/usr/local/sysroot`, so headers and libraries come from our tree first;
   - `-idirafter /usr/include[/multiarch]`, so Debian's other headers are still found,
     after ours;
   - `-B`, `-L` and `-Wl,-rpath-link` for our `/usr/lib64` and `/usr/lib`. `-B` is
     needed for `crt1.o` and friends, which gcc looks up outside the sysroot;
   - a trailing `-L` and `-rpath-link` for Debian's library directories.

   The result: glibc is ours, everything else links against Debian's.
3. **Helpers.** These are defined in the shell that sources the package script:

   | name | effect |
   | --- | --- |
   | `$ROOTFS` | `/usr/local/rootfs`, the `DESTDIR` |
   | `MAKEFLAGS=-j$(nproc)` | every `make` runs in parallel |
   | `meson_install [opts]` | `meson setup --prefix /usr --buildtype=release -Dlibdir=lib`, then compile and install |
   | `drop_installed prog…` | `rm` from `usr/bin`; fails if a name is not installed |
   | `assert_not_linked lib bin…` | fails if `readelf -d` shows `lib` as `NEEDED` |

4. **Sources `packages/<pkg>/build.sh`**, with the source tree as the working
   directory, under `set -euo pipefail`.
5. **Component record.** It writes `usr/share/flfs/components/<pkg>` (name, version,
   license, URL, SHA256, builder tag). This only runs if the build succeeded, so a
   failed package never shows up in the SBOM.

### `rootfs/` is shared and cumulative

Every package installs into the same tree, and nothing removes files from it. That has
three consequences:

- After a version bump or a removed component, old files stay behind. Use
  `./tools/build-image.sh --clean` to start over.
- `rootfs/` is both the install target and the sysroot for the next package. The trim
  must never run on it (see stage 3).
- Packages must build one at a time locally, since they would race on the tree. CI gets
  around this by building each package against a separate glibc-only sysroot and
  uploading only that package's files.

## 3. Assemble: `image/build-rootfs.sh`

This runs in `image/Containerfile`, a second pinned Debian image that contains
e2fsprogs and binutils. Use `./tools/build-image.sh --image-only` to run it locally. It
works on a **copy** of `rootfs/` at `/usr/local/image`.

Steps, in order:

1. Build the directory skeleton and copy in `/etc` from `image/files/`, which
   overrides anything staged under the same name.
2. **OCI only: subtractions.** Remove the kernel, systemd and udev, every binary whose
   `NEEDED` names `libsystemd-shared`, PAM, agetty, kmod and `libudev`. Keep
   `libsystemd.so.0`, because crun and `libmount` need it.
3. **Trim.** Strip ELF files, then remove static libraries, headers, pkg-config files,
   man/info/doc, locales, most terminfo, shell completions and translated catalogs.
   The rule: delete only what nothing in the image can reach.
   After the trim, `extra/` (local only, gitignored) is copied in unchanged. This
   happens before `ldconfig`, so libraries in it are added to the cache.
4. **Generated files.** Run `ldconfig`. For ext4 only, build the systemd message
   catalogue with *our* `journalctl`, run through our own loader.
5. **SBOM.** Write SPDX 2.3 from the component records, then delete the records.
6. **Size report.** Write `output/rootfs-size-<flavour>.txt`.
7. **Write the image.** ext4: `mkfs.ext4 -d`. OCI: a gzipped layer plus config,
   manifest, `index.json` and `oci-layout`, assembled by hand.

## 4. Verification

There is no unit test suite. The checks, cheapest first:

| check | catches |
| --- | --- |
| `test/check-licenses.sh` | a missing or non-DFSG `LICENSE=` |
| `test/check-rootfs-deps.sh` | a `NEEDED` library that nothing in `rootfs/` provides |
| `test/check-symbol-versions.sh` | a binary built against the builder's glibc rather than ours |
| `test/kernel-caps.sh` | kernel config missing a container feature |
| `test/oci.sh` | the OCI archive does not load or run |
| `test/check-sbom.sh` | the SBOM does not parse, or is incomplete |
| `test/rootfs-size.sh`, `vs-debian-slim.sh` | the image grew past its budget, or past debian-slim |
| `test/boot.sh` | kernel and loader: boots with `/bin/bash` as PID 1 |
| `test/systemd.sh` | a failed unit (`degraded`), or a taint |
| `test/network.sh` | DHCP, DNS and outbound TCP/TLS, first with builtins, then with `ip`/`curl` |
| `test/ssh.sh` | sshd up, key login guest-to-itself with a logind session, then from the host via `tools/ssh.sh` |
| `test/container.sh` | crun starts a container in the booted guest |
| `test/nspawn.sh` | nspawn runs a machine via machined, with a network over its nft-managed bridge (over ssh) |

The qemu tests share `test/qemu-lib.sh`, and so does `tools/boot-qemu.sh`, so an
interactive debug boot is the same guest that CI booted.

## 5. CI (`.github/workflows/ci.yml`)

```
builder (×arch) ─┐
sources ─────────┼─► glibc (×arch) ──► build (×arch × packages) ─┐
                 └─► kernel (×arch) ──────────────────────────────┼─► rootfs (×arch) ─► boot (×arch) ─► publish-oci (main only)
```

- **The package matrix is generated.** The `sources` job outputs every package without
  `NO_SYSROOT` as JSON, and `build` uses it through `fromJSON`. glibc and the kernel
  have their own jobs.
- **Each package job** (`.github/actions/build-package`) does the following:
  - reads `NO_SYSROOT` from `env.sh`;
  - stages glibc into `sysroot/`;
  - builds with `SYSROOT_DIR=sysroot`;
  - uploads only that package's files.
- **The cache key** hashes `build.sh`, `tools/lib.sh`, `build-package.sh`, glibc's
  `env.sh`, the package's own `env.sh`/`build.sh`/`src`, and the builder tag. A glibc
  bump or a builder change rebuilds everything.
- **`rootfs`** unpacks every package artifact for its arch, runs the static checks, and
  then calls `tools/build-image.sh --image-only`, the same path as a local build.
- **Per-arch jobs** share the `&per-arch` strategy, the `&runner` expression and the
  `&telemetry` step through YAML anchors.
- **`publish-oci`** only runs on `main`, so a pull request never exercises it.

## 6. Keeping versions current

| tool | job |
| --- | --- |
| `tools/check-updates.sh` | compares each `VERSION` with upstream (`tools/upstream.sh`: GitHub API or an index page) |
| `tools/bump-version.sh <pkg> <ver>` | rewrites `VERSION`, downloads the tarball, pins its `SHA256`, re-verifies it |
| `tools/check-snapshot.sh`, `bump-snapshot.sh` | the same for the Debian snapshot date and digest, in both Containerfiles |
| `update-packages.yml` | runs the above on a schedule and opens one pull request per update |

## Pitfalls

Each entry lists the symptom, the cause, and what to do about it.

### Builds

**Binary fails in qemu with `GLIBC_2.xx not found`.**
The build system *replaced* `CFLAGS`/`LDFLAGS` instead of adding to them, so the
`--sysroot` flags were lost. meson's `-Dc_args` does this. Carry `$CFLAGS` over by hand,
as `packages/systemd/build.sh` does. `check-symbol-versions.sh` catches it.

**Binary fails in qemu with `libfoo.so.N: cannot open shared object file`.**
`configure` found an optional dev package in the builder and linked against it. The fix
is to configure it out (`--without-…`, `-D…=disabled`). Do **not** add it to
`builder/deps.txt`. `check-rootfs-deps.sh` catches it, *unless the library is already in
`test/known-missing-libs.txt`*. In that case, add `assert_not_linked` to the package.

**The image is several times larger than it should be.**
A meson build without `--buildtype` compiles at `-O0`. Always use `meson_install`.
systemd's `-Dmode=release` is unrelated and does not change optimisation.

**The image ships a perl or python script.**
`make install` put a helper script into `DESTDIR`. Remove it with `drop_installed`, not
`rm -f`, so that an upstream rename fails the build. Check `DESTDIR` after any new
package or version bump.

**The build fails on a stale removal list.**
`drop_installed` found that a name is no longer installed, because upstream renamed or
dropped it. Update the list.

**A parallel build fails at random.**
`MAKEFLAGS` makes every `make` parallel. If a package's Makefile is not parallel-safe,
pass `-j1` to that `make` call in its `build.sh` and leave a comment saying why.

**Local-source package: the build leaves the git tree dirty, or fails with read-only
errors.**
`packages/<pkg>/src` is mounted read-only. Compile straight into `$ROOTFS`, or use a
build directory under `/tmp`.

**A version bump fails with `CHECKSUM MISMATCH`.**
`VERSION` changed but `SHA256` did not. Use `tools/bump-version.sh`, which writes both.

**A version bump builds the old source.**
The unpacked directory is named after `$PACKAGE`. If `PACKAGE` does not contain
`$VERSION`, the old tree is reused. Always derive `PACKAGE` from `VERSION`.

**`curl`, or anything that uses OpenSSL, fails to start after an OpenSSL bump.**
curl compiles against the builder's `libssl-dev` (3.x) and loads ours at runtime. Stay
on 3.x. `env.sh` pins the 3.5 series for this reason.

### Staging tree

**Removed files are still in the image, or headers from an old version are used.**
`rootfs/` is cumulative. Run `tools/build-image.sh --clean`.

**`rm` reports `Permission denied` in `rootfs/` or in a source tree.**
Those files belong to the container's root, which is a sub-UID on the host. Use
`podman unshare rm -rf …`.

**Don't rebuild an image from the `rootfs-dir` CI artifact.**
`upload-artifact` follows symlinks, so the merged-`/usr` links are lost. Use
`rootfs.ext4` from CI, or build locally.

### Image and kernel

**A change to `image/files/` does not show up.**
`image/files` is copied into the assembly image with `COPY`. `build-image.sh` rebuilds
that image every time; a manual `podman run` does not.

**A kernel option you set is not in `.config`.**
A fragment line whose dependencies are not met is dropped silently. `packages/kernel/build.sh`
compares `.config` with both fragments and fails the build. To clear a symbol that keeps
coming back, clear the symbol that *selects* it.

**A kernel feature is missing at runtime.**
`CONFIG_MODULES=n`, so anything set to `=m` is effectively absent. Everything has to be
`=y`.

**No console on amd64 after editing `vm.config`.**
Never disable `SERIAL_8250`. The fragment is shared between architectures, and the
8250 UART is the amd64 console.

**Lookups fail without an error.**
Every source in `nsswitch.conf` needs a matching `libnss_<name>.so.2` in the image.
Otherwise glibc skips that source without a warning.

**A service is denied by PAM.**
`/etc/pam.d/other` is `pam_deny`. Every PAM service needs its own file;
`pam_warn` logs which service had none.

**`degraded` with "XDG_RUNTIME_DIR is not set".**
`pam.d/systemd-user` is missing `pam_systemd.so`.

**`grep` finds nothing in a binary even though the string is there.**
GNU grep treats ELF files as binary and drops matches on lines with NUL bytes. Use
`grep -a`, or `readelf`.

**Something added late in `build-rootfs.sh` breaks one flavour.**
Code after the OCI subtractions runs on a tree with no systemd in it. Check the flavour
explicitly. A deleted binary shows up as "cannot open shared object file", which looks
like a missing library.

### Tests and CI

**A login test fails with `Login incorrect` although the password is right.**
The password was typed at the wrong prompt. `await` only matches output that arrives
after the mark you pass it; the credentials are not the problem.

**`ping` to an outside host fails in CI.**
qemu user networking only forwards ICMP if the *host* allows unprivileged ICMP sockets.
The test pings `127.0.0.1` for this reason.

**CI serves an old binary for a local-source package.**
The cache key must cover `src/`, and it does. Keep it that way when you change the key.

**A docs-only push gets no CI run.**
`paths-ignore` skips the whole workflow. If checks ever become required, switch to
per-job filters.

**The run page in the browser hangs.**
Every mermaid block in a job summary becomes an iframe, and the page shows all job
summaries together. Keep summaries as text.

**Publishing broke, but the pull request was green.**
`publish-oci` only runs on `main`. Test `tools/publish-oci.sh` by hand against a local
registry (`REGISTRY=`).
