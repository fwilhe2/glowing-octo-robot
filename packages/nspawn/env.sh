# Docker-like management of systemd-nspawn machines: OCI images from a registry, shared
# layers, a root service on the system bus (org.nspawn) that does the work, and a CLI
# that talks to it. https://github.com/nspawn/nspawn
#
# The first Rust package, and the reason the builder has rustc and cargo in it. What made
# that acceptable where runc and youki were not (CLAUDE.md, the crun note): those would
# have been a second toolchain *instead of* a C runtime that already did the job, while
# nothing in C does what this does. Two consequences are handled once, in
# builder/build-package.sh's cargo_build, rather than here:
#
#   - crates. CARGO_CRATES=1 makes tools/fetch-sources.sh download every crate the
#     tarball's Cargo.lock pins and verify each against the lock's sha256; the build
#     unpacks them as a vendored source, because the compile is --network=none.
#   - libgcc_s.so.1, which every Rust binary for *-linux-gnu has in NEEDED and this image
#     does not ship. -lgcc_s is pointed at gcc's static unwinder, libgcc_eh.a, instead.
#
# It links nothing from the image but libc and libm. TLS is rustls on aws-lc, compiled
# in, with the system trust store — /etc/ssl/certs/ca-certificates.crt from
# packages/ca-certificates, found through openssl-probe. zstd is compiled in too.
#
# What it drives at runtime: systemd-nspawn and systemd-machined (packages/systemd), nft
# (packages/nftables) for its bridge, and the NFT_CT/NFT_FIB_IPV4 kernel expressions its
# ruleset uses. Not polkit: there is none, and nspawn authorizes root without asking, so
# root is who may call it. test/nspawn.sh runs a machine.
VERSION="1.9.1"
PACKAGE="nspawn-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
URL="https://github.com/nspawn/nspawn/archive/refs/tags/${VERSION}.tar.gz"
SHA256="a82e97d72738031d0d72403cecb12bae0a116eb7c260a8712d0238ee1c81391e"
CARGO_CRATES=1
UPSTREAM_GITHUB="nspawn/nspawn"
# nspawn itself is MIT OR Apache-2.0. The binary also carries every crate it statically
# links, so this is the conjunction of what those require, read off `cargo tree -e
# normal,build --target <linux>` with the permissive choice taken wherever a crate offers
# one: MIT and Apache-2.0 for most, ISC for rustls-webpki and aws-lc, BSD-3-Clause and
# the remaining ISC/MIT parts inside aws-lc-sys, Unicode-3.0 for the ICU-derived crates
# behind URL parsing, and Zlib for a handful of small ones. Windows- and macOS-only
# crates are in Cargo.lock and downloaded, but never compiled, and are not counted.
LICENSE="(MIT OR Apache-2.0) AND MIT AND Apache-2.0 AND ISC AND BSD-3-Clause AND Unicode-3.0 AND Zlib"
