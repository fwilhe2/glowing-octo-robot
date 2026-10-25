# Linking: compiled against Debian, running on ours

This is a description of the system as it is, not a proposal. It explains how a binary in
this image finds its libraries, why the build gets away with compiling every package
against *Debian's* copy of a library and then running it against *ours*, exactly when
that stops working, and what checks it. The examples are real output from a staged
`rootfs/`. Every command in here also works on your own tree.

The short version: a compiled program does not contain its libraries. It contains their
**names**, and a list of the **functions it expects them to have**. Anything with that
name and those functions will do. That is a much looser contract than "the library it was
built against", and this repository leans on that looseness deliberately.

## 1. What a binary actually records

`readelf -d` shows the dynamic section, which is what the loader reads at exec time:

```
$ readelf -d usr/bin/curl | grep NEEDED
 (NEEDED)  Shared library: [libcurl.so.4]
 (NEEDED)  Shared library: [libc.so.6]

$ readelf -d usr/lib/libcurl.so.4 | grep -E 'NEEDED|SONAME'
 (NEEDED)  Shared library: [libssl.so.3]
 (NEEDED)  Shared library: [libcrypto.so.3]
 (NEEDED)  Shared library: [libzstd.so.1]
 (NEEDED)  Shared library: [libz.so.1]
 (NEEDED)  Shared library: [libc.so.6]
 (SONAME)  Library soname: [libcurl.so.4]
```

- **`NEEDED`** is a file name the loader must find, nothing more: no path, no checksum,
  no version beyond what is in the name.
- **`SONAME`** is the name a library says it should be found under. When the linker
  links `-lcurl`, it opens `libcurl.so` (a symlink, a build-time-only file), reads
  the SONAME from inside it, and writes *that* into the program's `NEEDED`. That is why
  the program asks for `libcurl.so.4` and not for `libcurl.so` or `libcurl.so.4.8.0`.

The number in a SONAME is the library's **ABI major version**: a promise by its authors
that anything linked against `libssl.so.3` keeps working with any later `libssl.so.3`.
Breaking that promise means bumping it to `.so.4`, which old binaries will then not find
at all. Nothing enforces this beyond the authors' discipline, and the well-run libraries
in this image are well run.

`readelf --dyn-syms` shows the other half, the symbols:

```
$ readelf -W --dyn-syms usr/bin/curl | grep UND
  FUNC GLOBAL DEFAULT UND ftell@GLIBC_2.2.5 (2)
  FUNC GLOBAL DEFAULT UND curl_easy_perform
  ...
$ readelf -W --dyn-syms usr/lib/libglib-2.0.so.0 | grep g_main_loop_run
  FUNC GLOBAL DEFAULT  12 g_main_loop_run
```

`UND` is "undefined here, somebody I load must define it". A number in that column is
the section it is defined in. And note the difference between the two `UND` lines:
`ftell@GLIBC_2.2.5` carries a **symbol version**, `curl_easy_perform` does not. That
difference decides which of the checks below can catch what.

## 2. What the loader does at exec time

The kernel maps the program and hands control to the dynamic loader
(`/lib64/ld-linux-x86-64.so.2`, itself part of glibc), which:

