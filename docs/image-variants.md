# Image variants: one build, many images

**Status: steps 1–3 of the migration below are implemented; 4–6 are not.** Per-package
manifests, the variant/platform files and their parser, the `full`/`net`/`minimal` variants
on the `ext4` and `oci` platforms, the per-image dependency check and the CI loop and boot
matrix are all in the tree. The `lima` and `firecracker` platforms, the `container-host`
and `k8s-node` variants and everything in the "lima variant" section below are still
design — nothing there is built, and the packages it names (openssh, sudo, sshfs, fuse3,
tzdata) do not exist here.

What landed differs from the sketch below in two places worth knowing about, both noted at
the point they come up: the `oci` platform has to name PAM's *consumers* by hand, because
`login`, `su` and `runuser` are util-linux's files rather than pam's; and the dangling
symlink sweep survives as a scoped pass rather than disappearing, because `/etc/resolv.conf`
is a deliberate dangling symlink that a tree-wide sweep would delete.

This document is the design for turning one hard-coded special case into a general one:
several images, declared rather than coded, differing both in *what they run on* and *what
is in them*.

The rule the whole design hangs on, stated first because everything else is downstream of
it: **the package build stage never learns about variants.** Every package is compiled once
per architecture into the same staging tree, exactly as today. A variant is a *selection
from* that tree, resolved at assembly time. That is what keeps 36 packages × 2 arches from
becoming 36 × 2 × N jobs, and it is the answer to "take care of pipeline complexity": the
cost of a new variant is paid in the image and boot stages only.

## What is wrong today

**There is one image, and it is the union of everything.** Someone who wants a machine that
boots to a shell gets OpenSSL, curl, a CA bundle and an OCI runtime as well, because there
is no way to ask for less. The project's own framing — "the image should be small because
nothing unnecessary was added" — has no mechanism behind it: nothing is unnecessary if
there is only one image and everything is for somebody.

**The container flavour is a special case in code.** The subtractions block in
`build-rootfs.sh` is 70 lines of careful, well-commented deletion that reconstructs, by
hand, the fact that the kernel and systemd should never have been selected. It works, and
it is the only such block that will ever be written by hand — a second one for `minimal`
and a third for `k8s` would each have their own version of the `readelf` sweep, the
dangling-symlink pass and the "which /etc does this need" judgement.

**Two different axes share one word.** `ext4` and `oci` differ in *format* (a filesystem
versus a tar of blobs) and, incidentally, in *content* (a container has no kernel). A
firecracker image would be the same content as `ext4` in a different launch shape; a
`minimal` image is the same shape as `ext4` with different content. One parameter cannot
carry both without becoming a list of every combination somebody wanted.

**Nothing checks a subset.** `test/check-rootfs-deps.sh` runs over the staging tree, which
has everything in it, so it can only ever answer "does the superset resolve". A variant
that drops `libmnl` and keeps `ip` is broken in a way nothing in CI can currently see —
the same shape as the allowlisted-library trap in `CLAUDE.md`, where the first sign was
`ip` not starting in qemu.

## The two axes

A **variant** is a feature set: which packages are in the image, and the `/etc` that goes
with them. A **platform** is what the assembled tree is turned into and what that target
does not need. An image is one of each, per architecture.

| variant | what it is for | packages | platforms |
| --- | --- | --- | --- |
| `minimal` | boots to a login shell on the serial console and nothing else | glibc, bash, coreutils, util-linux, systemd and what it needs | `ext4`, `oci` |
| `net` | a machine somebody can debug: addressing, DNS, TLS, `ip`/`ping`/`curl` | minimal + iproute2, iputils, libmnl, openssl, ca-certificates, curl | `ext4`, `oci` |
| `full` | everything this repository builds — today's image, unchanged | all of them | `ext4`, `oci` |
| `lima` | a VM somebody actually works in, via `limactl start` — see below | net + openssh, sudo, sshfs, fuse3 | `lima` |
| `container-host` *(later)* | runs OCI containers: crun and the tooling of `docs/container-runtime.md` | net + crun, json-c, … | `ext4` |
| `k8s-node` *(later)* | issue #83, once that question has an answer | container-host + … | `ext4` |

