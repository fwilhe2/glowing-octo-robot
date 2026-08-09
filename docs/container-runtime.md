# From `crun run` to `docker run`

**Status: nothing here is implemented.** `crun` works and `test/container.sh` proves it,
but starting a container today means building an OCI bundle by hand — `crun spec`, a
bind mount of the guest's own `/`, and a `config.json` patched with bash parameter
expansion — there is no jq in the image, and a JSON edit is not a job for `sed`. This
document is what stands between that and `run docker.io/library/alpine sh`.

The headline is that **the kernel is already finished**. Every gap is userspace, and
every missing piece has a C implementation, so nothing here forces a second toolchain
into the builder image the way runc or youki would.

## What already exists

`packages/kernel/build.sh`'s `container.config` fragment turns on everything the four
capabilities below need: `OVERLAY_FS` for the image store, `VETH`/`BRIDGE`/`TUN` for the
plumbing, `BRIDGE_NETFILTER` + `NF_TABLES` + `NFT_NAT` + `NFT_MASQ` for outbound
connectivity and published ports, `USER_NS` if rootless ever becomes interesting, and
`BPF_SYSCALL` + `CGROUP_BPF` for the cgroup v2 device controller crun already leans on.

Userspace has `crun` itself, `json-c` underneath it, `mount` and `nsenter` from
util-linux, `sha256sum` from coreutils, `tar` and `gzip` for the layers themselves, `acl`
and `attr` for the extended attributes inside them, `zlib` and `zstd`, and
systemd-networkd/resolved for anything declarative.

**The packaging under three of the four tiers below is now done.** Issue #77 did two of
them on their own merits rather than as a step towards this — `iproute2` and `libmnl` are
here, and so are `curl`, `openssl` and a CA bundle — and `tar` and `gzip` have since
followed. The tables below are marked accordingly. What that leaves is the parts that
are this document's actual work — an unpacker, a driver, a registry client, and the
netfilter half of the networking — rather than the packaging underneath them.

## The four capabilities

### 1. Pull an image from a registry

The only part that was genuinely a lot of new surface, because it drags in TLS — and
it is now in the image, put there by issue #77 for the sake of a machine you can debug.

