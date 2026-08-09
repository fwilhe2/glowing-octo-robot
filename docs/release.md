# Cutting a release

**Status: not implemented.** The two pieces it stands on are in flight — #95 teaches a
build to stamp its version into `os-release`, #96 pins both Debian images to a snapshot —
and the workflow itself is not written. This is the design, decided but unbuilt.

Today every commit on `main` publishes `flfs:<commit>` and `flfs:latest` to ghcr and
nothing else. There is no artifact a person can download, nothing that says which build it
is, and no name for "the one you should use".

## What a release is

A CalVer date, `yyyy-mm-dd`. No semantic component, because there is nothing to promise:
this is a rolling build of upstream releases, and a number implying compatibility would be
a claim nobody is making. A second release in one day takes a suffix — `2026-08-09.2`.

The consequence is that **the version says nothing about what changed**, so the release
notes carry the whole load. See below.

## Trigger

**Weekly, scheduled, plus `workflow_dispatch`.** That means nobody reviews a release
before it exists, which raises the bar on everything else here:

- it must be gated on `boot`, not `rootfs` — all four qemu tests, because a release is the
  first artifact a stranger will run;
- it must **decline to cut a release when nothing has changed since the last one**, or the
  project accumulates identical images under different dates. The check is the commit: if
  the previous release's commit is still `HEAD`, stop;
- it must never overwrite a published asset. A re-run of a date that already exists is an
  error, not an update.

## What ships

The disk cannot boot itself. systemd is built `-Dbootloader=disabled -Defi=false
-Dukify=disabled` — "no ESP to install a loader into and nothing to build a UKI for" — so
every boot here is `qemu -kernel bzImage -append "root=/dev/vda …"`. A release of
`rootfs.ext4` alone would be unbootable by anyone. So a release is the pair, per
architecture:

```
flfs-2026-08-09-amd64-rootfs.ext4.zst
flfs-2026-08-09-amd64-bzImage
flfs-2026-08-09-arm64-rootfs.ext4.zst
flfs-2026-08-09-arm64-bzImage
SHA256SUMS
```

as **GitHub Release assets**, not as an OCI artifact. The registry is already wired up and
that is exactly the reason to distrust the instinct: OCI buys content addressing, manifest
lists and a signing story, and a disk image a human downloads once and boots needs a URL.
An OCI *image* whose layer is a disk would be worse than neutral — it would pull like
`flfs:latest` and produce nonsense when run, so the registry would stop describing what it
holds. If a machine ever consumes these as part of a pipeline, revisit with a real OCI
artifact and `oras`, not with an image.

Compressed because `mkfs.ext4 -d … 1G` writes a fixed 1 GiB file holding ~118 MiB on amd64
and ~171 MiB on arm64. Checksummed because this project pins a `SHA256` for every byte it
consumes, across every package; shipping unverifiable output would be out of character.

### The version this wants to be

Give the image a UKI or an ESP and the whole shape improves: one file per architecture,
bootable by any VMM, no kernel argument, no pair to keep in lockstep. systemd already has
the code and it is switched off. Worth doing, and worth not blocking the first release on.

It also removes a wrinkle the current shape has: `bzImage` is the qemu/x86 entry path, and
Firecracker — named in `CLAUDE.md` as the next target — loads an ELF `vmlinux`. As it
stands, "boot a VM from these" means "boot qemu from these".

## Container tags

| tag | means |
| --- | --- |
| `flfs:2026-08-09` | that release |
| `flfs:latest` | the newest release |
| `flfs:edge` | tip of `main` |

`latest` moving is a deliberate break: today it is the last commit on `main`, and anyone
pulling it gets unreviewed tip. `edge` is where that behaviour goes. Per-arch and
per-commit tags are unchanged.

## Version information in the image

From #95. `image/build-rootfs.sh` reads two variables and writes nothing when they are
absent, so a local build and a PR build are unversioned, which is the honest answer:

- `FLFS_VERSION` — the CalVer date. Set **only** by this workflow. Fills `VERSION`,
  `VERSION_ID`, and folds into `PRETTY_NAME`.
- `FLFS_BUILD` — the commit. Set by ordinary CI too, fills `BUILD_ID`.

## Reproducibility, and the source obligation

Two things that are cheap here and awkward to retrofit.

**Corresponding source.** Distributing binaries built from GPL-2 and GPL-3 sources to the
public triggers the corresponding-source requirement. It has been moot while nothing was
released. The answer already exists: `tools/prep.sh` vendors every tarball into
`ghcr.io/…/sources`, described in `ci.yml` as "the copy of upstream that outlives
upstream". **Pin that image's digest in the release notes** and the obligation is
discharged against an artifact that is already published, already content-addressed, and
already what the build actually consumed.

**Rebuildability.** With #96 the toolchain is pinned to a Debian snapshot, so a release
records everything needed to reconstruct itself: sources (pinned and hashed per package),
toolchain (pinned by snapshot date and digest), instructions (git). The release notes
should name the builder and sources image digests for the same reason.

Add `actions/attest-build-provenance`. It is free, it is one step, and it fits a project
whose entire discipline is verifying bytes.

## Release notes

CalVer carries no signal, so the notes are the only place a reader learns what happened.
The most useful content is not a commit log:

- **which packages changed version since the previous release** — every version is one
  line in an `env.sh`, so this is a cheap diff and it is what anyone actually wants to
  know;
- the commit range, for people who want it;
- the builder and sources image digests, per above;
- the exact `qemu-system-*` line to boot the assets, matching what shipped.

## Testing the untestable

`publish-oci` is gated to `main` and so cannot be exercised by a pull request — `CLAUDE.md`
already flags this. A release workflow inherits the same blind spot and is worse, being
user-facing and unattended. It wants what `tools/publish-oci.sh` already has: the logic in
a script, taking `REGISTRY=` and a dry-run switch, so it can be run against a local
registry by hand. The workflow should be a thin caller.

## Still open

- Where the version number is computed. The workflow can take today's date, but the tag,
  the assets, `os-release` and the notes must all agree, so one step should emit it and
  everything else consume it.
- Whether the disk image should stay a fixed 1 GiB, or be sized to content with
  instructions to grow it.
- Whether an SBOM (#75) ships as a release asset. A release is the moment an SBOM is
  worth most, and #91 (CVE monitoring) would consume it.
- Whether bumping the Debian snapshot date should ride along with
  `.github/workflows/update-packages.yml` rather than being a hand edit.
