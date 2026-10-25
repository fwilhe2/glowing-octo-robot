# Build dependencies between packages

**Status: nothing here is implemented, and it may never need to be.** This is the design
for letting one package compile against another one we built, written down because the
question came up — a Firefox kiosk extension, whose GTK stack is twenty libraries deep —
and because answering it turned up something true about the build today. Whether the CI
cost below is worth paying is an open question; the last section says when it would be.

## What is true today

`docs/debugging.md` says an extension's packages cannot link against each other. That is
right, but it undersells it: **in CI, nothing links against anything we built except
glibc.** The `build-package` action stages a glibc-only sysroot (`SYSROOT_DIR=sysroot`),
and every other library a package compiles against comes from a `-dev` package in
`builder/deps.txt` — crun against sid's `libseccomp-dev`, iptables against sid's
`libnftnl-dev`, conmon against sid's `libglib2.0-dev` — and then loads ours at runtime by
SONAME. The matrix is flat because no package needs another's output.

Local builds used to differ. `SYSROOT_DIR` defaulted to `rootfs/`, which is cumulative,
so `--sysroot` put *our* headers and `.pc` files for everything staged so far ahead of
Debian's: the same package compiled against different headers in CI and on a laptop, and
which ones locally depended on what happened to be built first. It now defaults to
`sysroot/`, glibc alone, as CI's is — so a declared dependency would be the only way into
the sysroot in both places, not "declared in CI, anything staged on your machine".

For the base, the `-dev` model works because each library is one small, well-understood
package and the coupling is written down (`packages/openssl/env.sh`, the glib note in
`CLAUDE.md`). It does not scale to a stack. `libgtk-3-dev` pulls in roughly a hundred
`-dev` packages, X11 among them, and every base package's `configure` would see them — the
iproute2/libselinux trap fifty times over. Each would be coupled to sid the way glib is,
most with unversioned symbols that only `test/check-symbol-resolution.sh` would catch,
and only after the fact. And the
builder image is content-hashed, so each addition rebuilds every package.

The extensions have worked around this so far by vendoring: a library with one consumer
is that consumer's `VENDOR_TARBALL`, built static under `/tmp` (libpcap for tcpdump,
libtraceevent for perf). That holds while the libraries are leaves. GTK is not a leaf.

## The design

### `DEPENDS=` in `env.sh`

```sh
DEPENDS="glib-full cairo harfbuzz"
```

Build-time only, and validated by a `package_deps` helper in `tools/lib.sh`:

- A dependency is a base package, or a package in **the same** extension. Naming another
  extension is an error: sysexts merge independently, so a library in one cannot be a
  requirement of another.
- No cycles. freetype ↔ harfbuzz is the one a GTK stack has, and it is broken the way
  every distribution breaks it: freetype built without harfbuzz.

A package without `DEPENDS` behaves exactly as it does now.

### A second sysroot layer

Root `build.sh` mounts one more tree, read-only, at `/usr/local/sysroot-ext`, named by
`EXT_SYSROOT_DIR` the way the existing one is named by `SYSROOT_DIR`. Locally it defaults
to `extensions/$EXTENSION`, which is also that package's DESTDIR — the same arrangement
`rootfs/` already has for the base. In CI it is a directory holding only the declared
dependencies' artifacts.

`builder/build-package.sh` puts the layer after the glibc sysroot and ahead of the
`-idirafter` / trailing `-L` Debian paths:

```sh
-I$EXT/usr/include
-L$EXT/usr/lib -Wl,-rpath-link,$EXT/usr/lib
PKG_CONFIG_PATH=$EXT/usr/lib/pkgconfig:$SYSROOT/usr/lib/pkgconfig
PKG_CONFIG_RELOCATE_PATHS=1
```

