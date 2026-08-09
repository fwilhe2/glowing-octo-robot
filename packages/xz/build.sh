# The `xz` tool and liblzma are what this package is for — systemd links liblzma for
# journal compression, and xz itself is one of the three compressors a person on a
# booted machine might reasonably need. Everything else upstream installs is a
# compatibility shim, and upstream provides a switch for each:
#
#   --disable-xzdec       a decompress-only xz, for systems too small for the real one.
#   --disable-lzmadec     the same, for the pre-standard LZMA format.
#   --disable-lzmainfo    prints the header of a .lzma file.
#   --disable-lzma-links  the lzma/unlzma/lzcat names, for scripts written against LZMA
#                         Utils before .xz existed in 2009.
#   --disable-scripts     xzdiff, xzgrep, xzless and xzmore, plus the xzcmp/xzegrep/
#                         xzfgrep/lz* symlinks onto them. Two of the four wrap tools
#                         this image does not have — there is no `diff` and no `less` —
#                         and packages/gzip/build.sh already made the argument that
#                         shipping the subset that happens to work is a worse story than
#                         shipping none.
#   --disable-doc         the docdir files, which the trim would delete anyway.
#
# `unxz` and `xzcat` are not in that list and stay: they are argv[0] aliases for xz
# itself, the same case as the gunzip and zcat symlinks packages/gzip/build.sh keeps,
# and for the same reason — names too much of the world calls to simply not have.
./configure \
    --prefix=/usr \
    --disable-xzdec \
    --disable-lzmadec \
    --disable-lzmainfo \
    --disable-lzma-links \
    --disable-scripts \
    --disable-doc
make
make install DESTDIR=/usr/local/rootfs