| platform | artifact | what it subtracts |
| --- | --- | --- |
| `ext4` | `rootfs.ext4` via `mkfs.ext4 -d`, booted by qemu with `-kernel` | nothing |
| `oci` | a hand-written OCI archive | the kernel, systemd, the `/etc` only a booted machine reads |
| `lima` | a **self-bootable** GPT disk: ESP + systemd-boot + the root filesystem, plus the `lima.yaml` that names it | nothing from the tree |
| `firecracker` *(later)* | the same disk, an uncompressed kernel, a machine-config JSON | nothing from the tree |

The variants above are *indicative*, particularly `minimal`. Exactly which packages a
booting systemd needs is a question to be answered by the dependency check described below,
against a real assembled tree — not by guessing in a design document. Expect `minimal` to
be less minimal than it looks: systemd pulls dbus, expat, pam, libcap, libxcrypt, libbpf
and elfutils behind it, and none of that is negotiable under constraint 1.

## The primitive that is missing: per-package file manifests

Selection by package needs a mapping from package to files, and there isn't one. The
staging tree is a merged blob; `usr/share/flfs/components/<pkg>` records the pin, not the
paths.

The alternative — expressing a variant as a list of paths to delete — is the thing to
reject early. It is a hand-maintained list that goes stale on every version bump the moment
a SONAME changes, it puts `usr/lib/libcrypto.so.3` in a config file three levels away from
the package that installs it, and it is how `build-rootfs.sh`'s subtraction block came to
need a `readelf` sweep to stay correct.

So: **`builder/build-package.sh` writes a file manifest beside the component record.** It
already runs at exactly the right moment, it already writes one file per package, and the
staging tree is already its business.

Producing the manifest is a before-and-after diff of the tree, because `rootfs/` is
cumulative and a package cannot simply be told "everything here is yours":

```sh
# before `source /package-build.sh`
find /usr/local/rootfs -printf '%y %s %T@ %p\n' | sort > /tmp/before
# after
find /usr/local/rootfs -printf '%y %s %T@ %p\n' | sort > /tmp/after
comm -13 /tmp/before /tmp/after | cut -d' ' -f4- > manifests/$FLFS_PKG
```

Two subtleties, both worth writing into the file that does it:

- **Size and mtime are in the key, not just the path**, so a package that *overwrites*
  another's file claims it too. Ownership of an overwritten path is genuinely ambiguous and
  claiming it in both manifests is the safe direction: a file in either package's manifest
  is kept when either is selected.
- **Two `find`s over a 20 000-file tree** cost a second or so per package. In CI it is
  less, because `SYSROOT_DIR` staging means each job's tree starts empty and `before` is
  nearly nothing.

The manifests are staged into the tree, consumed by `build-rootfs.sh`, and deleted there
along with the component records — the same lifecycle, for the same reason: they are the
intermediate form and the assembled image should have one answer to "what is in me".

They pay for themselves outside this design too. "Which package shipped this file" is a
question nothing here can currently answer, it is the first question of every size
investigation, and it is what an SPDX file-level `CONTAINS` would need if the SBOM ever
goes to that resolution.

## The variant file

Line-oriented text with `#` comments — the idiom of `builder/deps.txt` and
`test/size-budget.txt` — rather than a sourced shell fragment. It has to be read from two
places (the container that assembles, and the host that enumerates the CI matrix), it
should be diffable in a pull request without anybody tracing control flow, and a directive
that cannot be executed is a directive that cannot do anything surprising.

```
# image/variants/net.conf
description  Minimal, plus a network somebody can debug: addressing, DNS, TLS
extends      minimal
platforms    ext4 oci
tests        boot systemd network
publish      oci

package      openssl ca-certificates curl
package      iproute2 iputils libmnl
```

```
# image/variants/full.conf
description  Everything this repository builds. The image published as flfs:latest.
extends      net
platforms    ext4 oci
tests        boot systemd network container
publish      oci
default      yes

package      *
```

| directive | meaning |
| --- | --- |
| `description <text>` | one line, used in job names and job summaries |
| `extends <variant>` | single inheritance; the parent is resolved first, then these lines applied |
| `platforms <list>` | which platforms this variant is built for. Not the cartesian product of everything — a variant that makes no sense as a container simply does not list `oci` |
| `package <names…>` | additive, repeatable. `*` means every package with an `env.sh` |
| `omit <names…>` | remove from an inherited or `*` set |
| `keep <glob>` | rescue paths from an omitted package — this is what lets `oci` drop systemd and keep `libsystemd.so.0` |
| `drop <glob>` | remove paths regardless of which package owns them |
| `files <dir>` | overlay a directory of `/etc` on top of `image/files` |
| `tests <names…>` | which of `test/{boot,systemd,network,container,oci}.sh` apply to this image |
| `publish <platform…>` | which artifacts get pushed to the registry |
| `default yes` | the variant whose output keeps today's unsuffixed filenames |

