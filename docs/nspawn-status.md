# nspawn: status (parked 2026-10-11)

Work on branch `nspawn`, draft PR #165. Parked, not abandoned. This file says where it
stopped and what is next. Delete it, or fold the useful parts into README/CLAUDE.md,
when the branch is merged.

## Goal

Run [nspawn](https://github.com/nspawn/nspawn) machines inside the disk image. nspawn is
Docker-like management of systemd-nspawn machines: images come from an OCI registry, and
a root service on the system bus does the work.

## What is on the branch

Commit 1, "nspawn: the first Rust package, without libgcc_s":

- `packages/nspawn`: nspawn 1.9.1. The binary links only libc and libm.
- `builder/deps.txt`: `rustc` and `cargo` from Debian, at 1.95.0, the version the
  builder's pinned snapshot (20260918) has.
- `CARGO_CRATES=1` in a package's `env.sh`:
  - `tools/fetch-sources.sh` reads `Cargo.lock` out of the verified tarball and fetches
    each crate from static.crates.io into `downloads/crates/`, checking each against the
    lock's sha256.
  - `tools/prep.sh` vendors those crates into the sources image.
  - root `build.sh` mounts them read-only at `/usr/local/crates`.
- `cargo_build` in `builder/build-package.sh`:
  - builds offline from a vendored source;
  - passes the sysroot `LDFLAGS` as `-C link-arg` (rustc ignores `LDFLAGS`);
  - makes `-lgcc_s` resolve to a linker script that pulls in gcc's static unwinder, then
    fails the build if any binary still needs `libgcc_s.so.1`.
- The OCI flavour subtracts nspawn: there is no systemd in a container, and at 22 MiB it
  would put the image past debian-slim.
- `Unicode-3.0` is on the DFSG list. nspawn's `LICENSE=` covers every crate compiled in.

Commit 2, "Run nspawn machines: machined, systemd-nspawn, nftables":

- systemd: `-Dmachined=true -Dnspawn=enabled`. importd, vmspawn and nss-mymachines stay
  off.
- New packages `nftables` 1.1.7 and `libnftnl` 1.3.2, for the `nspawn0` bridge NAT, with
  every optional dependency off. `libnftnl-dev` is added to deps.txt.
- Kernel `container.config`: `NFT_CT`, `NFT_FIB`, `NFT_FIB_IPV4`. `test/kernel-caps.sh`
  now requires them, along with `NFT_NAT` and `NFT_MASQ`.
- `test/nspawn.sh`, run in CI's `boot` job. It drives the guest over ssh, not the serial
  console, in three rounds:
  - `nspawn ps` reaches machined;
  - `nspawn run` starts the published flfs image as a machine named `smoke`;
  - `curl` inside a machine returns HTTP 200 over the bridge.

## Verified

Locally, on amd64, in an image assembled from CI's package artifacts plus local builds of
nspawn, nftables, libnftnl, systemd and the kernel:

- **Pass:** `test/nspawn.sh`, `systemd.sh`, `container.sh`, `ssh.sh`, `network.sh`,
  `oci.sh`.
- **Clean:** `kernel-caps.sh`, `check-rootfs-deps.sh`, `check-symbol-versions.sh`,
  `check-licenses.sh`, `check-sbom.sh`.
- **Sizes:** amd64 ext4 is 119.3 of 126 MiB (94%); OCI is 60.0 of 96 MiB.

## CI state (run 38068258865)

Every job passes except `build (arm64, nspawn)`. That failure skips `rootfs`, `boot` and
`publish-oci`, so nothing has booted in CI yet, on either architecture.

The arm64 failure:

```
libgcc_eh.a(unwind-dw2-fde-dip.o): in function `version_lock_unlock_exclusive':
undefined reference to `__aarch64_swp8_acq_rel'
```

On aarch64, gcc builds its unwinder with outline atomics, and the `__aarch64_*` helpers
are in `libgcc.a`. rustc links with `-nodefaultlibs`, so nothing adds `libgcc.a` after
`libgcc_eh.a`. amd64 has no such helpers, which is why it links.

## Next steps

1. **Fix arm64.** In `cargo_build`, make the linker script `INPUT(-lgcc_eh -lgcc)` (or
   `GROUP(...)`). Update the comments in `builder/build-package.sh`, CLAUDE.md
   ("Rust packages") and the README snippet, which tells people to use the one-library
   form. Expect it to fail first on the build scripts (`quote`, `proc-macro2`, `serde`):
   they are linked the same way, and they are what failed in CI.
2. **Get a green CI run.** That gives the first arm64 boot of all of this, and the first
   measured arm64 ext4 size. The estimate is about 162 MiB against a 186 MiB ceiling.
3. **Decide on the OCI image's entrypoint.** It is `Entrypoint: ["/bin/bash"]`, so
   `podman run flfs echo hi`, and `nspawn run flfs -- echo hi`, run `bash echo hi`, which
   exits 126. `Cmd: ["/bin/bash"]` would make the usual form work. That changes the
   published image, so it needs its own commit, and `test/nspawn.sh` would then drop its
   `-c '...'` wrappers.
4. **Make room under the size ceiling.** amd64 ext4 is at 94%, and nspawn is 22 MiB of
   that. The options are `opt-level = "s"` in `cargo_build`, or dropping nspawn features
   this image does not need. That needs a look at nspawn's Cargo features; sigstore and
   aws-lc are the large parts.

## Known gaps, not blocking

- **SBOM:** it records nspawn's source tarball but not the crates compiled into it.
- **OCI SBOM (existing bug):** it lists packages that the container subtractions delete:
  kernel, kmod, pam, and now nspawn.
- **No polkit:** only root can call the nspawn service. nspawn allows root without
  asking polkit.
- **`test/oci.sh` run locally:** its `BUILD_ID` check fails unless `FLFS_BUILD` is
  exported, because `tools/build-image.sh` stamps the commit and CI exports
  `FLFS_BUILD`. That is how the test is invoked, not a defect in the image.
