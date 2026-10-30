# GLib builds five libraries and two dozen tools, and conmon — the only consumer here —
# links one of them: libglib-2.0. So this builds the lot, as glib's meson insists, and
# ships only that library; the rest go with nothing to load them.
#
# What that leaves out, and why it is safe:
#   gobject, gio, gmodule, gthread  no consumer. A package that wants one later fails
#                    test/check-rootfs-deps.sh loudly rather than quietly finding it.
#                    gobject is also the only thing that needs libffi, which is why
#                    there is no libffi package: builder/deps.txt has libffi-dev for this
#                    build alone, the way it has libgmp-dev for gcc's.
#   gdbus-codegen, glib-mkenums, glib-genmarshal, gtester-report
#                    python scripts — constraint 5 — and share/glib-2.0/codegen is the
#                    python package behind the first.
#   gio, gsettings, gdbus, gresource, glib-compile-*
#                    tools for the libraries that are not shipped.
#
# The options turn off what would otherwise be found and linked: libmount (gio's mount
# monitor), SELinux and xattrs (gio's file attributes), libelf (gresource), and sysprof,
# dtrace and systemtap tracing. NLS for the usual C-locale reason; tests, docs, man
# pages and introspection because none of them can run or be read here.
meson_install \
    -Dselinux=disabled \
    -Dxattr=false \
    -Dlibmount=disabled \
    -Dlibelf=disabled \
    -Dsysprof=disabled \
    -Ddtrace=disabled \
    -Dsystemtap=disabled \
    -Dnls=disabled \
    -Dtests=false \
    -Dinstalled_tests=false \
    -Ddocumentation=false \
    -Dman-pages=disabled \
    -Dintrospection=disabled

# Everything except libglib-2.0, removed from the staging tree. Named by what to keep
# rather than by what to delete, so that a glib release adding a tool does not ship it.
find $ROOTFS/usr/lib -maxdepth 1 \( -name 'libgio-2.0.so*' -o -name 'libgobject-2.0.so*' \
    -o -name 'libgmodule-2.0.so*' -o -name 'libgthread-2.0.so*' -o -name 'libgirepository-2.0.so*' \) -delete
# usr/lib/glib-2.0 is glibconfig.h, a header installed outside usr/include where the trim
# does not look; consumers compile against the builder's anyway. usr/share/gdb is gdb's
# auto-load scripts for libglib and libgobject: python (constraint 5), for a debugger the
# image does not have, and the second for a library it does not ship.
rm -rf $ROOTFS/usr/lib/gio $ROOTFS/usr/lib/glib-2.0 $ROOTFS/usr/libexec/gio-launch-desktop \
       $ROOTFS/usr/share/glib-2.0 $ROOTFS/usr/share/gettext/its
drop_installed usr/share/gdb
for f in $ROOTFS/usr/bin/*; do
    case "$(basename "$f")" in
        gapplication|gdbus|gdbus-codegen|gi-*|gio|gio-querymodules|glib-*|gobject-query|\
        gresource|gsettings|gtester|gtester-report) rm -f "$f" ;;
    esac
done
