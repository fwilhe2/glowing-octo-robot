# Reproducing a build: the recipe image, and patches

**Status: nothing here is implemented.** Two changes to the build inputs, written as one
document because they are the same claim from two directions: *everything a build consumes
should be recoverable from the registry, including the parts that are not tarballs.*

Today the registry holds two of the three things a build eats. `sources:<hash>` has every
pinned tarball and `builder:<hash>` has the toolchain — but the third input, the set of
scripts that decides what to do with them, exists only in a git checkout. And there is no
way to feed a package anything other than what upstream shipped, which means the answer to
"upstream has a bug and the fix is four lines" is currently either "wait for a release" or
"don't".

## Part 0: what "reproducible" is being claimed

Worth settling before anything else, because the two readings ask for very different work.

**Bit-identical output is not the claim.** `mkfs.ext4` stamps a fresh UUID and superblock
timestamps into every disk it writes, the OCI config carries a `created` field taken from
`date`, and nothing here passes `SOURCE_DATE_EPOCH` down to the compilers. Getting to
byte-for-byte would be a project of its own and it is not this one.

**Reconstructible is the claim**: given a published artifact and nothing else — no
checkout, no working tree, no memory of what was on `main` that day — a person can recover
every input and run the build again, and what comes out is the same software. That is a
much cheaper property and it is the one that matters when the question is "what is
actually in the image I am running", or "does this old build have the CVE" (issue #91).

One thing the design should still fix in passing, because it is a bug rather than a
trade-off: `image/build-rootfs.sh` honours `SOURCE_DATE_EPOCH` for the SBOM's `created`
field and then ignores it three hundred lines later for the OCI config's, so two builds of
the same tree produce two different image digests for no reason anybody chose.

## Part 1: the recipe image

### What is missing

`packages/<pkg>/build.sh` is where the actual decisions live — `--without-selinux`,
`--buildtype=release`, which perl script to delete out of `DESTDIR`, the fifty systemd
components that are switched off. The tarball says nothing about any of it. So:

- an artifact cannot be traced back to the scripts that made it. `flfs:<commit>` names a
  commit, which is a pointer into a repository that may be rewritten, made private, or
  deleted. A digest is a claim about bytes; a commit is a claim about a service.
- `sources:<hash>` is described in `docs/build-container.md` as "the copy of upstream that
  outlives upstream". It half is. The tarballs outlive upstream; the knowledge of how to
  build them does not.
- the SBOM stops one level short. It records what went in and what compiled it — including
  `FLFS_BUILDER`, on the grounds that "same package, same source, different compiler is a
  different artifact". Same package, same source, same compiler, *different configure
  flags* is also a different artifact, and that one is unrecorded.

### The artifact

A third image, alongside the two that exist:

| artifact | contents | architecture | changes when |
| --- | --- | --- | --- |
| `builder:<hash>` | `debian:sid` + every build dependency | per-arch | `builder/` changes |
| `sources:<hash>` | every pinned tarball, `FROM scratch` | one list, both arches | any package's `VERSION`/`SHA256` changes |
| **`recipe:<hash>`** | **this repository's tracked files, `FROM scratch`** | **one list, both arches** | **any tracked file changes** |

It is small in a way that makes most of the usual objections evaporate: 136 tracked files,
625 KB as a tar and 175 KB gzipped. The tarballs it describes are two and a half thousand
times that.

Contents are `git ls-files` from the *working tree* rather than `git archive HEAD`, plus a
generated `PROVENANCE` naming the commit and whether the tree was dirty. Archiving `HEAD`
would be the tidier choice and it would also be a lie in the one case that matters: a local
build from uncommitted edits is exactly the build nobody can otherwise reconstruct. Record
what was on disk, and say honestly that it was not a commit.

The tar has to be deterministic or the tag is not a content hash —
`--sort=name --format=pax --numeric-owner --owner=0 --group=0 --mtime=@0`, which is the
same normalisation `image/build-rootfs.sh` already applies to the OCI layer, for the same
reason. `PROVENANCE` carries the commit and the dirty flag and no timestamp; a build at the
same commit an hour later is the same recipe and should hash to the same thing.

### Why not inside the sources image

The request that started this was "the sources image should also contain a snapshot of the
repo". Same idea; adjacent image rather than the same one, and the reason is specific
rather than aesthetic.

