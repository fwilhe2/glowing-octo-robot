# Just the network backend: the crate also builds a DHCP proxy client and a connection
# tester, which are for macvlan networks with DHCP and for netavark's own test suite.
# The DHCP proxy *server* is a mode of the netavark binary and its systemd units are in
# contrib/; they are not installed, because a macvlan container network is not something
# a VM guest on qemu's user network can use.
#
# protoc comes from the builder (protobuf-compiler), for the DHCP proxy's gRPC types,
# which are compiled into the binary whether or not that mode is used. build.rs reads
# SOURCE_DATE_EPOCH for the build date it embeds.
cargo_vendored --bin netavark

# /usr/libexec/podman is the first place podman looks for its helpers (helper_binaries_dir
# in containers.conf), and netavark is not a command anybody runs directly.
install -D -m 755 target/release/netavark $ROOTFS/usr/libexec/podman/netavark
