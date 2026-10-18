# Autotools, one .so and one small tool. gperf, which the syscall tables are generated
# with, is already in builder/deps.txt.
#
# --disable-python is the default and is named anyway: the python bindings are a build
# of their own against a python3-dev the builder does not have, and they would be an
# interpreter's module in an image that has no interpreter (constraint 5).
#
# scmp_sys_resolver stays. It maps syscall names to numbers for the architecture at hand,
# which is the question somebody reading a seccomp denial in the journal is asking.
./configure --prefix=/usr --disable-static --disable-python
make
make install DESTDIR=$ROOTFS
