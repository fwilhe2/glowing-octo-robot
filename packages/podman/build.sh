# The build tags are named rather than left to the Makefile, whose default runs a hack/
# script per tag that asks pkg-config what the builder happens to have — exactly the
# autodetection builder/deps.txt exists to keep from deciding what ships.
#
#   seccomp                    libseccomp, for the default seccomp profile podman hands
#                              crun. Without it every container runs unfiltered.
#   systemd                    the journald log driver and events backend, and sd_notify
#                              for Quadlet's Type=notify units. libsystemd is shipped.
#   exclude_graphdriver_btrfs  storage drivers are overlay here; btrfs would want
#                              libbtrfs-dev in the builder for a filesystem we never use.
#   containers_image_openpgp   signature verification in pure Go instead of through
#                              gpgme, which would be gpgme, libassuan and libgpg-error in
#                              the image for `podman image trust` alone.
#   grpcnotrace                upstream's default; drops gRPC's tracing support.
#
# Rootless podman: newuidmap/newgidmap come from packages/shadow (with file
# capabilities set by image/build-rootfs.sh), the network from packages/passt, and
# rootlessport — built here — forwards published ports into a rootless network
# namespace. No libsubid tag: that is for subordinate IDs from a database rather than
# /etc/subuid, which is all this image has. SQLite is the database podman 6 uses; without the libsqlite3 tag it is the copy
# compiled into the binary, which is one fewer library to ship and keep in step.
#
# GOFLAGS (-mod=vendor -trimpath -buildvcs=false) comes from builder/build-package.sh;
# the Makefile's own `?=` leaves it alone. BUILD_INFO is SOURCE_DATE_EPOCH. GIT_COMMIT
# is empty — there is no .git in a release tarball and no git in the builder — and the
# Makefile omits it rather than embedding a placeholder.
buildtags="seccomp systemd exclude_graphdriver_btrfs containers_image_openpgp grpcnotrace"
make_vars=(PREFIX=/usr ETCDIR=/etc HELPER_BINARIES_DIR=/usr/libexec/podman BUILDTAGS="$buildtags")
make "${make_vars[@]}" bin/podman bin/quadlet bin/rootlessport

install -D -m 755 bin/podman $ROOTFS/usr/bin/podman
install -D -m 755 bin/rootlessport $ROOTFS/usr/libexec/podman/rootlessport
# Quadlet: .container/.network/.volume files under /usr/share/containers/systemd (or
# /etc/containers/systemd) become systemd units at every boot and daemon-reload, which
# is how a container is part of an image rather than something done to a running one.
install -D -m 755 bin/quadlet $ROOTFS/usr/libexec/podman/quadlet
install -d $ROOTFS/usr/lib/systemd/system-generators $ROOTFS/usr/lib/systemd/user-generators
ln -sfn ../../../libexec/podman/quadlet $ROOTFS/usr/lib/systemd/system-generators/podman-system-generator
ln -sfn ../../../libexec/podman/quadlet $ROOTFS/usr/lib/systemd/user-generators/podman-user-generator
install -D -m 644 contrib/tmpfile/podman.conf $ROOTFS/usr/lib/tmpfiles.d/podman.conf

# podman.socket (the Docker-compatible API, for docker and compose clients),
# podman-restart.service (containers with --restart=always, at boot), auto-update, kube@
# and clean-transient. None is enabled: the image enables what it means to run, and
# `systemctl enable --runtime podman.socket` works on a read-only /etc.
make "${make_vars[@]}" DESTDIR=$ROOTFS install.systemd

for lib in libseccomp libc.so; do
    readelf -d $ROOTFS/usr/bin/podman | grep -q "NEEDED.*$lib" || {
        echo "podman: not linked against $lib" >&2
        exit 1
    }
done