**Sharing the tag would break the fetch path.** `tools/prep.sh` is pull-then-build-on-miss,
and its miss branch runs `tools/fetch-sources.sh`, which downloads every tarball from
upstream. In CI, where `downloads/` starts empty, a miss is 450 MB pulled from a dozen
upstreams over a flaky internet — the precise event the sources image exists to prevent. If
the sources tag included the repo, every commit would be a miss, and every CI run would
re-fetch every tarball. The registry would deduplicate the *push* (the tarball layer is
unchanged and its blob already exists), so this is not about storage; it is that the
fetch-on-miss path is what makes the tag a *cache*, and a cache that misses on every commit
is not one.

**Keeping the tag over tarballs only and adding the layer anyway is worse**, and this is
the option to reject loudest, because it looks free. The tag would then describe part of
the image. Two different commits with the same package versions produce two different
images under one tag, `prep.sh` serves whichever one exists, and the recipe you extract is
whichever commit happened to build that tarball set first — usually not yours, and never
detectably so. A silent wrong answer to "what built this" is worse than no answer.

Two axes, two artifacts, exactly the argument `docs/build-container.md` already makes for
splitting the builder from the sources: the tarballs change per version bump and the
recipe changes per commit, and neither should invalidate the other.

### Shipping it inside the image

The archive is 175 KB against a ~100 MiB image — less than the terminfo entries that were
deliberately kept. **Ship it, at `usr/share/flfs/recipe.tar.gz`, in both flavours.**

The trim's bar is "nothing in the image can reach the file", and by that reading a recipe
tarball goes out with the man pages. But `usr/share/flfs/sbom.json` already sits there
under the same objection and survives it, because both files are the artifact describing
itself, and an image that can be asked what it is without a network is worth 175 KB. The
alternative — a digest in the SBOM and the bytes only in the registry — makes the honest
answer "reconstructible, if ghcr.io is up", which is weaker than this project's other
guarantees.

Either way the SBOM gains the reference, which is where a consumer will look first:

```json
{ "SPDXID": "SPDXRef-Recipe", "name": "flfs-recipe",
  "versionInfo": "<commit>", "downloadLocation": "ghcr.io/.../recipe:<hash>",
  "checksums": [ { "algorithm": "SHA256", "checksumValue": "<hash of the tar>" } ] }
```

with `{ "spdxElementId": "SPDXRef-Recipe", "relationshipType": "GENERATED_FROM",
"relatedSpdxElement": "SPDXRef-Image" }` reversed appropriately — SPDX's
`GENERATED_FROM`/`GENERATES` pair is what says "this image came out of that source", and it
is the relationship the document is currently missing.

### The plumbing

Small, and mostly in files that already do this job for two images:

- `tools/image-tags.sh recipe` — prints `$REGISTRY/recipe:<sha256 of the tar, 16 chars>`.
  Building the tar to compute the tag is a few hundred milliseconds on 136 files; the
  alternative (hashing the file list and contents directly) is a second implementation of
  the same hash that has to agree with the first one forever.
- `tools/prep.sh [--push] recipe` — the existing `want` parameter gains a third value, and
  the existing `have`/`pull`/build ladder covers it unchanged.
- **CI: a step in the existing `sources` job, not a job of its own.** It is architecture-
  independent, it needs the same ghcr login, and it takes a second. The workflow is 77 jobs
  and the run summary page is already something this repository has had to work around;
  adding a 78th to push 175 KB would be a poor trade.
- `image/build-rootfs.sh` writes the SPDX entry and, with the archive mounted in, the file
  at `usr/share/flfs/recipe.tar.gz`.

### Reproducing, end to end

The payoff, and the thing to check the design against. Starting from an image reference and
nothing else:

```sh
# 1. What is in it, and what made it.
podman run --rm ghcr.io/.../flfs:<commit> cat /usr/share/flfs/sbom.json > sbom.json
#    → every package with version, URL and SHA256; the builder reference; the recipe reference.

# 2. The recipe.
podman create --name r ghcr.io/.../recipe:<hash> /nonexistent
podman cp r:/recipe.tar.gz - | tar xz && cd recipe

# 3. Everything else follows from it: the checkout knows its own tags.
./tools/prep.sh          # pulls builder:<hash> and sources:<hash>, unpacks downloads/
./build.sh glibc && for p in packages/*/; do ./build.sh "$(basename "$p")"; done
```

Step 3 is issue #74 — "a one-command build" — arriving from a different direction, and the
two should land as one thing rather than two scripts that both almost do it.

### What is still not reproducible

Stated plainly, so nobody reads more into the word than is there:

