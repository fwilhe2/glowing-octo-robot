# jq: a filter for JSON. `podman inspect`, `crictl`, `nft -j`, `ip -j`, `networkctl
# --json`, `busctl --json` and `bpftool -j` all answer in it, and grep and sed are the
# wrong tools for a nested document. It is a query language in the sense awk is, not an
# interpreter in the sense constraint 5 means: it runs filters over data, the way the
# gawk the base already ships does. C; the release tarball carries its own copy of the
# Oniguruma regex library, linked in statically (build.sh).
VERSION="1.8.2"
PACKAGE="jq-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
URL="https://github.com/jqlang/jq/releases/download/${PACKAGE}/${TARBALL}"
SHA256="71b8d6e8f5fe81f6c6d0d110e3892251f6ce76ed095abd315e26e6e1193af3af"
# jq itself, the decNumber library it carries, and the bundled Oniguruma.
LICENSE="MIT AND ICU AND BSD-2-Clause"
CPE="cpe:2.3:a:jqlang:jq:${VERSION}:*:*:*:*:*:*:*"
# In the debug system extension (docs/guides/debugging.md).
EXTENSION=debug
UPSTREAM_GITHUB="jqlang/jq"
UPSTREAM_SED='s/^jq-//'