1. **Finds each `NEEDED` by file name**: in the binary's `RUNPATH` if it has one
   (systemd's tools say `/usr/lib/systemd`, where `libsystemd-shared-262.so` lives), then
   `LD_LIBRARY_PATH`, then `/etc/ld.so.cache` (which `ldconfig` builds at image assembly),
   then `/usr/lib`. Then it does the same for *their* `NEEDED`, breadth-first, until the
   whole closure is loaded. A missing file stops the program before `main`:
   `error while loading shared libraries: libfoo.so.1: cannot open shared object file`.
2. **Checks symbol versions, all of them, up front.** Every `@VERSION` a binary needs must
   be defined by the library it names, or the program does not start:
   ``version `GLIBC_2.44' not found``.
3. **Binds unversioned function calls lazily.** By default a call through the PLT is
   resolved the first time it is *made*. A function that does not exist anywhere is not
   an error at startup. It is an error when the code path that calls it first runs:
   `symbol lookup error: undefined symbol: g_foo`. That can be days into uptime.
   (`LD_BIND_NOW=1`, or linking with `-z now`, makes binding eager. Many hardened builds
   are linked that way, which turns the late failure into a startup failure, not into a
   success.)

Lookup is by **name**, globally: the loader searches the program, then every loaded
library, in load order, for the first definition of `g_main_loop_run`. It does not care
which library the compiler saw it in.

You can watch all of this in the guest:

```sh
LD_DEBUG=libs curl -sI https://example.org     # which file each NEEDED resolved to
LD_DEBUG=bindings curl -sI https://example.org # each symbol, and who defined it
ldd /usr/bin/curl                              # the closure, resolved
```

## 3. Why compiling against Debian's headers works at all

Compiling a program that uses a library takes three things from that library, and only
one of them survives into the binary:

| at build time | from where, here | recorded in the binary |
| --- | --- | --- |
| the header (`openssl/ssl.h`): prototypes, structs, macros, constants | sid's `libssl-dev` | only as compiled code: offsets, constants, inlined bodies |
| the `.so` the linker reads | sid's `libssl.so` | the SONAME, `libssl.so.3`, and the names (and versions) of the symbols used |
| pkg-config's `.pc`: flags and library names | sid's `libssl-dev` | nothing |

At runtime only the right-hand column matters, and none of it says "Debian". So the
image's own `libssl.so.3` answers curl's `NEEDED` exactly as Debian's would have. That is
the arrangement in this repository, for every library we ship except glibc:

```
                build (container, sysroot = glibc only)        run (the image)
curl  ──compiles against──▶  sid's openssl/ssl.h, libssl.so    ──loads──▶  our libssl.so.3
conmon ─compiles against──▶  sid's glib.h, libglib-2.0.so      ──loads──▶  our libglib-2.0.so.0
```

glibc is the one exception. It is the sysroot, so every package compiles against *our*
glibc headers. That is not because the trick fails for libc in principle; it is because
glibc's symbol versions make the failure certain. A sid header newer than our glibc
produces binaries that ask for `GLIBC_2.44`, and they do not start. Escaping the host for
glibc and nothing else is the "pragmatic" in this project's description.

The `-dev` section of `builder/deps.txt` is the list of these stand-ins, one line per
library of ours. It is why the CI build matrix can be flat: no package needs another
package's build output, only glibc's, so all sixty-odd compile in parallel.

## 4. The direction rule, and what breaks when it is violated

A library is **backwards compatible**: it keeps everything older headers could have
named. So the safe direction is *header older than library*: ours equal to or newer than
sid's. The other direction, *sid's header newer than our library*, is where things
break, in four distinct ways:

| what is missing | example | when it fails | what catches it |
| --- | --- | --- | --- |
| the library file | a `NEEDED` the image does not ship | before `main` | `test/check-rootfs-deps.sh` |
| a symbol **version** | a function OpenSSL added in 3.6, tagged `OPENSSL_3.6.0` | before `main` | `test/check-symbol-versions.sh` |
| an **unversioned** symbol | a function glib added in 2.92 | at the first call | `test/check-symbol-resolution.sh` |
| something compiled *into* the caller | a struct grew, a macro changed value, an inline function changed | silently: wrong behaviour, or memory corruption | nothing |

The fourth row is the honest limit. A header is not only a list of functions: a
`sizeof(struct foo)` or an `#define FOO_FLAG 4` is compiled into the caller and never
looked up at runtime. A library that changes those within one SONAME has broken its own
ABI, which is exactly what the SONAME promises not to do. That promise is the whole
foundation here, and it is why the libraries this works for are mature ones with careful
maintainers. (Debian's packaging has the same exposure and handles it the same way, with
the `shlibs` and `symbols` files that record which package version introduced each
symbol. That is row three done by bookkeeping instead of by checking the result.)

### How the symbol versions make OpenSSL safe

```
$ readelf -V usr/lib/libssl.so.3 | grep 'Name: OPENSSL'
  Name: OPENSSL_3.0.0
  Name: OPENSSL_3.2.0
  ...
  Name: OPENSSL_3.5.0
```

Every function OpenSSL adds is tagged with the release that added it. Our 3.5 defines
nodes up to `OPENSSL_3.5.0`, so a curl that used something from sid's 3.6 headers would
ask for `OPENSSL_3.6.0`. `check-symbol-versions.sh` fails CI on that before anything
boots, and the loader would refuse to start it anyway. That is why
`packages/openssl/env.sh` can hold the 3.5 LTS series while sid moves on. The skew is
real, and it is fenced.

### Why glib was the sharp case, and what checks it now

glib, json-c, pcre2, jansson and libnftnl do not version their symbols. A conmon built
against a sid glib newer than ours would carry a plain `g_new_function`. No version means
nothing for `check-symbol-versions.sh` to hold it to, and lazy binding means the loader
says nothing until the call. Until `test/check-symbol-resolution.sh`, the only defence was
the comment in `packages/glib/env.sh` asking to keep ours at or above sid's.

That check does what the loader would do, statically, for every ELF object in the tree:
it walks the object's `NEEDED` closure exactly as in §2 and requires every non-weak
undefined symbol to be defined somewhere in it. This is the failure, reproduced: a
program linked against a "new" `libfoo.so.1`, run against an "old" one with the same
SONAME:

```
$ ./test/check-symbol-resolution.sh skew/tree
UNRESOLVED symbols in skew/tree/:
  usr/bin/app
      foo_new

$ LD_LIBRARY_PATH=skew/tree/usr/lib skew/tree/usr/bin/app
app: symbol lookup error: app: undefined symbol: foo_new
```

The check and the loader agree. The program also referenced a weak `foo_maybe` that
neither library defines, and both stayed quiet about it, correctly: a *weak* undefined
symbol resolves to NULL instead of failing. That is how a library asks "is this optional
function here?" (`if (foo_maybe) foo_maybe();`).

Three things the check had to get right, each of which is a fact about the loader:

- **`NEEDED` is matched by file name, not SONAME.** bash asks for `libtinfo.so.6`, which
  in this image is a symlink to ncurses' `libtinfow.so.6`, whose own SONAME says
  `libtinfow`. A check that only knew SONAMEs thought bash's library was missing. The SBOM
  generator hit the same thing (CLAUDE.md, "including symlinks").
- **Weak undefined symbols are not errors**, as above.
- **Some objects are resolved from outside their own closure, by design.** glibc's
  `libthread_db.so.1` calls `ps_pdread`, `ps_getpid` and the rest of the *proc_service*
  interface, which the debugger that loads it (gdb, gdbserver) implements. Those are
  listed in `test/known-unresolved-symbols.txt` with the reason, which is the only entry
  it needed on the whole image.

## 5. Where it stands

`tools/header-skew.sh` puts the builder's `-dev` versions next to ours. At the time of
writing:

| state | count | libraries |
| --- | --- | --- |
| same version | 17 | acl, attr, util-linux (4 headers), libcap, dbus, jansson, json-c, kmod, xz, libmnl, libnftnl, libseccomp, zstd, zlib |
| ours newer (safe) | 6 | elfutils, expat, glib, pam, pcre2, systemd |
| sid has upstream patches past our release | 2 | libxcrypt, ncurses |
| sid a whole release ahead | 1 | openssl 3.6.5 vs our 3.5.9, fenced by symbol versions (§4) |

and `check-symbol-resolution.sh` finds nothing on CI's tree. So the coupling is real, but
it is not hurting anyone today. Both versions move: ours through `update-packages.yml`,
sid's through a builder-image snapshot bump. The checks are what turn "it isn't hurting
anyone" from an observation into something CI enforces.

## 6. The trade-offs

There are three ways to arrange this, and the project sits deliberately in the middle one:

**Compile against Debian, run on ours, check the result** (what is done now). Costs
nothing in CI structure: the matrix stays flat and parallel. The price is the coupling
above. Versions have to be kept in the safe direction, the fourth row of §4 is trusted to
the libraries' maintainers, and a build cannot use a feature our library has but sid's
does not (the header would not declare it). `-dev` lines in `deps.txt` are also libraries
any `configure` can find, which is how `libselinux` reached `ip` through `libblkid-dev`
(CLAUDE.md, "a library that is already on the allowlist").

**Compile against our own headers: declared build dependencies.**
`docs/extension-dependencies.md` is the design. Each package declares what it links,
CI builds in dependency order, and each `-dev` line in `deps.txt` is replaced by the real
thing. The coupling disappears, and with it the fourth row. The price is CI: the
dependency graph becomes a build graph about five levels deep, each level a job that
waits for the one before, plus a cache key that has to include every dependency's key.
The *compiler* stays Debian's either way; this is not a toolchain change.

**A self-hosted toolchain**, LFS proper: build gcc and binutils against our glibc, then
everything with those. That removes the last coupling, gcc's runtime, which
`packages/gcc` already checks with `readelf -V`. It costs several bootstrap passes and
hours of build time, and it buys nothing a VM image can observe. The project's
constraints rule it out on purpose.

The first option plus checks is the right trade while the checks stay green and the skew
table stays mostly "same". The thing that would change that is a package that needs our
headers rather than tolerates sid's: an extension whose libraries depend on each other,
or a library we configure differently enough that sid's header misdescribes it. At that
point the second option stops being infrastructure without a user.

## Try it

```sh
readelf -d rootfs/usr/bin/<prog> | grep -E 'NEEDED|RUNPATH'  # what it asks for
readelf -W --dyn-syms rootfs/usr/lib/<lib> | grep -v UND      # what a library offers
readelf -V rootfs/usr/lib/<lib>                               # its symbol versions, if any
./test/check-rootfs-deps.sh rootfs                            # every NEEDED is shipped
./test/check-symbol-versions.sh rootfs                        # every version is defined
./test/check-symbol-resolution.sh rootfs                      # every symbol is defined
./tools/header-skew.sh                                        # sid's headers vs our libraries
```

and in a booted guest, `LD_DEBUG=help ls` lists everything the loader can tell you about
itself.
