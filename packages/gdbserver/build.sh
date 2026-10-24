# The gdb tarball is binutils-gdb's combined tree, so everything except gdbserver is
# turned off at the top level. --disable-inprocess-agent drops libinproctrace.so, the
# library gdbserver injects for fast tracepoints — a feature for production tracing
# that gdb drives through its own tracepoint commands, and a .so the extension would
# otherwise ship for nobody.
#
# Out of tree, in /tmp, which is how gdb is built and keeps the unpacked source clean.
build=/tmp/build-gdbserver
rm -rf "$build"
mkdir -p "$build"
cd "$build"
/usr/local/src/configure \
    --prefix=/usr \
    --disable-gdb \
    --disable-sim \
    --disable-binutils \
    --disable-ld \
    --disable-gold \
    --disable-gas \
    --disable-gprof \
    --disable-gprofng \
    --disable-nls \
    --disable-werror \
    --enable-gdbserver \
    --disable-inprocess-agent
make all-gdbserver
install -D -m 755 gdbserver/gdbserver $ROOTFS/usr/bin/gdbserver
cd /usr/local/src
