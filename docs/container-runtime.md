# From `crun run` to `docker run`

**Status: nothing here is implemented.** `crun` works and `test/container.sh` proves it,
but starting a container today means building an OCI bundle by hand — `crun spec`, a
bind mount of the guest's own `/`, and a `config.json` patched with bash parameter
expansion because the image has no `sed`. This document is what stands between that and
`run docker.io/library/alpine sh`.

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
util-linux, `sha256sum` from coreutils, `acl` and `attr` for extended attributes, `zlib`
and `zstd`, and systemd-networkd/resolved for anything declarative.

## The four capabilities

### 1. Pull an image from a registry

The only part that is genuinely a lot of new surface, because it drags in TLS.

| need | status | package |
| --- | --- | --- |
| HTTPS | missing | **mbedtls** preferred, OpenSSL admissible — see [Which TLS](#which-tls) |
| HTTP client | missing | **curl**, against whichever of the two |
| CA trust store | missing | a Mozilla CA bundle as a data file |
| JSON on the command line | library only | **jq**, or a small helper on the `json-c` already shipped |
| digest verification | present | coreutils `sha256sum` |

The protocol is not the hard part. Registry HTTP API v2 is: read the `WWW-Authenticate`
challenge from an unauthenticated `GET`, fetch an anonymous bearer token, `GET` the
manifest with an `Accept` header naming both the OCI index and the Docker manifest-list
media types, pick the platform out of the index, then `GET` the config blob and each
layer blob and verify every digest. A couple of hundred lines of bash around `curl` and
`jq`.

**This tier should be built last, and it is reasonable never to build it.** Everything
below works on layers already on disk. Deferring pull defers mbedtls, curl and the CA
bundle together — which is most of the new attack surface in this document — and a
rootfs brought in over a second virtio disk gives real `docker run` ergonomics in the
meantime.

### 2. Unpack layers

| need | status | package |
| --- | --- | --- |
| tar | **missing entirely** | **tar** |
| gzip | **missing entirely** | **gzip** |
| zstd layers | present | `zstd` |
| xattrs and file capabilities in layers | present | `tar --xattrs` against `acl` + `attr` |

Note that `tar` and `gzip` are absent from the image outright, not merely un-configured.
`zlib` is a library with no CLI on top, and `tar+gzip` is what almost every layer in the
wild is.

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

Two traps inherited from the current hand-built bundle are worth writing into the tool
rather than rediscovering. `crun spec` emits `"args": ["sh"]` and **this image has no
`/bin/sh`** — bash installs as `/usr/bin/bash` and nothing links `sh` to it, so an
untranslated spec fails with "executable file not found" rather than anything
informative. And the generated spec sets `"root": {"readonly": true}`, which is right
for a bind mount and wrong for an overlay upperdir.

### 4. Networking

The pleasant surprise is how much systemd already covers.

**The host bridge needs no new package.** A `.netdev` + `.network` pair in
`image/files/etc/systemd/network/` declares `br0`, and networkd's built-in
`[DHCPServer]` hands out addresses on it — that is the DHCP server that would otherwise
have to be packaged or written.

**veth plumbing needs one.** Creating a veth pair per container and moving one end into
the container's netns is netlink work, and no tool in the image speaks netlink;
`networkctl` only queries. That is **iproute2** — C, `libmnl` for the `tc`/`devlink`
paths, and it will find the already-shipped `elfutils` for its BPF bits. The right
insertion point is an OCI `createRuntime` hook in `config.json`: the netns exists by
then and the container process has not started.

**NAT and `-p` need three small ones.** `libmnl` → `libnftnl` → `nftables`, all C, all
small next to what this tree already builds. That covers both the masquerade rule for
outbound and DNAT for published ports. Plus `net.ipv4.ip_forward=1`, which systemd-sysctl
applies from a drop-in.

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
them. They need removing in the package's `build.sh` or in the trim. Two lines, but check
which ones a given release installs rather than trusting this paragraph.

So the choice is now decided on merits rather than by disqualification, and the merits
still favour **mbedTLS** for the job in this document:

- **Size.** Roughly 400 KB across `libmbedtls`/`libmbedx509`/`libmbedcrypto` against
  OpenSSL's ~5 MB of libcrypto and libssl. The image has a budget (`test/size-budget.txt`)
  and this tier is otherwise the most expensive thing proposed here.
- **Surface.** It covers what a registry pull needs — TLS 1.2/1.3 client, SNI, chain
  verification against a CA bundle — and little else, which suits an image whose build
  ends in a trim.
- **Build.** CMake, which `builder/deps.txt` already carries for `json-c`, and no
  generated-source step as long as the *release tarball* is used rather than a git
  checkout.
- curl supports it directly with `--with-mbedtls`.

**OpenSSL is now the reasonable second choice rather than an excluded one**, and it wins
on things mbedTLS cannot match: it is curl's best-tested backend by a distance, it is what
every other consumer of TLS in a distribution expects to find, and `libcrypto` is what a
future package (openssh, say) is most likely to want already present. If this image ever
grows a second TLS consumer, revisit — carrying mbedTLS *and* OpenSSL would be the worst
of both.

Losing the `openssl` CLI costs nothing today: blob digests come from coreutils
`sha256sum`.

The other alternatives, unchanged except that "no perl" is no longer what recommends them:

- **wolfSSL** — autotools, C, supported by curl. Licensed GPLv2-or-commercial, a
  different posture from the rest of the tree.
- **GnuTLS** — pulls nettle *and* gmp, and `libgmp.so.10` is on
  `test/known-missing-libs.txt` as deliberately absent. Heavier than the job needs.
- **LibreSSL** — OpenSSL-derived, so the same install-side script check applies.

## The package list

Nine new packages, of which only curl and mbedtls are more than an afternoon:

```
tar  gzip                              unpack       cheap, and unblocks everything else
libmnl  libnftnl  nftables  iproute2   networking   small, all C
jq                                     config       or a json-c helper instead
mbedtls  curl  + a CA bundle           pull         the expensive tier — defer it
```

Plus one bash driver and a `createRuntime` hook script.

## Migration

Each phase is independently useful, and CI stays green throughout.

1. **`tar` and `gzip`, and a layer unpacker that handles whiteouts.** No runtime change
   at all — the deliverable is the ability to turn a directory of layer tarballs into a
   correct overlay lowerdir stack, with a test that a file deleted in layer 2 is gone.
2. **The driver: overlay assembly plus image-config-to-runtime-spec translation.** At the
   end of this phase `run <local-image> <cmd>` works, with no networking beyond the
   loopback-only netns `crun spec` already produces. This is the phase that delivers most
   of the ergonomics.
3. **Networking.** `libmnl`/`libnftnl`/`nftables`/`iproute2`, the `br0` netdev, the
   `createRuntime` hook, masquerade, `-p`, and the resolved stub listener. Verified by a
   `test/` script in the shape of `test/network.sh` — outbound TCP and DNS from inside a
   container, and a published port reachable from the host side.
4. **Pull.** `mbedtls`, `curl`, the CA bundle, and the registry client.

Phases 1 and 2 are worth doing even if 3 and 4 never happen.

## Trade-offs and open questions

- **Seccomp is still not enforced, and this makes that matter more.** crun is built
  `--disable-seccomp`, so a bundle's syscall filter is accepted and silently ignored.
  That is defensible while every container is hand-written locally; it is much less so
  once the tool pulls and runs arbitrary images off the internet. Docker's default
  seccomp profile is a large part of what `docker run` means. **Packaging `libseccomp`
  should probably land before phase 4** — it also lets systemd stop being built
  `-Dseccomp=disabled`.
- **The image is 1 GiB and fixed** (`image/build-rootfs.sh:159`). An image store lives in
  `/var` and two pulled images will fill it. Either the image grows or containers get a
  second virtio disk; the second is tidier and matches the VM-only constraint.
- **The CA bundle has no update story.** It is the one artifact here that is neither
  compiled from a pinned tarball nor written by hand, and a stale trust store fails
  confusingly. It should probably go through the same `SHA256`-pinned path as any other
  source.
- **jq versus a json-c helper is unsettled.** jq is one more package but is immediately
  useful for everything else; a helper is ~200 lines against a library already shipped,
  and avoids putting a programming language in the image. Phase 2 forces the decision.
- **Rootless is out of scope but not ruled out.** `USER_NS` is on. It would additionally
  need `newuidmap`/`newgidmap` from shadow-utils and a subuid/subgid map, and every
  networking design above assumes root.
- **No opinion yet on image-store layout.** Content-addressed blobs under
  `/var/lib/…/blobs/sha256/` is the obvious answer; what is not obvious is garbage
  collection, which nothing in this document provides.
