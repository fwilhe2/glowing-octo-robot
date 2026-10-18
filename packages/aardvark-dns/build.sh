# One binary, started by netavark on a network's bridge address when that network has DNS
# enabled — every network made with `podman network create`, though not the default one.
cargo_vendored --bin aardvark-dns
install -D -m 755 target/release/aardvark-dns $ROOTFS/usr/libexec/podman/aardvark-dns