**Resolution order**, which has to be stated because every ambiguity in it is a silent
wrong image:

1. the parent chain, oldest first, then this variant's own lines;
2. **then the platform's**, which may `omit`/`drop`/`keep` on top — a platform constraint
   is physical (a container has no kernel to run) and a variant cannot override it;
3. the selected packages' manifests are unioned into the file set;
4. `drop` globs are removed;
5. `keep` globs are restored — **keeps win over both `omit` and `drop`**, which is the only
   precedence rule anybody will need to remember;
6. everything not in any manifest — the directory skeleton, `image/files`, and everything
   `build-rootfs.sh` generates — is present regardless. Selection is about compiled
   software, not about the tree's bones.

Platforms take the same directives in `image/platforms/<name>.conf`, plus `format`:

```
# image/platforms/oci.conf
description  A container image: the host provides the kernel, the runtime provides PID 1
format       oci
omit         kernel systemd
keep         usr/lib/libsystemd.so.0*  usr/lib/libudev.so.1*
drop         etc/fstab etc/shadow etc/hostname etc/resolv.conf etc/pam.d
```

**The code that writes the artifact stays code.** There will be three or four platforms
ever, `mkfs.ext4 -d` and a hand-assembled OCI layout have nothing in common, and a
plugin mechanism for two implementations is how a build system acquires an abstraction
layer nobody can read. `format` selects a `case` branch in `build-rootfs.sh` — the same
branch that is there now, given a name.

Note what those thirteen lines replace: the entire subtractions block, including the
`readelf` sweep for binaries linking `libsystemd-shared` (they are systemd's files, so the
manifest already knows), the two-pass dangling-symlink walk (the same), and the
`etc/profile.d`/`etc/ssh`/`etc/xdg` shared-directory dance (a directory that ends up empty
after selection is simply not created).

## What makes selection safe

Selection introduces a failure mode the current build cannot have: an image that is missing
a library some binary in it needs. The superset always resolves; a subset need not.

**The per-variant dependency check is therefore not optional, and it is not a new
technique** — `build-rootfs.sh` already computes exactly this set for the SBOM's
"unresolved" entries, with the same construction as `test/check-rootfs-deps.sh`
(SONAMEs and symlinks included in what counts as provided, which the first version of that
code got wrong and reported 29 shipped libraries as missing). What changes is the verdict:
today the number is written into a document, and for a variant it has to fail the build.

The error should name the fix, which the manifests make possible — *this variant needs
`libmnl.so.0`, which `libmnl` provides; add it to `image/variants/net.conf`* is a
thirty-second fix, and *unresolved: libmnl.so.0* is a twenty-minute one.

`test/known-missing-libs.txt` stays what it is: the accepted backlog for the superset. A
variant's check runs against the same allowlist, so a library that is accepted-missing for
everybody stays accepted-missing here — with the same caveat `CLAUDE.md` already records
about allowlists hiding new arrivals.

**Should selection close over dependencies automatically?** No, and deliberately. Nothing
in this repository declares a dependency graph — `env.sh` says nothing about what a package
needs, on purpose — so the closure would have to be derived from `DT_NEEDED`, which is a
guess that happens to be right often enough to be dangerous. Explicit lists plus a check
that names the missing package is the same trade this project already made when it replaced
`apt build-dep` with a reviewed `deps.txt`: the graph exists, it is just written down by a
person rather than resolved on the day.

## CI

The point of the design is that this section is short.

**`build` matrix: unchanged.** 36 packages × 2 arches, one universal superset, same cache
keys. A variant never causes a compile.

**`rootfs`: still one job per architecture, looping over variants inside it.** The
expensive part of that job is downloading and extracting 36 artifacts; assembling an image
from the extracted tree is seconds. A matrix over (arch × variant) would pay that setup
cost N times to save nothing. The job builds the assembly container once and runs it per
`(variant, platform)` pair from `tools/variants.sh list`, uploading one artifact each.

