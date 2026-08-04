# One builder image, vendored sources

**Status: phases 1-3 implemented, phase 4 not.** The two artifacts, the checksums, the
single builder image and the `--network=none` build all exist. Still open: pinning
`debian:sid` to a snapshot, and trimming `builder/deps.txt` further now that it is a list
somebody can actually read.

The idea is to split a build into two phases with a hard line between them: **prep**,
which is allowed to touch the network and produces two OCI artifacts, and **build**, which
gets those artifacts and nothing else.

## What was wrong with the model this replaced

Three separate problems, which happened to have one shared answer.

**The same apt work happened 46 times.** There are 23 packages and two architectures, so a
CI run is 46 build jobs. Each one ran `builder/base.sh`, which built `debian:sid` plus a
~40-package toolchain layer, and then `builder/package.Containerfile`, which ran
`apt-get update` and `apt build-dep`. Nothing was shared between jobs, so that was 46 full
toolchain installs per run. For most packages it dwarfs the compile. The `base` job in
`ci.yml` is a stub (`run: echo todo`) with `podman save` and `upload-artifact` commented
out underneath — an earlier attempt at this problem that stopped at passing the image
around as a CI artifact.

**Nothing verifies what was downloaded.** `build.sh` runs `wget -q -O` with no checksum,
no retry and no mirror. A truncated tarball becomes a confusing compile error somewhere
else, and there is no way to tell a corrupted download from a hostile one. The network is
also not reliable enough to assume a single attempt at a single URL works.

**A build is not reproducible, in two independent ways.** `downloads/` is gitignored and
upstream tarballs move or disappear, so an old commit can become unbuildable through no
fault of its own. And `apt build-dep` resolves against whatever sid says today, so even
with the sources in hand the *builder* cannot be reconstructed.

## Shape: two artifacts, not one

Prep produces two things, published to GitHub Container Registry:

| artifact | contents | architecture | changes when |
| --- | --- | --- | --- |
| `ghcr.io/fwilhe2/glowing-octo-robot/builder:<hash>` | `debian:sid` + every build dependency | per-arch, joined by a manifest list | a dependency list or the base image moves |
| `ghcr.io/fwilhe2/glowing-octo-robot/sources:<hash>` | every pinned tarball, `FROM scratch` | architecture-independent | any package's `VERSION` changes |

They are two artifacts rather than one because they differ on both axes that matter. The
toolchain is architecture-specific and the tarballs are not, so baking the sources into
the builder would store the 152 MB kernel tarball once per architecture. And they change
at different rates: a systemd bump would invalidate a multi-gigabyte toolchain image it
has nothing to do with.

Consuming them needs no tooling that is not already here. For a build, mount the sources
image directly:

```sh
podman run --mount type=image,source=ghcr.io/…/sources:<hash>,destination=/sources,ro …
```

To populate `downloads/` locally from it, `podman create` a container from the image and
`podman cp` out of it — a `FROM scratch` image never has to run for that to work.

## The invariant

Only prep may touch the network. The build step runs:

```sh
podman run --network=none …
```

This is the point of the whole exercise, not a detail of it. "We vendored the sources" is
a claim; a build container with no network is a guarantee. Today a `build.sh` could reach
out to the internet mid-compile and nobody would notice until the day it failed.

## Sources: checksums first

Each `packages/<pkg>/env.sh` gains:

```sh
SHA256="…"
MIRRORS="https://…"   # optional, space separated, tried after $URL
```

`tools/fetch-sources.sh [pkg...]` replaces the `wget` inlined in `build.sh`. Per package:

1. If `downloads/$TARBALL` exists and matches `$SHA256`, done.
2. Otherwise try, in order: the `sources` image from ghcr, then `$URL`, then `$MIRRORS`,
   then an archival fallback (Software Heritage, archive.org).
3. Each attempt uses `curl --retry 5 --retry-all-errors --retry-delay 2 --continue-at -`.
   Resumable matters more than retryable: the failure mode of a bad link is a transfer
   that dies at 80%, and starting the kernel tarball over from zero is how a flaky
   connection turns into an infinite loop.
4. Verify `$SHA256` after every attempt. **A mismatch is a hard failure, not another
   retry** — that is the wrong file, not a flaky one, and retrying cannot fix it.

