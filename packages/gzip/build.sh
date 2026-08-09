# gzip installs one ELF binary and a dozen wrapper scripts around it, and none of the
# wrappers ship. Most of them wrap a tool that is not here — zdiff and zcmp want
# diffutils, znew wants compress, zless wants less — which leaves zgrep and a couple of
# others, and shipping four of twelve because those four happen to work is a worse story
# than shipping none. Any one of them can come back later on its own argument.
#
# `gunzip` and `zcat` are the exception, being names too much of the world calls to
# simply not have — and they are better as symlinks than as wrappers regardless, a
# symlink costing neither a fork nor a shell. gzip has always been able to answer to
# those names itself: main() looks at argv[0] and decompresses when invoked as
# gun*/un*/?cat. That code sits behind `#if !GNU_STANDARD` with the macro defaulting to
# 1, which is why upstream ships wrappers rather than links at all. Turning it off is the
# documented way to get the symlink behaviour — gzip.c says so where it defines the macro
# — and it is the macro's entire effect, appearing nowhere else in the tree. Invoked as
# `gzip` the binary is unchanged.
#
# CPPFLAGS is appended to, not replaced: builder/build-package.sh puts the --sysroot
# flags there, and a build that overwrites it compiles against the builder image's glibc
# instead of ours. That is the first of CLAUDE.md's two silent breakages.
export CPPFLAGS="${CPPFLAGS:-} -DGNU_STANDARD=0"

./configure --prefix=/usr
make -j"$(nproc)"
make install DESTDIR=/usr/local/rootfs

# The wrappers, and the two that earn a symlink instead. zless is only built when
# configure found a `less` to wrap, which is a property of the builder image rather than
# of this package, so the list is longer than any one build installs.
rm -f /usr/local/rootfs/usr/bin/{gunzip,gzexe,zcat,zcmp,zdiff,zegrep,zfgrep,zforce,zgrep,zless,zmore,znew}
ln -s gzip /usr/local/rootfs/usr/bin/gunzip
ln -s gzip /usr/local/rootfs/usr/bin/zcat

# ...and the check the flag above is worth nothing without, because its failure is silent
# and backwards. A gunzip that did not get GNU_STANDARD=0 *compresses*: `gunzip x.gz`
# writes x.gz.gz, says nothing useful, and the first person to find out is whoever
# unpacks a layer with it. The builder container runs on our glibc — root build.sh binds
# it over Debian's, because builds execute what they just compiled — so the installed
# binary can simply be run under the installed name.
printf 'flfs\n' | /usr/local/rootfs/usr/bin/gzip -c > /tmp/gnu-standard-check.gz
if [ "$(/usr/local/rootfs/usr/bin/zcat /tmp/gnu-standard-check.gz)" != flfs ]; then
    echo "error: zcat did not decompress — -DGNU_STANDARD=0 did not reach the compile" >&2
    exit 1
fi
rm -f /tmp/gnu-standard-check.gz
