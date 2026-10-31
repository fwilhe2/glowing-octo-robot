# Releases

**Status: proposal.** The repository publishes the OCI image from `main`, but has no
versioned release workflow or downloadable VM image release.

## Proposed release format

Use a calendar date (`YYYY-MM-DD`) as the release version. A second release on the same
day can use a numeric suffix. The date identifies a build; release notes must describe the
changes because the version carries no compatibility promise.

Publish a release only after the full boot checks pass. Do not create a release when the
source commit has not changed since the previous release, and never replace an existing
release asset.

## VM artifacts

The current EROFS image is a filesystem, not a self-booting disk. A downloadable VM release
must include, for each architecture:

- `rootfs.erofs` and its matching `rootfs.cmdline` (the latter carries the dm-verity root
  hash);
- the matching kernel image;
- a SHA256 checksum file.

Publish the exact files and boot command needed for the supported VMMs. The current boot
scripts pass the kernel and command line separately; do not describe the EROFS file alone
as a bootable disk.

## OCI tags

If versioned OCI releases are added, keep `flfs:latest` for the latest stable release and
move the current `main` build behavior to an `edge` tag. Preserve per-commit tags. This
would change the current meaning of `latest`, so document the transition before making it.

## Provenance and source

Release metadata should identify the source commit and the builder and sources image
references used to build it. Include an SBOM and checksums. The pinned package archives and
builder inputs support reconstruction; retain their content-addressed references for as
long as the release is available.

Because the image contains software under copyleft licenses, publish or link the
corresponding source and build materials required by those licenses. Review the exact
obligations for the contents of each release rather than assuming the sources image alone
satisfies every requirement.

## Release notes

Summarize package version changes, significant system changes, known limitations, supported
architectures, and the exact commands to download and boot the artifacts. Include the
source commit and provenance references.

## Implementation notes

The release workflow should be a thin caller of scripts that can be run locally or against
a test registry. Keep release-version generation in one step so tags, image metadata,
asset names, and notes use the same value. `FLFS_VERSION` is supported by image assembly,
but the current CI does not set it for a release.