The pkg-config line is the crux. The builder's is pkgconf (2.5.1 at the time of writing),
and `PKG_CONFIG_RELOCATE_PATHS` makes a `.pc` file's `prefix=/usr` resolve to the
directory the file was found in, which is what a staged tree needs.
`PKG_CONFIG_SYSROOT_DIR` would be the wrong tool: it rewrites the paths in Debian's `.pc`
files too. `CGO_*` and `RUSTFLAGS` are derived from `CFLAGS`/`LDFLAGS` already, so they
follow without a change.

One trap: a build that runs what it just built against the layer's libraries — GTK runs
`gdk-pixbuf-query-loaders` — needs `LD_LIBRARY_PATH` for that one command, in the
package's `build.sh`. Never globally: Debian's own tools in the builder (meson's python,
perl) would then load our libffi and our glib.

### `image/build-extension.sh` gets a trim

It strips ELF files but does not run the image's trim, which has not mattered because no
extension package installs headers, `.pc` files or static archives today. Once libraries
live in an extension, all three would ship in its `.raw`. The list should be the one
`image/build-rootfs.sh` uses, factored out rather than copied.

### Already in place

The `rootfs` job's *Check the extensions' libraries against the base* step merges each
extension over the base and runs `check-rootfs-deps.sh` and `check-symbol-versions.sh`,
so a library provided within the same extension already counts as satisfied.

## The CI cost, honestly

This is the part that makes the design expensive, and there are two ways to pay it.

**Levels.** `sources` computes topological levels instead of one list. Level 0 is today's
`build` matrix, untouched. Each level above it is a reusable workflow invoked as `build-1`
… `build-N`, each with `needs:` on the one before and skipped when empty. GitHub cannot
express a DAG computed at runtime, so N is fixed in the YAML; a GTK-to-Firefox chain is
six or seven deep. The `build-package` action, for a package with `DEPENDS`, downloads
those artifacts transitively, untars their `rootfs/` half into `sysroot/` and their
`extensions/<ext>/` half into `ext-sysroot/`, and **adds its dependencies' cache keys to
its own**, recursively (`cache_key` in `lib.sh`). Without that, a cairo bump would serve
a stale GTK from the cache — the same failure the `$PKG/src` hashing exists to prevent.
Artifacts stay one per package, so nothing downstream of `build` changes.

Per-package caching and parallelism survive, which matters when one of the packages is a
browser that takes an hour. What it costs is N more jobs in the workflow graph, a chain of
`needs:` that lengthens the critical path by one job start-up per level, and a cache-key
function that is now recursive and must be right.

**One job per extension.** Packages with `DEPENDS` leave the matrix, and one job per
extension builds them in topological order with a plain loop over `./build.sh`, which
locally already does the right thing. The YAML is one job; the cache is the whole
`extensions/<ext>/` tree keyed on everything in it. The price is granularity: touching a
font rebuilds Firefox. For an extension of five small libraries that is fine; for a
browser it is an hour per unrelated change.

Either way, the base can opt in one edge at a time later — `crun` with
`DEPENDS=libseccomp` compiles against our headers in CI as well as locally, and that
`-dev` package can leave `deps.txt`. That replaces sid's headers with ours for exactly the
edges that are declared, which is the one benefit here that does not need a new extension
to be worth having.

## When to do it

Not before something needs it. Every extension that exists today is satisfied by the base
plus static vendoring, and nothing in this design is cheaper to build before its first
user than after. The trigger is an extension whose dependencies are a graph rather than
leaves — the kiosk is the example that prompted this, and is itself a long way off (the
kernel half needs DRM, `vm.config` currently clears it, and that is a decision about every
machine, not about an extension).

If it is done, the first step should be the smallest one that exercises every piece:
libpcap out of tcpdump's vendor tarball into a `libpcap` package with `EXTENSION=debug`,
and `DEPENDS=libpcap` on tcpdump — one edge, one level, through the sysroot layer, the
pkgconf relocation, the cache key and the extension trim. Start with one job per
extension; move to levels only when a package in the graph is slow enough that rebuilding
it for a neighbour's change hurts.