**`boot`: a matrix over (arch × variant), running only that variant's declared tests.**
This is where the wall clock goes, and it is worth doing the arithmetic in the open. Today:
2 arches × 4 boots. With `minimal` (boot, systemd), `net` (+ network) and `full`
(+ container): 2 × (2 + 3 + 4) = 18 boots against today's 8, on runners with no KVM. Each
variant genuinely needs its own boot — a subset booting is precisely the claim being tested,
and `full` passing says nothing about `minimal` — so the cost is real and roughly a
doubling. If that becomes the pull-request bottleneck, the lever to pull is *when* rather
than *what*: every variant on `main` and on a schedule, `full` only on branches. That is a
policy change of one `if:` and should not be pre-emptively taken.

**`publish-oci`: one manifest list per variant that declares `publish oci`.** The
compatibility point that matters: `flfs:latest` and `flfs:<commit>` keep meaning the `full`
variant, because they already have consumers. Others get their own repository
(`flfs-minimal:latest`) or a tag prefix — a decision to make once, in the open, rather than
by accident on the first push.

**Files that hard-code the two flavours today** and will need teaching, listed because
finding them later is the annoying part of this work: `test/size-budget.txt` (its rows
become `variant platform arch MiB`, and its own comment already says an image with no line
is an error rather than a pass — so a new variant must be given a ceiling before it ships),
`test/rootfs-size.sh`, `test/size-history.sh` (`FLAVOURS="ext4 oci"` and a two-column
table), `tools/publish-oci.sh`, `tools/fetch-image.sh`, and the output filenames
`output/rootfs.ext4` / `output/flfs-oci.tar`, which the `default yes` variant keeps so that
`docs/release.md` and the boot tests do not all move at once.

## What the model makes expressible

Three things that are awkward or impossible today, as evidence the shape is right:

- **The kernel is in the disk image.** `rootfs/boot/bzImage` is copied into the ext4 — 11
  MiB on amd64, and `test/size-budget.txt`'s accounting puts arm64's some 21 MiB above
  that — while every boot here passes `-kernel` from outside. `drop boot` in a
  variant is a legitimate, reviewable line — and, notably, one nobody would dare write as a
  global change today.
- **`firecracker` is mostly not an image change at all.** The disk is the `ext4` disk; what
  differs is an uncompressed kernel (`vmlinux` on x86-64, `Image` on arm64),
  `CONFIG_VIRTIO_MMIO` in the shared `vm.config` fragment — cheap and harmless for qemu
  too, so no kernel fork — and a machine-config JSON. The kernel belongs *beside* the disk
  rather than inside it, exactly as it already is for qemu, so no variant pays for it.
- **`k8s-node` becomes a list of packages and a `/etc` overlay** rather than a fork of the
  image build, which is what issue #83 will need once it has an answer.

## The `lima` variant, and the four things it forces

Worth taking seriously ahead of the later variants, and not because it is easy — it is the
hardest one here. It is the first variant whose requirements are **written down by somebody
else**. `minimal` and `net` are this project's own opinion about what belongs in an image,
and an opinion cannot fail a test. Lima's list can, which makes this the one variant that
genuinely proves the model expresses things it was not designed around. It is also the one
that turns the output into something a person uses on a Tuesday rather than something CI
boots.

**The rule first, because it is the one that cannot bend: no package manager, ever.** Lima's
own requirements end with "one of `apt-get`, `dnf`, `apk`, `pacman` or `zypper`", and that
is simply not on offer here. It does not have to be, because the requirement is
*conditional*: Lima's boot scripts reach for a package manager only to install what it
cannot find — `sshfs`, `newuidmap`/`newgidmap` — so an image that already has all of them
never enters that branch. The bargain has to be explicit, though, and it is the whole
reason this variant is more than a package list: **everything Lima might install, this
variant ships up front.** If a future Lima grows an unconditional call to one, the answer
is a patch to that boot script (see `docs/reproducing-a-build.md`) or a fork of it — never
a package manager in the image, and never a shim pretending to be one, which would be a
lie that fails at the worst moment.

### 1. The disk has to boot itself

The largest requirement, and it is not on Lima's list at all — because every cloud image
already satisfies it and nobody thinks to write it down.

What this project produces today is a bare filesystem. `mkfs.ext4 -d … 1G` writes no
partition table and no bootloader, systemd is built `-Dbootloader=disabled -Defi=false
-Dukify=disabled`, and every boot in this repository is `qemu -kernel bzImage -append
"root=/dev/vda …"` with the kernel handed in from outside. `docs/release.md` already names
this: "the disk cannot boot itself… a release of `rootfs.ext4` alone would be unbootable by
anyone". Lima starts the VM itself and boots the disk through firmware. There is no
`-kernel`.