| need | status | package |
| --- | --- | --- |
| HTTPS | present | **openssl**, 3.5 LTS — see [Which TLS](#which-tls) |
| HTTP client | present | **curl**, built `--with-openssl` |
| CA trust store | present | **ca-certificates**, Debian's snapshot of Mozilla's roots |
| JSON on the command line | library only | **jq**, or a small helper on the `json-c` already shipped |
| digest verification | present | coreutils `sha256sum` |

The protocol is not the hard part. Registry HTTP API v2 is: read the `WWW-Authenticate`
challenge from an unauthenticated `GET`, fetch an anonymous bearer token, `GET` the
manifest with an `Accept` header naming both the OCI index and the Docker manifest-list
media types, pick the platform out of the index, then `GET` the config blob and each
layer blob and verify every digest. A couple of hundred lines of bash around `curl` and
`jq`.

**The packaging half of this tier is done; the registry client is not.** What remains is
the bash above `curl` — the token dance, the manifest, the digest checks — and that is
still the last thing to build, because everything below works on layers already on disk
and a rootfs brought in over a second virtio disk gives real `docker run` ergonomics in
the meantime.

The attack-surface argument that used to say "defer this" has been overtaken rather than
answered: TLS and an HTTP client are in the image now, so the cost has been paid. What
has *not* been paid is the part that was always the sharper end of it — fetching and
running arbitrary images off the internet, which is what the seccomp note at the bottom
of this document is about.

### 2. Unpack layers

| need | status | package |
| --- | --- | --- |
| tar | present | **tar**, GNU tar 1.35 |
| gzip | present | **gzip** |
| zstd layers | present | `zstd` |
| xattrs and file capabilities in layers | present | `tar --xattrs` against `acl` + `attr` |

Both were absent from the image outright rather than merely un-configured — `zlib` is a
library with no CLI on top, and `tar+gzip` is what almost every layer in the wild is —
so they were packaged together. Two things about that are worth knowing here.
`packages/tar/build.sh` asserts on `config.h` that the ACL and xattr support this row
depends on actually got compiled in, because neither `--with-posix-acls` nor
`--with-xattrs` fails a configure that cannot have them, and the xattr calls come from
glibc rather than from `libattr` — so a tar with no xattr support has the same `NEEDED`
as one with it and unpacks a layer with no error and no capabilities. And gzip's
`gunzip`/`zcat` are symlinks rather than upstream's wrapper scripts, which costs neither
a fork nor a shell; see that package's `build.sh` for the one-macro mechanism.

**GNU tar does not understand OCI whiteouts.** `.wh.foo` and `.wh..wh..opq` are a layer
convention applied by the unpacker — containerd and umoci do it; tar has never heard of
them and never will. Extracting a multi-layer image with plain `tar -x` silently
resurrects every file a later layer deleted. The fix is a per-layer pass that either
deletes the marker and its target, or translates it into overlayfs's own whiteout
(`mknod c 0 0`). Small, but it is real work rather than a flag, and it is the single
most likely thing to be got wrong and not noticed.

### 3. Assemble and run

Nearly free.

- **overlayfs.** `mount -t overlay -o lowerdir=L3:L2:L1,upperdir=…,workdir=…` with
  util-linux's `mount`. No new package.
- **Config translation.** This *is* the `docker run` ergonomics: the image config's
  `Env`, `Cmd`, `Entrypoint`, `WorkingDir` and `User` have to be rewritten into the
  runtime spec's `process` block, with `-e`, `-v`, `-p` and `--memory` layered on top.
  Same jq-or-json-c decision as the pull tier.
- **Execution.** `crun run`, unchanged.

One trap inherited from the current hand-built bundle is worth writing into the tool
rather than rediscovering: the generated spec sets `"root": {"readonly": true}`, which is
right for a bind mount and wrong for an overlay upperdir.

There were two. `crun spec` also emits `"args": ["sh"]`, and for a long time this image
had no `/bin/sh` at all, so an untranslated spec failed with "executable file not found"
rather than anything informative. `packages/bash/build.sh` links `/usr/bin/sh` at bash
now, which is the whole fix — a container's entrypoint is the least surprising place in
the system to expect a shell, and this was the strongest of the several arguments for
having one.

### 4. Networking

The pleasant surprise is how much systemd already covers.

**The host bridge needs no new package.** A `.netdev` + `.network` pair in
`image/files/etc/systemd/network/` declares `br0`, and networkd's built-in
`[DHCPServer]` hands out addresses on it — that is the DHCP server that would otherwise
have to be packaged or written.

**veth plumbing needed one, and it is here.** Creating a veth pair per container and
moving one end into the container's netns is netlink work, and nothing in the image spoke
netlink; `networkctl` only queries. **iproute2** landed with issue #77 — `ip link add ...
type veth`, `ip link set ... netns` — along with the **libmnl** underneath it. The right
insertion point is still an OCI `createRuntime` hook in `config.json`: the netns exists by
then and the container process has not started.

**NAT and `-p` need two more small ones.** `libnftnl` → `nftables`, both C, both small,
and `libmnl` beneath them is already a package. That covers the masquerade rule for
outbound and DNAT for published ports. Plus `net.ipv4.ip_forward=1` as a systemd-sysctl
drop-in in `image/files/etc/sysctl.d/`, which is now a directory that exists.

**DNS is a configuration decision, not a package.** resolved's stub listener at
`127.0.0.53` is unreachable from inside a container netns, because loopback is not
shared. Either set `DNSStubListenerExtra=` so resolved also listens on the bridge address
and point the container's `/etc/resolv.conf` there, or write the upstream servers into
the container directly.

## Which TLS

An earlier version of this document ruled OpenSSL out because its `Configure` is perl.
That was the wrong rule, and it is worth stating the right one plainly, because it changes
which options are on the table:

> **A build-time interpreter is fine. An interpreter in the shipped image is not.**
> `builder/deps.txt` is builder-side only, and its size is not a consideration — perl is
> already at `builder/deps.txt:25` because glibc and the kernel need it. What the image
> must not gain is a perl (or python) *script*, and today it has none, not even glibc's
> `mtrace`, which lands here as the POSIX-shell variant.

By that rule **OpenSSL is admissible.** Perl builds it — `Configure`, and the perlasm
generators that emit its assembly — but nothing perl survives into what runs.
`libcrypto.so`, `libssl.so` and the `openssl` binary are C and link no interpreter.

One caveat, and it is the only place the rule actually bites: `make install` drops a
couple of perl *helper scripts* into the tree — `c_rehash` in `bindir`, and the `misc`
scripts (`CA.pl`, `tsget`) — which would ship as dead files with no interpreter to run
them. 3.5.7 installs exactly those three and `packages/openssl/build.sh` deletes them;
check the list again on a version bump rather than trusting this paragraph.

**Settled: OpenSSL, on the 3.5 LTS branch.** This document argued for mbedTLS, mostly on
size — roughly 1.5 MB across `libmbedtls`/`libmbedx509`/`libtfpsacrypto` against
OpenSSL's ~5 MB. Issue #77 left the choice open and it went the other way, on the *modern
and established* test in `CLAUDE.md`:

- **Established** is not a tie. mbedTLS is established *in embedded firmware*, which is a
  different population from the one this image belongs to. Every general-purpose Linux
  distribution ships OpenSSL as its TLS library, and "what does everyone use" is the right
  answer often enough that the burden is on the alternative.
- **The second consumer decides it.** The argument below — revisit if the image grows one
  — is really an argument for not choosing the library that loses that comparison, since
  carrying both is the worst outcome and openssh is the obvious next candidate.
  `libcrypto` is what it will look for.
- **Size is a means here, not the point.** `CLAUDE.md` says so about the image as a whole:
  it should be small because nothing unnecessary was added. 3.5 MB of difference buys the
  library every other piece of software expects, which is not nothing.
- **Modern** does not separate them. OpenSSL 3.5 is a current LTS with TLS 1.3 and ML-KEM
  key exchange; mbedTLS 4.x is current too, and its 3.6 LTS — the branch curl's mbedTLS
  backend is best tested against — is the older of the two.

The caveats above are real and `packages/openssl/build.sh` handles them: `no-docs` keeps
the perl pod renderer out of the build, and the three installed perl scripts (`c_rehash`,
`CA.pl`, `tsget`) are deleted from `DESTDIR`. `packages/curl/build.sh` deletes
`curl-config` too, though for a different reason now that `/bin/sh` exists: it describes
where libcurl's headers are, and the trim removes them.

The `openssl` CLI *is* shipped, which this document previously said was unnecessary.
Blob digests still come from coreutils `sha256sum`; `openssl s_client` and `openssl x509`
earn their megabyte on a machine whose whole point is being logged into.

There is one coupling worth knowing before bumping it, spelled out in
`packages/openssl/env.sh`: curl is compiled against the *builder image's* OpenSSL headers
and resolved against ours at runtime by SONAME, so the shipped major version has to stay
in step with Debian sid's. `packages/openssl/env.sh` holds the update check to the 3.5
series for that reason as much as for the LTS support window.

The alternatives, for the record:

- **mbedTLS** — the case above, and a good one; it lost on population rather than on
  merit.
- **wolfSSL** — autotools, C, supported by curl. Licensed GPLv2-or-commercial, a
  different posture from the rest of the tree.
- **GnuTLS** — pulls nettle *and* gmp, and `libgmp.so.10` is on
  `test/known-missing-libs.txt` as deliberately absent. Heavier than the job needs.
- **LibreSSL** — OpenSSL-derived, so the same install-side script check applies.

## The package list

Two left of the original nine, neither more than an afternoon. Issue #77 took the
expensive tier and half the networking one, and the unpack tier is done:

```
libnftnl  nftables                     networking   small, all C
jq                                     config       or a json-c helper instead

done: libmnl  iproute2                 networking   #77
      openssl  curl  ca-certificates   pull         #77
      tar  gzip                        unpack
```

Plus one bash driver, a registry client and a `createRuntime` hook script — which are now
the bulk of what is left, the packaging having stopped being the interesting part.

## Migration

Each phase is independently useful, and CI stays green throughout.

1. **`tar` and `gzip`, and a layer unpacker that handles whiteouts.** No runtime change
   at all — the deliverable is the ability to turn a directory of layer tarballs into a
   correct overlay lowerdir stack, with a test that a file deleted in layer 2 is gone.
   The two packages are done; the unpacker, which is the half with the whiteout problem
   in it, is not.
2. **The driver: overlay assembly plus image-config-to-runtime-spec translation.** At the
   end of this phase `run <local-image> <cmd>` works, with no networking beyond the
   loopback-only netns `crun spec` already produces. This is the phase that delivers most
   of the ergonomics.
3. **Networking.** `libnftnl`/`nftables` (`libmnl` and `iproute2` are done), the `br0`
   netdev, the `createRuntime` hook, masquerade, `-p`, and the resolved stub listener.
   Verified by a `test/` script in the shape of `test/network.sh` — outbound TCP and DNS
   from inside a container, and a published port reachable from the host side.
4. **Pull.** The registry client. `openssl`, `curl` and `ca-certificates` are done.

Phases 1 and 2 are worth doing even if 3 and 4 never happen.

## Trade-offs and open questions

- **Seccomp is still not enforced, and this makes that matter more.** crun is built
  `--disable-seccomp`, so a bundle's syscall filter is accepted and silently ignored.
  That is defensible while every container is hand-written locally; it is much less so
  once the tool pulls and runs arbitrary images off the internet. Docker's default
  seccomp profile is a large part of what `docker run` means. **Packaging `libseccomp`
  should probably land before phase 4** — it also lets systemd stop being built
  `-Dseccomp=disabled`. Now the sharpest open item here: the packaging that made pulling
  possible has landed, and this has not.
- **The image is 1 GiB and fixed** (`image/build-rootfs.sh:159`). An image store lives in
  `/var` and two pulled images will fill it. Either the image grows or containers get a
  second virtio disk; the second is tidier and matches the VM-only constraint.
- ~~**The CA bundle has no update story.**~~ Settled: it goes through exactly the same
  `SHA256`-pinned path as any other source. Debian's `ca-certificates` is a native package
  versioned by the date its `certdata.txt` was snapshotted, so `tools/upstream.sh` scrapes
  the pool directory and `tools/check-updates.sh` reports a new snapshot the way it
  reports any other release. A stale trust store now shows up as a pull request.
- **jq versus a json-c helper is unsettled.** jq is one more package but is immediately
  useful for everything else; a helper is ~200 lines against a library already shipped,
  and avoids putting a programming language in the image. Phase 2 forces the decision.
- **Rootless is out of scope but not ruled out.** `USER_NS` is on. It would additionally
  need `newuidmap`/`newgidmap` from shadow-utils and a subuid/subgid map, and every
  networking design above assumes root.
- **No opinion yet on image-store layout.** Content-addressed blobs under
  `/var/lib/…/blobs/sha256/` is the obvious answer; what is not obvious is garbage
  collection, which nothing in this document provides.
