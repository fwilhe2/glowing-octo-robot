# tar 1.35 has static helpers named acl_get_file_at, acl_set_file_at and
# acl_delete_def_file_at, which libacl 2.3.2 has since declared with other signatures.
# No released tar avoids it, and every distribution patches it; renaming tar's is the
# smaller change. Inline because only build.sh is mounted into the builder, and
# idempotent because a local rebuild reuses the unpacked tree.
sed -i -E 's/\b(acl_get_file_at|acl_set_file_at|acl_delete_def_file_at)\b/tar_\1/g' src/xattrs.c

# gnulib's mknod probe refuses to run as root. Answer it rather than bypass it
# (FORCE_UNSAFE_CONFIGURE takes the answer as "no" and compiles a replacement glibc does
# not need): mknod works on Linux, which is what gnulib itself guesses when it cannot test.
export gl_cv_func_mknod_works=yes

# --without-selinux: pinned, because libselinux.so.1 is already allowlisted for nscd and
# a tar that picked it up would pass every check. --with-rmt: rmt is a remote-tape server
# reached over rsh, and this keeps tar from installing one.
#
# ACLs and xattrs stay on: `tar --xattrs` is what carries an OCI layer's file
# capabilities. Both switch themselves off quietly when the headers are missing, and
# NEEDED cannot tell (xattrs are glibc), so config.h is checked.
./configure --prefix=/usr --without-selinux --with-rmt=/usr/libexec/rmt

for feature in HAVE_POSIX_ACLS HAVE_XATTRS; do
    if ! grep -q "^#define $feature" config.h; then
        echo "error: tar configured without $feature — see builder/deps.txt" >&2
        exit 1
    fi
done

make
make install DESTDIR=$ROOTFS
