# How the build works

The build has three stages: prepare pinned inputs, compile packages offline, and assemble
images. CI runs package builds in parallel; a local full build compiles them sequentially.

```text
packages/*/env.sh + builder/deps.txt
                 │
                 ▼
        tools/prep.sh ──► builder + sources images
                 │
                 ▼
          package builds ──► staging/<package>/
                 │
                 ▼
       tools/merge-staging.sh ──► rootfs/ + extensions/
                 │
                 ▼
        image/build-rootfs.sh ──► EROFS + OCI images
```

## Prepare inputs

`tools/prep.sh` ensures the builder and sources images are available. Their tags are
content-addressed by `tools/image-tags.sh`. The builder contains a pinned Debian snapshot
and the reviewed dependencies in `builder/deps.txt`. The sources image contains package
archives pinned by SHA256 in `packages/<name>/env.sh`.

Preparation may use the network. `tools/fetch-sources.sh` verifies each archive before
accepting it. `FRESH=1 ./tools/prep.sh` rebuilds the inputs instead of reusing cached
images.

## Build packages

Run `./build.sh <package>` to build one package. The script loads its `env.sh`, prepares
inputs, extracts the source if needed, and runs `packages/<name>/build.sh` in the builder
with networking disabled. `builder/build-package.sh` provides compiler and install helpers
and records package metadata for the SBOM.

Each package installs into its own tree under `staging/`. Packages normally target
`staging/<name>/rootfs`; packages with `EXTENSION=<name>` target
`staging/<name>/extensions/<name>`. The glibc staging tree is the sysroot. Other libraries
come from the builder's development packages and are checked against the runtime image.
See [Linking](linking.md) for the ABI model and its limits.

`tools/merge-staging.sh` rebuilds `rootfs/` and `extensions/` from the package trees. It
fails if multiple packages install the same path. Do not edit these merged trees by hand;
the next merge replaces them.

## Assemble images

`tools/build-image.sh` builds packages, merges their staging trees, and runs
`image/build-rootfs.sh` in the pinned image-assembly container. Use
`./tools/build-image.sh --image-only` to skip package builds and reassemble the existing
merged trees. Before assembling, it runs `test/check-rootfs-deps.sh rootfs` and stops on an
unresolved library, as CI's `rootfs` job does; `--allow-unresolved` downgrades that to a
warning for exploring a partial tree, and is never used in CI.

Assembly copies `rootfs/`, adds files from `image/files/`, trims build-only files, generates
configuration and SBOM data, then writes the requested image format:

- `erofs`: `output/rootfs.erofs` and `output/rootfs.cmdline`. The EROFS root and dm-verity
  tree share a file; the command line contains the root hash.
- `oci`: `output/flfs-oci.tar`, an OCI archive of userspace without the kernel or systemd.
  `./test/oci-trim.sh` reports what it leaves out of the disk image, by area, and runs the
  shared-library check on its layer to show nothing left behind needs what was removed.

Staged extensions are assembled into `output/extensions/` and `output/confexts/`.
With `--extra DIR` (never in CI), files from that directory are added to both image formats
after the trim. The overlay is additive only and refuses security-sensitive paths, setuid
files and file capabilities; the paths it adds are printed, written to
`output/extra-files-<flavour>.txt`, and recorded in the SBOM as `SPDXRef-LocalExtra`.

## Checks and CI

CI prepares the inputs, builds glibc and the kernel, builds package artifacts for each
architecture, merges them, assembles both image formats, and runs static and boot checks.
Every push runs the workflow. A push that changes only `docs/**` or root `*.md` files skips
the image build and gets the `docs` job, which checks that relative links resolve; the
`result` job reports one status for either case and is the check to require in branch
protection.
The main branch also publishes the OCI image. A scheduled fresh build checks that pinned
inputs can still be fetched and rebuilt.

Checks cover package licenses, shared-library dependencies and symbols, kernel options,
image contents and size, reproducibility, real boots, networking, SSH, containers, and
extensions. Individual scripts live in `test/`; for example:

```sh
./test/podman.sh output/rootfs.erofs rootfs/boot/bzImage
```

## Common build issues

- **Missing shared library at runtime:** disable the optional build feature that found the
  library in the builder. Do not add the library just to satisfy an accidental link.
- **Missing symbol or `GLIBC_2.*` version:** preserve the sysroot flags when overriding
  compiler flags. The symbol checks catch these cases.
- **Stale staged files:** package staging is replaced on rebuild, but a stale unpacked
  source tree may remain. `tools/clean.sh` removes rebuildable output; use
  `tools/bump-version.sh` for package version changes.
- **Container-owned files cannot be removed:** use `podman unshare rm -rf <path>` for files
  created by the build containers.

See [Build inputs](build-container.md), [Debugging](debugging.md), and the
[build reproduction proposal](../proposals/reproducing-a-build.md) for related details.
