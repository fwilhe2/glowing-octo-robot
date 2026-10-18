# The 8-bit library only, which is the one glib links; -16 and -32 are off by default and
# stay off. --enable-jit because GRegex asks for it and it is what makes PCRE2 fast; the
# PCRE2-exception in LICENSE is about exactly the code it generates.
#
# The two programs are dropped: pcre2grep is `grep -P`, which GNU grep is built without
# on purpose (packages/grep/build.sh), and pcre2test is the library's test driver.
# pcre2-config describes headers the trim removes, the same reason curl's curl-config goes.
./configure --prefix=/usr --disable-static --enable-jit
make
make install DESTDIR=$ROOTFS
drop_installed pcre2grep pcre2test pcre2-config

# libpcre2-posix, the regcomp()/regexec() wrapper for programs written against POSIX
# regex.h, which configure has no switch for. Nothing here uses it — glibc provides
# regcomp itself — and glib links only libpcre2-8.
rm -f $ROOTFS/usr/lib/libpcre2-posix.*