So `lima` is a **platform**, and a genuinely new artifact: a GPT disk with an ESP, a
bootloader (systemd-boot, or a UKI via `ukify`), the root partition, and the `lima.yaml`
template that names the result. That it lands cleanly on the platform axis rather than
forcing a third concept is the two-axis split earning its keep — `lima` the platform is how
it boots, `lima` the variant is what is in it, and neither had to learn about the other.

It pulls three things behind it: systemd rebuilt with the bootloader and EFI options *on*
(a change to the superset build, so every variant pays the size), `dosfstools` in
`image/Containerfile` for `mkfs.vfat`, and a partition table — `sfdisk` is in util-linux,
which is already here. And one to check rather than assume: Lima resizes the disk on
`limactl start --disk`, so the root partition has to grow to match. `systemd-repart` is the
answer that needs no new interpreter; whether our systemd build includes it is a question
for the implementation, not for this document.

### 2. cloud-init is Python, and is not coming in

Lima requires cloud-init preinstalled. Constraint 5 forbids a Python runtime in the image.
That is a real conflict rather than a technicality, and the resolution is not an exemption.

What cloud-init does for Lima is narrow: mount the `cidata` volume, set the hostname, create
the user, install the SSH key, and run Lima's own boot scripts out of
`/mnt/lima-cidata/boot/`. lima-vm maintains the precedent for doing that without it —
`lima-vm/alpine-lima`'s `lima-init.sh` is about 130 lines of shell reading `lima.env`,
`meta-data` and `user-data` directly, and it exists because Alpine's minimal image has no
cloud-init either. It calls `mount`, `awk`, `sed`, `ip`, `hostname` and `useradd`.

We ship all of those but the last: there is no shadow-utils here, so nothing can create a
user at runtime. `systemd-sysusers` is the substitute already in the image — generate a
snippet from `lima.env` and run it — and it is worth noticing that this is issue #84
("provision accounts with systemd credentials instead of a baked-in `/etc/shadow`") arriving
from a different direction. The two should be designed together or one will be rewritten.

**This is the part most likely to break, and it should be labelled that way rather than
discovered.** It is a reimplementation of an interface somebody else owns and will change,
in shell, without their test suite. The only honest mitigation is that the variant declares
a `lima` boot test, so CI says when it has drifted — which is exactly what the `tests`
directive is for.

### 3. What Lima names, and what it drags in

| need | package | notes |
| --- | --- | --- |
| SSH access | **openssh** | new. The first thing this image ever *listens* on, which is a change of security posture and not merely a package. Links against openssl and zlib, both already here |
| Lima's scripts call it by name | **sudo** | new. systemd's `run0` is not a drop-in and Lima does not know about it. C, ISC-style licence Debian carries in main — the exact SPDX expression is for the packaging pull request to settle against `test/dfsg-licenses.txt` |
| the default mount type | **sshfs**, **fuse3** | new. Lima's reverse-sshfs is the guest mounting the host, so this is guest-side and not optional unless the template switches to 9p or virtiofs |
| rootless containerd | `newuidmap`/`newgidmap` (shadow) | **avoid.** They need setuid or file capabilities, and `CLAUDE.md` already records that a `CAP_NET_RAW` file capability survives neither `mkfs.ext4 -d` nor the OCI layer tar. The first move is to ship a `lima.yaml` that does not enable rootless containerd, not to package shadow |
| Lima sets the guest timezone | **tzdata** | new, and pure data. There is no `/usr/share/zoneinfo` in this image today, so that step currently has nothing to point at. Accepting UTC is a defensible alternative |

### 4. Kernel options `vm.config` currently takes back out

- **`ISO9660_FS` — mandatory.** Lima hands the guest its `cidata` volume as an ISO, and
  `vm.config` explicitly clears ISO9660 today. Without it there is no configuration to
  read and the VM comes up as an unprovisioned box nobody can log into.
- **`FUSE_FS` — mandatory** for sshfs.
- **`VFAT_FS` — optional**, and worth leaving off. Firmware reads the ESP without the
  kernel's help; this is only needed to *mount* it in the guest, i.e. to run `bootctl`
  there.
- **9p or virtiofs** only if the template chooses those mount types over reverse-sshfs.

