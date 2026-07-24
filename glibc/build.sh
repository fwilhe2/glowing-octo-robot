mkdir -p build
pushd build
# --disable-werror: sid's linux-libc-dev redefines OPEN_TREE_CLONE etc. that glibc's
# own sys/mount.h also defines, which -Werror turns into a fatal build error.
../configure --prefix=/usr --disable-werror
make
make install DESTDIR=/usr/local/rootfs
popd