- **`FROM debian:sid` is unpinned.** The builder tag is a hash of `builder/`, not of what
  apt resolved that morning, so an old `builder:<hash>` that is still in the registry can
  be pulled and reused, but rebuilding it from scratch produces a different toolchain.
  This is phase 4 of `docs/build-container.md` and it is the largest remaining hole.
- **Timestamps and ordering.** The ext4 UUID, the OCI `created` field, `ldconfig`'s cache,
  and anything a parallel `make` orders differently.
- **The runner.** `nproc` changes what `make -j` does, and a compiler is allowed to care.

None of these stop a rebuild from producing working, equivalent software. All of them stop
the digests from matching, which is why the claim at the top of this document is worded the
way it is.

## Part 2: patching a package

### Policy, before mechanism

There is no patch in this repository today and no pending need for one. The mechanism is
worth having anyway — the alternative when the need arrives is a rushed decision under
pressure — but it should arrive with the bar written down, because a patch directory is
where a build system goes to accumulate debt:

- **A patch is a fork, and it has an owner.** Every patch is code this project now
  maintains against a moving upstream. `tools/check-updates.sh` exists because staying
  current is a goal here; a patch is a small tax on every future bump of that package.
- **Configure it out first.** The same instinct that `CLAUDE.md` applies to
  `builder/deps.txt` applies here: a `--without-x` is a line in a diff that upstream
  already supports, a patch is a line upstream has never seen.
- **Upstream it, and say where.** A patch whose header links a merge request has a
  scheduled end. One that does not is permanent by default.
- **Not for features.** Backporting a fix, unbreaking a build against a newer glibc or
  kernel header, removing something that cannot be configured out — yes. Changing what a
  package does, so that this image behaves unlike every other distribution's copy of it —
  no. That is a surprise waiting for whoever debugs it in five years.

So every patch carries a header, and a check enforces it:

```
Subject: [PATCH] iproute2: do not link ss against libselinux
Origin: backport, https://git.kernel.org/.../commit/?id=abc123
Upstream: https://lore.kernel.org/netdev/...
Reason: libselinux is in deps.txt's deliberately-absent list; configure has no
        --without-selinux, and libblkid drags it in. See CLAUDE.md.
Last-checked: 2026-08-11 against iproute2 6.19
```

`Origin` and `Reason` required, `Upstream` required unless `Origin: this-project`,
`Last-checked` so a stale patch is visible as stale. `test/check-patches.sh` verifies the
headers and that every patch file is referenced by nothing but its own directory — a
one-file check in the same shape as `test/check-licenses.sh`.

### Layout

```
packages/iproute2/
  env.sh
  build.sh
  patches/
    0001-do-not-link-ss-against-libselinux.patch
    0002-....patch
```

Applied in `LC_ALL=C` sorted order, hence the numeric prefix. `-p1`, because that is what
every tool that produces a patch emits. No series file: the directory listing is the
series, and a second place to write the order down is a second place for it to be wrong.

`LOCAL_SOURCE=1` and `patches/` together are an error — the source is in git, so edit it.

### Where they are applied

**At extraction, before the tree is moved into place**, inside `build.sh`'s existing
`.extracting` dance:

```sh
staging="$PKG_DIR/.extracting"
tar -xf "downloads/$TARBALL" -C "$staging" --strip-components=1
apply_patches "$staging"          # ← here
mv "$staging" "$PKG_DIR/$PACKAGE"
```

This buys the idempotency for free, and it is the same trick the extraction already uses
for a different reason. `build.sh` skips extraction when `packages/<pkg>/<PACKAGE>/`
exists, so patching anywhere later would have to answer "has this tree already been
patched?" with a stamp file, a `patch --dry-run` probe, or a re-extract. Applying before
the atomic `mv` makes the invariant structural instead: **the extracted directory exists
if and only if it is fully extracted and fully patched**, and an interrupted or failed
patch leaves `.extracting` behind, which the next run deletes.

`apply_patches` runs `patch` **in the builder container**, not on the host:

```sh
podman run --rm --network=none \
    --volume "$PWD/$staging":/src \
    --volume "$PWD/$PKG_DIR/patches":/patches:ro \
    "$BUILDER" sh -c 'cd /src && for p in /patches/*.patch; do
        printf ">> applying %s\n" "${p##*/}"
        patch -p1 --batch --forward --fuzz=0 < "$p" || exit 1
    done'
```

`patch` is already in `builder/deps.txt`, so this costs nothing but one container start,
and only for a package that has patches. The alternative — `patch` on the host — is two
lines shorter and adds the first new host dependency since podman; if that trade is
preferred later, nothing else in this design changes.

