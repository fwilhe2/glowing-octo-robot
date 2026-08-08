# Nothing is compiled here; `make` runs certdata2pem.py, which splits Mozilla's
# certdata.txt into one PEM file per root and drops the ones Debian's blacklist.txt names
# and the ones whose trust bits say they are not for server authentication.
make -C mozilla

# Concatenate them into the single file everything looks for. The alternative layout is a
# CApath — a directory of PEMs plus the hashed symlinks OpenSSL's c_rehash builds — and
# it is the wrong one here twice over: the perl that builds those symlinks is exactly
# what packages/openssl/build.sh deletes, and a bundle is one open() against a directory
# of a hundred and twenty-odd files to hash and stat.
#
# /etc rather than under --prefix=/usr, for the same reason as packages/iana-etc: the
# path is compiled into the consumers. OpenSSL's default CAfile is $OPENSSLDIR/cert.pem
# and its default CApath $OPENSSLDIR/certs, both fixed at configure time, and curl is
# built --with-ca-bundle pointing at this name.
cat mozilla/*.crt > ca-certificates.crt
install -D -m 644 ca-certificates.crt /usr/local/rootfs/etc/ssl/certs/ca-certificates.crt

# ...and the other name OpenSSL looks under, so `openssl s_client` verifies a chain with
# no -CAfile argument. Relative, so it resolves inside the image rather than against
# whatever /etc/ssl the builder container has.
ln -sfn certs/ca-certificates.crt /usr/local/rootfs/etc/ssl/cert.pem

echo "installed $(grep -c 'BEGIN CERTIFICATE' ca-certificates.crt) root certificates"
