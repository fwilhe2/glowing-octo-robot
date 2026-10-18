# passt and the pasta link to it, which is the name podman runs. Not the AVX2 builds, an
# x86-only throughput variant chosen at runtime; not passt-repair, which serves live
# migration of a VM's TCP connections; not pesto, its configuration client.
#
# VERSION has to be given — FLFS_VERSION is env.sh's, passed in by root build.sh, as
# packages/tzdata does — because the Makefile asks `git describe` and a snapshot has no
# .git. Its own flags are BASE_CFLAGS, with ours appended, so the sysroot reaches gcc.
make VERSION="$FLFS_VERSION" passt pasta
install -D -m 755 passt $ROOTFS/usr/bin/passt
ln -sfn passt $ROOTFS/usr/bin/pasta
