# --disable-liblastlog2: lastlog2 links libsqlite3, which we don't ship, so the
# lastlog2-import.service that util-linux installs alongside it fails at every boot
# with status 127 and leaves the system `degraded`. Its ConditionPathExists is met
# because systemd's own var.conf tmpfiles snippet creates /var/log/lastlog. Disabling
# the feature drops the binary, liblastlog2, pam_lastlog2 (which _files/etc/pam.d
# doesn't reference) and the unit itself, so there is nothing left to fail.
./configure --disable-asciidoc --disable-liblastlog2 --prefix=/usr
make
make install DESTDIR=/usr/local/rootfs
