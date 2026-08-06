# --without-selinux: find -context and the SELinux predicates, which need libselinux —
# no policy in the image, and libselinux-dev is deliberately absent from
# builder/deps.txt. Pinned rather than autodetected, like coreutils and sed.
#
# locate and updatedb come along with find and xargs and there is no configure option
# to leave them out. They are harmless: updatedb builds the database locate reads, so
# nothing is broken by shipping them, and carving them out would mean editing SUBDIRS
# in a generated Makefile — more fragile than the couple of hundred kilobytes is worth.
./configure --prefix=/usr --without-selinux
make
make install DESTDIR=/usr/local/rootfs
