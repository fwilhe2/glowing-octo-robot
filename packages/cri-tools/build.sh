# crictl only; critest is the CRI conformance suite, for runtime developers. Static Go.
# The version is stamped where `crictl --version` reads it, as upstream's Makefile does.
CGO_ENABLED=0 go build \
    -ldflags "-s -w -X sigs.k8s.io/cri-tools/pkg/version.Version=v$FLFS_VERSION" \
    -o "$ROOTFS/usr/bin/crictl" ./cmd/crictl

# Where crictl finds CRI-O, in the confext; without it crictl tries a list of sockets
# and warns about each one that is not there.
install -d "$ROOTFS/etc"
cat > "$ROOTFS/etc/crictl.yaml" <<'CONF'
runtime-endpoint: unix:///run/crio/crio.sock
CONF
