# Linking: build-time libraries and runtime compatibility

Packages compile in the Debian builder but run against libraries in the image. The build
uses the staged glibc sysroot; other headers and libraries usually come from the builder's
development packages. This keeps package builds independent, but it requires checking ABI
compatibility between the builder libraries and the versions shipped in the image.

## What the binary records

An ELF executable records shared-library names and undefined symbols. Inspect them with:

```sh
readelf -d rootfs/usr/bin/curl | grep NEEDED
readelf -W --dyn-syms rootfs/usr/bin/curl | grep UND
```

`DT_NEEDED` names a library such as `libcurl.so.4`. At runtime, the dynamic loader resolves
that name using the executable's search paths, `LD_LIBRARY_PATH`, the loader cache, and
standard library directories. The SONAME normally includes an ABI major version; compatible
updates keep that name, while an ABI break should change it.

The executable also records symbol names it expects. Versioned symbols are checked when
the program starts. Unversioned symbols may be resolved lazily, so a missing symbol can
remain unnoticed until the relevant code path runs. Header-defined structures, constants,
and inline functions are compiled into the executable and cannot be checked by the loader.

## The compatibility rule

Building against Debian's library headers and running against this image's libraries works
when the shipped library provides the ABI used by the binary. A newer header can declare
symbols absent from the older runtime library. It can also change structures or constants,
which static symbol checks cannot detect.

glibc is built into the sysroot so packages compile against the same glibc shipped in the
image. For other libraries, the repository checks:

| Check | Detects |
| --- | --- |
| `test/check-rootfs-deps.sh` | Required shared-library files missing from the image. |
| `test/check-symbol-versions.sh` | Required symbol versions not provided by the runtime libraries. |
| `test/check-symbol-resolution.sh` | Unresolved non-weak symbols in the dependency closure. |

These checks catch many ABI mismatches, but cannot prove compatibility of data layouts,
constants, or behavior. Keep shipped libraries at or newer than the builder headers where
possible, and configure optional dependencies out rather than linking against libraries
that are absent from the image.

## Investigate a mismatch

Compare the builder and shipped versions with `./tools/header-skew.sh`. In a booted guest,
inspect library resolution with `LD_DEBUG`:

```sh
LD_DEBUG=libs,bindings <program>
```

Use `ldd` on the host only when its loader and library paths match the target image.

Run the static checks against the merged tree:

```sh
./test/check-rootfs-deps.sh rootfs
./test/check-symbol-versions.sh rootfs
./test/check-symbol-resolution.sh rootfs
```

For package sysroot and build details, see [How the build works](how-it-works.md). Declared
package-to-package build dependencies remain a
[proposal](../proposals/extension-dependencies.md).