The checksums are load-bearing for everything else in this document. They are what makes
a mirror safe to fall back to, what makes a vendored copy trustworthy rather than merely
present, and what makes the `sources` tag deterministic. The initial set can be generated
from the tarballs already in `downloads/`.

## The builder image: list the dependencies, don't resolve them

The single builder image installs one explicit, reviewed dependency list —
`builder/deps.txt` — rather than the union of `apt build-dep` across 23 source packages.

This is a change of substance, not packaging. `apt build-dep systemd` installs whatever
sid's systemd source package asks for on the day it runs; nobody has ever seen that list,
it is different next week, and it is the reason the builder cannot be reconstructed. An
explicit list is a file that can be read, diffed and reviewed in a pull request, and it is
what makes phase 4 (pinning to a snapshot) possible at all.

It also mitigates the real hazard of merging the images. `packages/crun/env.sh` sets
`BUILD_DEP=""` on purpose so that `libseccomp-dev` is *absent* from crun's builder and
crun's `configure` cannot autodetect it. In a union image, any other package's build
dependencies could drag `libseccomp-dev` in and crun would silently link against it — the
"linked against a library only the builder image has" trap in `CLAUDE.md`, made
considerably easier to fall into. With an explicit list, adding that library is a visible
line in a diff rather than a transitive accident.

`test/check-rootfs-deps.sh` remains the safety net, but it should not be the first line of
defence.

## Tags

Both tags are content hashes, computed by one script (`tools/image-tags.sh`) so that CI
and a local checkout agree without coordinating:

- `builder:<hash>` — over `builder/Containerfile`, `builder/deps.txt`, and the base image
  reference.
- `sources:<hash>` — over every package's `VERSION` and `SHA256`.

CI tries `podman pull <tag>` and only builds and pushes on a miss. Only the prep job needs
registry write permission; everything downstream is read-only.

## What a build looks like

Local, unchanged on the surface:

```sh
./build.sh coreutils
```

`build.sh` ensures the sources are present (fetch, or extract from the sources image) and
the builder image is present (pull, or build it), then runs the compile with
`--network=none`. `tools/prep.sh` does the network half on its own, for "get everything
now, I am about to be offline".

In CI:

```
prep (per arch) ──┐
sources ──────────┴─> glibc ─> build matrix ─> rootfs ─> boot
```

The build matrix no longer runs apt at all.

## Migration

Each phase is independently useful and independently revertible. Do them in this order and
CI stays green throughout.

1. **Checksums and `tools/fetch-sources.sh`.** No structural change — `build.sh` calls it
   instead of inlining `wget`. Delivers the download resilience on its own.
2. **Collapse to one builder image**, still built locally and in CI, no registry. This is
   where the union image's exposure surfaces: watch `test/check-rootfs-deps.sh` and diff
   `test/known-missing-libs.txt` across the change, and measure the image size.
3. **Publish both images to ghcr**, have CI pull by hash and build only on a miss, and add
   `--network=none`. Replaces the abandoned `podman save` stub in the `base` job.
4. **Pin `FROM debian:sid` to a `snapshot.debian.org` date.** The builder-side equivalent
   of vendoring sources: without it, rebuilding an old commit still does not reproduce its
   toolchain no matter how well the tarballs are preserved.

Phases 1 and 2 are worth doing even if 3 never happens.

## Trade-offs and open questions

- **The registry becomes a new single point of failure.** Both images are reproducible
  from checksums and a dependency list, which is the real mitigation, but use immutable
  tags and make sure no untagged-cleanup policy can reap them. Attaching a source bundle
  to a GitHub release would give a second copy.
- **`update-packages.yml` needs teaching.** Bumping `VERSION` now also means regenerating
  `SHA256`, and every such pull request invalidates the `sources` tag. Cheap — one layer
  is repushed — but it is no longer a one-line edit.
- **Sources image growth policy is unsettled.** One image per pinned set, or one
  accumulating image holding every version ever built? The second is better insurance
  against upstreams disappearing and costs only storage.
- **Image size is unmeasured.** The union of 23 packages' build dependencies is probably
  low single-digit gigabytes per architecture. Phase 2 is where that number becomes real.