And the wrinkle that keeps this design honest: **kernel configuration is global.** One
superset build means these options are in every image, `minimal` included, which is mildly
absurd — a minimal VM image that can mount ISO9660. It is the same trade `firecracker`'s
`CONFIG_VIRTIO_MMIO` makes, it costs tens of kilobytes, and the alternative is a kernel per
variant, which would break the one rule this whole design rests on. The right response is a
comment in `vm.config` saying which variant each of these is for, so that a later reader
deleting "obviously unnecessary" filesystem support finds out here rather than from a Lima
VM that will not start.

## Migration

1. **✅ Per-package file manifests.** Useful on their own — "which package shipped this file"
   — and nothing consumes them yet, so this lands green and invisible.
2. **✅ `full`, `ext4` and `oci` as data, reproducing today's images.** The subtractions block
   becomes `image/platforms/oci.conf`. Verified by assembling both ways and diffing the
   trees: this step should change nothing, and being able to prove that is the whole
   reason it is a step of its own.
3. **✅ `minimal` and `net`**, with the per-variant dependency check, size-budget rows, the
   CI loop and the boot matrix. This is where the design either pays or does not: if
   `minimal` comes out at 90% of `full`, that is a finding worth having early.
4. **`lima`, in two halves that are worth landing separately.** The platform first — a
   self-bootable GPT disk with an ESP and systemd-boot — because that is useful on its own
   (`docs/release.md` currently has to ship a kernel beside every disk for exactly this
   reason) and because it can be tested by booting it in plain qemu with no `-kernel`, with
   no Lima anywhere. Then the variant: openssh, sudo, sshfs, the first-boot cidata reader,
   and a `lima.yaml` template. Splitting it this way means the risky half — somebody else's
   provisioning interface, reimplemented — lands on top of a disk that is already known to
   boot, rather than debugging both at once.
5. **`firecracker`**, which needs a runner-side binary and a fifth boot script, and is
   independent of everything above.
6. **`container-host` / `k8s-node`**, gated on the packaging in `docs/container-runtime.md`
   and issue #83 rather than on anything here.

## Trade-offs and open questions

- **A variant is a promise.** Each one costs CI time, an artifact, a size ceiling somebody
  maintains, and a claim that it works. The bar for adding one should be that somebody
  would actually boot it — not that it is expressible.
- **`lima` is the one that can be broken from outside.** Every other variant fails only
  when this repository changes. That one fails when Lima changes its cidata layout or its
  boot scripts, on somebody else's release schedule, and CI finds out on the next push
  rather than on the release that broke it. That is an argument for a `lima` boot test
  from day one, and an argument against reimplementing one byte more of the interface than
  Lima actually uses — but it is not an argument against the variant, because the same is
  true of every OCI image this project publishes and the registry has not moved yet.
- **Whether `lima` needs a testable boot in CI at all** is a fair question, since it needs
  the `limactl` binary on the runner and a nested VM. The cheap 80% is booting the `lima`
  *platform* disk in plain qemu with no `-kernel`, which proves the bootloader and the
  partition table, and leaving the provisioning half to a manual check until it breaks
  once.
- **Additive rather than subtractive, and that has a cost.** `package *` for `full` and
  explicit lists elsewhere means a new package joins `full` silently and every other
  variant deliberately. That is the right default for an image whose selling point is that
  nothing unnecessary is in it, and it does mean a new package's pull request now touches
  the variants that should carry it.
- **The resolver is more bash.** This is a file-set algebra with globs and inheritance,
  written in shell, running inside the assembly container — and issue #92 already asks
  whether bash is the right language for the test and assembly code, where the image's
  no-interpreters constraint does not apply. If that question is ever going to be answered
  differently, this is the code that would make the case.
- **Manifest correctness is load-bearing in a way nothing else here is.** A wrong manifest
  produces an image that is missing a file, and the failure surfaces at boot, in qemu, as
  something unrelated. The dependency check catches the library case, which is most of it;
  a missing *data* file (a unit, a terminfo entry, a certificate bundle) it will not catch.
- **`oci` keeps a `/etc` decision that is currently prose.** The current block deletes
  `etc/fstab`, `etc/shadow`, `etc/hostname` and `etc/resolv.conf` while keeping
  `etc/hosts`, with a paragraph explaining why. As a `drop` list that reasoning has nowhere
  to live except a comment in the platform file, which is fine — but it should be moved,
  not lost.
