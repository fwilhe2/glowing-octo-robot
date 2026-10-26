# crun: podman's default runtime, C, the smallest and fastest to start.
#   systemd  cgroups through sd-bus scopes, as the systemd cgroup driver.
#   seccomp  enforced through packages/libseccomp; checked below.
#   bpf      required, not optional: on cgroup v2 the device controller is a BPF program,
#            and without it every bundle with a device rule (all of them) fails. A raw
#            syscall, no library.
#   criu     off: checkpoint/restore would need libcriu and protobuf-c.
# --disable-libcrun: the static library would otherwise be installed for nothing.
./configure --prefix=/usr \
  --disable-libcrun \
  --disable-criu
make
make install DESTDIR=$ROOTFS

# configure quietly builds without libseccomp, and then ignores every profile.
readelf -d $ROOTFS/usr/bin/crun | grep -q 'libseccomp\.so' || {
    echo "crun: built without libseccomp — seccomp profiles would be ignored" >&2
    exit 1
}