`--fuzz=0` and no `--force`: a patch that does not apply exactly is a patch that needs
rewriting against the new upstream, and `set -e` turns that into a failed build with the
patch named. Fuzzy application is how a version bump silently half-applies a fix.

**The trap, which belongs in `CLAUDE.md` when this lands:** editing a patch does not
rebuild anything, because the extracted tree already exists and is skipped. The fix is
`rm -rf packages/<pkg>/<PACKAGE>` — the same shape as the note about `rootfs/` being
cumulative, and it will bite exactly once per person.

### The four places that assume a package is unmodified

Same table as `LOCAL_SOURCE` in `CLAUDE.md`, and for the same reason — a flag that changes
what a build *is* has to be threaded through everything that describes a build:

| file | what changes |
| --- | --- |
| `.github/actions/build-package` | **the cache key must hash `$PKG/patches`.** Without it, editing a patch changes nothing that the key sees — `env.sh` and `build.sh` are both untouched — and CI serves the previous build's binary. Precisely the bug `$PKG/src` was added to the key to prevent. |
| `build.sh` → `builder/build-package.sh` | a `FLFS_PATCHES` env carrying `name:sha256` per patch, written into the component record beside the pins. |
| `image/build-rootfs.sh` | the SBOM gains `"sourceInfo": "Patched with N local patches: 0001-…(sha256:…)"` on that package. A patched package is not the tarball it names, and an SBOM that says otherwise is worse than one that says nothing. `packageVerificationCode` would be the more formal answer and needs a file-level document to hang off; `sourceInfo` is free text and honest. |
| `tools/bump-version.sh` | print a warning when the package has patches. A bump is exactly when they stop applying, and the failure otherwise surfaces two jobs later as a build error with no mention of patches. `tools/check-updates.sh` should flag them in its listing for the same reason. |

And the tie back to Part 1: **patches are tracked files, so they are in the recipe image**,
which is what keeps "recover every input from the registry" true after this lands. A patch
mechanism without the recipe would put a build input in exactly one place — a git checkout
— which is the hole Part 1 is closing.

## Migration

Independently useful, independently revertible, in this order:

1. **The recipe image.** `tools/image-tags.sh recipe`, `tools/prep.sh recipe`, a step in
   the `sources` job. Nothing consumes it yet; it is already the archival copy.
2. **Wire it into the SBOM and the image.** `SPDXRef-Recipe` plus
   `usr/share/flfs/recipe.tar.gz`, and fix the OCI config's `created` to honour
   `SOURCE_DATE_EPOCH` while in there. `test/check-sbom.sh` gains an assertion that the
   recipe reference exists — same posture as every other field it checks.
3. **Patches: mechanism and check.** `packages/<pkg>/patches/`, the extraction-time
   application, `test/check-patches.sh`, and the cache key. Landing with no patches in the
   tree is fine and is the point — the mechanism is tested by the check and by a patch
   added and reverted in the same pull request.
4. **The reproduce path**, with issue #74: one script that goes from an image reference to
   a rebuilt image.

## Trade-offs and open questions

- **A third image is a third thing to keep alive.** All three are reproducible from the
  repository, which is the real mitigation, but the same "no untagged-cleanup policy may
  reap these" caution from `docs/build-container.md` now covers one more.
- **`recipe:<hash>` accumulates a tag per commit.** Blobs deduplicate and 175 KB is
  nothing, but ghcr will end up with hundreds of tags. Worth deciding whether untagged
  cleanup is configured before that is a thousand, and worth noting that this is exactly
  the growth the sources image is being kept away from.
- **The dirty-tree case is a policy question, not just a mechanism.** Recording
  `dirty=true` is honest; the alternative is refusing to build. Refusing is defensible for
  CI (where it can never happen) and hostile locally (where it is the normal state of
  someone working). Recommendation: record it, and have the *release* workflow refuse.
- **Nothing yet verifies that the recipe reproduces anything.** The check that would —
  rebuild from the published recipe and diff the assembled tree — is a full CI run's worth
  of compute and probably belongs on a schedule rather than on every push, if it belongs
  anywhere. Until it exists this is a well-founded belief rather than a tested property,
  which is worth saying out loud in the README when it lands.
- **A patch mechanism invites patches.** The honest cost of adding it is that "just patch
  it" becomes an available answer to problems whose right answer is a configure flag or a
  version bump. The header requirement and the review bar above are the whole mitigation,
  and they are social rather than mechanical.
