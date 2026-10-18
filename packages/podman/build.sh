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
# No libsubid tag, and no rootlessport: rootless podman needs newuidmap/newgidmap from
# shadow-utils, which is not in the image, so a rootless helper would be dead code.
# SQLite is the database podman 6 uses; without the libsqlite3 tag it is the copy
# compiled into the binary, which is one fewer library to ship and keep in step.
#
# GOFLAGS (-mod=vendor -trimpath -buildvcs=false) comes from builder/build-package.sh;
# the Makefile's own `?=` leaves it alone. BUILD_INFO is SOURCE_DATE_EPOCH. GIT_COMMIT
# is empty — there is no .git in a release tarball and no git in the builder — and the
# Makefile omits it rather than embedding a placeholder.
buildtags="seccomp systemd exclude_graphdriver_btrfs containers_image_openpgp grpcnotrace"
make_vars=(PREFIX=/usr ETCDIR=/etc HELPER_BINARIES_DIR=/usr/libexec/podman BUILDTAGS="$buildtags")
make "${make_vars[@]}" bin/podman bin/quadlet

install -D -m 755 bin/podman $ROOTFS/usr/bin/podman
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

# ---------------------------------------------------------------------------------
# The configuration podman cannot start without, written here for the same reason
# packages/openssh writes sshd_config: a package installs its own scaffolding, and this
# goes wherever the binary goes. Everything else is podman's compiled-in default —
# crun, netavark with nftables, overlay storage under /var/lib/containers, journald —
# so there is no containers.conf or storage.conf to keep in step with a version bump.
install -d $ROOTFS/etc/containers

# Signature policy. Without the file podman refuses to pull anything; with it, this is
# what every distribution ships by default: accept unsigned images, refuse nothing.
# Tightening it is a per-registry decision for whoever runs the machine.
cat > $ROOTFS/etc/containers/policy.json <<'JSON'
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ],
    "transports": {
        "docker-daemon": {
            "": [
                {
                    "type": "insecureAcceptAnything"
                }
            ]
        }
    }
}
JSON

# Where a bare `podman pull alpine` looks. One registry, so a short name resolves without
# asking — there is no terminal to ask on when a Quadlet unit pulls at boot — and it is
# the one a short name means everywhere else. Fully qualified names always work.
cat > $ROOTFS/etc/containers/registries.conf <<'CONF'
unqualified-search-registries = ["docker.io"]
short-name-mode = "permissive"
CONF
