# Reproducing builds and patching sources

This page records two proposals: archiving the build recipe as an artifact, and supporting
local patches to upstream sources. Neither feature is implemented. The current build inputs
and package reproducibility check are described below so the proposal does not imply
stronger guarantees than the project provides.

## Current reproducibility

The build pins package source archives by SHA256, pins the Debian builder to a snapshot,
and uses a fixed `SOURCE_DATE_EPOCH`. Image assembly normalizes timestamps and other
metadata. `test/reproducible.sh <package>` builds a package twice from clean worktrees and
compares staged paths, modes, owners, symlink targets, and file contents.

To compare a local package build with a CI artifact for the same commit, use:

```sh
AGAINST_RUN=<github-actions-run-id> ./test/reproducible.sh <package>
```

This verifies only the selected package. It does not establish that every package or image
has been reproduced independently. The normal CI workflow tests image builds and boots;
consult the workflow and reproducibility script for the checks currently run.

## Proposed recipe artifact

The builder and sources images preserve the toolchain and upstream archives. A recipe
artifact could preserve the tracked build scripts and configuration that combine those
inputs. It should be deterministic, identify the source commit, and record whether the
working tree was modified. A digest of the recipe could then be referenced by the image
SBOM.

Keep the recipe separate from the sources image: source archives change when package pins
change, while build scripts can change on every commit. Combining them would either
invalidate the sources cache for unrelated edits or make a content-addressed tag describe
inconsistent contents.

An end-to-end tool could extract the recipe, retrieve its builder and sources images, then
rebuild packages and images. It must report exactly which artifacts and checksums it used.
Until this exists, an image is not independently reconstructible from its OCI reference
alone; the repository commit and build artifacts remain relevant inputs.

## Proposed package patches

There are no local patch sets today. If a package needs a downstream fix, first check
whether an upstream option or version update solves it. A maintained patch should have an
upstream reference, a reason, and an owner; prefer fixes that can be submitted upstream.

A future implementation should keep patches under `packages/<name>/patches/`, apply them
to a fresh source extraction in sorted order, and fail if they do not apply exactly. Patch
files must be included in CI cache keys and SBOM provenance. Applying patches during
extraction avoids ambiguous state between already-patched and unpatched source trees.

The recipe artifact and patch mechanism are related: any recipe archive must include
patches and all other tracked build inputs. Implement these ideas only when users need
them, and update this document to describe the resulting behavior once it exists.
